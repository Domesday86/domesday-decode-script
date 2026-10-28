#!/usr/bin/env bash
#
# Install a disc's pack on the VP415e player: copy the three files the player
# loads -- <stem>.mkv, <stem>.dat and <stem>.dat.bsm -- into its media
# directory over ssh, and check that they arrived whole and that the player's
# service account can work with them (docs/emulator-pack-plan.md, phase 7). A
# side with no EFM (DISC_EFM=no) has no data area: its pack is the mkv alone.
#
# Never part of the build: build-pack.sh makes the pack, and this is run by
# hand to put it on the player for the hand check, or once it has passed.
#
# The media directory is the player's own (vp415e's provisioning makes it):
# group vp415d, mode 2775, so that the setgid bit gives every file in it the
# directory's group. rsync -a would carry the group over from here instead,
# which vp415-selftest reports, so the files are copied without their group,
# and then given the group and mode 0644 explicitly, in case one was already
# there and so was not copied. Nothing here uses sudo: the ssh user must be in
# the group.
#
# The .dat and its map are copied before the .mkv, since the player lists a
# side by its .mkv. A side the player has open keeps playing the file it
# opened until it is loaded again.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"
# shellcheck source=lib/stage.sh
. "$SELF_DIR/lib/stage.sh"

usage() {
  cat <<EOF
Usage: ${0##*/} <disc> <host> [options]

Copy <disc>'s current pack to the VP415e player at <host>, an ssh destination
such as development@vp415e-pi, and check it there. Discs: $(for d in "$SELF_DIR"/discs/*/disc.conf; do d="${d%/disc.conf}"; printf '%s ' "${d##*/}"; done)

Options:
      --pack DIR       install this pack version (a pack-<key> directory, such
                       as the previous one) instead of the current one
      --media-dir DIR  the player's media directory (default $MEDIA_DIR)
      --group NAME     the group the player's files must have (default $GROUP)
  -n, --dry-run        check both ends and show what would be copied; change
                       nothing
      --no-mount       check the decodes share but do not mount it
  -h, --help           this message

Environment: DD_DECODES DD_NO_MOUNT
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

MEDIA_DIR=/srv/vp415e/media
GROUP=vp415d
DISC=""
HOST=""
PACK=""
DRY_RUN=0
NO_MOUNT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pack)      PACK="${2:?--pack needs a directory}"; shift 2 ;;
    --media-dir) MEDIA_DIR="${2:?--media-dir needs a directory}"; shift 2 ;;
    --group)     GROUP="${2:?--group needs a name}"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --no-mount)  NO_MOUNT=(--no-mount); shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           if [ -z "$DISC" ]; then DISC="$1"
                 elif [ -z "$HOST" ]; then HOST="$1"
                 else die "one disc and one host (got $DISC, $HOST and $1)"; fi
                 shift ;;
  esac
done
[ -n "$DISC" ] && [ -n "$HOST" ] || { usage >&2; exit 2; }

DISC_DIR="$SELF_DIR/discs/$DISC"
[ -f "$DISC_DIR/disc.conf" ] || die "no such disc: $DISC (no $DISC_DIR/disc.conf)"
# shellcheck source=discs/volcanoes/disc.conf
. "$DISC_DIR/disc.conf"

command -v rsync >/dev/null || die "rsync is not on PATH (run: nix develop)"
command -v ssh >/dev/null   || die "ssh is not on PATH"

# --- the pack --------------------------------------------------------------

ensure_shares "${NO_MOUNT[@]}" decodes || die "the decodes share is not ready (./mount-shares.sh says why)"
OUT="$DD_DECODES/decode-script/$DISC_OUT"
[ -n "$PACK" ] || PACK="$OUT/pack"
[ -d "$PACK" ] || die "no pack at $PACK (build it with: ./build-pack.sh $DISC)"
PACK=$(phys_dir "$PACK")
stage_stamp_field "$PACK" stamped > /dev/null || die "$PACK is not a stamped pack: it was never checked, or its build was interrupted"
if [ "${DISC_EFM:-yes}" = no ]; then
  FILES=("$STEM.mkv")
else
  FILES=("$STEM.dat" "$STEM.dat.bsm" "$STEM.mkv")
fi
for f in "${FILES[@]}" SHA256SUMS pack.json; do
  [ -f "$PACK/$f" ] || die "$PACK has no $f"
done
ID=$(jq -r .id "$PACK/pack.json")
SUMS=$(for f in "${FILES[@]}"; do awk -v n="$f" '$2 == n' "$PACK/SHA256SUMS"; done)
[ "$(wc -l <<< "$SUMS")" = "${#FILES[@]}" ] || die "$PACK/SHA256SUMS does not list the pack's ${#FILES[@]} file(s)"
BYTES=0
for f in "${FILES[@]}"; do BYTES=$(( BYTES + $(file_size "$PACK/$f") )); done

printf 'pack:   %s (id %s), %s GB\n' "$PACK" "$ID" "$(awk -v b="$BYTES" 'BEGIN { printf "%.1f", b / 1e9 }')"
printf 'status: %s\n' "$(jq -r .status "$PACK/pack.json")"
printf 'to:     %s:%s\n\n' "$HOST" "$MEDIA_DIR"

# --- the player ------------------------------------------------------------

# remote <script> [arg...]: run a bash script on the player, with its
# arguments quoted for the remote shell.
remote() {
  local script="$1"; shift
  # shellcheck disable=SC2029 # the arguments are quoted here, for the far end
  ssh -o BatchMode=yes "$HOST" "bash -s -- $(printf '%q ' "$@")" <<< "$script"
}

# The media directory must be the player's: a directory of the group, mode
# 2775, that this user may write, with room for the pack; and the tools the
# copy and the checks need must be there.
# shellcheck disable=SC2016 # expanded on the player
PREFLIGHT='
dir="$1" group="$2" bytes="$3" bad=0
say() { printf "%s\n" "$*"; }
no()  { printf "FAIL  %s\n" "$*"; bad=1; }
for t in rsync sha256sum stat df; do command -v "$t" > /dev/null || no "$t is not installed on the player"; done
if [ ! -d "$dir" ]; then
  no "$dir is not a directory (vp415e provisioning makes it)"
else
  read -r g m < <(stat -c "%G %a" -- "$dir")
  [ "$g" = "$group" ] || no "$dir is group $g, not $group"
  [ "$m" = 2775 ] || no "$dir is mode $m, not 2775"
  [ -w "$dir" ] || no "$dir is not writable by $(id -un)"
  id -Gn | tr " " "\n" | grep -qx -- "$group" || no "$(id -un) is not in the group $group"
  avail=$(( $(df -Pk -- "$dir" | awk "NR == 2 { print \$4 }") * 1024 ))
  [ "$avail" -ge "$bytes" ] || no "$dir has $avail bytes free; the pack needs $bytes"
  [ "$bad" = 1 ] || say "ok    $dir: group $g, mode $m, $(( avail / 1000000000 )) GB free"
fi
v=$(vp415d --version 2>/dev/null | head -1) || v=""
say "note  vp415d on the player: ${v:-not on the PATH of a non-interactive ssh}"
exit "$bad"
'
printf 'checking the player\n'
remote "$PREFLIGHT" "$MEDIA_DIR" "$GROUP" "$BYTES" || die "the player is not ready for the pack (above)"

# --- the copy --------------------------------------------------------------

RSYNC=(rsync -e "ssh -o BatchMode=yes" --times --perms --chmod=F0644 --no-group --no-owner --human-readable)
if [ "$DRY_RUN" = 1 ]; then
  printf '\nwhat would be copied (dry run):\n'
  "${RSYNC[@]}" --dry-run --itemize-changes -- "${FILES[@]/#/$PACK/}" "$HOST:$MEDIA_DIR/"
  printf '\ndry run: nothing was changed\n'
  exit 0
fi

if [ "${#FILES[@]}" -gt 1 ]; then
  printf '\ncopying the data area, then the side\n'
  "${RSYNC[@]}" --info=progress2 -- "$PACK/$STEM.dat" "$PACK/$STEM.dat.bsm" "$HOST:$MEDIA_DIR/"
else
  printf '\ncopying the side (it has no data area)\n'
fi
"${RSYNC[@]}" --info=progress2 -- "$PACK/$STEM.mkv" "$HOST:$MEDIA_DIR/"

# --- the checks on the player ----------------------------------------------

# The group and mode, given explicitly; then every file as vp415-selftest
# judges it, and its hash against SHA256SUMS.
# shellcheck disable=SC2016 # expanded on the player
CHECK='
set -o pipefail
dir="$1" group="$2"; shift 2
cd -- "$dir" || exit 1
chgrp -- "$group" "$@" && chmod 0644 -- "$@" || exit 1
bad=0
for f; do
  read -r g m < <(stat -c "%G %a" -- "$f")
  if [ "$g" = "$group" ] && [ "$m" = 644 ]; then printf "ok    %s: group %s, mode %s\n" "$f" "$g" "$m"
  else printf "FAIL  %s: group %s, mode %s\n" "$f" "$g" "$m"; bad=1; fi
done
sha256sum -c --strict - <<"SUMS" | sed "s/^/      sha256 /" || bad=1
'"$SUMS"'
SUMS
exit "$bad"
'
printf '\nchecking the files on the player\n'
remote "$CHECK" "$MEDIA_DIR" "$GROUP" "${FILES[@]}" \
  || die "the pack on the player is not the pack here, or not usable by $GROUP (above)"

cat <<EOF

installed: $STEM (pack id $ID) on $HOST:$MEDIA_DIR

EOF
if [ "$(jq -r .complete "$PACK/pack.json")" = true ]; then
  printf 'This pack has already passed the hand check on the player.\n'
else
  cat <<EOF
Now check it on the player, then record the result in
discs/$DISC/player-check.yaml:

checks:
  - pack: "$ID"
    date: $(date +%F)
    vp415e: <the player's vp415e version>
    result: pass          # or fail
    notes: <what was checked>

and run ./build-pack.sh $DISC, which restamps the pack as complete.
EOF
fi
