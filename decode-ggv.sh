#!/usr/bin/env bash
#
# Decode the PAL and NTSC LaserDisc calibration discs through ld-decode.
#
# Each disc is decoded to CVBS (<name>.cvbs + <name>.meta) starting a
# configurable number of lead-in frames before CAV picture number 1, so the
# disc-spin-up region at the head of the capture is skipped.
#
# One decode does not fill a modern machine. ld-decode fans block demodulation
# out to worker processes, but the decode loop that consumes them is strictly
# in-order on the main thread, so the workers spend most of their time waiting
# on it. Measured on a 16-core host, on PAL Domesday sides -- the engine is the
# same one these discs go through: a single decode at its best setting keeps
# about five of the sixteen cores busy, and workers added past that draw CPU
# without returning frames -- 38% of the host at ten workers against 32% at
# four, for 7% fewer frames. The capture is read over a 10Gb link with iowait
# under 0.5%, so it is that serial loop, not I/O, that bounds one decode.
#
# What bounds the host is reached at about two decodes. Four workers per decode
# is the measured peak, and past it throughput falls away rather than levelling
# off: ld-decode's own choice of ten is 7% slower than four for 20% more CPU. A
# second concurrent decode is worth about 8.6% over running the two in turn; a
# third is worth nothing at all, and takes the host to 90% CPU to return it.
# Something shared, most likely memory bandwidth, is the real ceiling. The
# measurements are in docs/performance.md.
#
# Decodes are filed under the ld-decode commit that produced them, so decoding a
# disc again with a different build lands beside the earlier decode instead of
# on top of it: only a re-run of the same commit can overwrite, and only then
# with --force.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIND_START="$SELF_DIR/find-disc-start.sh"

# ---------------------------------------------------------------------------
# Configuration (override with environment variables or the flags below)
# ---------------------------------------------------------------------------

# Root of the capture library. Disc source paths are relative to this.
LIBRARY="${DD_LIBRARY:-/Volumes/Domesday86_Library}"

# Root of the decode output tree. Decodes are filed under
# <root>/<disc id>/<decoder>/, where <decoder> names the ld-decode build.
OUTPUT="${DD_OUTPUT:-/Volumes/Domesday86_Decodes/domesday-decode-script}"

# Name of the decoder directory. Empty means work it out from flake.lock (see
# "identifying the decoder" below); set it to label a decode by hand.
DECODER="${DD_DECODER:-}"

# Check that the ld-decode on PATH really is the build flake.lock pins before
# writing a decode under that commit's name. 0 skips the check.
VERIFY_DECODER="${DD_VERIFY_DECODER:-1}"

# Frames to decode per disc: a number, or "all" for the whole side.
FRAMES="${DD_FRAMES:-1000}"

# Frames of lead-in to include before CAV picture number 1.
LEAD_IN="${DD_LEAD_IN:-1}"

# Where the start search first probes, in file frames. This needs to be past
# disc spin-up and into settled playback; 800 clears it on these captures.
PROBE="${DD_PROBE:-800}"

# Discs to decode concurrently. One decode cannot saturate the machine (see the
# note at the top), and two is where the machine tops out: on the 16-core test
# host -j 2 finished 8.6% ahead of the same two decodes run in turn, while -j 3
# finished level with three in turn. Its other value is keeping every disc
# advancing, so one that crawls through damaged media does not hold up the rest
# of the queue.
JOBS="${DD_JOBS:-1}"

# ld-decode worker threads (0 = auto, divided between concurrent jobs).
THREADS="${DD_THREADS:-0}"

# What auto aims for, per decode. Measured, not guessed -- see
# docs/performance.md.
DECODE_THREADS_TARGET="${DD_THREADS_TARGET:-4}"

# Write .tbc instead of CVBS.
USE_CVBS="${DD_CVBS:-1}"

FORCE=0
DRY_RUN=0
REFRESH_START=0
START_OVERRIDE=""

# ---------------------------------------------------------------------------
# Disc table: id | standard | source path relative to LIBRARY
# ---------------------------------------------------------------------------

DISCS=(
  "GGV1011|PAL|Calibration/GGV1011/GGV1011_CAV_PAL_side1_DD1_2019-06-12_20-18-21.ldf"
  "GGV1069|NTSC|Calibration/GGV1069/Pioneer GGV1069_CAV_NTSC_side1_dup1_2019-09-12_21-11-38.ldf"
)

# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [disc ...]

Decode the calibration discs through ld-decode. With no disc named, every disc
in the table is decoded.

Options:
  -l, --library DIR     capture library root (default: $LIBRARY)
  -o, --output DIR      decode output root (default: $OUTPUT)
      --decoder NAME    decoder directory name (default: from flake.lock)
      --no-verify-decoder
                        skip the check that ld-decode matches flake.lock
  -f, --frames N|all    frames to decode per disc (default: $FRAMES)
      --lead-in N       frames of lead-in to keep before CAV #1 (default: $LEAD_IN)
      --probe N         first frame the start search probes (default: $PROBE)
      --start N         force the ld-decode --start frame (single disc only)
      --refresh-start   re-run the start search, ignoring the cached value
  -j, --jobs N          decode N discs concurrently (default: $JOBS)
  -t, --threads N       ld-decode worker threads per decode, 0 = auto
                        (default: $THREADS; auto aims for $DECODE_THREADS_TARGET each, shared between --jobs)
      --tbc             write .tbc output instead of CVBS
      --force           overwrite an existing decode
  -n, --dry-run         resolve starts and print the commands, decode nothing
      --list            list the discs in the table and exit
  -h, --help            this message

Environment: DD_LIBRARY DD_OUTPUT DD_DECODER DD_VERIFY_DECODER DD_FRAMES
             DD_LEAD_IN DD_PROBE DD_JOBS DD_THREADS DD_THREADS_TARGET DD_CVBS

Decodes go to <output>/<disc id>/<decoder>/<capture basename>.*, where
<decoder> is the ld-decode commit flake.lock pins. Decoding a disc again after
updating ld-decode therefore writes a new directory rather than overwriting the
earlier decode; re-running the same commit still needs --force.

A single decode uses only about a third of a 16-core machine, because
ld-decode's decode loop is serial and its demodulation workers wait on it.
--threads will not recover the rest: four workers per decode is the measured
peak and more is slower. -j 2 does recover some, finishing about 8.6% ahead of
decoding the two discs in turn, but -j 3 finishes level with three in turn. So
reach for -j to keep every disc advancing as much as to go faster, and do not
expect a third job to pay. With -j above 1 the console progress of each decode
is prefixed with its disc id, since the decodes interleave.

ld-decode writes its own timestamped progress log to <output>.log for each
disc; tail that to follow a long decode.

Examples:
  ${0##*/} --frames 2                       # quick smoke test of both discs
  ${0##*/} --frames all GGV1069             # full decode of the NTSC disc
  ${0##*/} --frames all -j 2                # both discs at once
  ${0##*/} -l /mnt/library -o /mnt/decodes  # different library and output roots
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }
log() { printf '\n== %s\n' "$*"; }

# --- ld-decode output ------------------------------------------------------
#
# ld-decode has no non-interactive output mode: it draws progress with carriage
# returns and no newlines whatever it is writing to, so a redirected console
# stream ends up as one enormous line that tail, grep and less are all useless
# on. Pass it through unchanged on a terminal, where redrawing in place is what
# you want, and split it into lines when it is not.
#
# Concurrent decodes are always split into lines and prefixed with the disc id:
# several streams redrawing in place on one terminal would overwrite each other,
# and unlabelled interleaved progress could not be told apart.
#
# This is only the console copy. ld-decode already keeps a proper timestamped
# log of its own next to the decode, at <outbase>.log.

run_ld_decode() {
  local prefix="$1"; shift
  if [ -z "$prefix" ] && [ -t 1 ]; then
    "$@"
  else
    "$@" 2>&1 | awk -v p="$prefix" '{ sub(/[[:space:]]+$/, "")
                                      if (length($0)) { print p $0; fflush() } }' RS='[\r\n]'
  fi
}

# Prefix a block of our own output the same way, so a disc's banner stays with
# its progress when decodes interleave.
prefixed() { awk -v p="$1" '{ print p $0 }'; }

# --- argument parsing ------------------------------------------------------

wanted=()
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--library)    LIBRARY="${2:?--library needs a directory}"; shift 2 ;;
    -o|--output)     OUTPUT="${2:?--output needs a directory}"; shift 2 ;;
    --decoder)       DECODER="${2:?--decoder needs a name}"; shift 2 ;;
    --no-verify-decoder) VERIFY_DECODER=0; shift ;;
    -f|--frames)     FRAMES="${2:?--frames needs a value}"; shift 2 ;;
    --lead-in)       LEAD_IN="${2:?--lead-in needs a value}"; shift 2 ;;
    --probe)         PROBE="${2:?--probe needs a frame}"; shift 2 ;;
    --start)         START_OVERRIDE="${2:?--start needs a frame}"; shift 2 ;;
    --refresh-start) REFRESH_START=1; shift ;;
    -j|--jobs)       JOBS="${2:?--jobs needs a count}"; shift 2 ;;
    -t|--threads)    THREADS="${2:?--threads needs a value}"; shift 2 ;;
    --tbc)           USE_CVBS=0; shift ;;
    --cvbs)          USE_CVBS=1; shift ;;
    --force)         FORCE=1; shift ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    --list)          for d in "${DISCS[@]}"; do
                       IFS='|' read -r id std rel <<< "$d"
                       printf '%-10s %-5s %s\n' "$id" "$std" "$rel"
                     done
                     exit 0 ;;
    -h|--help)       usage; exit 0 ;;
    -*)              die "unknown option: $1" ;;
    *)               wanted+=("$1"); shift ;;
  esac
done

case "$FRAMES" in
  all|ALL) FRAMES=all ;;
  *[!0-9]*|"") die "--frames must be a number or \"all\" (got \"$FRAMES\")" ;;
esac
case "$LEAD_IN" in *[!0-9]*|"") die "--lead-in must be a number" ;; esac
case "$PROBE" in *[!0-9]*|"") die "--probe must be a number" ;; esac
case "$THREADS" in *[!0-9]*|"") die "--threads must be a number" ;; esac
case "$JOBS" in *[!0-9]*|"") die "--jobs must be a number" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be at least 1"
if [ -n "$START_OVERRIDE" ]; then
  case "$START_OVERRIDE" in *[!0-9]*) die "--start must be a frame number" ;; esac
  [ "${#wanted[@]}" -eq 1 ] || die "--start applies to one disc; name exactly one"
fi

command -v ld-decode >/dev/null 2>&1 || die "ld-decode not on PATH (run: nix develop)"
[ -x "$FIND_START" ] || die "missing helper: $FIND_START"
[ -d "$LIBRARY" ] || die "library not found: $LIBRARY"

# --- identifying the decoder -----------------------------------------------
#
# A decode is only meaningful alongside the ld-decode that produced it: these
# are pre-release branch builds, and two of them will not agree frame for frame.
# So each decode is filed under the commit that made it, and a decode with a
# different ld-decode lands beside the old one instead of overwriting it.
#
# The name is the short revision flake.lock pins, since that is the build
# `nix develop` puts on PATH. But that is a statement about the flake, not about
# the ld-decode actually running: a shell entered before `nix flake update` (or
# before pulling a new lock) still holds the previous build, and would file
# hours of decoding under a commit that did not produce it. So the flake is
# evaluated -- evaluation only, it never builds -- and the store path it yields
# is checked against the binary that will run.
#
# The binary alone does not settle it either. ld-decode's launcher is a thin
# wrapper that only touches PATH, so the lddecode package the interpreter
# actually imports is whichever one PYTHONPATH names first -- and a dev shell
# exports a PYTHONPATH of its own. A shell can therefore hold a new ld-decode on
# PATH and an old lddecode on PYTHONPATH, and it is the module that decodes. So
# that is checked too.

decoder_from_lock() {
  local lock="$SELF_DIR/flake.lock" rev=""
  [ -f "$lock" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    rev=$(jq -r '.nodes["ld-decode"].locked.rev // empty' "$lock" 2>/dev/null)
  else
    # Within the ld-decode node, "locked" carries the revision and "original"
    # only the branch it was locked from, so the first "rev" here is the one.
    rev=$(sed -n '/^    "ld-decode": {/,/^    },$/p' "$lock" \
            | sed -n 's/.*"rev": "\([0-9a-f]\{7,\}\)".*/\1/p' | head -1)
  fi
  [ -n "$rev" ] || return 1
  printf 'ld-decode-%s\n' "${rev:0:7}"
}

# Fallback when there is no lock to read: the Nix store path already identifies
# the build exactly, it just does not say which commit it came from.
decoder_from_binary() {
  local bin="$1" hash
  case "$bin" in
    /nix/store/*) hash="${bin#/nix/store/}"; printf 'ld-decode-store-%s\n' "${hash:0:8}" ;;
    *)            printf 'ld-decode-%s\n' "$(ld-decode --version 2>/dev/null | tr -c 'A-Za-z0-9.+-' '-' | sed 's/-*$//')" ;;
  esac
}

# The lddecode package ld-decode will import, if PYTHONPATH supplies one: the
# first entry on it holding the package wins, exactly as Python resolves it.
# Nothing found means the interpreter falls back to the binary's own copy.
lddecode_on_pythonpath() {
  local entry
  local -a entries
  IFS=: read -r -a entries <<< "${PYTHONPATH:-}"
  for entry in "${entries[@]}"; do
    [ -n "$entry" ] || continue
    if [ -f "$entry/lddecode/__init__.py" ]; then
      readlink -f -- "$entry/lddecode"
      return 0
    fi
  done
  return 1
}

LD_DECODE_BIN=$(readlink -f -- "$(command -v ld-decode)")
DECODER_SOURCE=""

if [ -n "$DECODER" ]; then
  DECODER_SOURCE="named on the command line"
elif DECODER=$(decoder_from_lock); then
  DECODER_SOURCE="flake.lock"
else
  DECODER=$(decoder_from_binary "$LD_DECODE_BIN")
  DECODER_SOURCE="the ld-decode on PATH (no flake.lock to read)"
fi
case "$DECODER" in
  */*|""|.|..) die "invalid decoder name: \"$DECODER\"" ;;
esac

# Only the lock-derived name makes a claim that can be wrong: the other two are
# read from the binary itself, or asserted deliberately.
if [ "$DECODER_SOURCE" = flake.lock ] && [ "$VERIFY_DECODER" = 1 ]; then
  if ! command -v nix >/dev/null 2>&1; then
    printf 'warning: nix not on PATH; not checking ld-decode against flake.lock\n' >&2
  elif ! expected=$(nix eval --raw "$SELF_DIR#ld-decode.outPath" 2>/dev/null); then
    printf 'warning: could not evaluate the flake; not checking ld-decode against flake.lock\n' >&2
  else
    stale=""
    case "$LD_DECODE_BIN" in
      "$expected"/*) ;;
      *) stale="    on PATH:       $LD_DECODE_BIN" ;;
    esac
    if module=$(lddecode_on_pythonpath); then
      case "$module" in
        "$expected"/*) ;;
        *) stale="$stale${stale:+$'\n'}    on PYTHONPATH: $module" ;;
      esac
    fi
    [ -z "$stale" ] || die "the ld-decode that would run is not the build flake.lock pins, so
the decode would be filed under a commit that did not produce it:
$stale
    flake.lock:    $expected
Leave and re-enter the dev shell (exit; nix develop) to pick up the pinned
build, or pass --no-verify-decoder to decode with the one you have."
  fi
fi

# --- disc selection --------------------------------------------------------

selected=()
if [ "${#wanted[@]}" -eq 0 ]; then
  selected=("${DISCS[@]}")
else
  for want in "${wanted[@]}"; do
    hit=""
    for d in "${DISCS[@]}"; do
      IFS='|' read -r id _ _ <<< "$d"
      if [ "$id" = "$want" ]; then hit="$d"; break; fi
    done
    [ -n "$hit" ] || die "unknown disc: $want (try --list)"
    selected+=("$hit")
  done
fi

[ "$JOBS" -le "${#selected[@]}" ] || JOBS="${#selected[@]}"

# --- worker threads --------------------------------------------------------
#
# ld-decode's own auto is min(max(ncpu - 2, 1), 10) worker processes, chosen for
# a decode running alone. It is more than the work needs, and the surplus is not
# merely idle -- past the peak the curve turns down: 4.07, 5.42, 5.32, 5.16 and
# 5.03 FPS at 2, 4, 6, 8 and 10 workers on a single PAL decode, so ld-decode's
# ten comes out 7% behind four while drawing 20% more CPU. The sweep was run
# twice in opposite order and the two passes agree within 1%, so that is a curve
# rather than noise. Whatever bounds it is not worker CPU; iowait stayed under
# 0.5%. docs/performance.md has the measurements.
#
# So auto aims for DECODE_THREADS_TARGET workers per decode rather than as many
# as the host will hold. Four is the measured peak, and it spawns 60% fewer
# processes than ld-decode's own ten.
#
# The budget is still shared between concurrent decodes, so a large --jobs
# thins the pools rather than oversubscribing the host. This runs after disc
# selection because JOBS is clamped to the number of discs there: asking for more
# jobs than there are discs must not shrink the pool of the decodes that do run.

auto_threads() {
  local ncpu budget
  ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  budget=$(( ncpu - 2 ))
  [ "$budget" -ge 1 ] || budget=1
  budget=$(( budget / JOBS ))
  [ "$budget" -ge 1 ] || budget=1
  [ "$budget" -le "$DECODE_THREADS_TARGET" ] || budget="$DECODE_THREADS_TARGET"
  printf '%s\n' "$budget"
}

if [ "$THREADS" = 0 ]; then
  DECODE_THREADS=$(auto_threads)
else
  DECODE_THREADS="$THREADS"
fi

# --- resolving starts ------------------------------------------------------
#
# Every selected disc is resolved first, serially, before any decode starts.
# The start search runs short ld-decode probe decodes of its own, so running
# those concurrently would only make them contend for the same cores the real
# decodes are about to want; and resolving up front means a missing source or an
# existing output is reported in seconds rather than after hours of decoding.

R_ID=(); R_STD=(); R_SRC=(); R_DEST=(); R_BASE=(); R_START=()

# The decoded video file, if one is there. CVBS output is .cvbs on the pinned
# build and was .composite on earlier ones.
existing_product() {
  local dest="$1" base="$2" ext
  if [ "$USE_CVBS" = 1 ]; then
    set -- cvbs composite
  else
    set -- tbc
  fi
  for ext in "$@"; do
    if [ -e "$dest/$base.$ext" ]; then printf '%s\n' "$dest/$base.$ext"; return 0; fi
  done
  return 1
}

resolve_disc() {
  local id="$1" std="$2" rel="$3"
  local src="$LIBRARY/$rel"
  local dest="$OUTPUT/$id/$DECODER"
  local base name content start cache product report kv

  # The decode is named after the capture, minus its extension and with spaces
  # turned into dashes: one capture in the library has a space in its name, and
  # every path built from it -- the .cvbs, the sidecars, the progress log --
  # would then need quoting by hand in every command that touched it afterwards.
  name="${rel##*/}"
  base="${name%.ldf}"
  base="${base// /-}"

  log "$id ($std)"
  printf '   source: %s\n' "$src"
  [ -f "$src" ] || die "source not found: $src"

  printf '   output: %s/%s\n' "$dest" "$base"
  # The CVBS writer has been renamed between branch builds (.composite before
  # .cvbs), so a decode is looked for under either name rather than only the one
  # the pinned build happens to use: an existing decode must be recognised
  # whichever build made it, and a finished decode must not be called a failure
  # because the extension moved under us.
  product=$(existing_product "$dest" "$base") || product=""
  if [ -n "$product" ] && [ "$FORCE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    die "$product already exists; pass --force to overwrite"
  fi

  mkdir -p "$dest"
  # What the directory name is short for, for anyone who finds the decode later.
  if [ "$DRY_RUN" != 1 ]; then
    { printf 'decoder:  %s (from %s)\n' "$DECODER" "$DECODER_SOURCE"
      printf 'binary:   %s\n' "$LD_DECODE_BIN"
      printf 'version:  %s\n' "$(ld-decode --version 2>/dev/null || echo unknown)"
      printf 'recorded: %s\n' "$(date -Is)"
    } > "$dest/decoder.txt"
  fi
  cache="$dest/$base.start"

  if [ -n "$START_OVERRIDE" ]; then
    start="$START_OVERRIDE"
    printf '   start: %s (forced by --start)\n' "$start"
  else
    report=""
    if [ "$REFRESH_START" != 1 ] && [ -s "$cache" ]; then
      report=$(cat "$cache")
      case "$report" in
        # the cached start is only valid for the lead-in it was resolved for
        *"content="*"leadin=$LEAD_IN "*) printf '   %s (cached in %s)\n' "$report" "$cache" ;;
        *) report="" ;;
      esac
    fi
    if [ -z "$report" ]; then
      printf '   locating CAV frame #1 and a start that keeps the lead-in...\n'
      report=$("$FIND_START" "--${std,,}" --probe "$PROBE" --lead-in "$LEAD_IN" \
                 --report --verbose "$src" 2> >(sed 's/^/     /' >&2))
      printf '   %s\n' "$report"
      [ "$DRY_RUN" = 1 ] || printf '%s\n' "$report" > "$cache"
    fi

    content=""; start=""; opens=""
    for kv in $report; do
      case "$kv" in
        content=*) content="${kv#content=}" ;;
        start=*)   start="${kv#start=}" ;;
        opens=*)   opens="${kv#opens=}" ;;
      esac
    done
    [ -n "$content" ] && [ -n "$start" ] \
      || die "could not parse the start report: $report"

    # opens is the file frame the output really begins on, which is what says
    # how much lead-in was kept -- the start is only what ld-decode was told,
    # and how far the writer then moved on from it is not a fixed distance. A
    # cache written before that field existed does not carry it, and it cannot
    # be worked out from the other two, so that case says nothing rather than
    # guessing.
    if [ -n "$opens" ]; then
      printf '   start: %s (output opens at file frame %s, %s frame(s) before CAV #1; %s requested)\n' \
        "$start" "$opens" "$(( content - opens ))" "$LEAD_IN"
    else
      printf '   start: %s (cached before the opening frame was recorded; %s lead-in frame(s) requested, --refresh-start to measure)\n' \
        "$start" "$LEAD_IN"
    fi
  fi

  R_ID+=("$id");     R_STD+=("$std");   R_SRC+=("$src")
  R_DEST+=("$dest"); R_BASE+=("$base"); R_START+=("$start")
}

# --- decoding --------------------------------------------------------------

decode_one() {
  local i="$1" prefix="$2"
  local id="${R_ID[$i]}" std="${R_STD[$i]}" src="${R_SRC[$i]}"
  local dest="${R_DEST[$i]}" base="${R_BASE[$i]}"
  local start="${R_START[$i]}"
  local product
  local -a cmd

  cmd=(ld-decode)
  case "$std" in
    PAL) cmd+=(--pal) ;;
    *)   cmd+=(--ntsc) ;;
  esac
  # Ask for the format wanted either way rather than leaning on the default:
  # CVBS is the default on the pinned build but was not on earlier ones, and
  # the extension `existing_product` then looks for follows the flag, so a
  # silently flipped default would fail a finished decode as "wrote no video
  # file" -- after the hours it took to make it.
  if [ "$USE_CVBS" = 1 ]; then cmd+=(--cvbs); else cmd+=(--tbc); fi
  cmd+=(--start "$start")
  [ "$FRAMES" = all ] || cmd+=(--length "$FRAMES")
  cmd+=(--threads "$DECODE_THREADS" "$src" "$dest/$base")

  {
    printf '%s: start %s, frames %s, threads %s\n' \
      "$id" "$start" "$FRAMES" "$DECODE_THREADS"
    printf '   progress log: %s.log\n' "$dest/$base"
    printf '  '; printf ' %q' "${cmd[@]}"; printf '\n'
  } | prefixed "$prefix"

  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi

  run_ld_decode "$prefix" "${cmd[@]}"

  # An empty video file is a failed decode, not a finished one: ld-decode exits
  # cleanly when its writer never reached a frame it could open on.
  product=$(existing_product "$dest" "$base") \
    || die "ld-decode wrote no video file at $dest/$base.*"
  [ -s "$product" ] \
    || die "ld-decode wrote an empty $product: its writer never reached a frame \
it could open the file on. Decode more frames."
}

# --- main ------------------------------------------------------------------

printf 'library: %s\noutput:  %s\ndecoder: %s (%s)\nframes:  %s\njobs:    %s\nthreads: %s\n' \
  "$LIBRARY" "$OUTPUT" "$DECODER" "$DECODER_SOURCE" "$FRAMES" "$JOBS" \
  "$([ "$DECODE_THREADS" = 0 ] && echo "auto (ld-decode)" || echo "$DECODE_THREADS per decode")"

for d in "${selected[@]}"; do
  IFS='|' read -r id std rel <<< "$d"
  resolve_disc "$id" "$std" "$rel"
done

if [ "$JOBS" -le 1 ]; then
  for i in "${!R_ID[@]}"; do
    printf '\n'
    decode_one "$i" ""
  done
else
  # Each decode records its own exit status in a file, seeded as failed: a
  # decode_one that dies exits its subshell without reaching the success line,
  # so the seeded value stands and the failure is still attributed to its disc.
  # Collecting statuses this way (rather than from `wait -n`) keeps every disc's
  # result, instead of only the last one reaped.
  statusdir=$(mktemp -d "${TMPDIR:-/tmp}/decode-ggv.XXXXXX")
  trap 'rm -rf -- "$statusdir"' EXIT

  log "decoding ${#R_ID[@]} disc(s), $JOBS at a time"

  for i in "${!R_ID[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
    (
      echo 1 > "$statusdir/$i"
      decode_one "$i" "[${R_ID[$i]}] "
      echo 0 > "$statusdir/$i"
    ) &
  done
  wait

  failed=()
  for i in "${!R_ID[@]}"; do
    [ "$(cat "$statusdir/$i" 2>/dev/null || echo 1)" = 0 ] || failed+=("${R_ID[$i]}")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    die "decode failed for: ${failed[*]} (see each disc's .log)"
  fi
fi

log "done"
