#!/usr/bin/env bash
#
# Find the file frame holding a given CAV picture number in a LaserDisc capture.
#
# This replaces ld-decode's own ld-find-start, which looks for the first run of
# 30 contiguous CAV addresses scanning forward from the head of the capture. On
# a capture whose spin-up region happens to yield a short run of consecutive
# addresses that test passes inside the spin-up, and on a capture whose VBI
# reads through spin-up are intermittent it never passes at all -- so it can
# answer confidently but wrongly, or scan the whole image and fail. Both cases
# occur on the calibration discs.
#
# Instead: jump well past spin-up into settled playback, read the CAV picture
# number there, and use it to compute where the target frame must be. Because a
# capture-relative file frame is a nominal-length approximation, the file-frame
# to picture-number offset drifts slightly across the disc, so the estimate is
# re-probed until it lands on the target exactly.
#
set -euo pipefail

STANDARD=""
PROBE=800          # first probe, in file frames; well past spin-up
TARGET=1           # CAV picture number to locate
MAX_PROBES=8
THREADS=4
VERBOSE=0
LEAD_IN=""
REPORT=0
INFILE=""

usage() {
  cat <<EOF
Usage: ${0##*/} --pal|--ntsc [options] infile

Print the capture file frame holding CAV picture number --target.

With --lead-in, print an ld-decode --start frame that keeps at least N frames
of lead-in *in the output*. That is not simply target-N: ld-decode's CVBS
writer discards head fields until a first field with fieldPhaseID 1, so a start
off that colour-sequence lattice loses the frames before the first aligned one.

Options:
      --pal, --ntsc     source standard (required)
      --probe N         first probe frame (default: $PROBE)
      --target N        CAV picture number to locate (default: $TARGET)
      --lead-in N       print a colour-sequence-aligned start keeping N
                        lead-in frames, instead of the target frame
      --report          print "content=<n> leadin=<n> start=<n>" instead
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

# probe <frame>
#
# Decode three frames at <frame> and echo "<file frame> <cav>", where <cav> is
# the picture number, "leadin", or "none". A reading is only trusted when two
# successive frames advance together -- a lone address in a spin-up region can
# be a misread, and it is exactly that kind of misread that sends the
# arithmetic to the wrong part of the disc.
probe() {
  local frame="$1" raw
  local -a ff=() cav=()

  raw=$(ld-decode "--$STANDARD" --start "$frame" --length 3 --threads "$THREADS" \
          "$INFILE" "$WORK/probe" 2>&1 || true)

  while read -r f c; do
    ff+=("$f"); cav+=("$c")
  done < <(printf '%s\n' "$raw" \
    | grep -oE "File Frame [0-9]+: CAV (Frame #[0-9]+|Lead In)" \
    | sed -e 's/File Frame \([0-9]*\): CAV Frame #\([0-9]*\)/\1 \2/' \
          -e 's/File Frame \([0-9]*\): CAV Lead In/\1 leadin/')

  local i
  for (( i = 0; i + 1 < ${#ff[@]}; i++ )); do
    if [ "${cav[i]}" = leadin ]; then
      # Lead-in is a real, meaningful reading: it says the target is ahead.
      if [ "${cav[i+1]}" = leadin ] && [ "${ff[i+1]}" -eq $(( ff[i] + 1 )) ]; then
        printf '%s leadin\n' "${ff[i]}"; return 0
      fi
      continue
    fi
    [ "${cav[i+1]}" = leadin ] && continue
    if [ "${ff[i+1]}" -eq $(( ff[i] + 1 )) ] && \
       [ "${cav[i+1]}" -eq $(( cav[i] + 1 )) ]; then
      printf '%s %s\n' "${ff[i]}" "${cav[i]}"; return 0
    fi
  done

  printf '%s none\n' "$frame"
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

# cvbs_first_frame <start> <length> : file frame the writer opened the file on
cvbs_first_frame() {
  local s="$1" len="$2" wrote
  ld-decode "--$STANDARD" --cvbs --start "$s" --length "$len" \
    --threads "$THREADS" "$INFILE" "$WORK/cvbs" >/dev/null 2>&1 || true
  wrote=$(grep -o 'wrote [0-9]* frames' "$WORK/cvbs.log" 2>/dev/null \
          | grep -o '[0-9]*' | head -1)
  [ -n "$wrote" ] && [ "$wrote" -gt 0 ] || return 1
  printf '%s\n' "$(( s + len - wrote ))"
}

# lead_in_start <content frame> <lead-in frames wanted>
lead_in_start() {
  local f1="$1" lead="$2" k s first
  for (( k = lead; k <= lead + MAX_LEADIN_SEARCH; k++ )); do
    s=$(( f1 - k ))
    [ "$s" -ge 0 ] || break
    first=$(cvbs_first_frame "$s" $(( k + 2 ))) || continue
    if [ "$first" -eq "$s" ]; then
      note "lead-in trial: start $s -> output opens at $first (accepted)"
      printf '%s\n' "$s"
      return 0
    fi
    note "lead-in trial: start $s -> writer skipped ahead to $first"
  done
  return 1
}

visited=" "
frame="$PROBE"
attempt=0
before_start=""

while [ "$attempt" -lt "$MAX_PROBES" ]; do
  attempt=$(( attempt + 1 ))

  read -r landed reading <<< "$(probe "$frame")"
  note "probe $attempt: frame $frame -> file frame $landed, CAV $reading"

  case "$reading" in
    none)
      # Still in spin-up, or unreadable here. Push deeper into the capture.
      frame=$(( frame + PROBE ))
      continue
      ;;
    leadin)
      # Before the programme. Creep forward; lead-in is only ever a few frames.
      frame=$(( landed + 5 ))
      continue
      ;;
  esac

  if [ "$reading" -eq "$TARGET" ]; then
    note "converged after $attempt probe(s)"

    if [ -n "$LEAD_IN" ]; then
      start=$(lead_in_start "$landed" "$LEAD_IN") || die \
"could not find a start that keeps $LEAD_IN lead-in frame(s) in the output \
within $MAX_LEADIN_SEARCH frames of file frame $(( landed - LEAD_IN ))"
      note "start $start puts $(( landed - start )) frame(s) before CAV #$TARGET in the output"
    fi

    if [ "$REPORT" = 1 ]; then
      if [ -n "$LEAD_IN" ]; then
        printf 'content=%s leadin=%s start=%s\n' "$landed" "$LEAD_IN" "$start"
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
  if [ "$next" -lt 0 ]; then
    # The estimate points before the head of the capture. Either the probe
    # landed in spin-up, where addresses are not playback-rate, or the capture
    # genuinely starts after the target. Push deeper and let a settled reading
    # decide, rather than clamping to 0 and inventing an answer.
    note "estimate $next is before the capture; probing deeper"
    before_start="file frame $landed holds CAV #$reading, which puts CAV #$TARGET at $next"
    frame=$(( landed + PROBE ))
    continue
  fi

  case "$visited" in
    *" $next "*)
      die "start search oscillated around file frame $next without landing on \
CAV #$TARGET; probe by hand with: ld-decode --$STANDARD --start $next --length 3"
      ;;
  esac
  visited="$visited$next "
  frame="$next"
done

if [ -n "$before_start" ]; then
  die "CAV frame $TARGET appears to be before the start of this capture \
($before_start)"
fi
die "gave up after $MAX_PROBES probes without finding CAV #$TARGET"
