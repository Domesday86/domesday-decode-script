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
#   quality  the stacked video's SNR and dropouts,   orc-<rev>/quality/
#            measured as each set's are
#   pack     the three files, their provenance and   pack-<key>/
#            the pack's report (<stem>.report.pdf)
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

STAGES=(decode set map compare select video vfs quality pack)

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

# vfs_accept: what the selection accepts of the VFS stack: "bit-perfect", or
# "incomplete" when vfs.accept says a pack may ship with sectors the
# filesystem needs still bad (served by vp415e as MEDIUM ERROR).
vfs_accept() {
  local a=""
  [ ! -f "$SELECTION" ] || a=$(yq -r '.vfs.accept // ""' "$SELECTION" 2>/dev/null)
  printf '%s\n' "${a:-bit-perfect}"
}

# The VFS image's reference hash, recorded once the image has passed and been
# reviewed; every later stack is checked against it.
VFS_REFERENCE="$DISC_DIR/pack.sha256"

# The hand check of the pack on the player: a list of checks, each naming the
# pack by its id, with the date, the vp415e version and the result. A person
# writes it; the pack stage only reads it.
PLAYER_CHECK="$DISC_DIR/player-check.yaml"

# player_check_problems: what is wrong with PLAYER_CHECK, one line each, or
# nothing.
player_check_problems() {
  local json
  [ -f "$PLAYER_CHECK" ] || return 0
  json=$(yq -o=json . "$PLAYER_CHECK" 2>/dev/null) || { printf 'it is not valid YAML\n'; return 0; }
  jq -r '
    if type != "object" or (.checks | type) != "array" then "it has no list of checks" else
      .checks | to_entries[] | "check \(.key + 1)" as $c | .value
      | (if (.pack | type) == "string" and (.pack | test("^[0-9a-f]{16}$")) then empty else "\($c) names no pack id (16 hex digits, in quotes)" end),
        (if (.date // "" | tostring | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then empty else "\($c) has no date (YYYY-MM-DD)" end),
        (if (.vp415e // "" | tostring) != "" then empty else "\($c) names no vp415e version" end),
        (if .result == "pass" or .result == "fail" then empty else "\($c) has result \(.result // "none"), not pass or fail" end)
    end' <<< "$json"
}

# player_check_for <pack id>: the last check recorded for that pack, as JSON,
# or null.
player_check_for() {
  [ -f "$PLAYER_CHECK" ] || { printf 'null\n'; return 0; }
  yq -o=json . "$PLAYER_CHECK" | jq -c --arg id "$1" '[ .checks[]? | select(.pack == $id) ] | last'
}

# selection_problems: what is wrong with selection.yaml, one line each, or
# nothing. Each stack names its sets, best first, from the sets map.orcprj
# maps, each once, and lists every mapped set it leaves out under dropped,
# with a reason. The VFS stack may also accept an incomplete image.
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
            (.dropped[]? | select((.reason // "") == "") | "\($stack) drops \(.set) without a reason"),
            (if has("accept") and ($stack != "vfs" or .accept != "incomplete")
             then "\($stack) accept is \(.accept); only vfs takes one, and only incomplete" else empty end)
        end' "${mapped[@]}"
  done
}

MAP_PROJECT="$DISC_DIR/map.orcprj"

# The committed frame maps and alignment: the map stage's, reviewed. The video
# stage stacks from these.
FRAMEMAPS="$DISC_DIR/framemaps"

# map_sets: the sets map.orcprj maps, in its order: the labels of its CVBS
# sources, which are set ids. A set left out of it is not mapped.
map_sets() {
  [ -f "$MAP_PROJECT" ] || return 0
  yq -r '.dag.nodes[] | select(.stage == "*_CVBS_Source") | .user_label' "$MAP_PROJECT"
}

STACK_PROJECT="$DISC_DIR/stack.orcprj"

# stack_problems: what is wrong with stack.orcprj for the selection, one line
# each, or nothing. Its CVBS sources must be the selection's video sets, in
# its order, each with its "<set> map", and it must have the stages the video
# stage sets: Align and Video Out.
stack_problems() {
  local want have id
  [ -f "$STACK_PROJECT" ] || { printf 'is not written yet\n'; return 0; }
  want=$(selected_sets video | paste -sd' ' -)
  have=$(yq -r '.dag.nodes[] | select(.stage == "*_CVBS_Source") | .user_label' "$STACK_PROJECT" | paste -sd' ' -)
  [ "$have" = "$want" ] || printf 'stacks %s, but the selection'\''s video sets are %s\n' "${have:-nothing}" "$want"
  for id in $have "Align" "Video Out"; do
    case "$id" in Align|"Video Out") ;; *) id="$id map" ;; esac
    [ "$(yq -r "[.dag.nodes[] | select(.user_label == \"$id\")] | length" "$STACK_PROJECT")" = 1 ] \
      || printf 'has no one stage named "%s"\n' "$id"
  done
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
    set|map|video|quality) printf 'decode-orc|decode-orc|orc-cli\n' ;;
    compare)        printf 'decode-orc|decode-orc|orc-cli\nvfs-verifier|vfs-tools|vfs-stacker\n' ;;
    vfs)            printf 'vfs-verifier|vfs-tools|vfs-stacker\n' ;;
    pack)           printf 'vfs-verifier|vfs-tools|vfs-verifier\n' ;;
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

# The selected video sets stacked, from their decodes and the committed frame
# maps and alignment, which must be the map stage's. Only the video half of
# the selection counts: its sets and their order. The disc metadata is
# checked against what the chosen pressing reads (the compare stage), so that
# is an input too, as the values, not the stage. VIDEO_SETS is left as
# "<set>|<cvbs>", VIDEO_MAP names the map stage's directory and VIDEO_EXPECT
# holds the user code and Amendment 2 expected ("unknown" when the sets
# disagree or were not read).
describe_video() {
  local id ups=() ids=()
  describe_map; VIDEO_MAP="$STAGE_DIR"
  VIDEO_SETS=()
  for id in $(selected_sets video); do
    describe_decode "$id"
    ups+=("$id|$STAGE_DIR")
    VIDEO_SETS+=("$id|$STAGE_DIR/${STAGE_OUTPUTS[0]}")
  done
  mapfile -t ids < <(selected_sets video)
  VIDEO_EXPECT=unknown
  [ -f "$OUT/$ORC_DIR/compare/compare.json" ] && VIDEO_EXPECT=$(jq -r --args '[ .sets[] | select(.set | IN($ARGS.positional[])) | .metadata
      | if . == null then "unread" else "\(.user_code // "none") \(.amendment2.present // false | if . then "present" else "absent" end)" end ]
      | unique | if length == 1 and .[0] != "unread" then .[0] else "unknown" end' \
      "${ids[@]}" < "$OUT/$ORC_DIR/compare/compare.json" 2>/dev/null) || VIDEO_EXPECT="unknown"
  stage_begin video "$OUT/$ORC_DIR/video"
  for id in "${ups[@]}"; do
    stage_input_stamp "decode:${id%%|*}" "${id#*|}"
    stage_input_file "frame map ${id%%|*}" "$FRAMEMAPS/${id%%|*}.ranges"
  done
  stage_input_stamp map "$VIDEO_MAP"
  stage_input_file "alignment" "$FRAMEMAPS/alignment"
  stage_input "video sets" "$(selected_sets video | paste -sd' ' -)"
  stage_input_file "project" "$DISC_DIR/stack.orcprj"
  stage_input_tool decode-orc
  stage_input "decoder" "$VIDEO_DECODER"
  stage_input "disc" "$DISC_FORMAT side $DISC_SIDE, pictures $DISC_PICTURES, user code and Amendment 2 $VIDEO_EXPECT"
  stage_input_file "metadata check" "$SELF_DIR/lib/check-disc-metadata.py"
  stage_input "baseline" "${VIDEO_BASELINE:-none}"
  stage_output "$STEM.mkv"
  stage_output metadata.yaml
  stage_output video.json
  stage_output check.txt
}

# The selected VFS sets' EFM images stacked, best first, from the set stages.
# Only the VFS half of the selection counts: its sets, their order and what it
# accepts. The reference hash (VFS_REFERENCE) and the hand-built image
# (VFS_BASELINE) are inputs too, so recording or changing either rechecks the
# stack. VFS_SETS is left as "<set>|<set stage dir>".
describe_vfs() {
  local id
  VFS_SETS=()
  for id in $(selected_sets vfs); do describe_set "$id"; VFS_SETS+=("$id|$STAGE_DIR"); done
  stage_begin vfs "$OUT/$VFS_DIR"
  for id in "${VFS_SETS[@]}"; do stage_input_stamp "set:${id%%|*}" "${id#*|}"; done
  stage_input "vfs sets" "$(selected_sets vfs | paste -sd' ' -)"
  stage_input "vfs accepts" "$(vfs_accept)"
  stage_input_tool vfs-verifier
  stage_input_file "reference" "$VFS_REFERENCE"
  stage_input "baseline" "${VFS_BASELINE:-none}"
  stage_output "$STEM.dat"
  stage_output "$STEM.dat.bsm"
  stage_output vfs.sha256
  stage_output vfs.json
  stage_output check.txt
}

# The stacked video's SNR and dropouts, from the video stage's stack project
# as it was processed and the disc's set quality project, whose sinks measure
# the stack as they measure each set. QUALITY_VIDEO is left naming the video
# stage's directory.
describe_quality() {
  describe_video; QUALITY_VIDEO="$STAGE_DIR"
  stage_begin quality "$OUT/$ORC_DIR/quality"
  stage_input_stamp video "$QUALITY_VIDEO"
  stage_input_tool decode-orc
  stage_input_file "quality project" "$DISC_DIR/set-quality.orcprj"
  stage_output snr.csv
  stage_output dropouts.csv
  stage_output quality.json
  stage_output check.txt
}

# The pack: the video and vfs stages' outputs, and the provenance of the
# whole. Its directory is named after the key of what it holds (the two
# stacks and the stem), so each distinct pack is a version of its own and the
# newest two are kept. What only its provenance takes -- the compare stage's
# evidence, the selection and the hand check on the player -- is stamped too,
# but leaves the name alone, so recording the hand check restamps the same
# pack. So does what only its report takes: the quality stage's figures for
# the stack, and the report's script and layout, by their bytes (the layout's
# lines that start with # are code). PACK_VIDEO, PACK_VFS, PACK_COMPARE,
# PACK_MAP and PACK_QUALITY are left naming those stages' directories, and
# COMPARE_SETS each set's.
describe_pack() {
  local key
  describe_compare; PACK_COMPARE="$STAGE_DIR"; PACK_MAP="$COMPARE_MAP"
  describe_video;   PACK_VIDEO="$STAGE_DIR"
  describe_vfs;     PACK_VFS="$STAGE_DIR"
  describe_quality; PACK_QUALITY="$STAGE_DIR"
  stage_begin pack "$OUT/pack"
  stage_input_stamp video "$PACK_VIDEO"
  stage_input_stamp vfs "$PACK_VFS"
  stage_input "stem" "$STEM"
  key=$(stage_key)
  STAGE_DIR="$OUT/pack-${key:0:12}"
  stage_input_stamp compare "$PACK_COMPARE"
  stage_input_file "selection" "$SELECTION"
  stage_input_file "player check" "$PLAYER_CHECK"
  stage_input_stamp quality "$PACK_QUALITY"
  stage_input "report" "$(for f in "$SELF_DIR"/lib/pack-report.*; do printf '%s %s ' "${f##*/}" "$(sha256_stdin < "$f" | cut -c1-12)"; done)"
  stage_output "$STEM.mkv"
  stage_output "$STEM.dat"
  stage_output "$STEM.dat.bsm"
  stage_output "$STEM.provenance.yaml"
  stage_output "$STEM.report.pdf"
  stage_output SHA256SUMS
  stage_output pack.json
  stage_output check.txt
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
    video|vfs|quality|pack)
      if [ ! -f "$SELECTION" ]; then
        printf 'stale: waits on select\n'; return 1
      fi ;;
  esac
  if [ "$unit" = video ]; then
    problems=$(stack_problems)
    if [ -n "$problems" ]; then
      printf 'invalid: %s %s\n' "${STACK_PROJECT#"$SELF_DIR"/}" "$(paste -sd';' - <<< "$problems" | sed 's/;/; /g')"
      return 1
    fi
  fi
  describe_unit "$unit"
  # An up-to-date pack also says whether it has passed the hand check.
  if [ "$unit" = pack ] && state=$(stage_state); then
    printf '%s; %s\n' "$state" "$(jq -r '.status // "status unknown"' "$STAGE_DIR/pack.json" 2>/dev/null || echo 'status unknown')"
    return 0
  fi
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
  [ ! -L "$OUT/pack" ] || printf '    %-40s the current pack, %s\n' pack "$(readlink -- "$OUT/pack")"
}

if [ "$MODE" = status ]; then
  status
  exit 0
fi

# --- build -----------------------------------------------------------------

# Each stage is built from the units that are stale (or forced), all at once,
# so that a stage can run them side by side.
run_stage() {
  local name="$1"; shift
  case "$name" in
    decode) run_decode "$@"; return ;;
    set)    run_set "$@"; return ;;
    map)    run_map "$@"; return ;;
    compare) run_compare "$@"; return ;;
    select) die "select: decided by hand in ${SELECTION#"$SELF_DIR"/}; there is nothing to build" ;;
    video)  run_video "$@"; return ;;
    vfs)    run_vfs "$@"; return ;;
    quality) run_quality "$@"; return ;;
    pack)   run_pack "$@"; return ;;
  esac
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
# Its frame maps and alignment are also copied into discs/<disc>/framemaps/
# (FRAMEMAPS), for committing, so that a change in mapping shows up in
# review.

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

# --- video: the stacked, dropout-corrected mkv -----------------------------
#
# A copy of the disc's committed stack.orcprj, with its sources pointed at the
# video sets' decodes, each frame map set from the committed
# framemaps/<set>.ranges and Align from framemaps/alignment, then processed.
# Nothing is refreshed: the committed maps are the map stage's, reviewed, and
# a refresh would read every decode in full again (about an hour) to find the
# same ones. The stage checks instead that the committed copies are still the
# map stage's.
#
# The mkv is then checked as vp415e loads it (docs/emulator-pack-plan.md,
# phase 5): the container, every packet a keyframe, the audio, and the disc
# metadata document, which lib/check-disc-metadata.py reads as the format
# spec's reader does. The stacker's noise and weight for each set, and a
# comparison with the hand-built stack (VIDEO_BASELINE), go into video.json
# and check.txt.
#
# The video sink first pre-scans the stack for its VBI, then decodes it.

run_video() {
  local state
  ( build_video ) || die "video: failed (above)"
  state=$(unit_state video) || die "video: still $state after building"
  stage_prune "$OUT" orc video/stage.stamp
}

build_video() {
  local dir d id cvbs rel n=0 mode pad min map="" problems mkv rc t
  describe_video
  dir="$STAGE_DIR"
  problems=$(stack_problems)
  [ -z "$problems" ] || { printf 'video: %s %s\n' "${STACK_PROJECT#"$SELF_DIR"/}" "$problems" >&2; return 1; }
  if [ "$VIDEO_EXPECT" = unknown ]; then
    printf 'video: the compare stage gives no one user code and Amendment 2 for the video sets (%s/compare/report.txt)\n' "$OUT/$ORC_DIR" >&2
    return 1
  fi

  # The committed maps must still be the map stage's, and the alignment one
  # that pads, which a subset of the sets can take by moving every padding
  # down by the least.
  for d in "${VIDEO_SETS[@]}" "alignment|"; do
    id="${d%%|*}"; [ "$id" = alignment ] || id="$id.ranges"
    if ! cmp -s -- "$FRAMEMAPS/$id" "$VIDEO_MAP/framemaps/$id"; then
      printf 'video: %s is not the map stage'\''s %s; review with: diff %s %s\n' "${FRAMEMAPS#"$SELF_DIR"/}/$id" \
        "$VIDEO_MAP/framemaps/$id" "${FRAMEMAPS#"$SELF_DIR"/}/$id" "$VIDEO_MAP/framemaps/$id" >&2
      return 1
    fi
  done
  mode=$(sed -n '1s/^# //p' "$FRAMEMAPS/alignment")
  [ "$mode" = pad_for_alignment ] || { printf 'video: the alignment is %s; the stack takes pad_for_alignment\n' "${mode:-unstated}" >&2; return 1; }
  min=$(for d in "${VIDEO_SETS[@]}"; do awk -v s="${d%%|*}" '$1 == s { print $2 }' "$FRAMEMAPS/alignment"; done | sort -n | head -1)

  stage_mkdir "$dir" || return 1
  stage_unstamp || return 1
  rm -rf -- "$dir"/*.mkv* "$dir"/*.json* "$dir"/*.yaml* "$dir"/*.log "$dir"/*.orcprj \
            "$dir"/check.txt* "$dir"/check.failed.txt "$dir"/crash_bundle_*.zip

  mkv="$STEM.building.mkv"
  cp -- "$STACK_PROJECT" "$dir/stack.orcprj"
  for d in "${VIDEO_SETS[@]}"; do
    id="${d%%|*}" cvbs="${d#*|}"
    n=$(( n + 1 ))
    pad=$(awk -v s="$id" '$1 == s { print $2 }' "$FRAMEMAPS/alignment")
    [[ "$pad" =~ ^[0-9]+$ ]] || { printf 'video: %s has no padding in the alignment\n' "$id" >&2; return 1; }
    map+="${map:+, }$n+$(( pad - min ))"
    rel=$(realpath --relative-to="$dir" -- "$cvbs")
    if ! { orc-cli nodes set "$dir/stack.orcprj" "$id" "input_path=$rel" \
           && orc-cli nodes set "$dir/stack.orcprj" "$id map" "ranges=$(paste -sd, - < "$FRAMEMAPS/$id.ranges")"; } >/dev/null; then
      printf 'video: could not point %s at %s and its frame map\n' "$id" "$cvbs" >&2
      return 1
    fi
  done
  if ! { orc-cli nodes set "$dir/stack.orcprj" Align "alignmentMode=$mode" "alignmentMap=$map" \
         && orc-cli nodes set "$dir/stack.orcprj" "Video Out" "output_path=$mkv" "decoder_type=$VIDEO_DECODER"; } >/dev/null; then
    printf 'video: could not set the alignment and the video sink\n' >&2
    return 1
  fi

  cd -- "$dir" || return 1
  printf 'video: stacking %s (alignment %s), decoder %s; progress is in %s/stack.log\n' \
    "$(selected_sets video | paste -sd' ' -)" "$map" "$VIDEO_DECODER" "$dir"
  t=$SECONDS rc=0
  orc-cli "$dir/stack.orcprj" --process --log-file "$dir/stack.log" --log-out file > "$dir/console.log" 2>&1 || rc=$?
  printf 'video: orc-cli exited %s after %ss\n' "$rc" "$(( SECONDS - t ))"

  if ! check_video "$dir" "$rc" "$mkv"; then
    cat -- "$dir/check.failed.txt" >&2
    printf 'video: failed its checks and is not stamped (see %s/check.failed.txt)\n' "$dir" >&2
    return 1
  fi
  mv -- "$dir/$mkv" "$(stage_tmp "$STEM.mkv")"
  cat -- "$dir/check.txt.partial"
  stage_commit || { printf 'video: could not stamp the stage\n' >&2; return 1; }
  printf 'video: checked and stamped: %s/%s.mkv\n' "$dir" "$STEM"
}

# check_video <dir> <orc-cli exit code> <mkv>: run the checks, write check.txt,
# metadata.yaml and video.json to their stage_tmp names, and return non-zero
# if any failed.
check_video() {
  local dir="$1" rc="$2" mkv="$1/$3" out fails=0 level text frames=0 keys=0 base=""
  local -a sets=()
  out=$(stage_tmp check.txt) || return 1
  ok()   { printf 'ok    %s\n' "$*"; }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }
  mapfile -t sets < <(selected_sets video)

  {
    printf 'stage:   video\nsets:    %s\ndecoder: %s\nchecked: %s\n\n' "${sets[*]}" "$VIDEO_DECODER" "$(date '+%F %T')"

    if [ "$rc" = 0 ] && grep -q 'VideoSink: Successfully wrote' "$dir/stack.log" 2>/dev/null; then
      ok "the stack was processed: $(sed -n 's/.*VideoSink: Successfully wrote \([0-9]*\) frames.*/\1/p' "$dir/stack.log" | tail -1) frames written"
    else
      fail "orc-cli exited $rc ($(grep -v '\[\(info\|debug\)\]' "$dir/stack.log" 2>/dev/null | tail -3 | tr '\n' ' '))"
    fi

    check_mkv "$mkv" "$dir" "$(stage_tmp metadata.yaml)"

    # The stacker's view of each set: its noise and share of the weight,
    # every 500 frames.
    video_weights "$dir/stack.log" "${sets[@]}" > "$dir/weights.json" || fail "could not read the stacker's weights from stack.log"
    while IFS= read -r text; do note "$text"; done < <(jq -r '
      if .measurements == 0 then "the stacker logged no weights" else
        "stack weights, the mean of \(.measurements) measurement(s): "
          + ([ .sets[] | "\(.set) σ \(.mean_sigma // "-") at \(.mean_share // "-")% (least \(.least_share // "-")%)" ] | join(", ")),
        (.sets[] | select((.mean_share // 0) < 5) | "\(.set) carries almost no weight (\(.mean_share // 0)%)"),
        (.sample_grid[] | "\(.set): sample grid \(.samples | if . > 0 then "+\(.)" else tostring end) from the first set'"'"'s, from frame \(.from_frame)") end' "$dir/weights.json")

    # The hand-built stack, for comparison: not a pass or a fail.
    if [ -n "${VIDEO_BASELINE:-}" ] && [ -f "$DD_DECODES/$VIDEO_BASELINE" ] \
       && ffmpeg -v error -y -dump_attachment:m:filename:orc-disc-metadata.yaml "$dir/baseline.yaml" \
                 -i "$DD_DECODES/$VIDEO_BASELINE" -frames:v 1 -f null - >> "$dir/console.log" 2>&1; then
      pack-python "$SELF_DIR/lib/check-disc-metadata.py" "$dir/baseline.yaml" \
        --frames "$(yq -r '.video.frame_count' "$dir/baseline.yaml")" --format "$DISC_FORMAT" --side "$DISC_SIDE" \
        --pictures "$DISC_PICTURES" > "$dir/baseline-check.json" || true
      base="$dir/baseline-check.json"
      while IFS= read -r text; do note "$text"; done < <(jq -r --slurpfile s "$dir/metadata-check.json" --arg path "$VIDEO_BASELINE" '
        def fig: "\(.frame_count) frames, \(.address_map.runs) run(s), \(.address_map.undecoded) undecoded, \(.address_map.unmapped) unmapped, status agreement \(.disc.agreement)";
        .summary as $b | ($s[0].summary // {}) as $n
        | "baseline \($path): \($b | fig)",
          "this stack: \($n | fig)",
          (if ($n.address_map.undecoded // 1e9) > $b.address_map.undecoded or ($n.address_map.runs // 1e9) > $b.address_map.runs
           then "this stack reads its VBI worse than the baseline" else "this stack reads its VBI no worse than the baseline" end)' "$base" 2>/dev/null)
    else
      note "no baseline to compare with${VIDEO_BASELINE:+ ($VIDEO_BASELINE not found)}"
    fi

    # Everything the pack's provenance (phase 7) takes from this stage.
    jq -n --args --slurpfile probe "$dir/probe.json" --slurpfile weights "$dir/weights.json" \
          --rawfile meta "$dir/metadata-check.json" --rawfile base "${base:-/dev/null}" \
          --arg decoder "$VIDEO_DECODER" --argjson frames "$frames" --argjson keys "$keys" \
          --arg baseline "${VIDEO_BASELINE:-}" '
      { sets: $ARGS.positional, decoder: $decoder,
        container: ($probe[0] | { format: .format.format_name, tags: .format.tags,
                                  streams: [ .streams[] | del(.tags.filename, .tags.mimetype) ] })
                   + { packets: $frames, keyframes: $keys },
        metadata: ($meta | fromjson? // {} | .summary),
        stacker: $weights[0],
        baseline: (if $baseline == "" then null else { path: $baseline, metadata: ($base | fromjson? // {} | .summary) } end) }' \
      "${sets[@]}" > "$(stage_tmp video.json)" || fail "could not write video.json"

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dir/check.failed.txt"
    return 1
  fi
  rm -f -- "$dir/check.failed.txt"
}

# check_mkv <mkv> <work dir> <metadata out>: the checks of an mkv as vp415e
# loads it (docs/emulator-pack-plan.md, phase 5): the container, every packet
# a keyframe, the audio, and the disc metadata document, extracted to
# <metadata out> and read by lib/check-disc-metadata.py as the format spec's
# reader does. Reports with the caller's ok and fail, leaves probe.json and
# metadata-check.json in <work dir>, and sets the caller's frames and keys.
check_mkv() {
  local mkv="$1" work="$2" meta="$3" level text tagv code a2
  local -a expect=()
  if [ -s "$mkv" ]; then
    # The container, as vp415e loads it.
    ffprobe -v error -show_entries format=format_name:format_tags:stream=index,codec_type,codec_name,pix_fmt,width,height,coded_width,coded_height,r_frame_rate,sample_aspect_ratio,display_aspect_ratio,bits_per_raw_sample,sample_rate,channels:stream_tags=filename,mimetype,title \
      -of json "$mkv" > "$work/probe.json" 2>> "$work/console.log" || fail "ffprobe could not read the mkv"
    while IFS=$'\t' read -r level text; do "$level" "$text"; done < <(jq -r '
      def check(c; good; bad): if c then "ok\t\(good)" else "fail\t\(bad)" end;
      [ .streams[] | select(.codec_type == "video") ] as $v | [ .streams[] | select(.codec_type == "audio") ] as $a
      | check(.format.format_name | startswith("matroska"); "the container is Matroska"; "the container is \(.format.format_name), not Matroska"),
        (if ($v | length) != 1 then "fail\t\($v | length) video streams, not one" else $v[0] |
          check(.codec_name == "ffv1"; "video is FFV1"; "video is \(.codec_name), not FFV1"),
          check(.pix_fmt == "yuv422p" and .bits_per_raw_sample == "8"; "video is yuv422p, 8-bit"; "video is \(.pix_fmt), \(.bits_per_raw_sample)-bit, not yuv422p 8-bit"),
          check([.width, .height, .coded_width, .coded_height] == [720, 576, 720, 576]; "video is 720x576, coded 720x576";
                "video is \(.width)x\(.height), coded \(.coded_width)x\(.coded_height), not 720x576"),
          check(.r_frame_rate == "25/1"; "video is exactly 25/1"; "video is \(.r_frame_rate), not 25/1"),
          check(.display_aspect_ratio == "4:3"; "display aspect 4:3 (sample aspect \(.sample_aspect_ratio))"; "display aspect \(.display_aspect_ratio), not 4:3") end),
        (if ($a | length) == 0 then "fail\tno audio stream" else $a[] |
          check(.codec_name == "flac" and .sample_rate == "48000";
                "audio stream \(.index) (\(.tags.title // "untitled")) is FLAC at 48 kHz, \(.channels) channels";
                "audio stream \(.index) is \(.codec_name) at \(.sample_rate) Hz, not FLAC at 48 kHz") end),
        ([ .streams[] | select(.codec_type == "attachment" and .tags.filename == "orc-disc-metadata.yaml"
                               and .tags.mimetype == "application/vnd.decode-orc.disc-metadata+yaml") ] | length
         | check(. == 1; "the disc metadata is attached, by its filename and MIME type"; "\(.) attachments named orc-disc-metadata.yaml with its MIME type, not one"))' "$work/probe.json")

    # Every packet a keyframe, counted over the whole stream.
    read -r frames keys < <(ffprobe -v error -select_streams v:0 -show_entries packet=flags -of csv=p=0 "$mkv" \
                              | awk '{ n++ } /^K/ { k++ } END { print n + 0, k + 0 }')
    if [ "$frames" -gt 0 ] && [ "$frames" = "$keys" ]; then
      ok "all $frames video packets are keyframes"
    else
      fail "$keys of $frames video packets are keyframes"
    fi

    # The disc metadata, read as the format spec's reader reads it.
    if ffmpeg -v error -y -dump_attachment:m:filename:orc-disc-metadata.yaml "$meta" \
              -i "$mkv" -frames:v 1 -f null - >> "$work/console.log" 2>&1; then
      tagv=$(jq -r '.format.tags.ORC_DISC_METADATA_VERSION // ""' "$work/probe.json")
      read -r code a2 <<< "$VIDEO_EXPECT"
      expect=(--amendment2 "$a2")
      [ "$code" = none ] || expect+=(--user-code "$code")
      pack-python "$SELF_DIR/lib/check-disc-metadata.py" "$meta" --frames "$frames" \
        --format "$DISC_FORMAT" --side "$DISC_SIDE" --pictures "$DISC_PICTURES" --tag-version "$tagv" "${expect[@]}" \
        > "$work/metadata-check.json" || true
      while IFS=$'\t' read -r level text; do "$level" "metadata: $text"; done < <(
        jq -r '.checks[] | "\(.level)\t\(.text)"' "$work/metadata-check.json" 2>/dev/null || printf 'fail\tthe metadata check did not run\n')
    else
      fail "the disc metadata could not be extracted"
    fi
  else
    fail "${mkv##*/} is missing or empty"
  fi
}

# video_weights <stack.log> <set>...: the stacker's measured noise and share
# of the weight for each set, averaged over the measurements it logs (one
# whenever they change, for a block of frames), and each shift of a set's
# sample grid onto the first set's. Its sources are the sets in the order
# given; the noise lines list them in order, "-" for one not measured, and
# the grid lines number them from 0.
video_weights() {
  local log="$1"; shift
  jq -R -s --args '
    def r: . * 10 | round / 10;
    split("\n") as $lines
    | [ $lines[] | capture("StackerStage: frames [0-9]+-[0-9]+: input noise σ in codes \\(share of the weight\\) (?<list>[^;]*)")?
        | [ .list | split(", ")[] | (capture("^(?<sigma>[0-9.]+) \\((?<share>[0-9.]+)%\\)$") | map_values(tonumber)) // null ] ] as $logged
    | [ $lines[] | capture("StackerStage: frames (?<from>[0-9]+)-[0-9]+: source (?<n>[0-9]+) sample grid is (?<lag>[-+][0-9]+) ")?
        | map_values(tonumber) ] as $shifts
    | { measurements: ($logged | length),
        sets: [ $ARGS.positional | to_entries[] | .key as $i
                | [ $logged[] | .[$i] | select(. != null) ] as $m
                | { set: .value, measurements: ($m | length),
                    mean_sigma: (if ($m | length) > 0 then [ $m[].sigma ] | add / length | r else null end),
                    mean_share: (if ($m | length) > 0 then [ $m[].share ] | add / length | r else null end),
                    least_share: ([ $m[].share ] | min) } ],
        sample_grid: [ $shifts[] | { set: $ARGS.positional[.n], from_frame: .from, samples: .lag } ] }' \
    "$@" < "$log"
}

# --- vfs: the stacked, verified .dat and .bsm ------------------------------
#
# vfs-stacker merges the VFS sets' EFM images, best first, with its default
# majority consensus, and vfs-verifier reads the ADFS filesystem of the
# result. Neither exits non-zero for a bad image, so both logs are parsed.
#
# The image is then given the bit-perfect test (docs/emulator-pack-plan.md,
# phase 6). Most of a disc's EFM track is free space that no capture
# recovers, so the test is about what the filesystem depends on:
#
# 1. vfs-stacker's RESULT is GOOD: no sector in file data, the filesystem's
#    metadata or allocated space is still bad;
# 2. vfs-verifier passes: the filesystem is found and whole, and no bad
#    sector touches an object;
# 3. no sector the filesystem depends on rests on one capture, and no sector
#    at all was decided by a vote the sets split over.
#
# An image that fails stops the stage, with the bad sectors, the objects they
# fall in and which mapped sets recover any of them, unless the selection
# accepts an incomplete image (vfs.accept). Once an image has passed, its hash
# goes in VFS_REFERENCE, by hand after review; every later stack must match
# it. A dry run of vfs-stacker over this image and the hand-built one
# (VFS_BASELINE) shows whether the two hold the same bytes wherever both
# recovered a sector.

run_vfs() {
  local state
  ( build_vfs ) || die "vfs: failed (above)"
  state=$(unit_state vfs) || die "vfs: still $state after building"
  stage_prune "$OUT" vfs stage.stamp
}

build_vfs() {
  local dir s id sdir dat="$STEM.building.dat" rc vrc brc=none t
  local -a images=()
  describe_vfs
  dir="$STAGE_DIR"

  stage_mkdir "$dir" || return 1
  stage_unstamp || return 1
  rm -f -- "${dir:?}"/*.dat "${dir:?}"/*.dat.* "${dir:?}"/*.txt* "${dir:?}"/*.json* "${dir:?}"/*.sha256* "${dir:?}"/*.log
  cd -- "$dir" || return 1

  for s in "${VFS_SETS[@]}"; do
    IFS='|' read -r id sdir <<< "$s"
    images+=("$(realpath --relative-to="$dir" -- "$sdir/${id,,}_efm.dat")")
  done

  printf 'vfs: stacking the EFM images of %s\n' "$(selected_sets vfs | paste -sd' ' -)"
  t=$SECONDS rc=0
  vfs-stacker --log-file "$dir/vfs-stacker.debug.log" -o "$dat" "${images[@]}" > "$dir/vfs-stacker.txt" 2>&1 || rc=$?
  printf 'vfs: vfs-stacker exited %s after %ss\n' "$rc" "$(( SECONDS - t ))"
  vrc=0
  if [ -f "$dat" ]; then
    vfs-verifier "$dat" > "$dir/vfs-verifier.txt" 2>&1 || vrc=$?
  else
    : > "$dir/vfs-verifier.txt"
  fi
  printf 'vfs: vfs-verifier exited %s\n' "$vrc"
  : > "$dir/baseline.txt"
  if [ -n "${VFS_BASELINE:-}" ] && [ -f "$DD_DECODES/$VFS_BASELINE" ] && [ -f "$dat" ]; then
    brc=0
    vfs-stacker --dry-run "$dat" "$(realpath --relative-to="$dir" -- "$DD_DECODES/$VFS_BASELINE")" > "$dir/baseline.txt" 2>&1 || brc=$?
    printf 'vfs: compared with the hand-built image (exit %s)\n' "$brc"
  fi

  if ! check_vfs "$dir" "$rc" "$vrc" "$brc" "$dat"; then
    cat -- "$dir/check.failed.txt" >&2
    printf 'vfs: failed its checks and is not stamped (see %s/check.failed.txt)\n' "$dir" >&2
    return 1
  fi
  mv -- "$dir/$dat.bsm" "$(stage_tmp "$STEM.dat.bsm")"
  mv -- "$dir/$dat" "$(stage_tmp "$STEM.dat")"
  cat -- "$dir/check.txt.partial"
  stage_commit || { printf 'vfs: could not stamp the stage\n' >&2; return 1; }
  printf 'vfs: checked and stamped: %s/%s.dat\n' "$dir" "$STEM"
}

# check_vfs <dir> <vfs-stacker exit> <vfs-verifier exit> <baseline exit|none> <image>:
# run the checks, write check.txt, vfs.json and vfs.sha256 to their stage_tmp
# names, and return non-zero if any failed.
check_vfs() {
  local dir="$1" rc="$2" vrc="$3" brc="$4" dat="$1/$5" out fails=0 level text accept hash bsmhash size
  local -a sets=() mapped=()
  out=$(stage_tmp check.txt) || return 1
  ok()   { printf 'ok    %s\n' "$*"; }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }
  mapfile -t sets < <(selected_sets vfs)
  accept=$(vfs_accept)

  {
    printf 'stage:   vfs\nsets:    %s\naccepts: %s\nchecked: %s\n\n' "${sets[*]}" "$accept" "$(date '+%F %T')"

    if [ "$rc" = 0 ] && [ -s "$dat" ] && [ -f "$dat.bsm" ] && grep -q '^\[info\] Wrote ' "$dir/vfs-stacker.txt"; then
      ok "vfs-stacker wrote the image and its bad sector map"
    else
      fail "vfs-stacker exited $rc without writing the image ($(grep -v '^\[info\]' "$dir/vfs-stacker.txt" | tail -3 | tr '\n' ' '))"
    fi
    if [ "$vrc" = 0 ] && grep -q 'Verification \(passed\|failed\)' "$dir/vfs-verifier.txt"; then
      ok "vfs-verifier read the image"
    else
      fail "vfs-verifier exited $vrc without a verdict ($(grep -v '^\[info\]' "$dir/vfs-verifier.txt" | tail -3 | tr '\n' ' '))"
    fi

    if [ -s "$dat" ]; then
      size=$(stat -c %s -- "$dat" 2>/dev/null || stat -f %z -- "$dat")
      hash=$(sha256_stdin < "$dat")
      bsmhash=$(sha256_stdin < "$dat.bsm")
    fi
    mapfile -t mapped < <(map_sets)
    vfs_digest "$dir/vfs-stacker.txt" "$dir/vfs-stacker.debug.log" "$dir/vfs-verifier.txt" "$dir/baseline.txt" \
               "$dat.bsm" "${size:-0}" "${hash:-}" "${bsmhash:-}" "${sets[@]}" > "$dir/digest.json" \
      || fail "could not read the vfs-stacker and vfs-verifier logs"

    # The image itself.
    while IFS=$'\t' read -r level text; do "$level" "$text"; done < <(jq -r '
      def check(c; good; bad): if c then "ok\t\(good)" else "fail\t\(bad)" end;
      .image as $i | .stack as $s
      | check($i.size == ($s.output_sectors // -1) * 2048; "the image is \($s.output_sectors) EFM sectors (\($i.size) bytes)";
              "the image is \($i.size) bytes, not \($s.output_sectors) EFM sectors"),
        check($i.bsm_malformed == 0 and $i.bsm_sectors == ($s.bad // -1);
              "the bad sector map parses: \($i.bsm_sectors) sectors, as vfs-stacker reports";
              "the bad sector map has \($i.bsm_malformed) malformed line(s) and \($i.bsm_sectors) sectors, against \($s.bad) reported"),
        (if $s.padded > 0 then "note\t\($s.padded) sector(s) at the end are padding to the disc length: no set reached them" else empty end)' "$dir/digest.json")

    # The bit-perfect test. With the selection accepting an incomplete image,
    # its failures are reported but do not stop the stage.
    while IFS=$'\t' read -r level text; do
      [ "$level" != fail ] || [ "$accept" != incomplete ] || level=note
      "$level" "$text"
    done < <(jq -r '
      def check(c; good; bad): if c then "ok\t\(good)" else "fail\t\(bad)" end;
      .stack as $s | .verify as $v
      | check($s.result.verdict == "GOOD"; "1. vfs-stacker: GOOD, every sector the filesystem depends on was recovered";
              "1. vfs-stacker: \($s.result.verdict // "no result"): \($s.result.text // "see vfs-stacker.txt")"),
        check($v.passed and $v.located and ($v.roles.allocated_unlisted // 1) == 0 and $v.truncated == false;
              "2. vfs-verifier: passed; the filesystem is located and whole, and all \($v.objects) object(s) are free of bad sectors";
              "2. vfs-verifier: \(if $v.passed then "passed" else "failed" end); located \($v.located), free space map \($v.fsm), root directory \($v.directory), \($v.objects_damaged) object(s) damaged, \($v.roles.allocated_unlisted) bad sector(s) in allocated space no object lists\(if $v.truncated then ", truncated" else "" end)"),
        check(($s.vital_only == 0) and $s.majority == 0 and $s.split == 0 and $s.contested == 0 and $s.disagreements == 0;
              "3. no sector the filesystem depends on rests on one set, and no vote was split";
              "3. \($s.vital_only) sector(s) the filesystem depends on rest on one set; \($s.majority) majority vote(s), \($s.split) split, \($s.contested) contested consensus, \($s.disagreements) sector(s) the sets disagree on"),
        "note\tbad sectors by role: \($s.roles | to_entries | map("\(.key | gsub("_"; " ")) \(.value)") | join(", "))",
        "note\trecovered: \($s.unanimous) by agreement, \($s.consensus) by consensus (\($s.consensus_two) on two sets); stacking gained \($s.recovered_over_best // 0) over the best set alone (\($s.best_single.set // "?"), whose image is \($s.best_single.bad // "?") bad)",
        (.sets[] | select(.only_good > 0) | "note\t\(.set) alone recovered \(.only_good) sector(s), \(.vital_only) of them needed by the filesystem"),
        (if $v.fill_unflagged > 0 then "note\t\($v.fill_unflagged) recovered sector(s) within objects are blank fill: blank on the disc, or lost without the decoder noticing, which vfs-verifier cannot tell apart" else empty end),
        (if $v.unaccounted > 0 then "note\t\($v.unaccounted) used sector(s) belong to no object in the root directory (allocation slack, or subdirectories, which vfs-verifier does not descend)" else empty end),
        (if $v.displaced > 0 then "fail\t\($v.displaced) free extent(s) disagree with the content: a run of sectors may have been lost or duplicated" else empty end)' "$dir/digest.json")

    # What is still bad, for deciding what to do (phase 6, step 4).
    if [ "$(jq '.stack.vital | length' "$dir/digest.json" 2>/dev/null || echo 0)" != 0 ]; then
      vfs_coverage "$dir/digest.json" "${mapped[@]}" > "$dir/coverage.json" || fail "could not work out which sets cover the bad sectors"
      while IFS= read -r text; do note "$text"; done < <(jq -r '
        "still bad, and needed by the filesystem:", (.runs[] | "  \(.text)"),
        (.sets[] | "  \(.set)\(if .in_stack then "" else " (not in the stack)" end): reaches \(.reaches), recovers \(.recovers) of them")' "$dir/coverage.json")
    fi

    # The reference, once recorded.
    printf '%s  %s\n%s  %s\n' "${hash:-}" "$STEM.dat" "${bsmhash:-}" "$STEM.dat.bsm" > "$(stage_tmp vfs.sha256)"
    if [ -f "$VFS_REFERENCE" ]; then
      if diff -q <(grep -v '^#' "$VFS_REFERENCE") "$dir/vfs.sha256.partial" > /dev/null; then
        ok "the image and its map match the reference, ${VFS_REFERENCE#"$SELF_DIR"/}"
      else
        fail "the image or its map differs from the reference, ${VFS_REFERENCE#"$SELF_DIR"/}; if the change is expected, record it: cp $dir/vfs.sha256 ${VFS_REFERENCE#"$SELF_DIR"/}"
      fi
    else
      note "no reference yet; once this image is reviewed, record it: cp $dir/vfs.sha256 ${VFS_REFERENCE#"$SELF_DIR"/}"
    fi

    # The hand-built image, for comparison. Sectors both recovered must hold
    # the same bytes; otherwise there is a pipeline bug or a pressing
    # difference to explain before the pack ships. Lacking more than it does
    # of what the filesystem needs fails too, unless an incomplete image is
    # accepted.
    if [ "$brc" = none ]; then
      note "no baseline to compare with${VFS_BASELINE:+ ($VFS_BASELINE not found)}"
    else
      while IFS=$'\t' read -r level text; do
        [ "$level" != lacks ] || { [ "$accept" = incomplete ] && level=note || level=fail; }
        "$level" "$text"
      done < <(jq -r --arg path "$VFS_BASELINE" '
        .baseline as $b
        | if $b.compared == null then "fail\tvfs-stacker could not compare this image with \($path) (baseline.txt)" else
            (if $b.disagreed == 0 then "ok\tthis image and \($path) hold the same bytes in all \($b.compared) sector(s) both recovered"
             else "fail\tthis image and \($path) differ in \($b.disagreed) of the \($b.compared) sector(s) both recovered (a pipeline bug or a pressing difference; see baseline.txt)" end),
            (if $b.ours.vital_bad > $b.theirs.vital_bad then "lacks\tthis image lacks \($b.ours.vital_bad) sector(s) the filesystem needs, the baseline \($b.theirs.vital_bad)"
             else "ok\tthis image lacks no more of what the filesystem needs than the baseline (\($b.ours.vital_bad) against \($b.theirs.vital_bad))" end),
            "note\tbad sectors: \($b.ours.bad) here, \($b.theirs.bad) in the baseline; \($b.ours.only_good) recovered only here, \($b.theirs.only_good) only there"
          end' "$dir/digest.json")
    fi

    jq --arg accept "$accept" '
      { sets, accept: $accept, image, stack, verify, baseline,
        bit_perfect: (.stack.result.verdict == "GOOD" and .verify.passed and .stack.vital_only == 0
                      and .stack.majority == 0 and .stack.split == 0 and .stack.contested == 0 and .stack.disagreements == 0) }
      | .verdict = (if .bit_perfect then "bit-perfect" else "incomplete" end)' "$dir/digest.json" > "$(stage_tmp vfs.json)" \
      || fail "could not write vfs.json"
    [ "$fails" != 0 ] || note "verdict: $(jq -r .verdict "$dir/vfs.json.partial")"

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dir/check.failed.txt"
    return 1
  fi
  rm -f -- "$dir/check.failed.txt"
}

# vfs_digest <vfs-stacker log> <its debug log> <vfs-verifier log> <baseline log>
#            <bsm> <size> <sha256> <bsm sha256> <set>...: what the logs say,
# as JSON. Neither tool reports anything but text, so the lines are parsed
# here; vfs-stacker's sources are the sets in the order given, and in the
# baseline's dry run this image is source 1 and the baseline source 2. The
# stacker lists at most 20 runs of still-bad sectors at info level, so the
# vital ones are read from its debug log, which has them all.
vfs_digest() {
  local stack="$1" debug="$2" verify="$3" base="$4" bsm="$5" size="$6" hash="$7" bsmhash="$8"; shift 8
  jq -n --args --rawfile stack "$stack" --rawfile debug "$debug" --rawfile verify "$verify" --rawfile base "$base" \
        --argjson size "$size" --arg hash "$hash" --arg bsmhash "$bsmhash" \
        --argjson bsm "$(awk '/^[[:space:]]*$/ { next } /^[[:space:]]*[0-9]+[[:space:]]*$/ { n++; next } { m++ }
                               END { printf "{\"sectors\": %d, \"malformed\": %d}", n, m }' "$bsm" 2>/dev/null || echo '{"sectors": 0, "malformed": -1}')" '
    def lines($t): $t | split("\n") | map(sub("^\\[[a-z]+\\] "; ""));
    def first($l; re): [ $l[] | capture(re)? ] | .[0] // null;
    def num($l; re): first($l; re) | if . == null then null else .n | tonumber end;
    def contribution($l): [ $l[] | capture("^    (?<image>[^ ]+) +(?<used>[0-9]+) +(?<only_good>[0-9]+) +(?<vital_only>[0-9]+) +(?<vital_bad>[0-9]+)$")?
                            | del(.image) | map_values(tonumber) ];
    def sources($l): [ $l[] | capture("^    (?<image>[^ ]+) +(?<sectors>[0-9]+) +[0-9.]+ MB +(?<bad>[0-9]+) +[0-9.]+%$")?
                       | .sectors |= tonumber | .bad |= tonumber ];
    def role($l; $what): num($l; "^  \($what) +: (?<n>[0-9]+)");
    lines($stack) as $s | lines($debug) as $d | lines($verify) as $v | lines($base) as $b
    | sources($s) as $src | contribution($s) as $con
    | ($d | index(["Sectors the filesystem depends on that are still bad:"])) as $at
    | { sets: [ $ARGS.positional | to_entries[] | { set: .value } + ($src[.key] // {} | del(.image)) + ($con[.key] // {}) ],
        image: { size: $size, sha256: $hash, bsm_sha256: $bsmhash, bsm_sectors: $bsm.sectors, bsm_malformed: $bsm.malformed },
        stack: ({ result: first($s; "RESULT: (?<verdict>[A-Z]+) - (?<text>.*)$"),
                  output_sectors: num($s; "^  Output holds (?<n>[0-9]+) EFM"),
                  unanimous: num($s; "^  Recovered by agreement +: (?<n>[0-9]+)"),
                  majority: (num($s; "^  Recovered by majority vote +: (?<n>[0-9]+)") // 0),
                  split: (num($s; "^  Recovered but split +: (?<n>[0-9]+)") // 0),
                  consensus: (num($s; "^  Recovered by consensus +: (?<n>[0-9]+)") // 0),
                  consensus_two: (num($s; "^    Accepted on two sources +: (?<n>[0-9]+)") // 0),
                  contested: (num($s; "^    Contested +: (?<n>[0-9]+)") // 0),
                  unrecovered: num($s; "^  Still bad in every source +: (?<n>[0-9]+)"),
                  padded: (num($s; "^  Padding at the end +: (?<n>[0-9]+)") // 0),
                  disagreements: (num($s; "^Source disagreement \\((?<n>[0-9]+) sector") // 0),
                  recovered_over_best: num($s; "^  Stacking recovered (?<n>[0-9]+) EFM sector"),
                  best_single: (first($s; "^  Best single source  : (?<image>.+) with (?<n>[0-9]+) bad") as $best
                                | if $best == null then null else
                                    { set: ([ $src | to_entries[] | select(.value.image == $best.image) | $ARGS.positional[.key] ] | .[0]),
                                      bad: ($best.n | tonumber) } end),
                  vital_only: ([ $con[].vital_only ] | add // 0),
                  roles: { file_data: role($s; "Within file data"), metadata: role($s; "Filesystem metadata"),
                           allocated_unlisted: role($s; "Allocated, not in any object"),
                           before_filesystem: num($s; "^  Before the filesystem +: (?<n>[0-9]+) \\(harmless\\)"),
                           free_space: num($s; "^  Free space +: (?<n>[0-9]+) \\(harmless\\)"),
                           past_end: num($s; "^  Past the end of the image +: (?<n>[0-9]+) \\(harmless\\)") },
                  vital: (if $at == null then [] else
                            $d[$at + 1:] | (map(test("^    [0-9]")) | index(false) // length) as $n | .[:$n]
                            | map(capture("^    (?<from>[0-9]+)(-(?<to>[0-9]+) \\([^)]*\\))?(?<where>.*)$")
                                  | { from: (.from | tonumber), to: ((.to // .from) | tonumber), where: (.where | sub("^ (in |- )"; "")) }) end) }
                | .bad = ((.unrecovered // 0) + .padded)),
        verify: { passed: any($v[]; test("Verification passed")),
                  located: any($v[]; test("Located by validated")),
                  fsm: (first($v; "Free space map \\(sectors 0-1\\) : (?<s>.*)$") | .s? // null),
                  directory: (first($v; "Root directory \\(sectors 2-6\\) : (?<s>.*)$") | .s? // null),
                  metadata_bad: any($v[]; test("Metadata occupies .* listed as BAD")),
                  truncated: any($v[]; test("Image is TRUNCATED")),
                  objects: ((num($v; "^  All (?<n>[0-9]+) object\\(s\\) are free") // num($v; "^  [0-9]+ of (?<n>[0-9]+) object\\(s\\) are affected")) // 0),
                  objects_damaged: (num($v; "^  (?<n>[0-9]+) of [0-9]+ object\\(s\\) are affected") // 0),
                  fill_unflagged: (num($v; "^  (?<n>[0-9]+) fill sector\\(s\\) are not accounted") // 0),
                  displaced: (num($v; "^  (?<n>[0-9]+) of [0-9]+ free extent\\(s\\) disagree") // 0),
                  unaccounted: (num($v; "^  Unaccounted +: (?<n>[0-9]+) sector") // 0),
                  roles: { file_data: role($v; "Within file data"), metadata: role($v; "Filesystem metadata"),
                           allocated_unlisted: role($v; "Allocated, not in any object"),
                           before_filesystem: role($v; "Before the filesystem"),
                           free_space: num($v; "^  Free space \\(harmless\\) +: (?<n>[0-9]+)"),
                           past_end: role($v; "Past the end of the image") } },
        baseline: (sources($b) as $bs | contribution($b) as $bc
                   | first($b; "^    1 vs 2 +(?<compared>[0-9]+) +(?<disagreed>[0-9]+) ") as $pair
                   | { compared: ($pair.compared? | if . == null then null else tonumber end),
                       disagreed: ($pair.disagreed? | if . == null then null else tonumber end),
                       ours: (($bs[0] // {}) + ($bc[0] // {}) | del(.image)),
                       theirs: (($bs[1] // {}) + ($bc[1] // {}) | del(.image)) }) }' "$@"
}

# vfs_coverage <digest.json> <set>...: for the sectors the filesystem needs
# that the stack still lacks, how many each mapped set's own image reaches
# and recovers. A set outside the stack that recovers some is worth adding.
vfs_coverage() {
  local digest="$1" id img sectors
  local -a rows=()
  for id; do
    img="$OUT/$ORC_DIR/sets/$id/${id,,}_efm.dat"
    [ -f "$img" ] || continue
    sectors=$(( $(stat -L -c %s -- "$img" 2>/dev/null || stat -L -f %z -- "$img") / 2048 ))
    rows+=("$(jq -r '.stack.vital[] | "\(.from) \(.to)"' "$digest" | awk -v n="$sectors" -v id="$id" '
      FNR == NR { bad[$1 + 0] = 1; next }
      { for (s = $1 + 0; s <= $2 + 0; s++) if (s < n) { r++; if (!(s in bad)) g++ } }
      END { printf "{\"set\": \"%s\", \"reaches\": %d, \"recovers\": %d}\n", id, r, g }' "$img.bsm" -)")
  done
  printf '%s\n' "${rows[@]}" | jq -s --slurpfile d "$digest" '
    ($d[0].sets | map(.set)) as $stack
    | { runs: [ $d[0].stack.vital[] | { text: "\(if .from == .to then "\(.from)" else "\(.from)-\(.to)" end) \(.where)" } ],
        sets: map(. + { in_stack: (.set as $s | $stack | index($s) != null) }) }'
}

# --- quality: the stacked video, measured as each set is -------------------
#
# The set stage measures each set's SNR and dropouts; this measures the stack
# the same way, so the pack's report can set the two side by side. The video
# stage's stack.orcprj, as it was processed, keeps its stacker and everything
# that feeds it; what came after (dropout correction and the video sink) is
# replaced by the SNR and dropout sinks of the disc's set-quality.orcprj, so
# both are measured with the same settings. The stacker's output is what
# stacking gained (SNR), and what it left for dropout correction to conceal
# (dropouts). Burst level is the capture's, not something stacking improves,
# so it is not measured again.
#
# Each sink's tool is run as the set stage runs it, and each run stacks the
# whole disc again: about two hours in all for Volcanoes. Its own stamp keeps
# it to once per stack.

# The set analyses this stage runs on the stack.
QUALITY_ANALYSES=(snr dropouts)

run_quality() {
  local state
  ( build_quality ) || die "quality: failed (above)"
  state=$(unit_state quality) || die "quality: still $state after building"
}

# quality_project <stack project> <set quality project>: the stack project
# cut back to its stacker and what feeds it, with the set quality project's
# SNR and dropout sinks fed from the stacker. Which stages stay is worked out
# from the project as JSON; the cut is made by yq on the YAML itself, since a
# round trip through JSON loses the form of its numbers (version 2.0 is read
# back as 2, which decode-orc refuses).
quality_project() {
  local plan
  plan=$(jq -c -n --argjson stack "$(yq -o=json . "$1")" '
    def feeds($ids): ([ $stack.dag.edges[] | select(.to | IN($ids[])) | .from ] - $ids | unique) as $new
      | if ($new | length) == 0 then $ids else feeds($ids + $new) end;
    [ $stack.dag.nodes[] | select(.stage == "stacker") | .id ] as $s
    | if ($s | length) != 1 then error("the stack project has \($s | length) stacker stages, not one") else $s[0] end as $sid
    | { stacker: $sid, keep: feeds([ $sid ]), top: ([ $stack.dag.nodes[].id ] | max) }') || return 1
  # shellcheck disable=SC2016 # yq's own variables
  PLAN="$plan" SINKS="$2" yq '
    (strenv(PLAN) | from_json) as $p
    | (load(strenv(SINKS)).dag.nodes | map(select(.stage == "snr_analysis_sink" or .stage == "dropout_analysis_sink"))) as $sinks
    | .project.name += " quality"
    | .dag.nodes |= map(select(.id as $i | $p.keep | any_c(. == $i)))
    | .dag.edges |= map(select(.to as $i | $p.keep | any_c(. == $i)))
    | .dag.nodes += ($sinks | to_entries | map(.value.id = $p.top + 1 + .key | .value))
    | .dag.edges += ($sinks | to_entries | map({"from": $p.stacker, "to": $p.top + 1 + .key}))' "$1" || return 1
  [ "$(yq '[.dag.nodes[] | select(.stage == "snr_analysis_sink" or .stage == "dropout_analysis_sink")] | length' "$2")" = 2 ] \
    || { printf 'quality: %s has not one SNR and one dropout sink\n' "${2#"$SELF_DIR"/}" >&2; return 1; }
}

build_quality() {
  local dir a tool node csv t
  describe_quality
  dir="$STAGE_DIR"

  stage_mkdir "$dir" || return 1
  stage_unstamp || return 1
  rm -f -- "$dir"/*.csv* "$dir"/*.json* "$dir"/*.log "$dir"/*.orcprj \
           "$dir"/check.txt* "$dir"/check.failed.txt "$dir"/crash_bundle_*.zip

  # Beside the video stage's directory, so the sources' relative paths hold.
  quality_project "$QUALITY_VIDEO/stack.orcprj" "$DISC_DIR/set-quality.orcprj" > "$dir/quality.orcprj" \
    || { printf 'quality: could not make the project\n' >&2; return 1; }

  cd -- "$dir" || return 1
  for a in "${SET_ANALYSES[@]}"; do
    IFS='|' read -r tool node csv <<< "$a"
    [[ " ${QUALITY_ANALYSES[*]} " = *" $csv "* ]] || continue
    printf 'quality: %s of the stack of %s; this stacks the whole disc again\n' "$node" "$(selected_sets video | paste -sd' ' -)"
    t=$SECONDS
    orc-cli tools run "$dir/quality.orcprj" "$tool" --node "$node" --json --quiet \
      --csv "$(stage_tmp "$csv.csv")" > "$dir/$csv.json" 2> "$dir/$csv.log" || true
    printf 'quality: %s analysed in %ss\n' "$node" "$(( SECONDS - t ))"
  done

  if ! check_quality "$dir"; then
    cat -- "$dir/check.failed.txt" >&2
    printf 'quality: failed its checks and is not stamped (see %s/check.failed.txt)\n' "$dir" >&2
    return 1
  fi
  cat -- "$dir/check.txt.partial"
  stage_commit || { printf 'quality: could not stamp the stage\n' >&2; return 1; }
  printf 'quality: checked and stamped: %s\n' "$dir"
}

# check_quality <dir>: run the checks, write check.txt and quality.json to
# their stage_tmp names, and return non-zero if any failed.
check_quality() {
  local dir="$1" out fails=0 a tool node csv status frames total rows expect
  out=$(stage_tmp check.txt) || return 1
  ok()   { printf 'ok    %s\n' "$*"; }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }
  expect=$(jq -r '.metadata.frame_count // empty' "$QUALITY_VIDEO/video.json" 2>/dev/null) || expect=""

  {
    printf 'stage:   quality\nvideo:   %s\nchecked: %s\n\n' "${QUALITY_VIDEO#"$OUT"/}" "$(date '+%F %T')"
    # Each analysis ran, over every frame of the stack: the mkv's frames.
    for a in "${SET_ANALYSES[@]}"; do
      IFS='|' read -r tool node csv <<< "$a"
      [[ " ${QUALITY_ANALYSES[*]} " = *" $csv "* ]] || continue
      status=$(jq -r '.nodes[0].status // empty' "$dir/$csv.json" 2>/dev/null) || status=""
      if [ "$status" != success ]; then
        fail "$node analysis: ${status:-no report} ($(head -c 300 "$dir/$csv.log" 2>/dev/null | tr '\n' ' '))"
        continue
      fi
      read -r frames total < <(jq -r '.nodes[0].statistics | "\(.frames_analysed) \(.total_frames)"' "$dir/$csv.json") || true
      rows=$(( $(wc -l < "$dir/$csv.csv.partial" 2>/dev/null || echo 1) - 1 ))
      if [ "$frames" = "$total" ] && [ "$frames" = "$expect" ] && [ "$rows" = "$frames" ]; then
        ok "$node analysis over all $frames frames of the stack, per frame in $csv.csv"
      else
        fail "$node analysis covered ${frames:-no} of ${total:-unknown} frames, with $rows in $csv.csv; the stack has ${expect:-unknown}"
      fi
      note "$(jq -r --arg k "$csv" '.nodes[0].statistics | def r(n): . * n | round / n;
        if $k == "snr" then "SNR of the stack: white \(.mean_white_snr | r(100)) dB, black PSNR \(.mean_black_psnr | r(100)) dB (means; lowest white \(.min_white_snr | r(100)))"
        else "dropouts left by the stack: \(.total_dropouts) totalling \(.total_dropout_samples) samples, in \(.frames_with_dropouts) frames" end' "$dir/$csv.json")"
    done

    jq -n --arg video "${QUALITY_VIDEO#"$OUT"/}" --arg sets "$(selected_sets video | paste -sd' ' -)" \
          --rawfile snr "$dir/snr.json" --rawfile dropouts "$dir/dropouts.json" '
      def stats: (fromjson? // {}) | .nodes[0] // {} | if .status == "success" then .statistics else null end;
      { video: $video, sets: ($sets | split(" ")), measured: "the stacker output, before dropout correction",
        snr: ($snr | stats), dropouts: ($dropouts | stats) }' \
      > "$(stage_tmp quality.json)" || fail "could not write quality.json"

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dir/check.failed.txt"
    return 1
  fi
  rm -f -- "$dir/check.failed.txt"
}

# --- pack: the three files and their provenance ----------------------------
#
# The video and vfs stages' outputs are hard-linked into the pack where the
# share allows it, so nothing is copied or recomputed, and copied otherwise.
# They are then checked again as they stand (docs/emulator-pack-plan.md,
# phase 7): the mkv as the video stage checks it, and the image's hashes
# against the vfs stage's and the reference, its bad sector map and
# vfs-verifier on it.
#
# Beside them go SHA256SUMS and <stem>.provenance.yaml, which vp415e ignores:
# the captures' fingerprints, the tool revisions, the selection and the
# compare stage's evidence for it, the stacker's weights, the vfs verdict,
# every stage's checks and the hand check on the player.
#
# vp415e cannot open a side without the player's hardware, so the last check
# is a person's, on the player, recorded in PLAYER_CHECK against the pack's
# id: the first 16 hex digits of the sha256 of SHA256SUMS' lines for the three
# files the player loads. A pack is complete only once a check that passed is
# recorded for its id. Until then it is built and stamped, and awaits that
# check; a check that failed fails the stage.
#
# $OUT/pack links to the current version, for install-pack.sh.

run_pack() {
  local state
  ( build_pack ) || die "pack: failed (above)"
  state=$(unit_state pack) || die "pack: still $state after building"
  stage_prune "$OUT" pack stage.stamp
}

build_pack() {
  local dir f how
  local -a assembled=()
  describe_pack
  dir="$STAGE_DIR"

  stage_mkdir "$dir" || return 1
  stage_unstamp || return 1
  rm -f -- "${dir:?}"/*.mkv "${dir:?}"/*.dat "${dir:?}"/*.dat.* "${dir:?}"/*.yaml* "${dir:?}"/*.json* \
           "${dir:?}"/*.txt* "${dir:?}"/*.log "${dir:?}"/*.pdf* "${dir:?}"/SHA256SUMS*
  rm -rf -- "${dir:?}/report"
  cd -- "$dir" || return 1

  # Under their final names, so that each is checked as the player will find
  # it. The stamp, written last, is what makes the pack complete.
  for f in "$PACK_VIDEO/$STEM.mkv" "$PACK_VFS/$STEM.dat" "$PACK_VFS/$STEM.dat.bsm"; do
    if ln -- "$f" "${f##*/}" 2>/dev/null; then
      how=linked
    else
      printf 'pack: %s cannot be linked here; copying it\n' "${f##*/}"
      cp -- "$f" "${f##*/}" || return 1
      how=copied
    fi
    assembled+=("${f##*/}|$f|$how")
  done
  printf 'pack: assembled %s from %s and %s; checking it again\n' "$STEM" "${PACK_VIDEO#"$OUT"/}" "${PACK_VFS#"$OUT"/}"

  if ! check_pack "$dir" "${assembled[@]}"; then
    cat -- "$dir/check.failed.txt" >&2
    printf 'pack: failed its checks and is not stamped (see %s/check.failed.txt)\n' "$dir" >&2
    return 1
  fi
  cat -- "$dir/check.txt.partial"
  stage_commit || { printf 'pack: could not stamp the stage\n' >&2; return 1; }
  printf 'pack: checked and stamped: %s\n' "$dir"
}

# check_pack <dir> <file>|<source>|<linked|copied>...: run the checks, write
# check.txt, SHA256SUMS, pack.json and the provenance to their stage_tmp
# names, and return non-zero if any failed.
check_pack() {
  local dir="$1" out fails=0 level text frames=0 keys=0 a name src how hashpid accept sums id record problems
  local dathash bsmhash
  local -a rows=()
  shift
  out=$(stage_tmp check.txt) || return 1
  sums=$(stage_tmp SHA256SUMS) || return 1
  ok()   { printf 'ok    %s\n' "$*"; }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$(( fails + 1 )); }
  note() { printf 'note  %s\n' "$*"; }
  accept=$(vfs_accept)
  : > "$dir/console.log"

  # The mkv is hashed while the checks below read it, so that the two reads
  # of it over the share overlap.
  sha256_stdin < "$dir/$STEM.mkv" > "$dir/mkv-sha256.txt" &
  hashpid=$!

  {
    printf 'stage:   pack\nvideo:   %s\nvfs:     %s\nchecked: %s\n\n' "${PACK_VIDEO#"$OUT"/}" "${PACK_VFS#"$OUT"/}" "$(date '+%F %T')"

    # The files are the stages' own: the same file, or a copy that is
    # identical to it.
    for a; do
      IFS='|' read -r name src how <<< "$a"
      if [ "$how" = linked ] && [ "$(file_ino "$dir/$name")" = "$(file_ino "$src")" ]; then
        ok "$name is ${src#"$OUT"/}, linked"
      elif [ "$how" = copied ] && cmp -s -- "$dir/$name" "$src"; then
        ok "$name is a copy of ${src#"$OUT"/}, byte for byte"
      else
        fail "$name is not ${src#"$OUT"/}"
      fi
    done

    # The video stage's checks, again, on the pack's mkv.
    check_mkv "$dir/$STEM.mkv" "$dir" "$dir/metadata.yaml"
    if cmp -s -- "$dir/metadata.yaml" "$PACK_VIDEO/metadata.yaml"; then
      ok "the disc metadata is the document the video stage checked"
    else
      fail "the disc metadata differs from the document the video stage checked"
    fi

    # The vfs stage's checks, again, on the pack's image.
    dathash=$(sha256_stdin < "$dir/$STEM.dat")
    bsmhash=$(sha256_stdin < "$dir/$STEM.dat.bsm")
    while IFS=$'\t' read -r level text; do "$level" "$text"; done < <(
      jq -r --argjson size "$(file_size "$dir/$STEM.dat")" --arg hash "$dathash" --arg bsmhash "$bsmhash" \
            --argjson bsm "$(awk '/^[[:space:]]*$/ { next } /^[[:space:]]*[0-9]+[[:space:]]*$/ { n++; next } { m++ }
                                  END { printf "{\"sectors\": %d, \"malformed\": %d}", n, m }' "$dir/$STEM.dat.bsm")" '
        def check(c; good; bad): if c then "ok\t\(good)" else "fail\t\(bad)" end;
        .image as $i
        | check($size == $i.size and $hash == $i.sha256; "the image is the one the vfs stage checked (\($size) bytes)";
                "the image is not the one the vfs stage checked"),
          check($bsmhash == $i.bsm_sha256; "the bad sector map is the one the vfs stage checked";
                "the bad sector map is not the one the vfs stage checked"),
          check($bsm.malformed == 0 and $bsm.sectors == $i.bsm_sectors; "the bad sector map parses: \($bsm.sectors) sectors";
                "the bad sector map has \($bsm.malformed) malformed line(s) and \($bsm.sectors) sectors, against \($i.bsm_sectors)"),
          "note\tthe vfs stage judged the image \(.verdict)\(if .verdict != "bit-perfect" then ", which the selection accepts" else "" end)"' \
        "$PACK_VFS/vfs.json" 2>/dev/null || printf 'fail\tcould not read %s\n' "${PACK_VFS#"$OUT"/}/vfs.json")
    if [ -f "$VFS_REFERENCE" ]; then
      if diff -q <(grep -v '^#' "$VFS_REFERENCE") \
                 <(printf '%s  %s\n%s  %s\n' "$dathash" "$STEM.dat" "$bsmhash" "$STEM.dat.bsm") > /dev/null; then
        ok "the image and its map match the reference, ${VFS_REFERENCE#"$SELF_DIR"/}"
      else
        fail "the image or its map differs from the reference, ${VFS_REFERENCE#"$SELF_DIR"/}"
      fi
    else
      fail "there is no reference for the image yet (${VFS_REFERENCE#"$SELF_DIR"/}); the vfs stage says how to record one"
    fi
    if vfs-verifier "$dir/$STEM.dat" > "$dir/vfs-verifier.txt" 2>&1 && grep -q 'Verification passed' "$dir/vfs-verifier.txt"; then
      ok "vfs-verifier passes the image"
    elif [ "$accept" = incomplete ] && grep -q 'Verification failed' "$dir/vfs-verifier.txt"; then
      note "vfs-verifier fails the image, which the selection accepts (vfs.accept: incomplete)"
    else
      fail "vfs-verifier does not pass the image (vfs-verifier.txt)"
    fi

    # The hashes, and the pack's id.
    if wait "$hashpid" && [ -s "$dir/mkv-sha256.txt" ]; then
      printf '%s  %s\n%s  %s\n%s  %s\n' "$(cat -- "$dir/mkv-sha256.txt")" "$STEM.mkv" \
        "$dathash" "$STEM.dat" "$bsmhash" "$STEM.dat.bsm" > "$sums"
      id=$(sha256_stdin < "$sums" | cut -c1-16)
      ok "hashed: SHA256SUMS; the pack's id is $id"
    else
      fail "could not hash $STEM.mkv"
      id=unknown
    fi

    # The hand check on the player.
    problems=$(player_check_problems)
    record=null
    if [ -n "$problems" ]; then
      while IFS= read -r text; do fail "${PLAYER_CHECK#"$SELF_DIR"/}: $text"; done <<< "$problems"
    else
      record=$(player_check_for "$id")
      while IFS=$'\t' read -r level text; do "$level" "$text"; done < <(jq -r --arg id "$id" --arg file "${PLAYER_CHECK#"$SELF_DIR"/}" --arg disc "$DISC" '
        if . == null then
          "note\tawaiting the hand check on the player: install the pack (./install-pack.sh \($disc) <host>), check it there, and record the result in \($file) as a check with pack: \"\($id)\", date, vp415e (its version) and result (pass or fail)"
        elif .result == "pass" then "ok\tchecked by hand on the player on \(.date) with vp415e \(.vp415e): passed"
        else "fail\tchecked by hand on the player on \(.date) with vp415e \(.vp415e): failed\(if .notes then " (\(.notes))" else "" end)" end' <<< "$record")
    fi

    printf '\nresult: %s\n' "$([ "$fails" = 0 ] && echo pass || echo "FAIL ($fails)")"
  } > "$out"

  if [ "$fails" != 0 ]; then
    mv -- "$out" "$dir/check.failed.txt"
    return 1
  fi
  rm -f -- "$dir/check.failed.txt"

  for a; do
    IFS='|' read -r name src how <<< "$a"
    rows+=("$name|$(file_size "$dir/$name")|$(awk -v n="$name" '$2 == n { print $1 }' "$sums")|${src#"$OUT"/}|$how")
  done
  jq -n --arg id "$id" --argjson check "$record" --args '
    { id: $id,
      files: [ $ARGS.positional[] | split("|") | { name: .[0], bytes: (.[1] | tonumber), sha256: .[2], from: .[3], how: .[4] } ],
      player_check: $check,
      complete: ($check.result? == "pass") }
    | .status = (if .complete then "complete: passed the hand check on the player"
                 else "awaiting the hand check on the player (pack id \($id))" end)' "${rows[@]}" > "$(stage_tmp pack.json)" \
    || { printf 'pack: could not write pack.json\n' >&2; return 1; }
  pack_provenance "$dir" > "$(stage_tmp "$STEM.provenance.yaml")" || { printf 'pack: could not write the provenance\n' >&2; return 1; }
  printf '%s  %s\n' "$(sha256_stdin < "$dir/$STEM.provenance.yaml.partial")" "$STEM.provenance.yaml" >> "$sums"
  pack_report "$dir" || return 1
  printf '%s  %s\n' "$(sha256_stdin < "$dir/$STEM.report.pdf.partial")" "$STEM.report.pdf" >> "$sums"
}

# pack_report <dir>: <stem>.report.pdf, from the provenance and check results
# in <dir> (their stage_tmp names) and the stages the pack was built from.
# lib/pack-report.py reads them as a manifest names them, and keeps its
# graphs and tables in <dir>/report.
pack_report() {
  local dir="$1" s id cvbs sdir cmd path version pdf
  local -a sets=() tools=()
  for s in "${COMPARE_SETS[@]}"; do
    IFS='|' read -r id cvbs sdir <<< "$s"
    sets+=("$id|${cvbs%/*}|$sdir|$(basename -- "$cvbs" .cvbs)")
  done
  for cmd in ld-decode orc-cli vfs-stacker vfs-verifier ffmpeg typst; do
    path=$(command -v "$cmd") && path=$(realpath -- "$path") || path=""
    case "$cmd" in
      ld-decode) version=$(ld-decode --version 2>/dev/null | head -1) ;;
      ffmpeg)    version=$(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f1-3) ;;
      typst)     version=$(typst --version 2>/dev/null | head -1) ;;
      *)         version="" ;;
    esac
    tools+=("$cmd|$version|$path")
  done
  mkdir -p -- "$dir/report" || return 1
  jq -n --arg disc "$DISC" --arg title "${DISC_TITLE:-$DISC}" --arg stem "$STEM" --arg out "$OUT" \
        --arg format "$DISC_FORMAT" --arg side "$DISC_SIDE" --arg pictures "$DISC_PICTURES" \
        --arg lead_in "$DECODE_LEAD_IN" --arg frames "$DECODE_FRAMES" \
        --arg pack_dir "$dir" --arg version "${dir##*/}" --arg provenance "$dir/$STEM.provenance.yaml.partial" \
        --arg check "$dir/check.txt.partial" --arg sums "$dir/SHA256SUMS.partial" \
        --arg selection "$SELECTION" --arg framemaps "$FRAMEMAPS" \
        --arg map "$PACK_MAP" --arg compare "$PACK_COMPARE" --arg video "$PACK_VIDEO" --arg vfs "$PACK_VFS" --arg quality "$PACK_QUALITY" \
        --arg commit "$(git -C "$SELF_DIR" rev-parse HEAD 2>/dev/null || echo unknown)" \
        --arg describe "$(git -C "$SELF_DIR" describe --always --dirty 2>/dev/null || echo unknown)" \
        --argjson dirty "$([ -n "$(git -C "$SELF_DIR" status --porcelain 2>/dev/null)" ] && echo true || echo false)" \
        --arg inputs "$(stage_inputs)" --arg sets "$(printf '%s\n' "${sets[@]}")" --arg tools "$(printf '%s\n' "${tools[@]}")" \
        --argjson epoch "$(date +%s)" '
    def rows($t): [ $t | split("\n")[] | select(. != "") | split("|") ];
    { disc: $disc, title: $title, stem: $stem, out: $out, format: $format, side: $side, pictures: $pictures,
      lead_in: $lead_in, decode_frames: $frames, pack_dir: $pack_dir, pack_version: $version,
      provenance: $provenance, pack_check: $check, sums: $sums, selection: $selection, framemaps: $framemaps,
      map_dir: $map, compare_dir: $compare, video_dir: $video, vfs_dir: $vfs, quality_dir: $quality,
      script: { commit: $commit, describe: $describe, dirty: $dirty },
      pack_inputs: ($inputs | split("\n") | map(select(. != ""))),
      sets: [ rows($sets)[] | { set: .[0], decode_dir: .[1], set_dir: .[2], decode_base: .[3] } ],
      tools: [ rows($tools)[] | { name: .[0], version: .[1], path: .[2] } ],
      epoch: $epoch }' > "$dir/report/manifest.json" || { printf 'pack: could not write the report manifest\n' >&2; return 1; }
  pdf=$(stage_tmp "$STEM.report.pdf") || return 1
  if ! pack-python "$SELF_DIR/lib/pack-report.py" "$dir/report/manifest.json" "$pdf" --work "$dir/report" \
       || [ "$(head -c 5 "$pdf" 2>/dev/null)" != "%PDF-" ]; then
    printf 'pack: could not make the report (the work is in %s/report)\n' "$dir" >&2
    return 1
  fi
}

# pack_provenance <dir>: <stem>.provenance.yaml, from pack.json and the check
# results in <dir> (their stage_tmp names) and what the stages before it
# recorded.
pack_provenance() {
  local dir="$1" id
  local -a captures=() patches=()
  for id in $(map_sets); do
    captures+=("$id|$(set_field "$id" 2)|$(set_field "$id" 3)|$id/$LDD_DIR")
  done
  for id in "$SELF_DIR"/patches/*.patch; do
    [ -f "$id" ] && patches+=("${id##*/}|$(sha256_stdin < "$id")")
  done
  printf '# The provenance of the %s pack for %s: what it was made from, how,\n' "$STEM" "$DISC"
  printf '# and every check it passed. Written by build-pack.sh; vp415e ignores it.\n'
  jq -n --arg disc "$DISC" --arg stem "$STEM" --arg version "${dir##*/}" --arg built "$(date '+%FT%T%z')" \
        --arg script "$(git -C "$SELF_DIR" describe --always --dirty 2>/dev/null || echo unknown)" \
        --slurpfile pack "$dir/pack.json.partial" --slurpfile lock "$SELF_DIR/flake.lock" \
        --argjson selection "$(yq -o=json . "$SELECTION")" --slurpfile evidence "$PACK_COMPARE/compare.json" \
        --slurpfile video "$PACK_VIDEO/video.json" --slurpfile vfs "$PACK_VFS/vfs.json" \
        --rawfile sources "$SELF_DIR/sources.sha256" \
        --rawfile stamp_compare "$PACK_COMPARE/stage.stamp" --rawfile stamp_video "$PACK_VIDEO/stage.stamp" \
        --rawfile stamp_vfs "$PACK_VFS/stage.stamp" \
        --rawfile check_video "$PACK_VIDEO/check.txt" --rawfile check_vfs "$PACK_VFS/check.txt" \
        --rawfile check_pack "$dir/check.txt.partial" \
        --arg patches "$( [ "${#patches[@]}" = 0 ] || printf '%s\n' "${patches[@]}")" --args '
    def stamp($t): ($t | split("\n")) as $l
      | { key: ([ $l[] | capture("^key: (?<v>.*)")?.v ] | first),
          stamped: ([ $l[] | capture("^stamped: (?<v>[0-9]+)")?.v | tonumber | todate ] | first),
          inputs: [ $l[] | capture("^input: (?<v>.*)")?.v ] };
    def checks($t): [ $t | split("\n")[] | select(test("^(ok|note|FAIL) ") or test("^result: ")) ];
    def node($path): reduce $path[] as $step ("root";
      $lock[0].nodes[.].inputs[$step] as $n | if ($n | type) == "array" then node($n) else $n end);
    def tool($input): $lock[0].nodes[node([$input])] as $n
      | { rev: $n.locked.rev, narHash: $n.locked.narHash,
          source: ($n.original | "\(.type):\(.owner)/\(.repo)\(if .ref then "/\(.ref)" else "" end)") };
    ($sources | split("\n")) as $src
    | ([ $src[] | capture("^# head-bytes: (?<n>[0-9]+)")?.n | tonumber ] | first) as $head
    | [ $src[] | select(test("^[0-9a-f]{64}  ")) | capture("^(?<sha>[0-9a-f]+)  (?<bytes>[0-9]+)  (?<path>.*)$") ] as $fingerprints
    | def role($stack; $set): ($selection[$stack].sets | index($set)) as $i
        | if $i != null then { position: ($i + 1) }
          else { dropped: ([ $selection[$stack].dropped[]? | select(.set == $set) | .reason ] | first) } end;
      $pack[0] as $p
      | { disc: $disc, stem: $stem,
          pack: { id: $p.id, version: $version, built: $built, script: $script, status: $p.status, complete: $p.complete },
          files: $p.files,
          player_check: $p.player_check,
          captures: [ $ARGS.positional[] | split("|") as [$set, $first, $path, $decode]
                      | ([ $fingerprints[] | select(.path == $path) ] | first) as $f
                      | { set: $set, first_picture: ($first | tonumber), library_path: $path,
                          fingerprint: (if $f then { sha256_of_head: $f.sha, head_bytes: $head, bytes: ($f.bytes | tonumber) } else null end),
                          decode: $decode, video: role("video"; $set), vfs: role("vfs"; $set) } ],
          tools: ({ "ld-decode": tool("ld-decode"), "decode-orc": tool("decode-orc"), "vfs-verifier": tool("vfs-verifier"), nixpkgs: tool("nixpkgs") }
                  | .["decode-orc"].patches = [ $patches | split("\n")[] | select(. != "") | split("|") | { name: .[0], sha256: .[1] } ]),
          selection: $selection,
          evidence: $evidence[0],
          video: $video[0],
          vfs: $vfs[0],
          stamps: { compare: stamp($stamp_compare), video: stamp($stamp_video), vfs: stamp($stamp_vfs) },
          checks: { video: checks($check_video), vfs: checks($check_vfs), pack: checks($check_pack) } }' \
    "${captures[@]}" | yq -P -p=json -o=yaml
}

# pack_link: point $OUT/pack at the current pack, once it is up to date.
pack_link() {
  unit_state pack > /dev/null || return 0
  describe_pack
  [ "$(readlink -- "$OUT/pack" 2>/dev/null)" != "${STAGE_DIR##*/}" ] || return 0
  if [ -e "$OUT/pack" ] && [ ! -L "$OUT/pack" ]; then
    printf 'pack: %s is not a link, so it is left as it is\n' "$OUT/pack" >&2
    return 0
  fi
  stage_guard "$OUT/pack" && ln -sfn -- "${STAGE_DIR##*/}" "$OUT/pack" \
    && printf 'pack -> %s, the current pack\n' "${STAGE_DIR##*/}"
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

# The current pack, once the run has reached it and it is up to date.
[ "$UNTIL_I" -lt "$(stage_index pack)" ] || pack_link
