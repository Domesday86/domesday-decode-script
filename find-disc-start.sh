#!/usr/bin/env bash
#
# Find the file frame holding a given picture number in a LaserDisc capture.
#
# This replaces ld-decode's own ld-find-start, which looks for the first run of
# 30 contiguous CAV addresses scanning forward from the head of the capture. On
# a capture whose spin-up region happens to yield a short run of consecutive
# addresses that test passes inside the spin-up, and on a capture whose VBI
# reads through spin-up are intermittent it never passes at all -- so it can
# answer confidently but wrongly, or scan the whole image and fail. Both cases
# occur on the calibration discs.
#
# Instead: jump well past spin-up into settled playback, read the picture number
# there, and use it to compute where the target frame must be. Because a
# capture-relative file frame is a nominal-length approximation, the file-frame
# to picture-number offset drifts slightly across the disc, so the estimate is
# re-probed until it lands on the target exactly.
#
# CAV and CLV are both handled, because ld-decode reports a picture number for
# either: on CAV it is the address in the VBI, and on CLV it derives one from
# the timecode. Both count up by one a frame, which is all the arithmetic here
# needs. The exception is a pre-1985 "early CLV" disc, whose timecode carries
# only the minute and so yields no picture number at all; there is no target to
# converge on there, and the search reports that it found none.
#
set -euo pipefail

STANDARD=""
PROBE=800          # first probe, in file frames; well past spin-up
TARGET=1           # picture number to locate
MAX_PROBES=8
THREADS=4
VERBOSE=0
LEAD_IN=""
REPORT=0
INFILE=""

usage() {
  cat <<EOF
Usage: ${0##*/} --pal|--ntsc [options] infile

Print the capture file frame holding picture number --target.

The source may be CAV or CLV: on CAV the picture number is the VBI address,
and on CLV it is the one ld-decode derives from the timecode.

With --lead-in, print an ld-decode --start frame that keeps at least N frames
of lead-in *in the output*. That is not simply target-N: ld-decode's CVBS
writer discards head fields until a first field with fieldPhaseID 1, so a start
off that colour-sequence lattice loses the frames before the first aligned one.

A capture that begins mid-disc can have no aligned frame at or before the
target at all. There is then no start that writes the frames in front of the
first aligned one, so the earliest-opening start is used and --report's opens
field says where the output really begins.

Options:
      --pal, --ntsc     source standard (required)
      --probe N         first probe frame (default: $PROBE)
      --target N        picture number to locate (default: $TARGET)
      --lead-in N       print a colour-sequence-aligned start keeping N
                        lead-in frames, instead of the target frame
      --report          print "content=<n> leadin=<n> start=<n> opens=<n>"
                        instead, where opens is the file frame the output
                        actually begins on (see --lead-in)
      --max-probes N    give up after this many probes (default: $MAX_PROBES)
  -t, --threads N       ld-decode threads per probe (default: $THREADS)
  -v, --verbose         show each probe on stderr
  -h, --help            this message
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }
note() { [ "$VERBOSE" = 1 ] && printf '%s: %s\n' "${0##*/}" "$*" >&2; return 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pal|--PAL|-p)   STANDARD=pal; shift ;;
    --ntsc|--NTSC|-n) STANDARD=ntsc; shift ;;
    --probe)          PROBE="${2:?--probe needs a frame}"; shift 2 ;;
    --target)         TARGET="${2:?--target needs a frame}"; shift 2 ;;
    --lead-in)        LEAD_IN="${2:?--lead-in needs a count}"; shift 2 ;;
    --report)         REPORT=1; shift ;;
    --max-probes)     MAX_PROBES="${2:?--max-probes needs a count}"; shift 2 ;;
    -t|--threads)     THREADS="${2:?--threads needs a count}"; shift 2 ;;
    -v|--verbose)     VERBOSE=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    -*)               die "unknown option: $1" ;;
    *)                [ -z "$INFILE" ] || die "only one input file"; INFILE="$1"; shift ;;
  esac
done

[ -n "$STANDARD" ] || { usage >&2; die "--pal or --ntsc is required"; }
[ -n "$INFILE" ] || { usage >&2; die "no input file"; }
[ -f "$INFILE" ] || die "no such file: $INFILE"
for v in PROBE TARGET MAX_PROBES THREADS; do
  case "${!v}" in *[!0-9]*|"") die "--${v,,} must be a number" ;; esac
done
if [ -n "$LEAD_IN" ]; then
  case "$LEAD_IN" in *[!0-9]*) die "--lead-in must be a number" ;; esac
fi
command -v ld-decode >/dev/null 2>&1 || die "ld-decode not on PATH (run: nix develop)"
command -v python3 >/dev/null 2>&1 || die "python3 not on PATH (run: nix develop)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# probe <start> [length]
#
# Decode <length> frames from <start> and echo one "<file frame> <picture>" line
# per reading, in file order, where <picture> is the picture number or "leadin";
# a probe that reads nothing usable echoes the single line "<start> none". A
# reading is only trusted when two successive frames advance together -- a lone
# address in a spin-up region can be a misread, and it is exactly that kind of
# misread that sends the arithmetic to the wrong part of the disc. That costs
# the last frame of every probe, which can confirm its predecessor but has
# nothing after it to confirm it in turn.
#
# Note that ld-decode's --start is the frame it seeks to, and the first frame it
# then reports is the one after: a probe from <start> reads file frames
# <start>+1 onwards. The caller aims at a file frame, so it converts (see
# probe_start_for).
#
# Only the VBI readings ld-decode prints as it decodes are wanted here, and
# those are the same whichever writer runs -- but the output format is named
# anyway rather than left to the default, which has flipped between branch
# builds, so a probe stays the cheap CVBS run it is meant to be.
#
# ld-decode labels each reading with the disc format it decoded it from, and
# puts the CLV timecode ahead of the picture number:
#
#   File Frame 801: CAV Frame #39801
#   File Frame 205: CLV Timecode 0:00.02 Frame #2
#   File Frame 203: CAV Lead In
#
# so both labels are accepted and the timecode, if present, is stepped over --
# the picture number after it is what the search converges on. Lead-in carries
# no format (nothing has been decoded yet to tell CAV from CLV), so it turns up
# labelled CAV even at the head of a CLV capture; that is why it is matched
# under either label rather than only its own disc's.
probe() {
  local frame="$1" len="${2:-3}" raw out=""
  local -a ff=() cav=()

  raw=$(ld-decode "--$STANDARD" --cvbs --start "$frame" --length "$len" --threads "$THREADS" \
          "$INFILE" "$WORK/probe" 2>&1 || true)

  while read -r f c; do
    ff+=("$f"); cav+=("$c")
  done < <(printf '%s\n' "$raw" \
    | grep -oE "File Frame [0-9]+: C[AL]V (Timecode [^ ]+ )?(Frame #[0-9]+|Lead In)" \
    | sed -E -e 's/File Frame ([0-9]+): C[AL]V (Timecode [^ ]+ )?Frame #([0-9]+)/\1 \3/' \
             -e 's/File Frame ([0-9]+): C[AL]V Lead In/\1 leadin/')

  # The distance between the --start asked for and the first file frame the run
  # actually reports. It is a property of the capture, not a constant (see
  # cvbs_first_frame), and the caller needs it to aim a start at a frame.
  [ "${#ff[@]}" -eq 0 ] || printf '%s\n' "$(( ff[0] - frame ))" > "$WORK/offset"

  local i
  for (( i = 0; i + 1 < ${#ff[@]}; i++ )); do
    if [ "${cav[i]}" = leadin ]; then
      # Lead-in is a real, meaningful reading: it says the target is ahead.
      if [ "${cav[i+1]}" = leadin ] && [ "${ff[i+1]}" -eq $(( ff[i] + 1 )) ]; then
        out+="${ff[i]} leadin"$'\n'
      fi
      continue
    fi
    [ "${cav[i+1]}" = leadin ] && continue
    # The next picture may be one file frame on or two: on some captures the
    # file frame ld-decode reports is a nominal-length estimate that now and
    # then steps by two, then holds (Apple Visual Almanac DS3 side A runs
    # 439 #1, 441 #2, 441 #3), so it never advances by one twice running.
    if [ "${ff[i+1]}" -gt "${ff[i]}" ] && [ "${ff[i+1]}" -le $(( ff[i] + 2 )) ] && \
       [ "${cav[i+1]}" -eq $(( cav[i] + 1 )) ]; then
      out+="${ff[i]} ${cav[i]}"$'\n'
    fi
  done

  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s none\n' "$frame"; fi
}

# probe_start_for <file frame> : a --start that puts <file frame> inside the
# probe window, with a frame either side of it.
#
# A probe reads from <start>+1, so aiming straight at a file frame would read
# past it and the search would never see the frame it is converging on. Two
# frames back, with a window of four, leaves the estimate's neighbours readable
# too -- so when the file-frame to picture-number offset has drifted by one
# between the probe point and the target, the target is still in this probe and
# the search converges here rather than going round again.
PROBE_WINDOW=4
probe_start_for() {
  local f=$(( $1 - 2 ))
  [ "$f" -ge 0 ] || f=0
  printf '%s\n' "$f"
}

# ld-decode's CVBS writer opens the file on the first field carrying
# fieldPhaseID 1 -- the conventional colour-sequence position -- and discards
# everything before it. A start on any other phase silently loses every frame
# up to the next qualifying one, which is how the lead-in goes missing.
#
# Each file frame has one true phase ID, but the sequence through spin-up and
# lead-in is irregular: the player is still settling onto the disc, so fields
# are repeated and skipped and the qualifying frames are scattered rather than
# falling on a fixed lattice. Predicting them is therefore unsafe -- so test
# instead: decode a short CVBS run at each candidate and read back which frame
# the writer actually opened the file on.

MAX_LEADIN_SEARCH=8

# Frames to read past the content frame when measuring where the writer opens.
# The measurement only works if the window reaches the first frame the writer
# will accept, and at the head of a capture that can be several frames past the
# content frame -- so the window always runs well beyond it rather than stopping
# at the candidate's own lead-in.
MEASURE_TAIL=8

# cvbs_first_frame <start> <length> : echo "<first file frame written> <frames
# written>" for a CVBS run of <length> frames from <start>.
#
# The writer, once it opens, keeps every remaining frame, so the frames it wrote
# are the last <wrote> of the window and the first of them is <last> - <wrote> +
# 1. The window's last file frame is read back out of the run rather than
# computed from --start, because the two do not sit at a fixed distance: the
# file frame ld-decode reports for a given --start depends on where the seek
# lands in the capture, and it differs between captures -- on the calibration
# discs a run from --start 800 reports file frame 800 first, and on the Domesday
# captures the same start reports 801. Reading the number back makes the
# measurement independent of that.
cvbs_first_frame() {
  local s="$1" len="$2" wrote last
  ld-decode "--$STANDARD" --cvbs --start "$s" --length "$len" \
    --threads "$THREADS" "$INFILE" "$WORK/cvbs" >/dev/null 2>&1 || true
  wrote=$(grep -o 'wrote [0-9]* frames' "$WORK/cvbs.log" 2>/dev/null \
          | grep -o '[0-9]*' | head -1)
  [ -n "$wrote" ] && [ "$wrote" -gt 0 ] || return 1
  last=$(grep -oE 'File Frame [0-9]+:' "$WORK/cvbs.log" 2>/dev/null \
         | grep -oE '[0-9]+' | sort -n | tail -1)
  [ -n "$last" ] || return 1
  printf '%s %s\n' "$(( last - wrote + 1 ))" "$wrote"
}

# lead_in_start <content frame> <lead-in frames wanted>
#
# Sets START_FRAME to the --start to use and OPENS_AT to the file frame the
# output will then begin on. Two values because they are not the same fact: the
# start is what ld-decode is told, the opening frame is what the writer did with
# it, and only the second says how much lead-in was actually kept.
#
# Candidates are tried from f1 - lead outwards. Earlier starts first, which keep
# more than the lead-in asked for; then, only if none of those aligns, later
# ones, which keep less. The second pass is what makes a capture that begins at
# or near the target frame work at all -- a side captured in two passes picks up
# mid-disc with no spin-up and no lead-in in front of it, so there is nothing
# before f1 to align on and the best available start is f1 itself. It stops at
# k = 0, so a start is never chosen past the content frame.
#
# A candidate is accepted when the writer kept the whole window, since that is
# the start opening the output exactly where it was aimed. If no candidate does
# -- which happens when the capture's head is off the colour-sequence lattice,
# so the first frame the writer will accept is already past f1 -- the candidate
# that opens earliest is taken instead. That start loses the content frames
# before the writer's first aligned one, but they cannot be written from any
# start, so the choice is between losing them and decoding nothing; OPENS_AT
# then reports where the output really begins so the caller can say so.
START_FRAME=""
OPENS_AT=""
PROBE_OFFSET=0
lead_in_start() {
  local f1="$1" lead="$2" k s first wrote len measured
  local best="" best_first=""
  local -a candidates=()

  START_FRAME=""; OPENS_AT=""

  # A start is aimed at a frame by subtracting the seek offset, so the first
  # candidate is the one that lands on f1 - lead rather than one that merely
  # names it. Without this a capture whose runs report a frame ahead of their
  # --start opens the output on the content frame itself and keeps no lead-in.
  for (( k = lead; k <= lead + MAX_LEADIN_SEARCH; k++ )); do
    (( f1 - k - PROBE_OFFSET >= 0 )) && candidates+=( "$(( f1 - k - PROBE_OFFSET ))" )
  done
  for (( k = lead - 1; k >= 0; k-- )); do
    (( f1 - k - PROBE_OFFSET >= 0 )) && candidates+=( "$(( f1 - k - PROBE_OFFSET ))" )
  done

  for s in "${candidates[@]}"; do
    len=$(( f1 + MEASURE_TAIL - s ))
    [ "$len" -ge 2 ] || len=2
    if ! measured=$(cvbs_first_frame "$s" "$len"); then
      note "lead-in trial: start $s -> writer kept nothing in $len frame(s)"
      continue
    fi
    read -r first wrote <<< "$measured"
    # Keeping the whole window is the test, not the frame number: it says the
    # writer opened on the very first frame the start reached, which is what
    # aiming the start at a frame is supposed to achieve.
    if [ "$wrote" -eq "$len" ]; then
      note "lead-in trial: start $s -> output opens at file frame $first (accepted)"
      START_FRAME="$s"; OPENS_AT="$first"
      return 0
    fi
    note "lead-in trial: start $s -> writer skipped ahead to file frame $first"
    if [ -z "$best_first" ] || [ "$first" -lt "$best_first" ]; then
      best="$s"; best_first="$first"
    fi
  done

  [ -n "$best" ] || return 1
  note "no start opens the output where it was aimed; taking start $best, which \
opens earliest, at file frame $best_first"
  START_FRAME="$best"; OPENS_AT="$best_first"
  return 0
}

visited=" "
widened=" "
WIDE_WINDOW=12
frame="$PROBE"
length=3
attempt=0
before_start=""
landed=""

while [ "$attempt" -lt "$MAX_PROBES" ]; do
  attempt=$(( attempt + 1 ))

  readings=$(probe "$frame" "$length")
  # probe runs in a command substitution, so it hands the offset back through a
  # file rather than a variable the subshell could not export.
  [ -s "$WORK/offset" ] && PROBE_OFFSET=$(cat "$WORK/offset")
  note "probe $attempt: start $frame (offset $PROBE_OFFSET) -> $(printf '%s' "$readings" | paste -sd'; ' -)"

  # The target may be anywhere in the window, not only at its head, so the whole
  # probe is searched before its first reading is used to estimate again.
  hit=$(printf '%s\n' "$readings" | awk -v t="$TARGET" '$2 == t { print $1; exit }')

  if [ -z "$hit" ]; then
    read -r landed reading <<< "$(printf '%s\n' "$readings" | head -1)"

    case "$reading" in
      none)
        # Still in spin-up, or unreadable here. Push deeper into the capture.
        frame=$(( frame + PROBE ))
        length=3
        continue
        ;;
      leadin)
        # Before the programme. Creep forward; lead-in is only ever a few frames.
        frame=$(( landed + 5 ))
        length=3
        continue
        ;;
    esac
  fi

  if [ -n "$hit" ]; then
    landed="$hit"
    note "converged after $attempt probe(s)"

    if [ -n "$LEAD_IN" ]; then
      lead_in_start "$landed" "$LEAD_IN" || die \
"no start between file frame $(( landed - LEAD_IN - MAX_LEADIN_SEARCH )) and \
$landed got the writer to keep anything, so there is no start that decodes \
picture #$TARGET at file frame $landed"
      start="$START_FRAME"
      if [ "$OPENS_AT" -le "$landed" ]; then
        note "start $start opens the output at file frame $OPENS_AT, \
$(( landed - OPENS_AT )) frame(s) before picture #$TARGET"
      else
        note "start $start opens the output at file frame $OPENS_AT, which is \
$(( OPENS_AT - landed )) frame(s) after picture #$TARGET: the frames before it \
are off the colour sequence and no start can write them"
      fi
    fi

    if [ "$REPORT" = 1 ]; then
      if [ -n "$LEAD_IN" ]; then
        printf 'content=%s leadin=%s start=%s opens=%s\n' \
          "$landed" "$LEAD_IN" "$start" "$OPENS_AT"
      else
        printf 'content=%s\n' "$landed"
      fi
    elif [ -n "$LEAD_IN" ]; then
      printf '%s\n' "$start"
    else
      printf '%s\n' "$landed"
    fi
    exit 0
  fi

  next=$(( landed - (reading - TARGET) ))
  if [ "$next" -lt 1 ]; then
    # The estimate points before the head of the capture. Either the probe
    # landed in spin-up, where addresses are not playback-rate, or the capture
    # genuinely starts after the target. Push deeper and let a settled reading
    # decide, rather than clamping to the head and inventing an answer.
    note "estimate $next is before the capture; probing deeper"
    before_start="file frame $landed holds picture #$reading, which puts picture #$TARGET at $next"
    frame=$(( landed + PROBE ))
    length=3
    continue
  fi

  # An estimate made twice means the window missed the target, and the next
  # probe would only miss it again: the player repeated a picture just after
  # it, say, so the window holds that one picture throughout (Apple Visual
  # Almanac DS2 side A holds #3 for four frames, two after #1). So it is
  # probed once more in a window of WIDE_WINDOW frames around it before the
  # search gives up.
  case "$visited" in
    *" $next "*)
      case "$widened" in
        *" $next "*)
          die "start search kept estimating file frame $next without reading \
picture #$TARGET there; probe by hand with: \
ld-decode --$STANDARD --start $(( next - WIDE_WINDOW / 2 )) --length $WIDE_WINDOW"
          ;;
      esac
      note "estimate $next made again; probing $WIDE_WINDOW frames around it"
      widened="$widened$next "
      frame=$(( next - WIDE_WINDOW / 2 ))
      [ "$frame" -ge 0 ] || frame=0
      length=$WIDE_WINDOW
      continue
      ;;
  esac
  visited="$visited$next "
  frame=$(probe_start_for "$next")
  length=$PROBE_WINDOW
done

if [ -n "$before_start" ]; then
  die "picture #$TARGET appears to be before the start of this capture \
($before_start)"
fi
die "gave up after $MAX_PROBES probes without finding picture #$TARGET"
