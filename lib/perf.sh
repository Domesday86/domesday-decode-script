# shellcheck shell=bash
#
# Performance records: one line per timed step of a pack build, appended to
# decode-script/performance.tsv on the decodes share, so a tool that slows
# down from one pin to the next shows up (perf-report.sh). Sourced, not run;
# needs lib/shares.sh sourced and the decodes share checked first.
#
#   perf_record <disc> <stage> <unit> <tool> <frames> <seconds>
#   perf_decode_frames <cvbs>       frames a decode wrote, from its log
#   perf_decode_took <cvbs>         "<seconds> <frames>" from ld-decode's Took line
#
# The columns, tab-separated, with a header line:
#
#   when      ISO 8601 local time the step ended
#   host      short host name
#   platform  uname -s
#   cpus      online CPUs
#   disc      the disc (build-pack.sh's name for it)
#   stage     decode, set:efm, set:snr, map, video, quality:snr, ...
#   unit      the set, or "-" for a stage over the whole side
#   tool      the tool's version directory: ld-decode-<rev>, orc-<rev>, vfs-<rev>
#   frames    frames the step read or wrote ("-" where that means nothing)
#   seconds   wall clock of the step
#   fps       frames / seconds, to two places ("-" without frames)
#
# Recording is best effort: a step that has already succeeded is never failed
# for want of its performance line.

PERF_HEADER=$'when\thost\tplatform\tcpus\tdisc\tstage\tunit\ttool\tframes\tseconds\tfps'

perf_file() { printf '%s\n' "${DD_PERF_FILE:-$DD_DECODES/decode-script/performance.tsv}"; }

perf_cpus() { getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo '?'; }

# perf_append <line>: append one line under a lock. Several sets record at
# once, and NFSv3 has no atomic append, so the lock is a directory (mkdir is
# atomic on NFS). A lock older than a minute is a crashed writer's, and is
# broken.
perf_append() {
  local f lock i
  f=$(perf_file)
  lock="$f.lock"
  for (( i = 0; i < 100; i++ )); do
    mkdir -- "$lock" 2>/dev/null && break
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir -- "$lock" 2>/dev/null
      continue
    fi
    sleep 0.1
  done
  [ "$i" -lt 100 ] || return 1
  { [ -s "$f" ] || printf '%s\n' "$PERF_HEADER"; printf '%s\n' "$1"; } >> "$f"
  rmdir -- "$lock" 2>/dev/null
  return 0
}

perf_record() {
  local disc="$1" stage="$2" unit="${3:--}" tool="$4" frames="${5:--}" seconds="$6" fps="-"
  [[ "$seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0
  [[ "$frames" =~ ^[0-9]+$ ]] || frames="-"
  if [ "$frames" != - ] && awk -v s="$seconds" 'BEGIN { exit !(s > 0) }'; then
    fps=$(awk -v f="$frames" -v s="$seconds" 'BEGIN { printf "%.2f", f / s }')
  fi
  perf_append "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$(date +%Y-%m-%dT%H:%M:%S%z)" "$(hostname -s 2>/dev/null || uname -n)" "$(uname -s)" "$(perf_cpus)" \
    "$disc" "$stage" "$unit" "$tool" "$frames" "$seconds" "$fps")" \
    || printf 'perf: could not record %s %s in %s\n' "$stage" "$unit" "$(perf_file)" >&2
  return 0
}

# The log ld-decode wrote beside a decode.
perf_decode_log() { printf '%s.log\n' "${1%.cvbs}"; }

perf_decode_frames() {
  local log
  log=$(perf_decode_log "$1")
  [ -f "$log" ] || return 1
  sed -n 's/.*CVBS: wrote \([0-9][0-9]*\) frames.*/\1/p' "$log" | tail -1 | grep .
}

perf_decode_took() {
  local log
  log=$(perf_decode_log "$1")
  [ -f "$log" ] || return 1
  sed -n 's/.*Took \([0-9.][0-9.]*\) seconds to decode \([0-9][0-9]*\) frames.*/\1 \2/p' "$log" | tail -1 | grep .
}
