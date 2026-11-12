#!/usr/bin/env bash
#
# Publish the current packs: copy each disc's pack -- the files the player
# loads, <stem>.mkv, <stem>.dat and <stem>.dat.bsm (a side with no EFM has the
# mkv alone), and <stem>-lossy.mkv, the lossy alternative to <stem>.mkv --
# into a folder of its own under the emulation-packs folder on
# the SFTP share, with a README.md that names the pack by its id and lists its
# files with their sizes and SHA-256.
#
# Never part of the build: build-pack.sh makes the packs, and this is run by
# hand to hand them on.
#
# Each disc's folder is named from its DISC_OUT without the word "side", and
# with a trailing number set off by a hyphen: countryside-side1 is
# countryside-1, city-culture1 is city-culture-1, apple-almanac-side-a is
# apple-almanac-a. A folder that already holds a pack has it replaced by the
# current one: a file there at the same size and time as the pack's is left,
# any other is copied over, and anything in the folder that is not part of
# the current pack (an older pack's files, a stray, the leftovers of an
# interrupted copy) is removed. The old README is removed before the copy and
# the new one written after it, so a README only ever names a pack that is
# all there. Nothing outside the disc folders is touched.
#
# The destination folder must already exist; it is never made here, so that a
# share that is not mounted is not mistaken for an empty folder. The SFTP
# share's NFS mount on macOS is read-only (shares.conf), so publish through a
# writable mount of it, such as the Finder's SMB mount, with --dest.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"
# shellcheck source=lib/stage.sh
. "$SELF_DIR/lib/stage.sh"

shares_load
DEST="${DD_EMULATION_PACKS:-$(share_conf sftp mount)/simoninns/emulation-packs}"

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [disc ...]

Copy each disc's current pack (all discs by default) to a folder of its own
under the emulation-packs folder, with a README.md giving the pack id.
Discs: $(for d in "$SELF_DIR"/discs/*/disc.conf; do d="${d%/disc.conf}"; printf '%s ' "${d##*/}"; done)

Options:
      --dest DIR   the emulation-packs folder (default $DEST); it must exist
                   and be writable
      --verify     after copying, hash every published file and check it
                   against the pack's SHA256SUMS (reads every file back)
  -n, --dry-run    show what would be copied; change nothing
      --no-mount   check the decodes share but do not mount it
  -h, --help       this message

Environment: DD_DECODES DD_EMULATION_PACKS DD_NO_MOUNT
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

DISCS=()
VERIFY=0
DRY_RUN=0
NO_MOUNT=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dest)      DEST="${2:?--dest needs a directory}"; shift 2 ;;
    --verify)    VERIFY=1; shift ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    --no-mount)  NO_MOUNT=(--no-mount); shift ;;
    -h|--help)   usage; exit 0 ;;
    -*)          die "unknown option: $1" ;;
    *)           DISCS+=("$1"); shift ;;
  esac
done
DEST="${DEST%/}"
if [ "${#DISCS[@]}" = 0 ]; then
  for d in "$SELF_DIR"/discs/*/disc.conf; do d="${d%/disc.conf}"; DISCS+=("${d##*/}"); done
fi
for disc in "${DISCS[@]}"; do
  [ -f "$SELF_DIR/discs/$disc/disc.conf" ] || die "no such disc: $disc (no discs/$disc/disc.conf)"
done

command -v rsync >/dev/null || die "rsync is not on PATH (run: nix develop)"
command -v jq >/dev/null    || die "jq is not on PATH (run: nix develop)"
command -v sha256sum >/dev/null || die "sha256sum is not on PATH (run: nix develop)"

ensure_shares "${NO_MOUNT[@]}" decodes || die "the decodes share is not ready (./mount-shares.sh says why)"

# The destination must be there, answer, and take a write.
_dest_writable() {
  local t
  [ -d "$1" ] || return 1
  t=$(mktemp "$1/.publish-test.XXXXXX") || return 1
  rm -f -- "$t" || return 1
  printf 'ok'
}
if ! share_timed test -d "$DEST" >/dev/null; then
  die "$DEST is not there (or does not answer); it is never made here, so make it, or mount its share, first"
fi
if [ "$DRY_RUN" = 0 ] && ! share_timed _dest_writable "$DEST" >/dev/null; then
  die "$DEST is not writable; the SFTP share's NFS mount is read-only, so give a writable mount of it with --dest (such as /Volumes/Domesday86_SFTP/simoninns/emulation-packs)"
fi

# folder_name <disc_out>: the published folder for a disc.
folder_name() {
  local n="${1/-side-/-}"
  n="${n/-side/-}"
  if [[ $n =~ ^(.*[a-z])([0-9]+)$ ]]; then n="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"; fi
  printf '%s\n' "$n"
}

# Folder names must not collide.
declare -A FOLDER_OF=() DISC_IN=()
for disc in "${DISCS[@]}"; do
  # shellcheck source=discs/volcanoes/disc.conf
  out=$(DISC_OUT=""; . "$SELF_DIR/discs/$disc/disc.conf"; printf '%s' "$DISC_OUT")
  f=$(folder_name "$out")
  [ -z "${DISC_IN[$f]:-}" ] || die "$disc and ${DISC_IN[$f]} would both publish to $f"
  FOLDER_OF[$disc]="$f"; DISC_IN[$f]="$disc"
done

human_bytes() { awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b / 1e9; else if (b >= 1e6) printf "%.1f MB", b / 1e6; else printf "%d bytes", b }'; }

# write_readme <pack dir> <file> ...: the README for a pack, on stdout.
# shellcheck disable=SC2016,SC2031 # the backticks are Markdown; called in the per-disc subshell that set DISC_*
write_readme() {
  local pack="$1"; shift
  local id stamped built f bytes sum from
  id=$(jq -r .id "$pack/pack.json")
  stamped=$(stage_stamp_field "$pack" stamped)
  built=$(date -u -d "@$stamped" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -r "$stamped" '+%Y-%m-%d %H:%M UTC')
  printf '# %s\n\n' "$DISC_TITLE"
  printf 'Pack id: **%s**\n\n' "$id"
  printf 'Built %s, for the VP415e emulated player. ' "$built"
  if [ "${DISC_EFM:-yes}" = no ]; then
    printf 'The side has no data area (no EFM), so the pack is the video alone. '
  else
    printf 'Copy the .mkv, the .dat and the .dat.bsm into the player'"'"'s media directory; the .dat is the side'"'"'s data area and the .dat.bsm its map. '
  fi
  printf 'The video comes twice: %s.mkv is lossless (FFV1), and %s-lossy.mkv the same stack in H.264, a fraction of the size. Copy one of the two, not both.\n\n' "$STEM" "$STEM"
  printf '| File | Bytes | SHA-256 |\n|---|---:|---|\n'
  for f in "$@"; do
    bytes=$(file_size "$pack/$f")
    sum=$(awk -v n="$f" '$2 == n { print $1 }' "$pack/SHA256SUMS")
    printf '| %s | %s | `%s` |\n' "$f" "$bytes" "$sum"
  done
  printf '\nMade from:\n\n'
  for f in "$@"; do
    from=$(jq -r --arg n "$f" '.files[] | select(.name == $n) | .from' "$pack/pack.json")
    printf -- '- %s: %s\n' "$f" "${from:-unknown}"
  done
  printf '\nCheck the files with: `sha256sum -c` on the lines below, saved as a file beside them.\n\n```\n'
  for f in "$@"; do awk -v n="$f" '$2 == n' "$pack/SHA256SUMS"; done
  printf '```\n'
}

RSYNC=(rsync --times --no-perms --no-owner --no-group --human-readable)
total=0 published=0 skipped=() failed=()

printf 'from:   %s/decode-script\nto:     %s\n' "$DD_DECODES" "$DEST"
[ "$DRY_RUN" = 0 ] || printf 'dry run: nothing will be changed\n'

for disc in "${DISCS[@]}"; do
  (
    set -euo pipefail
    DISC_EFM="" DISC_TITLE="" DISC_OUT="" STEM=""
    # shellcheck source=discs/volcanoes/disc.conf
    . "$SELF_DIR/discs/$disc/disc.conf"
    folder="${FOLDER_OF[$disc]}"
    printf '\n%s -> %s/\n' "$disc" "$folder"

    link="$DD_DECODES/decode-script/$DISC_OUT/pack"
    [ -d "$link" ] || { printf 'SKIP  no pack (build it with: ./build-pack.sh %s)\n' "$disc"; exit 3; }
    pack=$(phys_dir "$link")
    stage_stamp_field "$pack" stamped > /dev/null \
      || { printf 'FAIL  %s is not a stamped pack: it was never checked, or its build was interrupted\n' "$pack"; exit 1; }
    if [ "${DISC_EFM:-yes}" = no ]; then
      files=("$STEM.mkv" "$STEM-lossy.mkv")
    else
      files=("$STEM.dat" "$STEM.dat.bsm" "$STEM.mkv" "$STEM-lossy.mkv")
    fi
    for f in "${files[@]}" SHA256SUMS pack.json; do
      [ -f "$pack/$f" ] || { printf 'FAIL  %s has no %s\n' "$pack" "$f"; exit 1; }
    done
    for f in "${files[@]}"; do
      awk -v n="$f" '$2 == n { found = 1 } END { exit !found }' "$pack/SHA256SUMS" \
        || { printf 'FAIL  %s/SHA256SUMS does not list %s\n' "$pack" "$f"; exit 1; }
    done
    id=$(jq -r .id "$pack/pack.json")
    bytes=0
    for f in "${files[@]}"; do bytes=$(( bytes + $(file_size "$pack/$f") )); done
    printf 'pack  %s (id %s), %s\n' "${pack##*/}" "$id" "$(human_bytes "$bytes")"

    readme=$(mktemp "$TMPDIR/publish-readme.XXXXXX")
    trap 'rm -f -- "$readme"' EXIT
    write_readme "$pack" "${files[@]}" > "$readme"

    to="$DEST/$folder"
    # What is there already: the pack its README names, and anything that is
    # not part of the new pack (an old pack's files, a stray, the leftovers of
    # an interrupted copy), which the new pack replaces.
    old_id=""
    [ ! -f "$to/README.md" ] || old_id=$(sed -n 's/^Pack id: \*\*\([0-9a-f]*\)\*\*$/\1/p' "$to/README.md" | head -1)
    extras=()
    if [ -d "$to" ]; then
      keep=(! -name README.md)
      for f in "${files[@]}"; do keep+=(! -name "$f"); done
      while IFS= read -r extra; do extras+=("$extra"); done \
        < <(cd -- "$to" && find . -mindepth 1 -maxdepth 1 "${keep[@]}" | sed 's|^\./||' | sort)
    fi
    if [ ! -d "$to" ]; then
      printf 'new   the folder is new
'
    elif [ -z "$old_id" ]; then
      printf 'note  the folder has no pack README; whatever is there is replaced
'
    elif [ "$old_id" = "$id" ]; then
      printf 'same  the folder already has pack %s; only what differs is copied
' "$id"
    else
      printf 'old   the folder has pack %s, which pack %s replaces
' "$old_id" "$id"
    fi

    if [ "$DRY_RUN" = 1 ]; then
      if [ -d "$to" ]; then
        "${RSYNC[@]}" --dry-run --itemize-changes -- "${files[@]/#/$pack/}" "$to/" | sed 's/^/      /'
      else
        printf '      %s\n' "${files[@]}"
      fi
      [ -f "$to/README.md" ] && cmp -s "$readme" "$to/README.md" || printf '      README.md (written)\n'
      for extra in "${extras[@]}"; do printf 'would remove  %s\n' "$extra"; done
    else
      mkdir -p -- "$to"
      # The old README goes first, so that while the files are replaced the
      # folder does not claim to hold the old pack; the new one is written
      # last, once every file is there.
      if [ -f "$to/README.md" ] && ! cmp -s "$readme" "$to/README.md"; then
        rm -f -- "$to/README.md"
      fi
      # The data area and its map first, then the side. A file that differs
      # in size or time from the pack's is replaced (by a copy renamed into
      # place); one that matches is left.
      "${RSYNC[@]}" --info=progress2 -- "${files[@]/#/$pack/}" "$to/"
      for f in "${files[@]}"; do
        [ "$(file_size "$to/$f")" = "$(file_size "$pack/$f")" ] \
          || { printf 'FAIL  %s is not the size of the pack'"'"'s copy\n' "$to/$f"; exit 1; }
      done
      if [ "$VERIFY" = 1 ]; then
        printf 'verifying the published files\n'
        (cd -- "$to" && for f in "${files[@]}"; do awk -v n="$f" '$2 == n' "$pack/SHA256SUMS"; done \
          | sha256sum -c --strict -) | sed 's/^/      sha256 /' \
          || { printf 'FAIL  the published files are not the pack'"'"'s\n'; exit 1; }
      fi
      for extra in "${extras[@]}"; do
        rm -rf -- "${to:?}/$extra"
        printf 'gone  %s (not part of pack %s)\n' "$extra" "$id"
      done
      cp -- "$readme" "$to/.README.md.tmp"
      chmod 0644 -- "$to/.README.md.tmp"
      mv -f -- "$to/.README.md.tmp" "$to/README.md"
      printf 'ok    %s: %s, pack id %s\n' "$folder" "${files[*]} README.md" "$id"
    fi
    exit 0
  ) && rc=0 || rc=$?
  total=$(( total + 1 ))
  case "$rc" in
    0) published=$(( published + 1 )) ;;
    3) skipped+=("$disc") ;;
    *) failed+=("$disc") ;;
  esac
done

printf '\n%d of %d disc(s) %s' "$published" "$total" "$([ "$DRY_RUN" = 1 ] && echo 'ready to publish' || echo published)"
[ "${#skipped[@]}" = 0 ] || printf '; no pack: %s' "${skipped[*]}"
[ "${#failed[@]}" = 0 ] || printf '; FAILED: %s' "${failed[*]}"
printf '\n'
[ "${#failed[@]}" = 0 ]
