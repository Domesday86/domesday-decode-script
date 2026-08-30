#!/usr/bin/env bash
#
# Decode the PAL and NTSC LaserDisc calibration discs through ld-decode.
#
# Each disc is decoded to CVBS (<name>.composite + <name>.meta) starting a
# configurable number of lead-in frames before CAV picture number 1, so the
# disc-spin-up region at the head of the capture is skipped.
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

# ld-decode worker threads (0 = auto).
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
  -t, --threads N       ld-decode worker threads, 0 = auto (default: $THREADS)
      --tbc             write .tbc output instead of CVBS
      --force           overwrite an existing decode
  -n, --dry-run         resolve starts and print the commands, decode nothing
      --list            list the discs in the table and exit
  -h, --help            this message

Environment: DD_LIBRARY DD_OUTPUT DD_FRAMES DD_LEAD_IN DD_PROBE DD_THREADS DD_CVBS

ld-decode writes its own timestamped progress log to <output>.log for each
disc; tail that to follow a long decode.

Examples:
  ${0##*/} --frames 2                       # quick smoke test of both discs
  ${0##*/} --frames all GGV1069             # full decode of the NTSC disc
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
# This is only the console copy. ld-decode already keeps a proper timestamped
# log of its own next to the decode, at <outbase>.log.

run_ld_decode() {
  if [ -t 1 ]; then
    "$@"
  else
    "$@" 2>&1 | awk '{ sub(/[[:space:]]+$/, "")
                       if (length($0)) { print; fflush() } }' RS='[\r\n]'
  fi
}

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
if [ -n "$START_OVERRIDE" ]; then
  case "$START_OVERRIDE" in *[!0-9]*) die "--start must be a frame number" ;; esac
  [ "${#wanted[@]}" -eq 1 ] || die "--start applies to one disc; name exactly one"
fi

command -v ld-decode >/dev/null 2>&1 || die "ld-decode not on PATH (run: nix develop)"
[ -x "$FIND_START" ] || die "missing helper: $FIND_START"
[ -d "$LIBRARY" ] || die "library not found: $LIBRARY"

# --- decode ----------------------------------------------------------------

decode_disc() {
  local id="$1" std="$2" rel="$3"
  local src="$LIBRARY/$rel"
  local dest="$OUTPUT/$id"
  local base name content start cache product report kv
  local -a cmd

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

  cmd=(ld-decode)
  case "$std" in
    PAL) cmd+=(--pal) ;;
    *)   cmd+=(--ntsc) ;;
  esac
  if [ "$USE_CVBS" = 1 ]; then cmd+=(--cvbs); fi
  cmd+=(--start "$start")
  [ "$FRAMES" = all ] || cmd+=(--length "$FRAMES")
  cmd+=(--threads "$THREADS" "$src" "$dest/$base")

  printf '   frames: %s\n' "$FRAMES"
  printf '   progress log: %s.log\n\n' "$dest/$base"
  printf '  '; printf ' %q' "${cmd[@]}"; printf '\n\n'

  if [ "$DRY_RUN" = 1 ]; then
    return 0
  fi

  run_ld_decode "${cmd[@]}"

  if [ "$USE_CVBS" = 1 ]; then
    # ld-decode names its CVBS output <base>.composite; the required name is
    # <base>.cvbs. Rename until ld-decode does it itself. Nothing refers to the
    # file by name -- the .meta sidecar records a signal_type, not a filename --
    # so this is just the rename, with no sidecar to keep in step.
    [ -f "$dest/$base.composite" ] \
      || die "ld-decode wrote no $dest/$base.composite to rename"
    mv -f -- "$dest/$base.composite" "$product"
    printf '\n   renamed %s.composite -> %s.cvbs\n' "$base" "$base"
  fi
}

# --- main ------------------------------------------------------------------

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

printf 'library: %s\noutput:  %s\nframes:  %s\n' "$LIBRARY" "$OUTPUT" "$FRAMES"

for d in "${selected[@]}"; do
  IFS='|' read -r id std rel <<< "$d"
  decode_disc "$id" "$std" "$rel"
done

log "done"
