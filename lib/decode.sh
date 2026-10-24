# shellcheck shell=bash
#
# What an ld-decode decode is, as a stage: its stamp's inputs and outputs, and
# the start it was resolved to. Shared by the decode scripts, which build and
# stamp decodes, and build-pack.sh, which asks whether they are up to date, so
# the two can never describe a decode differently. Sourced, not run; needs
# lib/stage.sh sourced first.

# decode_base <relpath>: the name a capture's decode is filed under -- its
# basename without .ldf, spaces turned into dashes.
decode_base() {
  local b="${1##*/}"
  b="${b%.ldf}"
  printf '%s\n' "${b// /-}"
}

# decode_cached_start <cache> <lead-in> <first picture>: the start report
# cached beside a decode, if it was resolved for this lead-in and picture.
# The report is find-disc-start.sh's ("content=… leadin=… start=… opens=…")
# with " target=<first picture>" added when it was cached.
decode_cached_start() {
  local report
  [ -s "$1" ] || return 1
  report=$(head -1 -- "$1")
  case "$report" in
    *"content="*"leadin=$2 "*" target=$3") printf '%s\n' "$report" ;;
    *) return 1 ;;
  esac
}

# decode_report_field <report> <field>: one key=value field of a start report.
decode_report_field() {
  local kv
  for kv in $1; do
    case "$kv" in "$2"=*) printf '%s\n' "${kv#"$2"=}"; return 0 ;; esac
  done
  return 1
}

# decode_describe <set> <dir> <base> <relpath> <start> <frames> <flags>
#
# The stamp covers the capture's fingerprint, the locked ld-decode, the start
# frame ld-decode was given, the frames it was asked for and its flags. Worker
# threads and concurrency are left out: they change how fast a decode runs,
# not what it writes.
#
# Outputs: the CVBS and its metadata, the EFM and its metadata, the dropout
# map, and check.txt, the result of the checks the decode passed before it
# was stamped. The CVBS comes first: build-pack.sh's later stages find the
# decode by it.
decode_describe() {
  local id="$1" dir="$2" base="$3" rel="$4" start="$5" frames="$6" flags="$7"
  stage_begin "decode:$id" "$dir"
  stage_input_source "$rel"
  stage_input_tool ld-decode
  stage_input "start" "$start"
  stage_input "frames" "$frames"
  stage_input "flags" "$flags"
  stage_output "$base.cvbs"
  stage_output "$base.meta"
  stage_output "$base.efm"
  stage_output "$base.efm.meta"
  stage_output "$base.dropouts.meta"
  stage_output check.txt
}
