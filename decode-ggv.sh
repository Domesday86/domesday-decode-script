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
# on it. Measured on a 16-core host: a single decode keeps about 5.4 cores busy,
# its 10 auto-selected workers running at about a third of a core each, with the
# capture read at 4 MB/s over a 10Gb link and iowait at 0.1% -- so it is that
# serial loop, not I/O and not the worker count, that bounds a decode. --jobs
# runs several decodes at once, which is what actually fills the cores.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIND_START="$SELF_DIR/find-disc-start.sh"

# ---------------------------------------------------------------------------
# Configuration (override with environment variables or the flags below)
# ---------------------------------------------------------------------------

# Root of the capture library. Disc source paths are relative to this.
LIBRARY="${DD_LIBRARY:-/home/sdi/raid/library}"

# Root of the decode output tree. Each disc gets a subdirectory here.
OUTPUT="${DD_OUTPUT:-/home/sdi/raid/decodes/domesday-decode-script}"

# Frames to decode per disc: a number, or "all" for the whole side.
FRAMES="${DD_FRAMES:-1000}"

# Frames of lead-in to include before CAV picture number 1.
LEAD_IN="${DD_LEAD_IN:-1}"

# Where the start search first probes, in file frames. This needs to be past
# disc spin-up and into settled playback; 800 clears it on these captures.
PROBE="${DD_PROBE:-800}"

# Discs to decode concurrently. One decode cannot saturate the machine (see the
# note at the top), so this is the setting that fills the cores. About three
# decodes will use a 16-core host.
JOBS="${DD_JOBS:-1}"

# ld-decode worker threads (0 = auto, divided between concurrent jobs).
THREADS="${DD_THREADS:-0}"

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
  -f, --frames N|all    frames to decode per disc (default: $FRAMES)
      --lead-in N       frames of lead-in to keep before CAV #1 (default: $LEAD_IN)
      --probe N         first frame the start search probes (default: $PROBE)
      --start N         force the ld-decode --start frame (single disc only)
      --refresh-start   re-run the start search, ignoring the cached value
  -j, --jobs N          decode N discs concurrently (default: $JOBS)
  -t, --threads N       ld-decode worker threads per decode, 0 = auto (default: $THREADS)
      --tbc             write .tbc output instead of CVBS
      --force           overwrite an existing decode
  -n, --dry-run         resolve starts and print the commands, decode nothing
      --list            list the discs in the table and exit
  -h, --help            this message

Environment: DD_LIBRARY DD_OUTPUT DD_FRAMES DD_LEAD_IN DD_PROBE DD_JOBS
             DD_THREADS DD_CVBS

A single decode uses only about a third of a 16-core machine, because
ld-decode's decode loop is serial and its demodulation workers wait on it.
Raising --threads does not help; -j does, by decoding several discs at once.
With -j above 1 the console progress of each decode is prefixed with its disc
id, since the decodes interleave.

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
# a decode running alone. Concurrent decodes would each claim that many, so
# divide the same budget between them instead. A decode's workers are only ever
# partly busy -- the in-order decode loop is what bounds them -- so a smaller
# pool per decode still keeps up, and the cores go to the extra decodes.
#
# With one job the choice is left to ld-decode (--threads 0), so its own formula
# stays authoritative for the single-decode case. This runs after disc selection
# because JOBS is clamped to the number of discs there: asking for more jobs than
# there are discs must not shrink the pool of the decodes that do run.

auto_threads() {
  local ncpu budget
  ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  budget=$(( ncpu - 2 ))
  [ "$budget" -ge 1 ] || budget=1
  budget=$(( budget / JOBS ))
  [ "$budget" -ge 1 ] || budget=1
  [ "$budget" -le 10 ] || budget=10
  printf '%s\n' "$budget"
}

if [ "$THREADS" = 0 ] && [ "$JOBS" -gt 1 ]; then
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

R_ID=(); R_STD=(); R_SRC=(); R_DEST=(); R_BASE=(); R_START=(); R_PRODUCT=()

resolve_disc() {
  local id="$1" std="$2" rel="$3"
  local src="$LIBRARY/$rel"
  local dest="$OUTPUT/$id"
  local base name content start cache product report kv

  name="${rel##*/}"
  base="${name%.ldf}"

  log "$id ($std)"
  printf '   source: %s\n' "$src"
  [ -f "$src" ] || die "source not found: $src"

  printf '   output: %s/%s\n' "$dest" "$base"
  if [ "$USE_CVBS" = 1 ]; then
    product="$dest/$base.cvbs"
  else
    product="$dest/$base.tbc"
  fi
  if [ -e "$product" ] && [ "$FORCE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    die "$product already exists; pass --force to overwrite"
  fi

  mkdir -p "$dest"
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

    content=""; start=""
    for kv in $report; do
      case "$kv" in
        content=*) content="${kv#content=}" ;;
        start=*)   start="${kv#start=}" ;;
      esac
    done
    [ -n "$content" ] && [ -n "$start" ] \
      || die "could not parse the start report: $report"

    printf '   start: %s (opens %s frame(s) before CAV #1; %s requested)\n' \
      "$start" "$(( content - start ))" "$LEAD_IN"
  fi

  R_ID+=("$id");     R_STD+=("$std");   R_SRC+=("$src")
  R_DEST+=("$dest"); R_BASE+=("$base"); R_START+=("$start"); R_PRODUCT+=("$product")
}

# --- decoding --------------------------------------------------------------

decode_one() {
  local i="$1" prefix="$2"
  local id="${R_ID[$i]}" std="${R_STD[$i]}" src="${R_SRC[$i]}"
  local dest="${R_DEST[$i]}" base="${R_BASE[$i]}"
  local start="${R_START[$i]}" product="${R_PRODUCT[$i]}"
  local -a cmd

  cmd=(ld-decode)
  case "$std" in
    PAL) cmd+=(--pal) ;;
    *)   cmd+=(--ntsc) ;;
  esac
  if [ "$USE_CVBS" = 1 ]; then cmd+=(--cvbs); fi
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

  [ -f "$product" ] || die "ld-decode wrote no $product"
}

# --- main ------------------------------------------------------------------

printf 'library: %s\noutput:  %s\nframes:  %s\njobs:    %s\nthreads: %s\n' \
  "$LIBRARY" "$OUTPUT" "$FRAMES" "$JOBS" \
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
