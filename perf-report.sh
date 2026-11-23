#!/usr/bin/env bash
#
# Summarise decode-script/performance.tsv on the decodes share: the average
# speed of every pack stage, per host and tool version, and how far each
# version moved from the one before it on the same host. build-pack.sh
# appends a line to the file for every step it times (lib/perf.sh).
#
#   ./perf-report.sh                  every stage, every host
#   ./perf-report.sh --disc volcanoes only this disc's steps
#   ./perf-report.sh --backfill       first add the decodes already on the share
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"
# shellcheck source=lib/perf.sh
. "$SELF_DIR/lib/perf.sh"

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Average speed of each pack stage, by host and tool version, from
decode-script/performance.tsv. FPS is total frames over total seconds, so a
long step counts for more than a short one. "vs prev" compares a version with
the version before it, of the same tool on the same host and stage; one that
is slower by more than the threshold is marked SLOWER.

Options:
      --disc DISC       only steps of this disc
      --min-frames N    leave out steps of fewer frames (default 5000: a short
                        test decode spends a large share of its time in setup)
      --threshold PCT   how much slower counts as SLOWER (default 10)
      --backfill        first add a line for every ld-decode decode on the share
                        that the file does not have yet, from the decode's own
                        log (its "Took" line). The host of such a line is
                        unknown, so it is named by platform: macos or linux
      --raw             print the matching lines instead of the summary
      --no-mount        check the decodes share but do not mount it
  -h, --help            this message
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

disc="" min_frames=5000 threshold=10 backfill=0 raw=0
while [ $# -gt 0 ]; do
  case "$1" in
    --disc)       disc="${2:?}"; shift 2 ;;
    --min-frames) min_frames="${2:?}"; shift 2 ;;
    --threshold)  threshold="${2:?}"; shift 2 ;;
    --backfill)   backfill=1; shift ;;
    --raw)        raw=1; shift ;;
    --no-mount)   export DD_NO_MOUNT=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

ensure_shares decodes || die "the decodes share is not ready (./mount-shares.sh says why)"
PERF=$(perf_file)

# --backfill: one "decode" line per decode log on the share. The decode's
# check.txt names the path it was made at, which tells a Mac from Linux.
if [ "$backfill" = 1 ]; then
  added=0
  have=$( [ -f "$PERF" ] && awk -F'\t' 'NR > 1 && $6 == "decode" { print $5 "|" $7 "|" $8 "|" $1 }' "$PERF" || true)
  while IFS= read -r log; do
    dir="${log%/*}"
    tool="${dir##*/}"; tool=$(sed -E 's/^(ld-decode-[0-9a-f]+).*/\1/' <<< "$tool")
    unit=$(basename -- "${dir%/*}")
    d="${dir#"$DD_DECODES/decode-script/"}"; d="${d%%/*}"
    took=$(sed -n 's/.*Took \([0-9.][0-9.]*\) seconds to decode \([0-9][0-9]*\) frames.*/\1 \2/p' "$log" | tail -1)
    [ -n "$took" ] || continue
    when=$(grep 'Took ' "$log" | tail -1 | awk '{ print $1 "T" substr($2, 1, 8) }')
    platform=linux; host=linux
    if grep -q '^decode: */Users/' "$dir/check.txt" 2>/dev/null; then platform=Darwin; host=macos; fi
    grep -qxF "$d|$unit|$tool|$when" <<< "$have" && continue
    fps=$(awk -v s="${took%% *}" -v f="${took#* }" 'BEGIN { if (s > 0) printf "%.2f", f / s; else print "-" }')
    perf_append "$(printf '%s\t%s\t%s\t?\t%s\tdecode\t%s\t%s\t%s\t%s\t%s' \
      "$when" "$host" "$platform" "$d" "$unit" "$tool" "${took#* }" "${took%% *}" "$fps")"
    added=$(( added + 1 ))
  done < <(find "$DD_DECODES/decode-script" -mindepth 4 -maxdepth 4 -path '*/ld-decode-*/*.log' \
             -not -path '*/.work/*' -not -name '*.start*' 2>/dev/null | sort)
  printf 'backfill: added %s decode(s) to %s\n\n' "$added" "$PERF"
fi

[ -s "$PERF" ] || die "$PERF has no records yet; they are written by build-pack.sh"

if [ "$raw" = 1 ]; then
  awk -F'\t' -v disc="$disc" 'NR == 1 || disc == "" || $5 == disc' "$PERF" | column -t -s $'\t'
  exit 0
fi

printf 'From %s (FPS = frames / seconds; steps under %s frames left out)\n\n' "$PERF" "$min_frames"
awk -F'\t' -v disc="$disc" -v minf="$min_frames" -v thr="$threshold" '
  NR == 1 { next }
  disc != "" && $5 != disc { next }
  {
    stage = $6; host = $2; tool = $8; frames = $9; secs = $10
    timed = (frames ~ /^[0-9]+$/)
    if (timed && frames + 0 < minf + 0) next
    k = stage SUBSEP host SUBSEP tool
    if (!(k in n)) { order[++nk] = k; first[k] = $1 }
    n[k]++; s[k] += secs
    if (timed) f[k] += frames
    last[k] = $1
  }
  END {
    # Versions in the order they were first seen, within each stage and host.
    for (i = 1; i <= nk; i++) for (j = i + 1; j <= nk; j++) {
      split(order[i], a, SUBSEP); split(order[j], b, SUBSEP)
      if (a[1] "|" a[2] "|" first[order[i]] > b[1] "|" b[2] "|" first[order[j]]) { t = order[i]; order[i] = order[j]; order[j] = t }
    }
    printf "%-17s %-8s %-19s %5s %10s %10s %9s  %-8s %s\n", "stage", "host", "tool", "steps", "frames", "seconds", "avg fps", "vs prev", "last run"
    prevkey = ""
    for (i = 1; i <= nk; i++) {
      k = order[i]; split(k, a, SUBSEP)
      fps = (f[k] > 0 && s[k] > 0) ? f[k] / s[k] : -1
      vs = ""
      group = a[1] SUBSEP a[2]
      if (group == prevgroup && fps > 0 && prevfps > 0) {
        d = (fps / prevfps - 1) * 100
        vs = sprintf("%+.0f%%", d)
        if (d < -thr) vs = vs " SLOWER"
      }
      printf "%-17s %-8s %-19s %5d %10s %10.0f %9s  %-8s %s\n", a[1], a[2], a[3], n[k], (f[k] > 0 ? f[k] : "-"), s[k], \
        (fps > 0 ? sprintf("%.2f", fps) : "-"), vs, substr(last[k], 1, 10)
      prevgroup = group; prevfps = fps
    }
  }' "$PERF"
