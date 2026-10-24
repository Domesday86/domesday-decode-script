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
    set)    run_set "$@"; return ;;
    map) phase=3 ;; select) phase=4 ;;
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
