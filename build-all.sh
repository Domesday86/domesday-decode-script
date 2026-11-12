#!/usr/bin/env bash
#
# Build every disc's VP415e pack, one disc after another, with build-pack.sh:
# the one command that brings every pack up to date. Each disc is built only
# as far as it is out of date, so a disc whose pack is current costs a status
# check and nothing more.
#
# The discs are built in a fixed order, PAL first and NTSC last: the Domesday
# discs, then Volcanoes, EcoDisc, Countryside, the City discs and North
# Polar, then Dragon's Lair and the Apple Visual Almanac. ORDER below holds
# it, and must name every disc in discs/ exactly once, so that a disc added
# there is not quietly left out.
#
# One at a time, because the decodes share is what every stage waits on: two
# discs at once would each take about twice as long. A disc that fails does
# not stop the rest (unless --stop); its log says why, and running this
# again picks it up where it stopped, since build-pack.sh redoes only what is
# out of date.
#
# Each run writes, under $DD_DECODES/decode-script/build-all/<date>/, one log
# per disc (<disc>.log, build-pack.sh's own output) and summary.txt, a line
# per disc as it finishes, which is printed as well. On macOS the run keeps
# the machine awake (caffeinate -i) until it ends.
#
# Run it from the dev shell (nix develop), as build-pack.sh is.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"

ORDER=(
  # PAL: the Domesday discs
  national-a national-b community-north community-south
  # PAL: the rest
  volcanoes
  ecodisc-side1 ecodisc-side2
  countryside-side1 countryside-side2
  city-culture1 city-culture2 city-financial1 city-financial2
  north-polar
  # NTSC
  dragons-lair apple-almanac-side-a apple-almanac-side-b
)

usage() {
  cat <<EOF
Usage: ${0##*/} [status] [options] [disc ...]

Build every disc's pack with build-pack.sh, one disc after another, in this
order (the discs named, in the same order, if any are):
  ${ORDER[*]}

With "status", report each disc's stages as build-pack.sh status does, and
build nothing.

Options:
      --stop       stop at the first disc that fails, rather than going on
      --no-mount   check the shares but do not mount them
  -h, --help       this message

Logs: \$DD_DECODES/decode-script/build-all/<date>/<disc>.log and summary.txt.

Environment: DD_LIBRARY DD_DECODES DD_NO_MOUNT
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

# in_list <word> <list...>: whether the word is one of the list.
in_list() {
  local w="$1" x; shift
  for x; do [ "$x" = "$w" ] && return 0; done
  return 1
}

# --- arguments -------------------------------------------------------------

MODE=build
STOP=0
NO_MOUNT=()
WANT=()
while [ $# -gt 0 ]; do
  case "$1" in
    status)     MODE=status; shift ;;
    --stop)     STOP=1; shift ;;
    --no-mount) NO_MOUNT=(--no-mount); shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option: $1" ;;
    *)          WANT+=("$1"); shift ;;
  esac
done

# ORDER and discs/ must name the same discs.
listed=$(printf '%s\n' "${ORDER[@]}" | sort)
[ -z "$(printf '%s\n' "${ORDER[@]}" | sort | uniq -d)" ] || die "ORDER names a disc twice: $(printf '%s\n' "${ORDER[@]}" | sort | uniq -d | paste -sd' ' -)"
present=$(for d in "$SELF_DIR"/discs/*/disc.conf; do d="${d%/disc.conf}"; printf '%s\n' "${d##*/}"; done | sort)
missing=$(comm -13 <(printf '%s\n' "$listed") <(printf '%s\n' "$present") | paste -sd' ' -)
extra=$(comm -23 <(printf '%s\n' "$listed") <(printf '%s\n' "$present") | paste -sd' ' -)
[ -z "$missing" ] || die "ORDER in ${0##*/} does not name $missing, which discs/ has; add it in its place"
[ -z "$extra" ]   || die "ORDER in ${0##*/} names $extra, which discs/ does not have"

DISCS=()
if [ "${#WANT[@]}" = 0 ]; then
  DISCS=("${ORDER[@]}")
else
  for d in "${WANT[@]}"; do
    in_list "$d" "${ORDER[@]}" || die "no such disc: $d"
  done
  for d in "${ORDER[@]}"; do
    ! in_list "$d" "${WANT[@]}" || DISCS+=("$d")
  done
fi

if [ "$MODE" = status ]; then
  for d in "${DISCS[@]}"; do
    printf '\n== %s\n' "$d"
    "$SELF_DIR/build-pack.sh" "$d" status "${NO_MOUNT[@]}" || true
  done
  exit 0
fi

# --- the run ---------------------------------------------------------------

command -v orc-cli > /dev/null || die "orc-cli is not on PATH (run: nix develop)"

# Keep a Mac awake for the whole run, which takes days for every disc.
# The arguments are given again as they were parsed.
if [ "$(uname -s)" = Darwin ] && [ -z "${BUILD_ALL_AWAKE:-}" ] && command -v caffeinate > /dev/null; then
  again=("${NO_MOUNT[@]}" "${WANT[@]}")
  [ "$STOP" = 0 ] || again+=(--stop)
  BUILD_ALL_AWAKE=1 exec caffeinate -i "$SELF_DIR/${0##*/}" "${again[@]}"
fi

ensure_shares "${NO_MOUNT[@]}" library decodes || die "the shares are not ready (./mount-shares.sh says why)"
LOGS="$DD_DECODES/decode-script/build-all/$(date +%Y%m%d-%H%M%S)"
mkdir -p -- "$LOGS"
SUMMARY="$LOGS/summary.txt"

say() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$SUMMARY"; }

say "building ${DISCS[*]}; logs in $LOGS"
failed=()
for d in "${DISCS[@]}"; do
  t=$SECONDS
  say "$d: building"
  if "$SELF_DIR/build-pack.sh" "$d" "${NO_MOUNT[@]}" > "$LOGS/$d.log" 2>&1; then
    say "$d: ok after $(( SECONDS - t ))s"
  else
    rc=$?
    say "$d: FAILED (exit $rc) after $(( SECONDS - t ))s; the end of $d.log:"
    tail -5 -- "$LOGS/$d.log" | sed 's/^/    /' | tee -a "$SUMMARY"
    failed+=("$d")
    [ "$STOP" = 0 ] || break
  fi
done

if [ "${#failed[@]}" = 0 ]; then
  say "done: every pack is up to date"
else
  say "done: ${#failed[@]} failed: ${failed[*]}"
  exit 1
fi
