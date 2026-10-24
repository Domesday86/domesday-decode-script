#!/usr/bin/env bash
#
# Decode the PAL North Polar Expedition LaserDisc through ld-decode.
#
# North Polar Expedition (Virgin Publishing, 1989) is a single-sided CAV
# interactive videodisc, a team-building exercise in which a group plays the
# members of an expedition to the North Pole. It is not a BBC title, but it is an
# AIV-era disc captured the same way as the rest of the library. Being
# single-sided, a disc set here is one capture rather than the four a Domesday
# set holds. The library has two sets -- two independent captures of two
# different copies of the disc, both made in January 2021 -- and each is decoded
# in its own right, so they can be compared against each other or combined.
#
# The disc carries no EFM digital audio -- its sound is analogue only -- so the
# EFM front end is switched off; see the note above FORCE_EFM.
#
# Each side is decoded to CVBS (<name>.cvbs + <name>.meta) starting a
# configurable number of lead-in frames before its first picture, so the
# disc-spin-up region at the head of the capture is skipped.
#
# One decode does not fill a modern machine. ld-decode fans block demodulation
# out to worker processes, but the decode loop that consumes them is strictly
# in-order on the main thread, so the workers spend most of their time waiting
# on it. Measured on a 16-core host, on PAL Domesday sides -- the same engine
# these captures go through: a single decode at its best setting keeps about
# five of the sixteen cores busy, and workers added past that draw CPU without
# returning frames -- 38% of the host at ten workers against 32% at four, for 7%
# fewer frames. The capture is read over a 10Gb link with iowait under 0.5%, so
# it is that serial loop, not I/O, that bounds one decode.
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
# set again with a different build lands beside the earlier decode instead of on
# top of it: only a re-run of the same commit can overwrite, and only then with
# --force.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIND_START="$SELF_DIR/find-disc-start.sh"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"
# shellcheck source=lib/stage.sh
. "$SELF_DIR/lib/stage.sh"
shares_load || exit 1

# ---------------------------------------------------------------------------
# Configuration (override with environment variables or the flags below)
# ---------------------------------------------------------------------------

# Root of the capture library. Set source paths are relative to this.
LIBRARY="$DD_LIBRARY"

# Root of the decode output tree. Decodes are filed under
# <root>/<set>/<decoder>/, where <decoder> names the ld-decode build.
OUTPUT="${DD_OUTPUT:-$DD_DECODES/decode-script/north-polar}"

# Name of the decoder directory. Empty means work it out from flake.lock (see
# "identifying the decoder" below); set it to label a decode by hand.
DECODER="${DD_DECODER:-}"

# Check that the ld-decode on PATH really is the build flake.lock pins before
# writing a decode under that commit's name. 0 skips the check.
VERIFY_DECODER="${DD_VERIFY_DECODER:-1}"

# Frames to decode per set: a number, or "all" for the whole side.
FRAMES="${DD_FRAMES:-1000}"

# Frames of lead-in to include before the side's first picture.
LEAD_IN="${DD_LEAD_IN:-1}"

# Where the start search first probes, in file frames. This needs to be past
# disc spin-up and into settled playback; on these captures the content starts
# by file frame 360 or so, and 800 clears that.
PROBE="${DD_PROBE:-800}"

# Sets to decode concurrently. One decode cannot saturate the machine (see the
# note at the top), and two is where the machine tops out: on the 16-core test
# host -j 2 finished 8.6% ahead of the same two sides decoded in turn, while
# -j 3 finished level with three in turn. Its other value is keeping every set
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

# Run ld-decode's EFM front end anyway. North Polar Expedition carries no EFM
# digital audio, so by default the front end is off: run on a disc that has none
# it spends its time demodulating noise into an .efm file no one can use. That
# was measured rather than assumed -- probes every 500 pictures across DS1 and
# every 1000 across DS2, scored for frame sync with lddecode.efm_score, found no
# T11-T11 sync pairs anywhere on either capture, where the AIV discs that do
# carry EFM frame up at a sync rate of 1.000 with near-full demodulator
# confidence. 1 forces it back on, for checking that claim.
FORCE_EFM="${DD_EFM:-0}"

FORCE=0
DRY_RUN=0
REFRESH_START=0
START_OVERRIDE=""

# ---------------------------------------------------------------------------
# Set table: set | first picture | source path relative to LIBRARY
#
# Every capture is PAL CAV and covers the disc's one content-bearing side.
#
# "first picture" is the picture number the start search converges on -- the
# first frame of the side's content. It is 1 for every capture here, each of
# which begins at the head of the side; the column exists for a side the player
# lost and had to be captured in more than one pass, whose later part picks up
# mid-disc (the Domesday library has one such side).
# ---------------------------------------------------------------------------

SETS=(
  "DS1|1|BBC_AIV/North_Polar_Expedition/NPE_DS1/North_Polar_Expedition_DD86-DS1_Side1_20210103_CAV_PAL_00001-51437.ldf"
  "DS2|1|BBC_AIV/North_Polar_Expedition/NPE_DS2/North_Polar_Expedition_DD86-DS2_Side1_20210103_CAV_PAL_00001-54348.ldf"
)

# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [set ...]

Decode the North Polar Expedition LaserDisc through ld-decode. With no set
named, every set in the table is decoded. North Polar Expedition is
single-sided, so a set is one capture.
Set names are matched regardless of case.

Options:
  -l, --library DIR     capture library root (default: $LIBRARY)
  -o, --output DIR      decode output root (default: $OUTPUT)
      --decoder NAME    decoder directory name (default: from flake.lock)
      --no-verify-decoder
                        skip the check that ld-decode matches flake.lock
  -f, --frames N|all    frames to decode per set (default: $FRAMES)
      --lead-in N       frames of lead-in to keep before the first picture (default: $LEAD_IN)
      --probe N         first frame the start search probes (default: $PROBE)
      --start N         force the ld-decode --start frame (one set only)
      --refresh-start   re-run the start search, ignoring the cached value
  -j, --jobs N          decode N sets concurrently (default: $JOBS)
  -t, --threads N       ld-decode worker threads per decode, 0 = auto
                        (default: $THREADS; auto aims for $DECODE_THREADS_TARGET each, shared between --jobs)
      --tbc             write .tbc output instead of CVBS
      --efm             decode EFM anyway (off: the disc has none)
      --force           overwrite an existing decode
  -n, --dry-run         resolve starts and print the commands, decode nothing
      --list            list the sets in the table and exit
  -h, --help            this message

Environment: DD_LIBRARY DD_DECODES DD_NO_MOUNT DD_OUTPUT DD_DECODER
             DD_VERIFY_DECODER DD_FRAMES
             DD_LEAD_IN DD_PROBE DD_JOBS DD_THREADS DD_THREADS_TARGET DD_CVBS
             DD_EFM

Decodes go to <output>/<set>/<decoder>/<capture basename>.*, where <decoder> is
the ld-decode commit flake.lock pins. Decoding a set again after updating
ld-decode therefore writes a new directory rather than overwriting the earlier
decode; re-running the same commit still needs --force.

Every set is decoded with --V4300D_coherent_subtract: both captures were made
on an LD-V4300D, so its ~8.5MHz clock spur is in their RF, and subtracting
the tone coherently removes its leakage skirts as well as the tone.

EFM is not decoded. North Polar Expedition carries no digital audio -- probes
right across both captures found no EFM frame sync at all -- so the front end
would only demodulate noise. --efm (DD_EFM=1) turns it back on, for checking
that claim.

A single decode uses only about a third of a 16-core machine, because
ld-decode's decode loop is serial and its demodulation workers wait on it.
--threads will not recover the rest: four workers per decode is the measured
peak and more is slower. -j 2 does recover some, finishing about 8.6% ahead of
decoding the two sets in turn, but -j 3 finishes level with three in turn. So
reach for -j to keep every set advancing as much as to go faster, and do not
expect a third job to pay. With -j above 1 the console progress of each decode
is prefixed with its set id, since the decodes interleave.

ld-decode writes its own timestamped progress log to <output>.log for each set;
tail that to follow a long decode.

Examples:
  ${0##*/} --list                  # what would be decoded
  ${0##*/} -f 30 DS1               # quick smoke test of one set
  ${0##*/} DS1                     # set 1, first 1000 frames
  ${0##*/} --frames all DS2        # one set in full
  ${0##*/} --frames all -j 2       # both sets at once
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
# Concurrent decodes are always split into lines and prefixed with the set id:
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

# Prefix a block of our own output the same way, so a set's banner stays with
# its progress when decodes interleave.
prefixed() { awk -v p="$1" '{ print p $0 }'; }

# --- argument parsing ------------------------------------------------------

wanted=()
LIST=0
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
    --efm)           FORCE_EFM=1; shift ;;
    --cvbs)          USE_CVBS=1; shift ;;
    --force)         FORCE=1; shift ;;
    -n|--dry-run)    DRY_RUN=1; shift ;;
    --list)          LIST=1; shift ;;
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
case "$FORCE_EFM" in 0|1) ;; *) die "DD_EFM must be 0 or 1 (got \"$FORCE_EFM\")" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be at least 1"
if [ -n "$START_OVERRIDE" ]; then
  case "$START_OVERRIDE" in *[!0-9]*) die "--start must be a frame number" ;; esac
fi

# Both shares are checked (and mounted if need be) before anything else, and
# the output must lie on the decodes share: the library is never written to.
# Scratch space moves to the decodes share with them (TMPDIR).
DD_LIBRARY="${LIBRARY%/}"
ensure_shares library decodes || die "the shares are not ready (./mount-shares.sh says why)"
stage_guard "$OUTPUT" || exit 1
if [ "$LIST" != 1 ]; then
  command -v ld-decode >/dev/null 2>&1 || die "ld-decode not on PATH (run: nix develop)"
  [ -x "$FIND_START" ] || die "missing helper: $FIND_START"
fi

# --- selecting sets --------------------------------------------------------
#
# Selectors are collected into a set of ids rather than filtering the table once
# per selector, so naming the same set twice decodes it once, and so the table's
# order is what the decodes come out in whatever order the selectors were
# written.

canonical_set() {
  local want="${1,,}" d id
  for d in "${SETS[@]}"; do
    IFS='|' read -r id _ _ <<< "$d"
    if [ "$want" = "${id,,}" ]; then printf '%s\n' "$id"; return 0; fi
  done
  return 1
}

declare -A picked=()

if [ "${#wanted[@]}" -eq 0 ]; then
  for d in "${SETS[@]}"; do
    IFS='|' read -r id _ _ <<< "$d"
    picked["$id"]=1
  done
  [ "${#picked[@]}" -gt 0 ] || die "the set table is empty"
else
  for want in "${wanted[@]}"; do
    s=$(canonical_set "$want") || die "unknown disc set: $want (try --list)"
    picked["$s"]=1
  done
fi

selected=()
for d in "${SETS[@]}"; do
  IFS='|' read -r id _ _ <<< "$d"
  [ -n "${picked[$id]+x}" ] || continue
  selected+=("$d")
done

[ "${#selected[@]}" -gt 0 ] || die "nothing selected"

if [ "$LIST" = 1 ]; then
  for d in "${selected[@]}"; do
    IFS='|' read -r id target rel <<< "$d"
    printf '%-5s CAV PAL  picture #%-6s %s\n' "$id" "$target" "$rel"
  done
  exit 0
fi

# --start names one ld-decode start frame, which can only belong to one capture.
[ -z "$START_OVERRIDE" ] || [ "${#selected[@]}" -eq 1 ] \
  || die "--start applies to one set; name exactly one"

command -v ld-decode >/dev/null 2>&1 || die "ld-decode not on PATH (run: nix develop)"

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
# The budget is still shared between concurrent decodes, so a large --jobs thins
# the pools rather than oversubscribing the host. This runs after set selection
# because JOBS is clamped to the number of sets there: asking for more jobs than
# there are sets must not shrink the pool of the decodes that do run.

[ "$JOBS" -le "${#selected[@]}" ] || JOBS="${#selected[@]}"

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
# Every selected set is resolved before any decode starts, so a missing source
# or an existing output is reported in minutes rather than after hours of
# decoding.
#
# The resolves run at the same concurrency as the decodes. A start search is
# several short ld-decode probes, each of which spends most of its wall clock
# seeking into the .ldf rather than working, so run one at a time they are
# nearly all waiting. Nothing is contended for: the resolve phase finishes
# before any decode is launched.

R_ID=(); R_SRC=(); R_DEST=(); R_BASE=(); R_START=()

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

# resolve_one <index> <id> <target> <relative path> <prefix>
#
# Prints its own banner and writes the resolved start to $WORK/start.<index>, so
# it can be run in a subshell: the caller reads the starts back afterwards
# rather than relying on assignments that a subshell could not export.
resolve_one() {
  local i="$1" id="$2" target="$3" rel="$4" prefix="$5"
  local src="$LIBRARY/$rel"
  local dest="$OUTPUT/$id/$DECODER"
  local base name content start opens cache product report kv

  # The decode is named after the capture, minus its extension and with spaces
  # turned into dashes: a capture name with a space in it would otherwise need
  # quoting by hand in every command that touched the .cvbs, the sidecars or the
  # progress log afterwards.
  name="${rel##*/}"
  base="${name%.ldf}"
  base="${base// /-}"

  {
    printf '\n== %s (CAV)\n' "$id"
    printf '   source: %s\n' "$src"
    printf '   output: %s/%s\n' "$dest" "$base"
  } | prefixed "$prefix"

  [ -f "$src" ] || die "source not found: $src"

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
    printf '   start: %s (forced by --start)\n' "$start" | prefixed "$prefix"
  else
    report=""
    if [ "$REFRESH_START" != 1 ] && [ -s "$cache" ]; then
      report=$(cat "$cache")
      case "$report" in
        # the cached start is only valid for the lead-in it was resolved for
        *"content="*"leadin=$LEAD_IN "*)
          printf '   %s (cached in %s)\n' "$report" "$cache" | prefixed "$prefix" ;;
        *) report="" ;;
      esac
    fi
    if [ -z "$report" ]; then
      printf '   locating picture #%s and a start that keeps the lead-in...\n' \
        "$target" | prefixed "$prefix"
      # The trace is indented and labelled through prefixed(), not sed: the
      # label is data, and sed would read any character in it as part of the
      # s/// expression.
      report=$("$FIND_START" --pal --probe "$PROBE" --target "$target" \
                 --lead-in "$LEAD_IN" --report --verbose "$src" \
                 2> >(prefixed "     $prefix" >&2))
      printf '   %s\n' "$report" | prefixed "$prefix"
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
    # how much lead-in was kept -- the start is only what ld-decode was told, and
    # how far the writer then moved on from it is not a fixed distance. A cache
    # written before that field existed does not carry it, and it cannot be
    # worked out from the other two, so that case says nothing rather than
    # guessing.
    if [ -z "$opens" ]; then
      printf '   start: %s (cached before the opening frame was recorded; %s lead-in frame(s) requested, --refresh-start to measure)\n' \
        "$start" "$LEAD_IN" | prefixed "$prefix"
    elif [ "$opens" -le "$content" ]; then
      printf '   start: %s (output opens at file frame %s, %s frame(s) before picture #%s; %s requested)\n' \
        "$start" "$opens" "$(( content - opens ))" "$target" "$LEAD_IN" | prefixed "$prefix"
    else
      printf '   start: %s (output opens at file frame %s, %s frame(s) AFTER picture #%s: the head of this capture is off the colour sequence and cannot be written)\n' \
        "$start" "$opens" "$(( opens - content ))" "$target" | prefixed "$prefix"
    fi
  fi

  printf 'id=%s\nsrc=%s\ndest=%s\nbase=%s\nstart=%s\n' \
    "$id" "$src" "$dest" "$base" "$start" > "$WORK/start.$i"
}

# --- decoding --------------------------------------------------------------

decode_one() {
  local i="$1" prefix="$2"
  local id="${R_ID[$i]}" src="${R_SRC[$i]}"
  local dest="${R_DEST[$i]}" base="${R_BASE[$i]}"
  local start="${R_START[$i]}"
  local product
  local -a cmd

  # Every North Polar Expedition capture is PAL. The disc format is not flagged: ld-decode
  # reads CAV or CLV out of the VBI itself, and every capture here is CAV.
  #
  # EFM is off unless --efm asked for it: the disc carries none, so the front
  # end would only demodulate noise (see the note above FORCE_EFM).
  cmd=(ld-decode --pal)
  [ "$FORCE_EFM" = 1 ] || cmd+=(--noEFM)
  # Ask for the format wanted either way rather than leaning on the default:
  # CVBS is the default on the pinned build but was not on earlier ones, and the
  # extension `existing_product` then looks for follows the flag, so a silently
  # flipped default would fail a finished decode as "wrote no video file" --
  # after the hours it took to make it.
  # With CVBS, --cvbs-spec-origin 0H-aligns each frame as the CVBS
  # specification requires; the pinned build still defaults to its legacy
  # origin, and its author recommends the spec origin.
  if [ "$USE_CVBS" = 1 ]; then cmd+=(--cvbs --cvbs-spec-origin); else cmd+=(--tbc); fi
  # Both captures came off an LD-V4300D, whose ~8.5MHz digital-audio clock
  # spur sits in the RF band, so the coherent subtraction is asked for
  # unconditionally. It estimates the tone and subtracts it in the time domain,
  # which -- unlike the old FFT-bin notch -- takes the spectral-leakage skirts
  # with it. On the pinned build it costs no concurrency: its no-video guard
  # makes it safe from the first block, so it neither defers to sync acquisition
  # nor forces demodulation serial.
  cmd+=(--V4300D_coherent_subtract)
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
  # cleanly when its writer never reached a frame it could open on, which is
  # what happens on a capture whose output opens past the frames --frames
  # covers (see the start report's "output opens at").
  product=$(existing_product "$dest" "$base") \
    || die "ld-decode wrote no video file at $dest/$base.*"
  [ -s "$product" ] \
    || die "ld-decode wrote an empty $product: its writer never reached a frame \
it could open the file on. This capture's output opens later than --frames \
$FRAMES reaches; decode more frames."
}

# --- main ------------------------------------------------------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/decode-north-polar.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

printf 'library: %s\noutput:  %s\ndecoder: %s (%s)\nframes:  %s\nsets:    %s\njobs:    %s\nthreads: %s\n' \
  "$LIBRARY" "$OUTPUT" "$DECODER" "$DECODER_SOURCE" "$FRAMES" "${#selected[@]}" "$JOBS" \
  "$([ "$DECODE_THREADS" = 0 ] && echo "auto (ld-decode)" || echo "$DECODE_THREADS per decode")"

# Resolve the starts. Each resolve records its own exit status in a file, seeded
# as failed, so a resolve that dies is still attributed to its set -- and so
# every set's result is kept, rather than only the last one reaped.
log "resolving starts for ${#selected[@]} set(s)"

ids=(); targets=(); rels=()
for d in "${selected[@]}"; do
  IFS='|' read -r id target rel <<< "$d"
  ids+=("$id"); targets+=("$target"); rels+=("$rel")
done

resolve_prefix() { [ "$JOBS" -gt 1 ] && printf '[%s] ' "${ids[$1]}"; }

for i in "${!ids[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
  (
    echo 1 > "$WORK/rc.$i"
    resolve_one "$i" "${ids[$i]}" "${targets[$i]}" "${rels[$i]}" \
      "$(resolve_prefix "$i")"
    echo 0 > "$WORK/rc.$i"
  ) &
done
wait

failed=()
for i in "${!ids[@]}"; do
  [ "$(cat "$WORK/rc.$i" 2>/dev/null || echo 1)" = 0 ] || failed+=("${ids[$i]}")
done
[ "${#failed[@]}" -eq 0 ] || die "could not resolve a start for: ${failed[*]}"

# Read the resolved values back. Each record is parsed rather than sourced: it
# holds paths from the table, and sourcing would run whatever they contained.
for i in "${!ids[@]}"; do
  R_ID+=(   "$(sed -n 's/^id=//p'    "$WORK/start.$i")")
  R_SRC+=(  "$(sed -n 's/^src=//p'   "$WORK/start.$i")")
  R_DEST+=( "$(sed -n 's/^dest=//p'  "$WORK/start.$i")")
  R_BASE+=( "$(sed -n 's/^base=//p'  "$WORK/start.$i")")
  R_START+=("$(sed -n 's/^start=//p' "$WORK/start.$i")")
done

if [ "$JOBS" -le 1 ]; then
  for i in "${!R_ID[@]}"; do
    printf '\n'
    decode_one "$i" ""
  done
else
  log "decoding ${#R_ID[@]} set(s), $JOBS at a time"

  for i in "${!R_ID[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
    (
      echo 1 > "$WORK/rc.$i"
      decode_one "$i" "[${R_ID[$i]}] "
      echo 0 > "$WORK/rc.$i"
    ) &
  done
  wait

  failed=()
  for i in "${!R_ID[@]}"; do
    [ "$(cat "$WORK/rc.$i" 2>/dev/null || echo 1)" = 0 ] || failed+=("${R_ID[$i]}")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    die "decode failed for: ${failed[*]} (see each set's .log)"
  fi
fi

log "done"
