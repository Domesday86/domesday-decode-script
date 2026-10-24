#!/usr/bin/env bash
#
# Build a disc's VP415e pack -- <stem>.mkv, <stem>.dat and <stem>.dat.bsm --
# from its captures, one stage at a time, redoing only what is out of date.
#
# The stages, in order (docs/emulator-pack-plan.md has the detail):
#
#   decode   ld-decode rev8 on each set             <set>/ld-decode-<rev>/
#   set      decode-orc EFM image and quality, each  orc-<rev>/sets/<set>/
#   map      Disc Mapper and Source Alignment on    orc-<rev>/map/
#            every set, for the selection report
#   select   the committed selection.yaml: which sets go into the video and
#            VFS stacks. Decided by a person; nothing here writes it
#   video    the stacked, dropout-corrected .mkv     orc-<rev>/video/
#   vfs      the stacked, verified .dat and .bsm     vfs-<rev>/
#   pack     the three files and their provenance    pack-<key>/
#
# Each stage keeps a stamp of its inputs (lib/stage.sh): the captures'
# fingerprints, the locked tool revisions, its parameters and project files,
# and the stamps of the stages before it. A stage whose stamp matches is
# skipped, so a re-run with nothing changed does nothing.
#
# Everything is written under $DD_DECODES/decode-script/<disc>/. The capture
# library is only ever read.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"
# shellcheck source=lib/stage.sh
. "$SELF_DIR/lib/stage.sh"
# shellcheck source=lib/decode.sh
. "$SELF_DIR/lib/decode.sh"

STAGES=(decode set map select video vfs pack)

usage() {
  cat <<EOF
Usage: ${0##*/} <disc> [status] [options]

Build <disc>'s pack, or with "status" report each stage as up to date or
stale, with the reason, and build nothing. Discs: $(for d in "$SELF_DIR"/discs/*/disc.conf; do d="${d%/disc.conf}"; printf '%s ' "${d##*/}"; done)

Options:
      --from STAGE    start at STAGE (the stages before it must be up to date)
      --until STAGE   stop after STAGE
      --force STAGE   rebuild STAGE even if its stamp matches. A per-set stage
                      takes one set as STAGE:SET, e.g. decode:DS3
      --no-mount      check the shares but do not mount them
  -h, --help          this message

Stages: ${STAGES[*]}

Environment: DD_LIBRARY DD_DECODES DD_NO_MOUNT
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

stage_index() {
  local i
  for i in "${!STAGES[@]}"; do
    [ "${STAGES[$i]}" = "$1" ] && { printf '%s\n' "$i"; return 0; }
  done
  return 1
}

# --- arguments -------------------------------------------------------------

DISC=""
MODE=build
FROM=""
UNTIL=""
FORCE=()
NO_MOUNT=()
while [ $# -gt 0 ]; do
  case "$1" in
    status)     MODE=status; shift ;;
    --from)     FROM="${2:?--from needs a stage}"; shift 2 ;;
    --until)    UNTIL="${2:?--until needs a stage}"; shift 2 ;;
    --force)    FORCE+=("${2:?--force needs a stage}"); shift 2 ;;
    --no-mount) NO_MOUNT=(--no-mount); shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          [ -z "$DISC" ] || die "one disc at a time (got $DISC and $1)"
                DISC="$1"; shift ;;
  esac
done
[ -n "$DISC" ] || { usage >&2; exit 2; }

DISC_DIR="$SELF_DIR/discs/$DISC"
[ -f "$DISC_DIR/disc.conf" ] || die "no such disc: $DISC (no $DISC_DIR/disc.conf)"
# shellcheck source=discs/volcanoes/disc.conf
. "$DISC_DIR/disc.conf"

FROM_I=0
UNTIL_I=$(( ${#STAGES[@]} - 1 ))
[ -z "$FROM" ]  || FROM_I=$(stage_index "$FROM")   || die "no such stage: $FROM"
[ -z "$UNTIL" ] || UNTIL_I=$(stage_index "$UNTIL") || die "no such stage: $UNTIL"
[ "$FROM_I" -le "$UNTIL_I" ] || die "--from $FROM comes after --until $UNTIL"
for f in "${FORCE[@]}"; do
  stage_index "${f%%:*}" >/dev/null || die "no such stage: ${f%%:*}"
done

# --- the disc's sets -------------------------------------------------------
#
# Read from the decode script's own SETS table, so there is one list of
# captures: "<set>|<first picture>|<path relative to the library>".

SETS=()
while IFS= read -r line; do
  SETS+=("$line")
done < <(sed -n '/^SETS=(/,/^)/p' "$SELF_DIR/$DISC_SCRIPT" | sed -n 's/^  "\(.*\)"$/\1/p')
[ "${#SETS[@]}" -gt 0 ] || die "no SETS table found in $DISC_SCRIPT"

# And its ld-decode flags, which are part of every decode's stamp. The decode
# script always writes CVBS here.
DECODE_FLAGS=$(sed -n 's/^DECODE_FLAGS=(\(.*\))$/\1/p' "$SELF_DIR/$DISC_SCRIPT")
[ -n "$DECODE_FLAGS" ] || die "no DECODE_FLAGS line found in $DISC_SCRIPT"
DECODE_FLAGS="$DECODE_FLAGS --cvbs"

set_ids()   { local s; for s in "${SETS[@]}"; do printf '%s\n' "${s%%|*}"; done; }
set_field() { # set_field <set> <1|2|3>
  local s
  for s in "${SETS[@]}"; do
    [ "${s%%|*}" = "$1" ] || continue
    printf '%s\n' "$s" | cut -d'|' -f"$2"
    return 0
  done
  return 1
}

SELECTION="$DISC_DIR/selection.yaml"

# selected_sets <video|vfs>: the sets chosen for one stack, in order. Empty
# until selection.yaml has been written (phase 4).
selected_sets() {
  [ -f "$SELECTION" ] || return 0
  yq -r ".$1.sets[]" "$SELECTION"
}

# --- shares and tools ------------------------------------------------------

check_shares() {
  ensure_shares "${NO_MOUNT[@]}" library decodes \
    || die "the shares are not ready (./mount-shares.sh says why)"
}

check_shares
OUT="$DD_DECODES/decode-script/$DISC_OUT"

LDD_DIR=$(stage_tool_dir ld-decode)    || die "flake.lock pins no ld-decode"
ORC_DIR=$(stage_tool_dir decode-orc)   || die "flake.lock pins no decode-orc"
VFS_DIR=$(stage_tool_dir vfs-verifier) || die "flake.lock pins no vfs-verifier"

# Which tool each stage runs: <flake input>|<flake package>|<command>.
stage_tool() {
  case "$1" in
    decode)         printf 'ld-decode|ld-decode|ld-decode\n' ;;
    set|map|video)  printf 'decode-orc|decode-orc|orc-cli\n' ;;
    vfs)            printf 'vfs-verifier|vfs-tools|vfs-stacker\n' ;;
    *)              return 1 ;;
  esac
}

# --- the stages, described -------------------------------------------------
#
# describe_<stage> [set] calls stage_begin and declares the stage's inputs and
# outputs. It decides nothing and writes nothing, so status can describe every
# stage without running any.

# A decode is described exactly as the decode script stamps it
# (lib/decode.sh). Its start is the one cached beside it for this lead-in and
# first picture; with none cached, the decode script has to resolve it, and
# the decode cannot be up to date.
describe_decode() {
  local id="$1" rel base dir report start
  rel=$(set_field "$id" 3)
  base=$(decode_base "$rel")
  dir="$OUT/$id/$LDD_DIR"
  if report=$(decode_cached_start "$dir/$base.start" "$DECODE_LEAD_IN" "$(set_field "$id" 2)"); then
    start=$(decode_report_field "$report" start) || start="unresolved"
  else
    start="unresolved"
  fi
  decode_describe "$id" "$dir" "$base" "$rel" "$start" "$DECODE_FRAMES" "$DECODE_FLAGS"
}

describe_set() {
  local id="$1"
  describe_decode "$id"; local up="$STAGE_DIR"
  stage_begin "set:$id" "$OUT/$ORC_DIR/sets/$id"
  stage_input_stamp "decode:$id" "$up"
  stage_input_tool decode-orc
  stage_input_file "project" "$DISC_DIR/sets/$id.orcprj"
}

describe_map() {
  local id ups=()
  for id in $(set_ids); do describe_decode "$id"; ups+=("$id|$STAGE_DIR"); done
  stage_begin map "$OUT/$ORC_DIR/map"
  for id in "${ups[@]}"; do stage_input_stamp "decode:${id%%|*}" "${id#*|}"; done
  stage_input_tool decode-orc
  stage_input_file "project" "$DISC_DIR/stack.orcprj"
  stage_output analysis.json
}

describe_video() {
  local id ups=()
  for id in $(selected_sets video); do describe_decode "$id"; ups+=("$id|$STAGE_DIR"); done
  stage_begin video "$OUT/$ORC_DIR/video"
  for id in "${ups[@]}"; do stage_input_stamp "decode:${id%%|*}" "${id#*|}"; done
  stage_input_file "selection" "$SELECTION"
  stage_input_file "project" "$DISC_DIR/stack.orcprj"
  stage_input_tool decode-orc
  stage_input "decoder" "$VIDEO_DECODER"
  stage_input "aspect" "4:3"
  stage_output "$STEM.mkv"
}

describe_vfs() {
  local id ups=()
  for id in $(selected_sets vfs); do describe_set "$id"; ups+=("$id|$STAGE_DIR"); done
  stage_begin vfs "$OUT/$VFS_DIR"
  for id in "${ups[@]}"; do stage_input_stamp "set:${id%%|*}" "${id#*|}"; done
  stage_input_file "selection" "$SELECTION"
  stage_input_tool vfs-verifier
  stage_output "$STEM.dat"
  stage_output "$STEM.dat.bsm"
}

# The pack is filed under its own key, so each distinct pack is a version of
# its own and the newest two are kept.
describe_pack() {
  local video vfs key
  describe_video; video="$STAGE_DIR"
  describe_vfs;   vfs="$STAGE_DIR"
  stage_begin pack "$OUT/pack"
  stage_input_stamp video "$video"
  stage_input_stamp vfs "$vfs"
  stage_input "stem" "$STEM"
  key=$(stage_key)
  STAGE_DIR="$OUT/pack-${key:0:12}"
  stage_output "$STEM.mkv"
  stage_output "$STEM.dat"
  stage_output "$STEM.dat.bsm"
  stage_output provenance.yaml
}

# The units a stage is built in: one per set, or the stage itself.
stage_units() {
  case "$1" in
    decode|set) set_ids | sed "s/^/$1:/" ;;
    *)          printf '%s\n' "$1" ;;
  esac
}

describe_unit() {
  case "$1" in
    *:*) "describe_${1%%:*}" "${1#*:}" ;;
    *)   "describe_$1" ;;
  esac
}

forced() {
  local f
  for f in "${FORCE[@]}"; do
    [ "$f" = "$1" ] || [ "$f" = "${1%%:*}" ] && return 0
  done
  return 1
}

# unit_state <unit>: as stage_state, for any unit, including select.
unit_state() {
  local unit="$1"
  if [ "$unit" = select ]; then
    if [ -f "$SELECTION" ]; then
      printf 'decided: video %s; vfs %s\n' \
        "$(selected_sets video | paste -sd' ' -)" "$(selected_sets vfs | paste -sd' ' -)"
      return 0
    fi
    printf 'waiting: %s is not written yet (a person decides it from the map report)\n' "${SELECTION#"$SELF_DIR"/}"
    return 1
  fi
  case "$unit" in
    video|vfs|pack)
      if [ ! -f "$SELECTION" ]; then
        printf 'stale: waits on select\n'; return 1
      fi ;;
  esac
  describe_unit "$unit"
  stage_state
}

# --- status ----------------------------------------------------------------

show_versions() {
  local parent="$1" prefix="$2" marker="$3" d t
  for d in "$parent/$prefix"-*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    if t=$(stage_stamp_field "$(dirname -- "$d/$marker")" stamped); then
      printf '    %-40s complete %s\n' "${d#"$OUT"/}" "$(date -d "@$t" '+%F %T' 2>/dev/null || date -r "$t" '+%F %T')"
    else
      printf '    %-40s incomplete\n' "${d#"$OUT"/}"
    fi
  done
  return 0
}

status() {
  local name unit state tool input pkg cmd problem id
  printf 'shares\n'
  share_report library | sed 's/^/  /' || true
  share_report decodes | sed 's/^/  /' || true

  printf '\ntools (flake.lock)\n'
  for tool in "ld-decode|ld-decode|ld-decode" "decode-orc|decode-orc|orc-cli" "vfs-verifier|vfs-tools|vfs-stacker"; do
    IFS='|' read -r input pkg cmd <<< "$tool"
    if problem=$(stage_tool_verify "$pkg" "$cmd"); then
      printf '  %-13s %-22s %s is the locked build\n' "$input" "$(stage_tool_dir "$input")" "$cmd"
    else
      printf '  %-13s %-22s %s\n' "$input" "$(stage_tool_dir "$input")" "$problem"
    fi
  done

  printf '\nstages (under %s)\n' "$OUT"
  for name in "${STAGES[@]}"; do
    while IFS= read -r unit; do
      state=$(unit_state "$unit") || true
      printf '  %-12s %s\n' "$unit" "$state"
    done < <(stage_units "$name")
  done

  printf '\nversions held (two are kept of each)\n'
  for id in $(set_ids); do show_versions "$OUT/$id" ld-decode stage.stamp; done
  show_versions "$OUT" orc video/stage.stamp
  show_versions "$OUT" vfs stage.stamp
  show_versions "$OUT" pack stage.stamp
}

if [ "$MODE" = status ]; then
  status
  exit 0
fi

# --- build -----------------------------------------------------------------

# Each stage is built from the units that are stale (or forced), all at once,
# so that a stage can run them side by side. The stages after decode are
# written phase by phase (docs/emulator-pack-plan.md); until a stage's phase
# lands, reaching it stale stops the run there.
run_stage() {
  local name="$1" phase; shift
  case "$name" in
    decode) run_decode "$@"; return ;;
    set) phase=2 ;; map) phase=3 ;; select) phase=4 ;;
    video) phase=5 ;; vfs) phase=6 ;; pack) phase=7 ;;
  esac
  die "$1: not built yet -- this stage arrives in phase $phase of docs/emulator-pack-plan.md"
}

# The decodes are made, checked and stamped by the disc's own decode script,
# so a decode made by hand and one made here are the same thing. It verifies
# the captures first, and refuses to replace a stale decode unless told to:
# here, by --force decode or decode:<set>.
run_decode() {
  local u state
  local -a stale=() again=() args
  for u; do
    if forced "$u"; then again+=("${u#decode:}"); else stale+=("${u#decode:}"); fi
  done
  args=(--library "$DD_LIBRARY" --output "$OUT"
        --frames "$DECODE_FRAMES" --lead-in "$DECODE_LEAD_IN"
        --jobs "$DECODE_JOBS" --threads "$DECODE_THREADS")
  if [ "${#stale[@]}" -gt 0 ]; then
    "$SELF_DIR/$DISC_SCRIPT" "${args[@]}" "${stale[@]}" || die "decode: $DISC_SCRIPT stopped"
  fi
  if [ "${#again[@]}" -gt 0 ]; then
    "$SELF_DIR/$DISC_SCRIPT" "${args[@]}" --force "${again[@]}" || die "decode: $DISC_SCRIPT stopped"
  fi
  for u; do
    state=$(unit_state "$u") || die "$u: still $state after decoding"
  done
}

verify_tool() {
  local t input pkg cmd problem
  t=$(stage_tool "$1") || return 0
  IFS='|' read -r input pkg cmd <<< "$t"
  problem=$(stage_tool_verify "$pkg" "$cmd") || die "$1: $problem"
}

# What the decode script is told about the shares.
[ "${#NO_MOUNT[@]}" = 0 ] || export DD_NO_MOUNT=1

# --from skips the stages before it, so they must already be up to date:
# otherwise the stages after would be built from stale inputs.
for (( i = 0; i < FROM_I; i++ )); do
  while IFS= read -r unit; do
    state=$(unit_state "$unit") || die "--from $FROM: $unit is $state"
  done < <(stage_units "${STAGES[$i]}")
done

for (( i = FROM_I; i <= UNTIL_I; i++ )); do
  name="${STAGES[$i]}"
  # The shares can drop during a run of several hours, so they are checked
  # again before every stage. A stage that failed partway left no stamp, so
  # running again after a remount resumes here.
  check_shares
  todo=()
  while IFS= read -r unit; do
    state=$(unit_state "$unit") && up=1 || up=0
    if [ "$up" = 1 ] && ! forced "$unit"; then
      printf '%-12s %s\n' "$unit" "$state"
      continue
    fi
    [ "$unit" != select ] || die "select: $state"
    [ "$up" = 0 ] || state="up to date, but forced"
    printf '%-12s %s\n' "$unit" "$state"
    todo+=("$unit")
  done < <(stage_units "$name")
  [ "${#todo[@]}" -gt 0 ] || continue
  verify_tool "$name"
  run_stage "$name" "${todo[@]}"
done
