#!/usr/bin/env bash
#
# Decode the Culture 2 disc of the PAL BBC AIV City Disc set through
# ld-decode, for its VP415e pack (build-pack.sh city-culture2).
#
# The City Disc (BBC, 1990) is an interactive videodisc set about the City of
# London -- the "square mile" -- covering its history, its customs and its role
# as a modern financial market place. The set is four discs: Culture 1,
# Culture 2, Financial 1 and Financial 2. Culture 2 is single-sided, and the
# library has two sets, each with one capture of it. Each is decoded in its
# own right, so they can be compared against each other or combined. Each
# pack has its own decode script: this is Culture 2's, the only list of its
# captures, and it checks and stamps its decodes for build-pack.sh. Culture 1
# has its own, decode-city-culture1.sh; the two Financial discs are still
# decoded by decode-city.sh.
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
# Each finished decode is checked and then stamped (lib/decode.sh): the stamp
# records the capture's fingerprint, the ld-decode revision, the start, the
# frames and the flags. A decode whose stamp matches is skipped, so a re-run
# with nothing changed does nothing. One with no stamp or a different one is
# stale, and is reported as such rather than overwritten: replacing it still
# takes --force. The captures are verified against sources.sha256 before any
# of this, so a changed or missing capture is caught before hours of decoding.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FIND_START="$SELF_DIR/find-disc-start.sh"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"
# shellcheck source=lib/stage.sh
. "$SELF_DIR/lib/stage.sh"
# shellcheck source=lib/decode.sh
. "$SELF_DIR/lib/decode.sh"
shares_load || exit 1

# ---------------------------------------------------------------------------
# Configuration (override with environment variables or the flags below)
# ---------------------------------------------------------------------------

# Root of the capture library. Set source paths are relative to this.
LIBRARY="$DD_LIBRARY"

# Root of the decode output tree. Decodes are filed under
# <root>/<set>/<decoder>-<date>/, where <decoder> names the ld-decode build
# and <date> (YYYYMMDD-HHMMSS) is when the run that first made it started.
OUTPUT="${DD_OUTPUT:-$DD_DECODES/decode-script/city-culture2}"

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
# by file frame 390 or so, and 800 clears that.
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

# The ld-decode flags every set is decoded with, besides the start, length,
# threads and --cvbs/--tbc. They are part of each decode's stamp, and
# build-pack.sh reads this line too, so it stays a single line.
#
# Both captures came off an LD-V4300D, whose ~8.5MHz digital-audio clock
# spur sits in the RF band, so the coherent subtraction is asked for
# unconditionally. It estimates the tone and subtracts it in the time domain,
# which -- unlike the old FFT-bin notch -- takes the spectral-leakage skirts
# with it. On the pinned build it costs no concurrency: its no-video guard
# makes it safe from the first block, so it neither defers to sync acquisition
# nor forces demodulation serial.
DECODE_FLAGS=(--pal --V4300D_coherent_subtract)

# What a finished decode is checked against before it is stamped. A side is
# 39104 pictures, unless its capture ends sooner (the last picture in its
# file name; both captures are named ..._00001-39104). The side's EFM data
# is localised, to pictures 31000-39104 (the efm_score probes under "City
# Culture 2" in the README), so the check runs from 31100 to the end.
SIDE_FRAMES=39104
EFM_FROM_PICTURE=31100

FORCE=0
ADOPT=0
DRY_RUN=0
REFRESH_START=0
START_OVERRIDE=""

# ---------------------------------------------------------------------------
# Set table: set | first picture | source path relative to LIBRARY
#
# Every capture is PAL CAV, of the Culture 2 disc's one side.
#
# "first picture" is the picture number the start search converges on -- the
# first frame of the side's content. It is 1 for DS2, whose capture begins at
# the head of the side. DS1's is 4, and that is a fact about the capture
# rather than about the disc. Picture #1 is present on it, at file frame 332,
# right behind the lead-in at 330-331 -- but the capture reports a duplicated
# file frame just after it (#2 and #3 both land on file frame 334), so
# picture #1 is only confirmed two file frames on, by #2 at 334. Picture #4,
# at file frame 335, is confirmed by #5 at 336 and converges immediately.
# Nothing is lost by aiming at #4: the start that keeps the lead-in has to
# land on the colour-sequence lattice ld-decode's CVBS writer opens on, and
# the nearest one below 335 opens the output at file frame 332 -- picture #1
# itself. See "Decoding the City Disc set" in the README.
# ---------------------------------------------------------------------------

SETS=(
  "DS1|4|BBC_AIV/City_Disc/City_Disc_DS1/City-Disc_DD86-DS1_Culture2-Side1_20210101_CAV_PAL_00001-39104.ldf"
  "DS2|1|BBC_AIV/City_Disc/City_Disc_DS2/City-Disc_DD86-DS2_Culture2-Side1_20210101_CAV_PAL_00001-39104.ldf"
)

# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [set ...]

Decode the Culture 2 disc of the City Disc set through ld-decode. With no set
named, every set in the table is decoded. Each set has one capture of the
disc's one side. Set names are matched regardless of case.

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
      --force           decode again, replacing an existing decode
      --adopt           check an existing decode that has no stamp (or a
                        stale one) and stamp it as it is, without decoding
  -n, --dry-run         resolve starts and print the commands, decode nothing
      --list            list the sets in the table and exit
  -h, --help            this message

Environment: DD_LIBRARY DD_DECODES DD_NO_MOUNT DD_OUTPUT DD_DECODER
             DD_VERIFY_DECODER DD_FRAMES
             DD_LEAD_IN DD_PROBE DD_JOBS DD_THREADS DD_THREADS_TARGET DD_CVBS

Decodes go to <output>/<set>/<decoder>-<date>/<capture basename>.*, where
<decoder> is the ld-decode commit flake.lock pins and <date> (YYYYMMDD-HHMMSS)
is when the run that first made the directory started; one run dates all of
its directories the same. Decoding a set again after updating ld-decode
therefore writes a new directory rather than overwriting the earlier decode;
the newest two such directories are kept for each set.

The captures are verified against sources.sha256 first. Each finished decode
is then checked -- every file present, a signal state decode-orc accepts, the
frame count, EFM data where the disc carries it -- and stamped, with the
results in check.txt beside it. A set whose stamp matches (same capture,
ld-decode, start, frames and flags) is skipped as up to date. A set whose
decode is stale or unstamped is refused: --force decodes it again, and --adopt
checks the decode that is there and stamps it if it passes. Only a decode made
by the build flake.lock pins, in CVBS, is stamped.

Every set is decoded with --V4300D_coherent_subtract: both captures were
made on an LD-V4300D, so its ~8.5MHz clock spur is in their RF, and subtracting
the tone coherently removes its leakage skirts as well as the tone.

EFM is decoded on every set. Culture 2 is a CAV AIV side and carries
digital data in its EFM track, from about picture 31000 to the end, so the
front end has something real to read -- unlike the Domesday National B
sides, where it is switched off. It is asserted here rather than offered as
a flag, for the same reason the PAL and CAV of these captures are: it is a
fact about the disc.

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
  ${0##*/} DS1                     # one capture, first 1000 frames
  ${0##*/} --frames all DS2        # one capture in full
  ${0##*/} --frames all -j 2       # both captures, two at a time
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
    --cvbs)          USE_CVBS=1; shift ;;
    --force)         FORCE=1; shift ;;
    --adopt)         ADOPT=1; shift ;;
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
[ "$JOBS" -ge 1 ] || die "--jobs must be at least 1"
if [ -n "$START_OVERRIDE" ]; then
  case "$START_OVERRIDE" in *[!0-9]*) die "--start must be a frame number" ;; esac
fi
[ "$ADOPT" = 0 ] || [ "$FORCE" = 0 ] || die "--adopt keeps a decode and --force replaces it: pick one"

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
DECODER_VERIFIED=0
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
    DECODER_VERIFIED=1
  fi
fi

# --- stamping --------------------------------------------------------------
#
# A stamp says a decode was made by the ld-decode revision flake.lock pins, so
# it is written only when that has been checked. A decode labelled by hand, or
# made without the check, or as .tbc (which nothing downstream reads), is left
# unstamped, and an existing one is refused without --force as before.

STAMPING=1
NO_STAMP_WHY=""
if [ "$DECODER_VERIFIED" != 1 ]; then
  STAMPING=0; NO_STAMP_WHY="the decoder is not the verified flake.lock build"
elif [ "$USE_CVBS" != 1 ]; then
  STAMPING=0; NO_STAMP_WHY="only CVBS decodes are stamped"
fi
[ "$STAMPING" = 1 ] || [ "$ADOPT" = 0 ] || die "--adopt stamps a decode, and $NO_STAMP_WHY"
FLAGS_LABEL="${DECODE_FLAGS[*]} --cvbs --cvbs-spec-origin"

if [ "$STAMPING" = 1 ] && [ "$DRY_RUN" != 1 ]; then
  for tool in orc-cli sqlite3 jq; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not on PATH, and a decode is checked with it before it is stamped (run: nix develop)"
  done
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
R_REL=(); R_TARGET=(); R_ACTION=(); R_REPORT=()

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
# Prints its own banner and writes what it resolved -- the start, and what is
# to be done with the set -- to $WORK/start.<index>, so it can be run in a
# subshell: the caller reads the results back afterwards rather than relying
# on assignments that a subshell could not export.
#
# What is to be done is one of:
#   skip    the decode is up to date
#   decode  there is no decode, or --force replaces the one there
#   adopt   --adopt checks the decode that is there and stamps it
resolve_one() {
  local i="$1" id="$2" target="$3" rel="$4" prefix="$5"
  local src="$LIBRARY/$rel"
  local dest base content start opens cache product report action state
  dest="$OUTPUT/$id/$(stage_version_name "$OUTPUT/$id" "$DECODER")"

  # The decode is named after the capture, minus its extension and with spaces
  # turned into dashes: a capture name with a space in it would otherwise need
  # quoting by hand in every command that touched the .cvbs, the sidecars or the
  # progress log afterwards.
  base=$(decode_base "$rel")

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
  if [ -n "$product" ] && [ "$STAMPING" != 1 ] && [ "$FORCE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    die "$product already exists; pass --force to overwrite"
  fi

  cache="$dest/$base.start"
  report=""

  if [ -n "$START_OVERRIDE" ]; then
    start="$START_OVERRIDE"
    printf '   start: %s (forced by --start)\n' "$start" | prefixed "$prefix"
  else
    # The cached start is only valid for the lead-in and the picture it was
    # resolved for.
    if [ "$REFRESH_START" != 1 ] && report=$(decode_cached_start "$cache" "$LEAD_IN" "$target"); then
      printf '   %s (cached in %s)\n' "$report" "$cache" | prefixed "$prefix"
    else
      printf '   locating picture #%s and a start that keeps the lead-in...\n' \
        "$target" | prefixed "$prefix"
      # The trace is indented and labelled through prefixed(), not sed: the
      # label is data, and sed would read any character in it as part of the
      # s/// expression.
      report=$("$FIND_START" --pal --probe "$PROBE" --target "$target" \
                 --lead-in "$LEAD_IN" --report --verbose "$src" \
                 2> >(prefixed "     $prefix" >&2))
      report="$report target=$target"
      printf '   %s\n' "$report" | prefixed "$prefix"
      if [ "$DRY_RUN" != 1 ]; then
        stage_mkdir "$dest" || exit 1
        printf '%s\n' "$report" > "$cache"
      fi
    fi

    content=$(decode_report_field "$report" content) || content=""
    start=$(decode_report_field "$report" start) || start=""
    opens=$(decode_report_field "$report" opens) || opens=""
    [ -n "$content" ] && [ -n "$start" ] \
      || die "could not parse the start report: $report"

    # opens is the file frame the output really begins on, which is what says
    # how much lead-in was kept -- the start is only what ld-decode was told, and
    # how far the writer then moved on from it is not a fixed distance.
    if [ -z "$opens" ]; then
      printf '   start: %s (%s lead-in frame(s) requested; the report does not say where the output opens)\n' \
        "$start" "$LEAD_IN" | prefixed "$prefix"
    elif [ "$opens" -le "$content" ]; then
      printf '   start: %s (output opens at file frame %s, %s frame(s) before picture #%s; %s requested)\n' \
        "$start" "$opens" "$(( content - opens ))" "$target" "$LEAD_IN" | prefixed "$prefix"
    else
      printf '   start: %s (output opens at file frame %s, %s frame(s) AFTER picture #%s: the head of this capture is off the colour sequence and cannot be written)\n' \
        "$start" "$opens" "$(( opens - content ))" "$target" | prefixed "$prefix"
    fi
  fi

  # What is there already, against what this run would make.
  action=decode
  state=""
  if [ "$STAMPING" = 1 ]; then
    decode_describe "$id" "$dest" "$base" "$rel" "$start" "$FRAMES" "$FLAGS_LABEL"
    if state=$(stage_state); then
      action=skip
      [ "$FORCE" != 1 ] || { action=decode; state="up to date, but --force decodes it again"; }
    fi
    printf '   state: %s\n' "$state" | prefixed "$prefix"
  fi
  if [ "$ADOPT" = 1 ] && [ "$action" != skip ]; then
    [ -n "$product" ] || die "$id: --adopt: there is no decode at $dest/$base to check and stamp"
    action=adopt
  elif [ "$action" = decode ] && [ -n "$product" ] && [ "$FORCE" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    # Never overwritten silently: a stale or unstamped decode may be hours of
    # work that only needs checking.
    die "$id: $state
A decode is there ($product), and is not replaced without --force. Pass
--force to decode it again, or --adopt to check the decode that is there and
stamp it if it passes."
  fi

  {
    printf 'id=%s\nsrc=%s\ndest=%s\nbase=%s\nstart=%s\n' "$id" "$src" "$dest" "$base" "$start"
    printf 'rel=%s\ntarget=%s\naction=%s\nreport=%s\n' "$rel" "$target" "$action" "$report"
  } > "$WORK/start.$i"
}

# --- checking --------------------------------------------------------------
#
# A decode is stamped only once it has been checked, and check.txt beside it
# says what was found. Every check runs, so one report shows everything that is
# wrong; any failure leaves the decode unstamped, and the report is kept as
# check.failed.txt.

# The ld-decode log names the picture on every frame it writes:
#   "… Frame <n>/<total>: File Frame <file frame>: CAV Frame #<picture>"
# printed here as "<frame index from 0> <file frame> <picture>". Lead-in
# frames ("CAV Lead In") have no picture, and are left out.
log_pictures() {
  sed -n 's/.* Frame \([0-9][0-9]*\)\/[0-9][0-9]*: File Frame \([0-9][0-9]*\): CAV Frame #\([0-9][0-9]*\).*/\1 \2 \3/p' "$1" \
    | awk '{ print $1 - 1, $2, $3 }'
}

# sql <db> <query>: read a decode's SQLite metadata without locking it.
sql() { sqlite3 -readonly -separator ' ' "file:$1?immutable=1" "$2"; }

# check_decode <id> <dest> <base> <target> <start> <report>: run the checks,
# write check.txt to its stage_tmp name, and return non-zero if any failed.
check_decode() {
  local id="$1" dest="$2" base="$3" target="$4" start="$5" report="$6"
  local out fails=0 ext f frames want tol lo hi tol_text kept content opens state cont last
  local held longest
  local prj orc status sstate scont pics first_file first_pic last_pic irregular
  local efm_frames efm_with span span_with wav desc

  out=$(stage_tmp check.txt) || return 1
  ok()   { printf 'ok    %s\n' "$*"; }
  bad()  { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }

  {
    printf 'decode:  %s/%s\nchecked: %s\n\n' "$dest" "$base" "$(date '+%F %T')"

    # Every file the later stages read.
    for ext in cvbs meta efm efm.meta dropouts.meta; do
      f="$dest/$base.$ext"
      if [ -s "$f" ]; then ok "$base.$ext is there ($(file_size "$f") bytes)"
      else bad "$base.$ext is missing or empty"; fi
    done

    # What ld-decode says it wrote.
    frames=""; state=""; cont=""
    if [ -s "$dest/$base.meta" ]; then
      read -r frames state cont < <(sql "$dest/$base.meta" \
        'select number_of_sequential_frames, signal_state_preset, sequence_continuous from cvbs_file limit 1') || true
      note "ld-decode recorded $state, sequence continuous $([ "$cont" = 1 ] && echo yes || echo no)"
    fi

    # And what decode-orc makes of it: a one-source project, listed. decode-orc
    # refuses a CVBS source in any state but these two.
    prj="$WORK/check-$id.orcprj"
    if orc-cli --log-level warn -i "PAL_CVBS_Source=input_path=$dest/$base.cvbs" --export-project "$prj" >/dev/null 2>&1 \
       && orc=$(orc-cli nodes list "$prj" --json 2>/dev/null); then
      read -r status sstate scont < <(jq -r '.[0] | "\(.status) \(.signal_state) \(.sequence_continuous)"' <<< "$orc") || true
      case "$sstate" in
        STANDARD_STABLE_LOCKED|STANDARD_STABLE_UNLOCKED)
          ok "decode-orc accepts the source: $sstate, status $status, sequence continuous $scont" ;;
        *) bad "decode-orc does not accept the source: signal state ${sstate:-none}, status ${status:-none}" ;;
      esac
    else
      bad "decode-orc could not read $base.cvbs"
    fi

    # The frame count: the whole side and the lead-in kept before it, or the
    # frames asked for. A player skip or a repeated picture moves the count a
    # little, so a whole side is allowed 1% either way. A player that stalls
    # holds one picture for longer than that (Countryside DS2's first side
    # holds #52791 for 2984 frames), so a whole side that is long is counted again without
    # the frames that repeat the picture before, which the Disc Mapper drops.
    # --length counts from the start ld-decode was given, not from the frame
    # its writer opens on, so a short decode may come out short by that gap,
    # and one frame more.
    content=$(decode_report_field "$report" content) || content=""
    opens=$(decode_report_field "$report" opens) || opens=""
    if [ -n "$content" ] && [ -n "$opens" ] && [ "$opens" -le "$content" ]; then
      kept=$(( content - opens ))
    else
      kept="$LEAD_IN"
    fi
    if [ "$FRAMES" = all ]; then
      # To the capture's last picture, which its file name gives (_PAL_a-b).
      last=$(sed -n 's/.*_PAL_[0-9]*-\([0-9]*\)$/\1/p' <<< "$base")
      want=$(( ${last:-$SIDE_FRAMES} - target + 1 + kept )); tol=$(( want / 100 ))
      lo=$(( want - tol )); hi=$(( want + tol )); tol_text=", give or take $tol"
    else
      want="$FRAMES"; hi="$FRAMES"; lo="$FRAMES"; tol_text=""
      if [ -n "$opens" ] && [ "$opens" -gt "$start" ]; then
        lo=$(( FRAMES - (opens - start) - 1 ))
        tol_text=", or down to $lo as the output opens $(( opens - start )) after the start"
      fi
    fi
    if [ -z "$frames" ]; then
      bad "the frame count is not in $base.meta"
    elif [ "$frames" -ge "$lo" ] && [ "$frames" -le "$hi" ]; then
      ok "$frames frames written (expected $want$tol_text)"
    elif [ "$FRAMES" = all ] && [ "$frames" -gt "$hi" ] && [ -s "$dest/$base.log" ] \
         && read -r held longest < <(log_pictures "$dest/$base.log" \
              | awk 'NR > 1 && $3 == p { n++; r++; if (r > m) { m = r; mp = p } next } { r = 0; p = $3 }
                     END { print n + 0, (m ? "#" mp " for " m + 1 " frames" : "none") }') \
         && [ $(( frames - held )) -ge "$lo" ] && [ $(( frames - held )) -le "$hi" ]; then
      ok "$frames frames written, $(( frames - held )) without the $held that repeat the picture before (expected $want$tol_text)"
      note "the player held pictures for $held extra frame(s), the longest $longest"
    else
      bad "$frames frames written (expected $want$tol_text)"
    fi

    # Which picture each frame holds, from the log. A log without them (some
    # other ld-decode) falls back to counting on from the first picture.
    pics="$WORK/pictures-$id"
    if [ -s "$dest/$base.log" ]; then log_pictures "$dest/$base.log" > "$pics"; else : > "$pics"; fi
    if [ -s "$pics" ]; then
      # The first and last frames' pictures, not the smallest and largest: a
      # VBI misread on a single frame can name any picture at all.
      read -r _ _ first_pic < "$pics"
      last_pic=$(tail -1 "$pics" | awk '{ print $3 }')
      irregular=$(awk 'NR > 1 && $3 != p + 1 { n++ } { p = $3 } END { print n + 0 }' "$pics")
      # The frame the output opens on, lead-in or not.
      first_file=$(sed -n 's/.* Frame 1\/[0-9][0-9]*: File Frame \([0-9][0-9]*\).*/\1/p' "$dest/$base.log" | head -1)
      ok "pictures #$first_pic to #$last_pic, by the log; the output opens at file frame $first_file"
      [ "$irregular" = 0 ] || note "$irregular frame(s) do not hold the picture after the one before: VBI misreads, player skips or repeats, which the Disc Mapper sorts out (phase 3)"
      if [ -n "$opens" ] && [ "$first_file" != "$opens" ]; then
        note "the start search expected the output to open at file frame $opens"
      fi
    else
      note "the log names no pictures; picture numbers are counted from #$target"
      first_pic=$(( target - kept ))
      if [ -n "$frames" ]; then
        awk -v n="$frames" -v p="$first_pic" 'BEGIN { for (i = 0; i < n; i++) print i, "-", p + i }' > "$pics"
      fi
    fi

    # EFM: t-values on every frame where the disc carries EFM data. That is all
    # this can tell: the front end writes t-values on frames with no EFM too,
    # out of noise, so whether they decode to data is for the EFM sink (phase
    # 2 of docs/emulator-pack-plan.md).
    if [ -s "$dest/$base.efm.meta" ]; then
      read -r efm_frames efm_with < <(sql "$dest/$base.efm.meta" \
        'select count(*), sum(t_value_count > 0) from efm_frame') || true
      read -r span span_with < <(sql "$dest/$base.efm.meta" 'select frame_id, t_value_count from efm_frame' \
        | awk -v from="$EFM_FROM_PICTURE" 'FILENAME != "-" { pic[$1] = $3; next }
                                         ($1 in pic) && pic[$1] >= from { n++; if ($2 > 0) w++ }
                                         END { print n + 0, w + 0 }' "$pics" -) || true
      if [ "${efm_with:-0}" -gt 0 ]; then
        ok "EFM t-values on ${efm_with} of ${efm_frames} frames"
      else
        bad "no frame has EFM t-values"
      fi
      if [ "${span:-0}" = 0 ]; then
        note "this decode does not reach picture #$EFM_FROM_PICTURE, where the disc's EFM data starts"
      elif [ $(( span_with * 100 )) -ge $(( span * 95 )) ]; then
        ok "EFM t-values on $span_with of $span frames from picture #$EFM_FROM_PICTURE"
      else
        bad "EFM t-values on only $span_with of $span frames from picture #$EFM_FROM_PICTURE (95% expected)"
      fi
    fi

    # Where the analogue audio went: rev8 writes it beside the decode as WAV
    # files, one per channel pair, rather than inside the .cvbs or .meta.
    for wav in "$dest/${base}"_audio_*.wav; do
      [ -e "$wav" ] || continue
      ok "analogue audio in ${wav##*/} ($(file_size "$wav") bytes)"
    done
    [ -e "$wav" ] || note "no analogue audio sidecar (${base}_audio_*.wav)"
    if [ -s "$dest/$base.meta" ]; then
      desc=$(sql "$dest/$base.meta" 'select channel_pair || ": " || coalesce(description, "") from audio_channel_pair' | paste -sd, - | sed 's/,/, /g')
      [ -z "$desc" ] || note "audio channel pairs in $base.meta: $desc"
    fi

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dest/check.failed.txt"
    return 1
  fi
  rm -f -- "$dest/check.failed.txt"
}

# finish_decode <index> <prefix>: check a decode and, if it passes, stamp it
# and drop all but the newest two decodes of the set.
finish_decode() {
  local i="$1" prefix="$2"
  local id="${R_ID[$i]}" dest="${R_DEST[$i]}" base="${R_BASE[$i]}"
  decode_describe "$id" "$dest" "$base" "${R_REL[$i]}" "${R_START[$i]}" "$FRAMES" "$FLAGS_LABEL"
  if ! check_decode "$id" "$dest" "$base" "${R_TARGET[$i]}" "${R_START[$i]}" "${R_REPORT[$i]}"; then
    prefixed "$prefix" < "$dest/check.failed.txt" >&2
    die "$id: the decode failed its checks and is not stamped (see $dest/check.failed.txt)"
  fi
  prefixed "$prefix   " < "$dest/check.txt.partial"
  stage_commit || die "$id: could not stamp the decode"
  printf '%s: checked and stamped\n' "$id" | prefixed "$prefix"
  stage_prune "$OUTPUT/$id" ld-decode stage.stamp | prefixed "$prefix"
}

# --- decoding --------------------------------------------------------------

decode_one() {
  local i="$1" prefix="$2"
  local id="${R_ID[$i]}" src="${R_SRC[$i]}"
  local dest="${R_DEST[$i]}" base="${R_BASE[$i]}"
  local start="${R_START[$i]}"
  local product f
  local -a cmd

  # Every Culture 2 capture is PAL. The disc format is not flagged: ld-decode
  # reads CAV or CLV out of the VBI itself, and every capture here is CAV.
  #
  # EFM is left on. Culture 2 carries digital data in its EFM track, so the
  # front end has something real to read -- unlike the Domesday National B
  # sides, which carry none.
  cmd=(ld-decode "${DECODE_FLAGS[@]}")
  # Ask for the format wanted either way rather than leaning on the default:
  # CVBS is the default on the pinned build but was not on earlier ones, and the
  # extension `existing_product` then looks for follows the flag, so a silently
  # flipped default would fail a finished decode as "wrote no video file" --
  # after the hours it took to make it.
  # With CVBS, --cvbs-spec-origin 0H-aligns each frame as the CVBS
  # specification requires; the pinned build still defaults to its legacy
  # origin, and its author recommends the spec origin.
  if [ "$USE_CVBS" = 1 ]; then cmd+=(--cvbs --cvbs-spec-origin); else cmd+=(--tbc); fi
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

  stage_mkdir "$dest" || exit 1
  # The stamp goes before anything is rewritten, so an interrupted decode is
  # stale. So does the last decode, so that nothing it wrote -- a sidecar this
  # run might not write again, a SQLite file ld-decode would add to -- is
  # mistaken for part of this one. Only the cached start is kept.
  if [ "$STAMPING" = 1 ]; then
    decode_describe "$id" "$dest" "$base" "${R_REL[$i]}" "$start" "$FRAMES" "$FLAGS_LABEL"
    stage_unstamp || exit 1
  fi
  for f in "$dest/$base".* "$dest/${base}"_* "$dest/check.txt" "$dest/check.failed.txt"; do
    [ -e "$f" ] || continue
    [ "$f" != "$dest/$base.start" ] || continue
    rm -f -- "$f"
  done

  # What the directory name is short for, for anyone who finds the decode later.
  { printf 'decoder:  %s (from %s)\n' "$DECODER" "$DECODER_SOURCE"
    printf 'binary:   %s\n' "$LD_DECODE_BIN"
    printf 'version:  %s\n' "$(ld-decode --version 2>/dev/null || echo unknown)"
    printf 'recorded: %s\n' "$(date -Is)"
  } > "$dest/decoder.txt"

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

  if [ "$STAMPING" = 1 ]; then
    finish_decode "$i" "$prefix"
  else
    printf '%s: not stamped: %s\n' "$id" "$NO_STAMP_WHY" | prefixed "$prefix"
  fi
}

# --- main ------------------------------------------------------------------

WORK=$(mktemp -d "${TMPDIR:-/tmp}/decode-city-culture2.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT

printf 'library: %s\noutput:  %s\ndecoder: %s (%s)\nframes:  %s\nsets:    %s\njobs:    %s\nthreads: %s\n' \
  "$LIBRARY" "$OUTPUT" "$DECODER" "$DECODER_SOURCE" "$FRAMES" "${#selected[@]}" "$JOBS" \
  "$([ "$DECODE_THREADS" = 0 ] && echo "auto (ld-decode)" || echo "$DECODE_THREADS per decode")"

ids=(); targets=(); rels=()
for d in "${selected[@]}"; do
  IFS='|' read -r id target rel <<< "$d"
  ids+=("$id"); targets+=("$target"); rels+=("$rel")
done

# The captures are checked before anything reads them: a changed or missing
# capture is caught in seconds, not after hours of decoding it.
log "verifying ${#selected[@]} capture(s) against sources.sha256"
"$SELF_DIR/verify-sources.sh" --library "$LIBRARY" "${rels[@]}" \
  || die "the captures do not match sources.sha256; nothing was decoded"

# Resolve the starts. Each resolve records its own exit status in a file, seeded
# as failed, so a resolve that dies is still attributed to its set -- and so
# every set's result is kept, rather than only the last one reaped.
log "resolving starts for ${#selected[@]} set(s)"

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
[ "${#failed[@]}" -eq 0 ] || die "stopped before decoding anything, because of: ${failed[*]} (see above)"

# Read the resolved values back. Each record is parsed rather than sourced: it
# holds paths from the table, and sourcing would run whatever they contained.
field() { sed -n "s/^$1=//p" "$WORK/start.$2"; }
for i in "${!ids[@]}"; do
  R_ID+=(    "$(field id "$i")")
  R_SRC+=(   "$(field src "$i")")
  R_DEST+=(  "$(field dest "$i")")
  R_BASE+=(  "$(field base "$i")")
  R_START+=( "$(field start "$i")")
  R_REL+=(   "$(field rel "$i")")
  R_TARGET+=("$(field target "$i")")
  R_ACTION+=("$(field action "$i")")
  R_REPORT+=("$(field report "$i")")
done

todo=(); skipped=()
for i in "${!R_ID[@]}"; do
  case "${R_ACTION[$i]}" in
    skip)   skipped+=("${R_ID[$i]}") ;;
    adopt)  [ "$DRY_RUN" = 1 ] || { log "${R_ID[$i]}: checking the decode that is there"; finish_decode "$i" ""; } ;;
    decode) todo+=("$i") ;;
  esac
done
[ "${#skipped[@]}" = 0 ] || log "up to date, not decoded: ${skipped[*]}"

if [ "${#todo[@]}" = 0 ]; then
  :
elif [ "$JOBS" -le 1 ]; then
  for i in "${todo[@]}"; do
    printf '\n'
    decode_one "$i" ""
  done
else
  log "decoding ${#todo[@]} set(s), $JOBS at a time"

  for i in "${todo[@]}"; do
    while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n || true; done
    (
      echo 1 > "$WORK/rc.$i"
      decode_one "$i" "[${R_ID[$i]}] "
      echo 0 > "$WORK/rc.$i"
    ) &
  done
  wait

  failed=()
  for i in "${todo[@]}"; do
    [ "$(cat "$WORK/rc.$i" 2>/dev/null || echo 1)" = 0 ] || failed+=("${R_ID[$i]}")
  done
  if [ "${#failed[@]}" -gt 0 ]; then
    die "decode failed for: ${failed[*]} (see each set's .log, and check.failed.txt if it was checked)"
  fi
fi

log "done"
