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
#   compare  every set's evidence side by side, and   orc-<rev>/compare/
#            the report the selection is decided from
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

STAGES=(decode set map compare select video vfs pack)

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

# selection_problems: what is wrong with selection.yaml, one line each, or
# nothing. Each stack names its sets, best first, from the sets map.orcprj
# maps, each once, and lists every mapped set it leaves out under dropped,
# with a reason.
selection_problems() {
  local stack
  local -a mapped=()
  mapfile -t mapped < <(map_sets)
  yq . "$SELECTION" > /dev/null 2>&1 || { printf 'it is not valid YAML\n'; return 0; }
  for stack in video vfs; do
    yq -o=json ".$stack" "$SELECTION" | jq -r --arg stack "$stack" --args '
      $ARGS.positional as $mapped
      | if type != "object" then "\($stack) is missing" else
          [ .sets[]? ] as $sets | [ .dropped[]?.set ] as $dropped
          | (if ($sets | length) == 0 then "\($stack) uses no sets" else empty end),
            ($sets | group_by(.)[] | select(length > 1) | "\($stack) lists \(.[0]) twice"),
            (($sets + $dropped) | unique[] | select(. as $s | $mapped | index($s) | not)
             | "\($stack) names \(.), which map.orcprj does not map"),
            ($sets[] | select(. as $s | $dropped | index($s)) | "\($stack) both uses and drops \(.)"),
            ($mapped[] | select(. as $s | ($sets + $dropped) | index($s) | not)
             | "\($stack) neither uses nor drops \(.)"),
            (.dropped[]? | select((.reason // "") == "") | "\($stack) drops \(.set) without a reason")
        end' "${mapped[@]}"
  done
}

MAP_PROJECT="$DISC_DIR/map.orcprj"

# map_sets: the sets map.orcprj maps, in its order: the labels of its CVBS
# sources, which are set ids. A set left out of it is not mapped.
map_sets() {
  [ -f "$MAP_PROJECT" ] || return 0
  yq -r '.dag.nodes[] | select(.stage == "*_CVBS_Source") | .user_label' "$MAP_PROJECT"
}

# How many frames from each end of a decode the compare stage reads the disc
# metadata from.
COMPARE_PROBE_FRAMES=250

for id in $(map_sets); do
  set_field "$id" 1 >/dev/null || die "${MAP_PROJECT#"$SELF_DIR"/} has a source labelled $id, which is not a set in $DISC_SCRIPT"
done

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

# Which tools each stage runs, one per line: <flake input>|<flake package>|<command>.
stage_tool() {
  case "$1" in
    decode)         printf 'ld-decode|ld-decode|ld-decode\n' ;;
    set|map|video)  printf 'decode-orc|decode-orc|orc-cli\n' ;;
    compare)        printf 'decode-orc|decode-orc|orc-cli\nvfs-verifier|vfs-tools|vfs-stacker\n' ;;
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

# A set's EFM image and quality figures, from its decode and the disc's two
# committed set projects. SET_DECODE is left naming the decode it reads.
describe_set() {
  local id="$1" efm="${1,,}_efm.dat"
  describe_decode "$id"
  SET_DECODE="${STAGE_DIR}/${STAGE_OUTPUTS[0]}"
  stage_begin "set:$id" "$OUT/$ORC_DIR/sets/$id"
  stage_input_stamp "decode:$id" "${SET_DECODE%/*}"
  stage_input_tool decode-orc
  stage_input_file "efm project" "$DISC_DIR/set-efm.orcprj"
  stage_input_file "quality project" "$DISC_DIR/set-quality.orcprj"
  stage_output "$efm"
  stage_output "$efm.bsm"
  stage_output "$efm.txt"
  stage_output quality.json
  stage_output snr.csv
  stage_output dropouts.csv
  stage_output burst.csv
  stage_output check.txt
}

# Every set map.orcprj names, mapped and aligned together, from their decodes.
# MAP_DECODES is left naming each one's decode, as "<set>|<cvbs>".
describe_map() {
  local id ups=()
  MAP_DECODES=()
  for id in $(map_sets); do
    describe_decode "$id"
    ups+=("$id|$STAGE_DIR")
    MAP_DECODES+=("$id|$STAGE_DIR/${STAGE_OUTPUTS[0]}")
  done
  stage_begin map "$OUT/$ORC_DIR/map"
  for id in "${ups[@]}"; do stage_input_stamp "decode:${id%%|*}" "${id#*|}"; done
  stage_input_tool decode-orc
  stage_input_file "map project" "$MAP_PROJECT"
  stage_output analysis.json
  stage_output refresh.json
  for id in "${ups[@]}"; do stage_output "framemaps/${id%%|*}.ranges"; done
  stage_output framemaps/alignment
  stage_output check.txt
}

# Every mapped set's figures and EFM image (set), the map and alignment
# (map), and the two measurements the compare stage makes itself.
# COMPARE_SETS is left as "<set>|<decode>|<set stage dir>", and COMPARE_MAP
# names the map stage's directory.
describe_compare() {
  local id ups=()
  COMPARE_SETS=()
  for id in $(map_sets); do
    describe_set "$id"
    ups+=("$id|$STAGE_DIR")
    COMPARE_SETS+=("$id|$SET_DECODE|$STAGE_DIR")
  done
  describe_map; COMPARE_MAP="$STAGE_DIR"
  stage_begin compare "$OUT/$ORC_DIR/compare"
  for id in "${ups[@]}"; do stage_input_stamp "set:${id%%|*}" "${id#*|}"; done
  stage_input_stamp map "$COMPARE_MAP"
  stage_input_tool decode-orc
  stage_input_tool vfs-verifier
  stage_input "metadata probe" "first and last $COMPARE_PROBE_FRAMES frames, video_sink mono mkv-ffv1"
  stage_output report.txt
  stage_output compare.json
  for id in "${ups[@]}"; do stage_output "metadata/${id%%|*}.yaml"; done
  stage_output vfs-stacker.txt
  stage_output check.txt
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
  local unit="$1" problems
  if [ "$unit" = select ]; then
    if [ -f "$SELECTION" ]; then
      problems=$(selection_problems)
      if [ -n "$problems" ]; then
        printf 'invalid: %s %s\n' "${SELECTION#"$SELF_DIR"/}" "$(paste -sd';' - <<< "$problems" | sed 's/;/; /g')"
        return 1
      fi
      printf 'decided: video %s; vfs %s\n' \
        "$(selected_sets video | paste -sd' ' -)" "$(selected_sets vfs | paste -sd' ' -)"
      return 0
    fi
    printf 'waiting: %s is not written yet (a person decides it from the compare report)\n' "${SELECTION#"$SELF_DIR"/}"
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
    set)    run_set "$@"; return ;;
    map)    run_map "$@"; return ;;
    compare) run_compare "$@"; return ;;
    select) die "select: decided by hand in ${SELECTION#"$SELF_DIR"/}; there is nothing to build" ;;
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

# --- set: each set's EFM image and quality figures -------------------------
#
# Two projects per set, copies of the disc's committed set-efm.orcprj and
# set-quality.orcprj pointed at the set's decode. They are separate because
# --process triggers every sink in a project, and SNR and burst level each
# read the whole decode: in one project, --process for the EFM would read it
# twice more for nothing. So the EFM project is processed, and each analysis
# sink of the other is run with tools run, which reports its statistics as
# JSON and writes its per-frame figures as CSV.
#
# The sets run SET_JOBS at a time (disc.conf). Each one's console lines carry
# its set id.

# The analysis sinks of set-quality.orcprj: <tool>|<stage name>|<csv>.
SET_ANALYSES=("snr_analysis|SNR|snr" "dropout_analysis|Dropouts|dropouts" "burst_level_analysis|Burst|burst")

run_set() {
  local u id state fails=0 running=0
  for u; do
    id="${u#set:}"
    ( build_set "$id" ) 2>&1 | awk -v p="[$id] " '{ print p $0; fflush() }' &
    running=$(( running + 1 ))
    if [ "$running" -ge "$SET_JOBS" ]; then
      wait -n || fails=$(( fails + 1 ))
      running=$(( running - 1 ))
    fi
  done
  while [ "$running" -gt 0 ]; do
    wait -n || fails=$(( fails + 1 ))
    running=$(( running - 1 ))
  done
  [ "$fails" = 0 ] || die "set: $fails set(s) failed (above, and in each one's check.failed.txt if it reached its checks)"
  for u; do
    state=$(unit_state "$u") || die "$u: still $state after building"
  done
}

# build_set <set>: make one set's EFM image and quality figures, check them,
# and stamp them if they pass.
build_set() {
  local id="$1" dir decode efm rel a tool node csv rc t
  describe_set "$id"
  dir="$STAGE_DIR"; decode="$SET_DECODE"; efm="${id,,}_efm.dat"

  # Start clean: no stamp, and nothing left from an earlier run.
  stage_mkdir "$dir" || return 1
  stage_unstamp || return 1
  rm -f -- "$dir"/*_efm.dat* "$dir"/*.csv* "$dir"/*.json* "$dir"/*.log \
           "$dir"/*.orcprj "$dir"/check.txt* "$dir"/check.failed.txt "$dir"/crash_bundle_*.zip

  # The projects, beside their outputs. Their paths are relative to the
  # project file, which decode-orc resolves them against, so the projects open
  # the same on any host that mounts the decodes share.
  rel=$(realpath --relative-to="$dir" -- "$decode")
  cp -- "$DISC_DIR/set-efm.orcprj" "$dir/efm.orcprj"
  cp -- "$DISC_DIR/set-quality.orcprj" "$dir/quality.orcprj"
  if ! { orc-cli nodes set "$dir/efm.orcprj" Disc "input_path=$rel" \
         && orc-cli nodes set "$dir/efm.orcprj" EFM "output_path=$efm" \
         && orc-cli nodes set "$dir/quality.orcprj" Disc "input_path=$rel"; } >/dev/null; then
    printf '%s: could not point the set projects at %s\n' "$id" "$decode" >&2
    return 1
  fi

  # orc-cli writes a crash bundle to its working directory: here, if anywhere.
  cd -- "$dir" || return 1

  printf 'EFM: decoding %s\n' "${decode##*/}"
  t=$SECONDS rc=0
  orc-cli "$dir/efm.orcprj" --process --log-file "$dir/efm.log" --log-out file || rc=$?
  printf 'EFM: orc-cli exited %s after %ss\n' "$rc" "$(( SECONDS - t ))"

  for a in "${SET_ANALYSES[@]}"; do
    IFS='|' read -r tool node csv <<< "$a"
    t=$SECONDS
    orc-cli tools run "$dir/quality.orcprj" "$tool" --node "$node" --json --quiet \
      --csv "$(stage_tmp "$csv.csv")" > "$dir/$csv.json" 2> "$dir/$csv.log" || true
    printf '%s: analysed in %ss\n' "$node" "$(( SECONDS - t ))"
  done

  if ! check_set "$id" "$dir" "$efm" "$rc"; then
    cat -- "$dir/check.failed.txt" >&2
    printf '%s: failed its checks and is not stamped (see %s/check.failed.txt)\n' "$id" "$dir" >&2
    return 1
  fi
  cat -- "$dir/check.txt.partial"
  stage_commit || { printf '%s: could not stamp the set\n' "$id" >&2; return 1; }
  printf '%s: checked and stamped\n' "$id"
}

# efm_report_value <report> <label>: the figure after "<label> :" in the EFM
# sink's decode report, with its thousands separators taken out.
efm_report_value() {
  sed -n "s/^ *$2 *: *//p" "$1" | head -1 | tr -d ,
}

# check_set <set> <dir> <efm image> <EFM exit code>: run the checks, write
# check.txt and quality.json to their stage_tmp names, and return non-zero if
# any failed.
check_set() {
  local id="$1" dir="$2" efm="$3" rc="$4"
  local out fails=0 f size=0 sectors=0 bad=0 recovery a tool node csv status frames total
  local result="" assessment="" good="" corrected="" uncorrectable="" c1="" c2="" loss="" missing=""
  local -a counts=()

  out=$(stage_tmp check.txt) || return 1
  ok()   { printf 'ok    %s\n' "$*"; }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }

  {
    printf 'set:     %s\ndecode:  %s\nchecked: %s\n\n' "$id" "$SET_DECODE" "$(date '+%F %T')"

    # The EFM image: whole 2048-byte sectors, a bad sector map and a report
    # that says the decode succeeded. How much was recovered is evidence for
    # the selection (phase 4), not a pass or a fail.
    if [ "$rc" = 0 ]; then ok "the EFM sink finished"
    else fail "the EFM sink exited $rc (efm.log has its log)"; fi
    if [ -s "$dir/$efm" ]; then
      size=$(file_size "$dir/$efm"); sectors=$(( size / 2048 ))
      if [ $(( size % 2048 )) = 0 ]; then ok "$efm is $sectors sectors ($size bytes)"
      else fail "$efm is $size bytes, not a whole number of 2048-byte sectors"; fi
    else
      fail "$efm is missing or empty"
    fi
    if [ -e "$dir/$efm.bsm" ]; then
      bad=$(grep -c . "$dir/$efm.bsm" || true)
      ok "$efm.bsm lists $bad sector(s) not recovered"
    else
      fail "$efm.bsm is missing"
    fi
    f="$dir/$efm.txt"
    if [ -s "$f" ]; then
      result=$(efm_report_value "$f" Result)
      assessment=$(efm_report_value "$f" 'Overall assessment')
      recovery=$(efm_report_value "$f" 'Good \/ corrected \/ uncorrectable')
      IFS='/ ' read -r good corrected uncorrectable <<< "$recovery" || true
      c1=$(efm_report_value "$f" 'C1 uncorrectable' | sed -n 's/.*(\(.*\) %).*/\1/p')
      c2=$(efm_report_value "$f" 'C2 uncorrectable' | sed -n 's/.*(\(.*\) %).*/\1/p')
      loss=$(efm_report_value "$f" 'Data loss (post-C2)' | sed 's/ *%.*//')
      missing=$(efm_report_value "$f" 'Sections missing' | awk '{ print $1 }')
      if [ "$result" = SUCCESS ]; then ok "the decode report says $result"
      else fail "the decode report says ${result:-nothing} (SUCCESS expected)"; fi
      note "EFM $assessment: sectors good $good, corrected $corrected, uncorrectable $uncorrectable; data loss after C2 $loss%; C1 uncorrectable $c1%, C2 $c2%; sections missing $missing"
    else
      fail "$efm.txt, the decode report, is missing or empty"
    fi

    # The analysis sinks: each ran, over every frame of the decode.
    for a in "${SET_ANALYSES[@]}"; do
      IFS='|' read -r tool node csv <<< "$a"
      status=$(jq -r '.nodes[0].status // empty' "$dir/$csv.json" 2>/dev/null) || status=""
      if [ "$status" != success ]; then
        fail "$node analysis: ${status:-no report} ($(head -c 300 "$dir/$csv.log" 2>/dev/null | tr '\n' ' '))"
        continue
      fi
      read -r frames total < <(jq -r '.nodes[0].statistics | "\(.frames_analysed) \(.total_frames)"' "$dir/$csv.json") || true
      if [ "$frames" = "$total" ] && [ "${frames:-0}" -gt 0 ] && [ -s "$dir/$csv.csv.partial" ]; then
        ok "$node analysis over all $frames frames, per frame in $csv.csv"
      else
        fail "$node analysis covered ${frames:-no} of ${total:-unknown} frames"
      fi
      counts+=("$total")
      note "$(jq -r --arg k "$csv" '.nodes[0].statistics | def r(n): . * n | round / n;
        if $k == "snr" then "SNR: white \(.mean_white_snr | r(100)) dB, black PSNR \(.mean_black_psnr | r(100)) dB (means; lowest white \(.min_white_snr | r(100)))"
        elif $k == "dropouts" then "dropouts: \(.total_dropouts) totalling \(.total_dropout_samples) samples, in \(.frames_with_dropouts) frames"
        else "burst: median level \(.mean_median_burst_10bit | r(10)) (10-bit, mean over frames)" end' "$dir/$csv.json")"
    done
    if [ "${#counts[@]}" -gt 1 ] && [ "$(printf '%s\n' "${counts[@]}" | sort -u | wc -l)" -ne 1 ]; then
      fail "the analyses saw different numbers of frames: ${counts[*]}"
    fi

    # Everything the selection report (phase 4) reads from a set, in one file.
    jq -n --arg set "$id" --arg decode "$SET_DECODE" --arg image "$efm" \
          --argjson bytes "$size" --argjson sectors "$sectors" --argjson bad "$bad" \
          --arg result "$result" --arg assessment "$assessment" \
          --arg good "$good" --arg corrected "$corrected" --arg uncorrectable "$uncorrectable" \
          --arg c1 "$c1" --arg c2 "$c2" --arg loss "$loss" --arg missing "$missing" \
          --rawfile snr "$dir/snr.json" --rawfile dropouts "$dir/dropouts.json" --rawfile burst "$dir/burst.json" '
      def num: if . == "" then null else (tonumber? // null) end;
      def stats: (fromjson? // {}) | .nodes[0] // {} | if .status == "success" then .statistics else null end;
      { set: $set, decode: $decode,
        efm: { image: $image, bytes: $bytes, sectors: $sectors, bad_sectors: $bad,
               result: $result, assessment: $assessment,
               good: ($good | num), corrected: ($corrected | num), uncorrectable: ($uncorrectable | num),
               c1_uncorrectable_pct: ($c1 | num), c2_uncorrectable_pct: ($c2 | num),
               data_loss_pct: ($loss | num), sections_missing: ($missing | num) },
        snr: ($snr | stats), dropouts: ($dropouts | stats), burst: ($burst | stats) }' \
      > "$(stage_tmp quality.json)" || fail "could not write quality.json"

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dir/check.failed.txt"
    return 1
  fi
  rm -f -- "$dir/check.failed.txt"
}

# --- map: every set mapped and aligned, for the selection report -----------
#
# A copy of the disc's committed map.orcprj, pointed at the decodes, is
# refreshed with tools refresh: the Disc Mapper builds each set's frame map,
# then Source Alignment places the sets against each other and compares the
# captures (noise, pressing groups, softness). Nothing is processed. The
# refresh saves into the copy, so the mapped project can be opened in the GUI.
#
# The Disc Mapper reads the whole of every decode, one set after another, so
# the stage takes about as long as reading them all over the share.
#
# Its frame maps and alignment are also copied into discs/<disc>/framemaps/,
# for committing, so that a change in mapping shows up in review.

FRAMEMAPS="$DISC_DIR/framemaps"

run_map() {
  local state
  ( build_map ) || die "map: failed (above)"
  state=$(unit_state map) || die "map: still $state after building"
}

build_map() {
  local dir rel d id cvbs rc t
  describe_map
  dir="$STAGE_DIR"
  [ "${#MAP_DECODES[@]}" -gt 0 ] || { printf 'map: %s names no sets\n' "${MAP_PROJECT#"$SELF_DIR"/}" >&2; return 1; }

  stage_mkdir "$dir" || return 1
  stage_unstamp || return 1
  rm -rf -- "$dir"/*.json* "$dir"/*.log "$dir"/*.orcprj "$dir"/framemaps* \
            "$dir"/check.txt* "$dir"/check.failed.txt "$dir"/crash_bundle_*.zip

  cp -- "$MAP_PROJECT" "$dir/map.orcprj"
  for d in "${MAP_DECODES[@]}"; do
    id="${d%%|*}" cvbs="${d#*|}"
    rel=$(realpath --relative-to="$dir" -- "$cvbs")
    orc-cli nodes set "$dir/map.orcprj" "$id" "input_path=$rel" >/dev/null || {
      printf 'map: could not point %s at %s\n' "$id" "$cvbs" >&2; return 1; }
  done

  cd -- "$dir" || return 1
  printf 'map: mapping and aligning %s (the Disc Mapper reads each decode in full)\n' "$(map_sets | paste -sd' ' -)"
  t=$SECONDS rc=0
  orc-cli tools refresh "$dir/map.orcprj" --json > "$(stage_tmp refresh.json)" 2> "$dir/refresh.log" || rc=$?
  printf 'map: orc-cli exited %s after %ss\n' "$rc" "$(( SECONDS - t ))"

  if ! check_map "$dir" "$rc"; then
    cat -- "$dir/check.failed.txt" >&2
    printf 'map: failed its checks and is not stamped (see %s/check.failed.txt)\n' "$dir" >&2
    return 1
  fi
  cat -- "$dir/check.txt.partial"
  stage_commit || { printf 'map: could not stamp the stage\n' >&2; return 1; }
  printf 'map: checked and stamped\n'

  # The committed copies, replaced whole so a set dropped from the project
  # loses its map here too.
  rm -rf -- "$FRAMEMAPS"
  cp -R -- "$dir/framemaps" "$FRAMEMAPS"
  if git -C "$SELF_DIR" status --porcelain -- "$FRAMEMAPS" | grep -q .; then
    printf 'map: the frame maps or alignment differ from the committed ones; review them with: git diff -- %s\n' "${FRAMEMAPS#"$SELF_DIR"/}"
  fi
}

# check_map <dir> <refresh exit code>: run the checks, write check.txt,
# analysis.json and the frame maps to their stage_tmp names, and return
# non-zero if any failed.
check_map() {
  local dir="$1" rc="$2" report out fails=0 i id node status ranges pad n
  local -a sets=() order=()

  report="$dir/refresh.json.partial"
  out=$(stage_tmp check.txt) || return 1
  ok()   { printf 'ok    %s\n' "$*"; }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }
  mapfile -t sets < <(map_sets)

  {
    printf 'stage:   map\nsets:    %s\nchecked: %s\n\n' "${sets[*]}" "$(date '+%F %T')"

    if [ "$rc" = 0 ] && [ "$(jq -r '.completed' "$report" 2>/dev/null)" = true ]; then
      ok "the refresh ran every tool and saved map.orcprj"
    else
      fail "the refresh exited $rc ($(grep -v '^\[' "$dir/refresh.log" 2>/dev/null | tail -3 | tr '\n' ' '))"
      # A set that cannot be mapped stops the refresh there, and is named.
      while IFS= read -r line; do fail "$line"; done < <(
        jq -r '.nodes[]? | select(.status != "success" and .status != "skipped")
               | "\(.node): \(.tool) \(.status): \(.summary)"' "$report" 2>/dev/null)
      if [ "$rc" = 6 ]; then
        note "a set that cannot be mapped is dropped by deleting its source and frame map from ${MAP_PROJECT#"$SELF_DIR"/}"
      fi
    fi

    # Each set's frame map: the Disc Mapper succeeded and wrote ranges, and
    # the capture is in a signal state decode-orc accepts.
    for id in "${sets[@]}"; do
      node="$id map"
      status=$(jq -r --arg n "$node" '.nodes[]? | select(.node == $n) | .status' "$report" 2>/dev/null) || status=""
      ranges=$(jq -r --arg n "$node" '.nodes[]? | select(.node == $n) | .parameter_changes.ranges // empty' "$report" 2>/dev/null) || ranges=""
      if [ "$status" = success ] && [ -n "$ranges" ]; then
        ok "$id mapped: $(jq -r --arg n "$node" '.nodes[] | select(.node == $n) | .statistics
          | "\(.outputFrames) frames, \(.paddingFrames) padding in \(.gapsPadded) gaps"' "$report")"
        tr ',' '\n' <<< "$ranges" > "$(stage_tmp "framemaps/$id.ranges")"
      else
        fail "$id was not mapped (${status:-no report})"
        continue
      fi
      note "$id: $(jq -r --arg n "$node" '.nodes[] | select(.node == $n) | (.statistics
        | "\(.splitFieldFrames) split-field frames dropped, \(.removedDuplicates) duplicates removed (\(.duplicatesDecidedByQuality) of \(.duplicateGroups) groups decided on quality), \(.removedUnmappable) unmappable, \(.gapsTooWideToPad) gaps too wide to pad, \(.correctedVBIErrors) VBI errors corrected")
        + ([.sources[0] | select(.signal_state != null) | ", \(.signal_state)"] | add // "")' "$report")"
      jq -r --arg n "$node" '.nodes[] | select(.node == $n) | .items[]? | select(.type != "info") | .message' "$report" \
        | while IFS= read -r line; do note "$id: $line"; done
    done

    # Everything the selection report (phase 4) reads from this stage, by set.
    map_digest "$report" "${sets[@]}" > "$(stage_tmp analysis.json)" || fail "could not write analysis.json"

    # The alignment: an offset for every set, in the order Align takes them.
    status=$(jq -r '.nodes[]? | select(.tool == "source_alignment") | .status' "$report" 2>/dev/null) || status=""
    if [ "$status" = success ]; then
      mapfile -t order < <(jq -r '.nodes[] | select(.tool == "source_alignment") | .sources[].label' "$report")
      if [ "${order[*]}" = "${sets[*]}" ]; then
        ok "Align takes the sets in the project's order"
      else
        fail "Align takes the sets as ${order[*]}, not ${sets[*]}"
      fi
      {
        printf '# %s\n' "$(jq -r '.nodes[] | select(.tool == "source_alignment") | .parameter_changes.alignmentMode' "$report")"
        n=0
        for id in "${order[@]}"; do
          n=$(( n + 1 ))
          pad=$(jq -r --argjson i "$n" '.nodes[] | select(.tool == "source_alignment") | .parameter_changes.alignmentMap
                | split(", ")[] | select(startswith("\($i)+")) | ltrimstr("\($i)+")' "$report")
          printf '%s %s\n' "$id" "${pad:-none}"
          [ -n "$pad" ] || fail "$id has no place in the alignment map"
        done
      } > "$(stage_tmp framemaps/alignment)"
      ok "aligned: $(jq -r '.alignment | "map \(.map); output frame 1 is picture \(.statistics.globalFirstVBIFrame); \(.statistics.framesWith3PlusSources) frames have 3 or more sources, \(.statistics.framesWith2Sources) two, \(.statistics.framesWith1Source) one"' "$dir/analysis.json.partial")"
      # The capture comparison and its warnings, with "Source N" (the Nth
      # input of Align) given its set id.
      jq -r --args 'def named: gsub("Source (?<n>[0-9]+)"; $ARGS.positional[(.n | tonumber) - 1]);
             .nodes[] | select(.tool == "source_alignment")
             | (.summary | split("\n")[] | select(test("^  Source [0-9]+: (noise|not compared)|^Pressings:|stands alone"))
                | ltrimstr("  ")), (.items[]? | select(.type != "info") | .message)
             | named' "${order[@]}" < "$report" \
        | while IFS= read -r line; do note "$line"; done
    else
      fail "Source Alignment did not run to success (${status:-no report})"
    fi

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dir/check.failed.txt"
    return 1
  fi
  rm -f -- "$dir/check.failed.txt"
}

# map_digest <refresh report> <set>...: analysis.json, the refresh report by
# set. Source Alignment's capture comparison exists only as text in its
# summary, so each source's line of it is parsed here; "Source N" is the Nth
# input of Align. Its statistics (the first picture, the frame coverage and
# the number of pressings) are missing from the refresh report at the pinned
# decode-orc, so they are read from the summary too when they are absent.
# With a single pressing the summary names none, and every source compared is
# given pressing A.
map_digest() {
  local report="$1"; shift
  jq --args '
    def align: .nodes[] | select(.tool == "source_alignment");
    def summary: align.summary // "";
    def pads: (align.parameter_changes.alignmentMap // "") | split(", ") | map(select(. != "") | split("+")
              | { key: .[0], value: (.[1] | tonumber) }) | from_entries;
    def found(re): [ summary | capture(re) | .n | tonumber ] | first;
    def statistics: (align.statistics // {}) as $s
      | if ($s | length) > 0 then $s else
          { globalFirstVBIFrame: found("output frame 1 holds picture (?<n>-?[0-9]+)"),
            framesWith1Source: found("\n  1 source: +(?<n>[0-9]+) frames"),
            framesWith2Sources: found("\n  2 sources: +(?<n>[0-9]+) frames"),
            framesWith3PlusSources: found("\n  3\\+ sources: +(?<n>[0-9]+) frames"),
            pressingGroups: (if summary | test("\nPressings: all [0-9]+ sources appear to come from one pressing") then 1
                             else found("\nPressings: (?<n>[0-9]+) groups") end) } end;
    def comparison($i): summary | split("\n")[]
      | capture("^  Source (?<n>[0-9]+): noise σ (?<sigma>[0-9.]+) codes(, 5–6 MHz response (?<response>[0-9.]+))?(, pressing (?<pressing>[A-Z]+))?(, sample grid (?<grid>[-+][0-9]+))?$")
      | select(.n == ($i | tostring))
      | { noise_sigma: (.sigma | tonumber), response_5_6mhz: (.response | if . then tonumber else null end),
          pressing, sample_grid: (.grid | if . then tonumber else 0 end) };
    . as $r
    | ([ $r | align ] | first | if . then $r | statistics else null end) as $stats
    | { project: .project, completed: .completed,
        sets: [ $ARGS.positional | to_entries[] | .value as $id | (.key + 1) as $i
                | ($r | .nodes[] | select(.node == "\($id) map")) as $m
                | { set: $id,
                    source: ($m.sources[0] // null),
                    map: { status: $m.status, statistics: $m.statistics, summary: $m.summary,
                           warnings: [ $m.items[]? | select(.type != "info") | .message ] },
                    alignment_padding: ($r | pads["\($i)"]),
                    capture: ([ $r | comparison($i)
                                | .pressing //= (if $stats.pressingGroups == 1 then "A" else null end) ] | first // null),
                    soft: ([ $r | align.items[]? | select(.message | startswith("Source \($i) is soft")) ] | length > 0) } ],
        alignment: ($r | [ align ] | first // null | if . then
                     { status, mode: .parameter_changes.alignmentMode, map: .parameter_changes.alignmentMap,
                       statistics: $stats, summary, warnings: [ .items[]? | select(.type != "info") | .message ] } else null end),
        pressing_groups: $stats.pressingGroups }' \
    "$@" < "$report"
}

# --- compare: every set's evidence side by side, for the selection ---------
#
# What the earlier stages found about each set, in one report a person reads
# to write selection.yaml (docs/emulator-pack-plan.md, phase 4). It selects
# nothing. Two more things are measured here, both quickly:
#
# - The disc's metadata as each set reads it: the user code, the programme
#   status (CX, Amendment 2, side) and the first and last picture, which can
#   tell pressings apart. decode-orc decodes these only for the video sink's
#   embedded disc metadata, so the first and last COMPARE_PROBE_FRAMES frames
#   of each decode go through a video sink, and the document is kept from the
#   clip, which is not.
# - vfs-stacker --dry-run --show-conflicts over every set's EFM image: whether
#   the images agree sector for sector, and where they do not, whether the
#   same sets always dissent (a different version of the disc) or not
#   (damage).

run_compare() {
  local state
  ( build_compare ) || die "compare: failed (above)"
  state=$(unit_state compare) || die "compare: still $state after building"
}

build_compare() {
  local dir s id decode sdir stage frames n="$COMPARE_PROBE_FRAMES" meta clip rc t
  local -a images=()
  describe_compare
  dir="$STAGE_DIR"
  [ "${#COMPARE_SETS[@]}" -gt 0 ] || { printf 'compare: %s names no sets\n' "${MAP_PROJECT#"$SELF_DIR"/}" >&2; return 1; }

  stage_mkdir "$dir" || return 1
  stage_unstamp || return 1
  rm -rf -- "$dir"/*.json* "$dir"/*.txt* "$dir"/metadata "$dir"/crash_bundle_*.zip
  cd -- "$dir" || return 1

  for s in "${COMPARE_SETS[@]}"; do
    IFS='|' read -r id decode sdir <<< "$s"
    images+=("$(realpath --relative-to="$dir" -- "$sdir/${id,,}_efm.dat")")
    stage=$(yq -r ".dag.nodes[] | select(.user_label == \"$id\") | .stage" "$MAP_PROJECT")
    frames=$(jq -r --arg id "$id" '.sets[] | select(.set == $id) | .map.statistics.totalFields / 2 | floor' "$COMPARE_MAP/analysis.json")
    meta=$(stage_tmp "metadata/$id.yaml") || return 1
    clip="$dir/metadata/$id.mkv"
    printf 'compare: %s: reading the disc metadata from its first and last %s frames\n' "$id" "$n"
    t=$SECONDS rc=0
    orc-cli -i "$stage=input_path=$decode" \
            -f "frame_map=ranges=\"0-$(( n - 1 )),$(( frames - n ))-$(( frames - 1 ))\"" \
            -o "video_sink=output_path=$clip:decoder_type=mono:ffmpeg_format=mkv-ffv1:embed_disc_metadata=true" \
            > "$dir/metadata/$id.log" 2>&1 || rc=$?
    [ "$rc" != 0 ] || ffmpeg -v error -y -dump_attachment:t:0 "$meta" -i "$clip" -frames:v 1 -f null - \
                        >> "$dir/metadata/$id.log" 2>&1 || rc=$?
    rm -f -- "$clip"
    printf 'compare: %s: done in %ss (exit %s)\n' "$id" "$(( SECONDS - t ))" "$rc"
  done

  printf 'compare: vfs-stacker --dry-run over the EFM images of %s\n' "$(map_sets | paste -sd' ' -)"
  t=$SECONDS rc=0
  vfs-stacker --dry-run --show-conflicts "${images[@]}" > "$(stage_tmp vfs-stacker.txt)" 2>&1 || rc=$?
  printf 'compare: vfs-stacker exited %s after %ss\n' "$rc" "$(( SECONDS - t ))"

  if ! check_compare "$dir" "$rc"; then
    cat -- "$dir/check.failed.txt" >&2
    printf 'compare: failed its checks and is not stamped (see %s/check.failed.txt)\n' "$dir" >&2
    return 1
  fi
  cat -- "$dir/check.txt.partial"
  stage_commit || { printf 'compare: could not stamp the stage\n' >&2; return 1; }
  printf 'compare: checked and stamped; the report is %s/report.txt\n' "$dir"
}

# check_compare <dir> <vfs-stacker exit code>: run the checks, write check.txt,
# compare.json and report.txt to their stage_tmp names, and return non-zero if
# any failed. What the evidence says is for the person reading the report,
# not a pass or a fail: vfs-stacker refusing sets that disagree is evidence.
check_compare() {
  local dir="$1" rc="$2" out log fails=0 s id decode sdir meta line
  local -a args=() sets=()
  out=$(stage_tmp check.txt) || return 1
  log="$dir/vfs-stacker.txt.partial"
  ok()   { printf 'ok    %s\n' "$*"; }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }
  mapfile -t sets < <(map_sets)

  {
    printf 'stage:   compare\nsets:    %s\nchecked: %s\n\n' "${sets[*]}" "$(date '+%F %T')"

    for s in "${COMPARE_SETS[@]}"; do
      IFS='|' read -r id decode sdir <<< "$s"
      meta="$dir/metadata/$id.yaml.partial"
      if [ "$(yq -r .format "$meta" 2>/dev/null)" = orc-disc-metadata ]; then
        ok "$id: disc metadata read"
      else
        fail "$id: no disc metadata from the video sink (metadata/$id.log)"
      fi
      args+=("$id|$sdir/quality.json|$meta")
    done
    if grep -q 'Alignment cross-check:' "$log"; then
      ok "vfs-stacker compared the EFM images (exit $rc)"
    else
      fail "vfs-stacker exited $rc without comparing the EFM images ($(grep -v '^\[info\]' "$log" | tail -3 | tr '\n' ' '))"
    fi

    compare_digest "$COMPARE_MAP/analysis.json" "$log" "${args[@]}" > "$(stage_tmp compare.json)" \
      || fail "could not write compare.json"
    if compare_report "$dir/compare.json.partial" "$log" > "$(stage_tmp report.txt)"; then
      ok "report.txt written"
      while IFS= read -r line; do note "$line"; done < <(
        sed -n '/^PRESSINGS$/,/^VIDEO$/s/^  \([^ ]\)/\1/p' "$dir/report.txt.partial")
    else
      fail "could not write report.txt"
    fi

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dir/check.failed.txt"
    return 1
  fi
  rm -f -- "$dir/check.failed.txt"
}

# compare_digest <analysis.json> <vfs-stacker log> <set>|<quality.json>|<metadata yaml>...:
# compare.json, every set's evidence side by side, and the pressing groups as
# each kind of evidence draws them. The disc metadata is the video sink's
# document; vfs-stacker's findings exist only as text in its log, so they are
# parsed here, its sources being the sets in the order given.
compare_digest() {
  local analysis="$1" log="$2" s id quality meta; shift 2
  local -a ids=()
  {
    for s; do
      IFS='|' read -r id quality meta <<< "$s"
      ids+=("$id")
      jq -c --arg id "$id" --rawfile meta <(yq -o=json . "$meta" 2>/dev/null || echo null) \
        '{ set: $id, quality: ., metadata: ($meta | fromjson? // null) }' "$quality" || return 1
    done
  } | jq -s --slurpfile analysis "$analysis" --rawfile log "$log" '
    def lines: $log | split("\n") | map(sub("^\\[[a-z]+\\] "; ""));
    def first_capture(re): [ lines[] | capture(re)? ] | first // null;
    def num: if . == null then null else tonumber end;
    # The fields of the disc metadata that tell pressings apart: everything
    # the disc says about itself. The pictures it runs from and to, the
    # confidence and the lead-in and lead-out depend on the capture as well.
    def disc_key: { format, side, size_inches, cx_enabled, teletext, digital_video, sound_mode,
                    fm_multiplex, programme_dump, user_code, amendment2 };
    ($analysis[0]) as $a
    | [ .[] | . as $s | ($a.sets[] | select(.set == $s.set)) as $m
        | ($s.metadata // {}) as $md
        | (($md.address_map // {}).runs // []) as $runs
        | { set,
            decode: .quality.decode,
            capture: { noise_sigma: $m.capture.noise_sigma, response_5_6mhz: $m.capture.response_5_6mhz,
                       pressing: $m.capture.pressing, sample_grid: $m.capture.sample_grid, soft: $m.soft },
            map: ($m.map.statistics // {} | { outputFrames, paddingFrames, gapsPadded, splitFieldFrames,
                   removedDuplicates, duplicateGroups, removedUnmappable, gapsTooWideToPad, correctedVBIErrors })
                 + { signal_state: $m.source.signal_state, alignment_padding: $m.alignment_padding,
                     warnings: $m.map.warnings },
            snr: .quality.snr, dropouts: .quality.dropouts, burst: .quality.burst, efm: .quality.efm,
            metadata: (if $s.metadata == null then null else
                        ($md.disc // {}) + {
                          # The lowest and highest picture: a decode can open
                          # on a frame or two of stray picture numbers.
                          first_picture: ([ $runs[] | .picture? // empty ] | min),
                          last_picture: ([ $runs[] | select(.picture?) | .picture + .count - 1 ] | max),
                          lead_in: (($md.events.lead_in // []) | length > 0),
                          lead_out: (($md.events.lead_out // []) | length > 0) } end) } ] as $sets
    | [ lines[] | capture("^    (?<a>[0-9]+) vs (?<b>[0-9]+) +(?<compared>[0-9]+) +(?<disagreed>[0-9]+) ")?
        | { a: $sets[(.a | tonumber) - 1].set, b: $sets[(.b | tonumber) - 1].set,
            compared: (.compared | tonumber), disagreed: (.disagreed | tonumber) } ] as $pairs
    | [ lines[] | capture("^    (?<image>[^ ]+) +(?<used>[0-9]+) +(?<only_good>[0-9]+) +(?<vital_only>[0-9]+) +(?<vital_bad>[0-9]+)$")?
        | del(.image) | map_values(tonumber) ] as $contribution
    | { sets: [ $sets | to_entries[] | .value + { vfs_stacker: $contribution[.key] } ],
        pressings: {
          capture: ([ $sets[] | select(.capture.pressing != null) ] as $c
                    | if ($c | length) == 0 then null
                      else [ $c | group_by(.capture.pressing)[] | { pressing: .[0].capture.pressing, sets: map(.set) } ] end),
          metadata: ([ $sets[] | select(.metadata != null) ] as $d
                     | { groups: [ $d | group_by(.metadata | disc_key)[] | { disc: (.[0].metadata | disc_key), sets: map(.set) } ],
                         differing: [ $d[0].metadata // {} | disc_key | keys[] as $k
                                      | select([ $d[] | .metadata | disc_key | .[$k] ] | unique | length > 1) | $k ],
                         unread: [ $sets[] | select(.metadata == null) | .set ] }),
          efm: { pairs: $pairs,
                 disagreeing_pairs: [ $pairs[] | select(.disagreed > 0) ],
                 conflicts: (first_capture("^Source disagreement \\((?<n>[0-9]+) sector") | .n? | num // 0),
                 versions_differ: any(lines[]; test("these are different versions of the disc")),
                 refused: any(lines[]; test("^Refusing to stack")),
                 result: first_capture("RESULT: (?<verdict>[A-Z_]+) - (?<text>.*)$"),
                 recovered_over_best: (first_capture("^  Stacking recovered (?<n>[0-9]+) EFM sector") | .n? | num) } },
        video_by_noise: [ $sets | sort_by(.capture.noise_sigma // 1e9, -(.snr.mean_white_snr // 0))[] | .set ],
        vfs_by_loss: [ $sets | sort_by(.efm.data_loss_pct // 1e9, .efm.uncorrectable // 1e9)[] | .set ] }'
}

# compare_report <compare.json> <vfs-stacker log>: report.txt, the evidence laid
# out for a person to read.
compare_report() {
  local digest="$1" log="$2"
  jq -r --arg disc "$DISC" --arg when "$(date '+%F %T')" --arg selection "${SELECTION#"$SELF_DIR"/}" '
    def pad($n): tostring | . + " " * ([$n - length, 0] | max);
    def lpad($n): tostring | " " * ([$n - length, 0] | max) + .;
    def r($n): if . == null then "-" else . * $n | round / $n end;
    def yn: if . == null then "-" elif . then "yes" else "no" end;
    def row($w): [ range(length) as $i | .[$i] | if $i == 0 then pad($w[$i]) else lpad($w[$i]) end ] | join("  ");
    def table($w): map("  " + row($w))[];
    def disc_text: "\(.format // "?") side \(.side // "?"), \(.size_inches // "?") inch, user code \(.user_code // "none"), CX \(.cx_enabled | if . then "on" else "off" end), Amendment 2 \(.amendment2.present // false | if . then "present" else "absent" end), sound \(.sound_mode // "?")";
    . as $c
    | "\($disc): the evidence for \($selection)",
      "made \($when), from the sets map.orcprj maps: \([.sets[].set] | join(" "))",
      "",
      "This report selects nothing. A person reads it and writes \($selection):",
      "the video sets and the VFS sets, each best first, and a reason for every set",
      "left out (docs/emulator-pack-plan.md, phase 4).",
      "",
      "PRESSINGS",
      "",
      (if .pressings.capture == null then
         "  Capture comparison: not made (Source Alignment compares pressings only with 4 or more sources)"
       else
         "  Capture comparison (Source Alignment): \(.pressings.capture | length) pressing(s): \([.pressings.capture[] | "\(.pressing) = \(.sets | join(" "))"] | join("; "))"
       end),
      (.pressings.metadata | if (.groups | length) == 0 then "  Disc metadata: read from no set"
       elif (.groups | length) == 1 then "  Disc metadata: every set reads the same: \(.groups[0].disc | disc_text)"
       else "  Disc metadata: the sets differ in \(.differing | join(", "))", (.groups[] | "    \(.sets | join(" ")): \(.disc | disc_text)") end),
      (.pressings.metadata.unread | select(length > 0) | "  Disc metadata not read from: \(join(" "))"),
      (.pressings.efm | if (.pairs | length) == 0 then "  EFM content: vfs-stacker compared nothing (see vfs-stacker.txt)"
       elif (.disagreeing_pairs | length) == 0 and .conflicts == 0 then
         "  EFM content (vfs-stacker): every pair of sets holds the same bytes wherever both recovered a sector"
       else
         "  EFM content (vfs-stacker): \(.conflicts) sector(s) differ; pairs that disagree: \([.disagreeing_pairs[] | "\(.a)/\(.b) \(.disagreed) of \(.compared)"] | join(", "))",
         (if .versions_differ then "    the same sets dissent every time: vfs-stacker reads these as different versions of the disc"
          else "    which sets dissent varies: vfs-stacker reads this as damage rather than a different version" end)
       end),
      (.pressings.capture // (.pressings.metadata.groups | map({ pressing: (.sets | join("+")), sets }))
       | (map(.sets | length) | max) as $most
       | [ .[] | select((.sets | length) == $most) ] as $top
       | if length == 0 then empty
         elif ($top | length) > 1 then "  Most sources: a tie, \([$top[] | .pressing] | join(" and ")) with \($most) each; the pressing is chosen by hand"
         else "  Most sources: \($top[0].pressing), \($most) of \($c.sets | length) sets" end),
      "",
      "VIDEO",
      "",
      ([["set", "noise σ", "5-6 MHz", "soft", "white SNR", "black PSNR", "dropouts", "samples", "burst", "padding", "gaps", "split", "dups", "unmappable", "pad"]]
       + [ .sets[] | [ .set, (.capture.noise_sigma | r(100)), (.capture.response_5_6mhz | r(100)), (.capture.soft | yn),
                       (.snr.mean_white_snr | r(100)), (.snr.mean_black_psnr | r(100)),
                       (.dropouts.total_dropouts // "-"), (.dropouts.total_dropout_samples // "-"), (.burst.mean_median_burst_10bit | r(10)),
                       (.map.paddingFrames // "-"), (.map.gapsPadded // "-"), (.map.splitFieldFrames // "-"),
                       (.map.removedDuplicates // "-"), (.map.removedUnmappable // "-"), (.map.alignment_padding // "-") ] ]
       | table([4, 7, 7, 4, 9, 10, 8, 9, 6, 7, 4, 5, 4, 10, 3])),
      "",
      "  noise σ and 5-6 MHz: Source Alignment capture comparison (10-bit codes; response 1 is typical,",
      "  soft below 0.75). SNR, PSNR (dB) and burst: means over every frame (set stage). padding, gaps,",
      "  split, dups, unmappable: the Disc Mapper. pad: frames Align puts before the set.",
      "  Lowest noise first: \(.video_by_noise | join(" "))",
      (.sets[] | .set as $id | .map.warnings[]? | "  \($id): \(.)"),
      (.sets[] | select(.map.signal_state != null) | "  \(.set) signal: \(.map.signal_state)") ,
      "",
      "VFS",
      "",
      ([["set", "sectors", "not recovered", "good", "corrected", "uncorrectable", "loss after C2", "missing", "used", "only good", "vital bad"]]
       + [ .sets[] | [ .set, (.efm.sectors // "-"), (.efm.bad_sectors // "-"), (.efm.good // "-"), (.efm.corrected // "-"),
                       (.efm.uncorrectable // "-"), (.efm.data_loss_pct | if . == null then "-" else "\(.)%" end),
                       (.efm.sections_missing // "-"),
                       (.vfs_stacker.used // "-"), (.vfs_stacker.only_good // "-"), (.vfs_stacker.vital_bad // "-") ] ]
       | table([4, 7, 13, 6, 9, 13, 13, 7, 6, 9, 9])),
      "",
      "  sectors to missing: each set on its own (the EFM sink). used, only good, vital bad: the set in a",
      "  stack of all of them (vfs-stacker --dry-run): sectors taken from it, sectors no other set had,",
      "  and sectors the filesystem needs that it could not supply.",
      "  Lowest data loss first: \(.vfs_by_loss | join(" "))",
      (.pressings.efm.result | select(. != null) | "  Stacking all of them: \(.verdict) - \(.text)"),
      (.pressings.efm.recovered_over_best | select(. != null) | "  Stacking all of them recovers \(.) sector(s) the best single set lacks"),
      (.pressings.efm.refused | select(.) | "  vfs-stacker refused to stack them, because they do not agree"),
      "",
      "DISC METADATA, AS EACH SET READS IT",
      "",
      "  From the first and last frames of each decode, through the decode-orc video sink.",
      (.sets[] | if .metadata == null then "  \(.set): not read" else
         "  \(.set): \(.metadata | disc_text); pictures \(.metadata.first_picture // "?")-\(.metadata.last_picture // "?"); lead-in \(.metadata.lead_in | if . then "seen" else "not seen" end), lead-out \(.metadata.lead_out | if . then "seen" else "not seen" end); \(.metadata.confidence.agreement // "-") of status fields agree" end),
      "",
      "VFS-STACKER --DRY-RUN, ALL SETS",
      ""' "$digest"
  sed -e 's/^\[[a-z]*\] /  /' -e 's/^/  /' -- "$log"
}

verify_tool() {
  local t input pkg cmd problem
  t=$(stage_tool "$1") || return 0
  while IFS='|' read -r input pkg cmd; do
    problem=$(stage_tool_verify "$pkg" "$cmd") || die "$1: $problem"
  done <<< "$t"
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
