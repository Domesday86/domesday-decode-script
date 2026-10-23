#!/bin/bash
#
# Mount the NFS shares on macOS. Run as root:
#
#   sudo ./mac-nfs-mount.sh             mount library, decodes and sftp
#   sudo ./mac-nfs-mount.sh --unmount   unmount them
#
# macOS lets only root make an NFS mount, so the other scripts cannot mount
# these themselves the way they do on Linux; this is the one step that needs
# sudo, once after each boot. Mount points, sources and options come from
# shares.conf (and shares.local.conf). The library and sftp shares are
# mounted read-only, so the "never written" rule holds at the mount too.
#
# Written for macOS's own /bin/bash 3.2, since sudo's PATH does not reach the
# dev shell's bash.
#
set -eu

SELF_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
ROLES="library decodes sftp"

usage() {
  cat <<EOF
Usage: sudo ${0##*/} [--unmount] [library|decodes|sftp ...]

Mount (or unmount) each NFS share named in shares.conf for macOS, all of them
by default, at its own mount point. A share already mounted there from the
right source is left alone.
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

unmount=0
roles=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unmount) unmount=1 ;;
    -h|--help) usage; exit 0 ;;
    library|decodes|sftp) roles="$roles $1" ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
[ -n "$roles" ] || roles="$ROLES"

[ "$(uname -s)" = Darwin ] || die "this is for macOS; on Linux the host's own mounts are used"
[ "$(id -u)" = 0 ] || die "run it with sudo: sudo $0"

# shellcheck source=shares.conf
. "$SELF_DIR/shares.conf"
local_conf="${SHARES_LOCAL_CONF:-$SELF_DIR/shares.local.conf}"
# shellcheck source=/dev/null
[ ! -f "$local_conf" ] || . "$local_conf"

conf() { eval "printf '%s\n' \"\${SHARE_$1_darwin_$2:-}\""; }

# The source mounted at a path, if any, from the kernel's mount table.
mounted_source() {
  /sbin/mount | awk -v m="$1" '{ i = index($0, " on " m " ("); if (i) print substr($0, 1, i - 1) }'
}

# Directories are made by root but given to the user who ran sudo, so that
# the mount points can be seen and removed without sudo.
owner="${SUDO_UID:-0}:${SUDO_GID:-0}"

rc=0
for role in $roles; do
  mp=$(conf "$role" mount)
  src=$(conf "$role" source)
  fstype=$(conf "$role" fstype)
  opts=$(conf "$role" options)
  if [ -z "$mp" ] || [ -z "$src" ]; then
    printf '%-8s not configured for macOS in shares.conf; skipped\n' "$role"
    continue
  fi
  [ "$fstype" = nfs ] || { printf '%-8s is %s, not nfs; skipped\n' "$role" "$fstype"; continue; }
  have=$(mounted_source "$mp")

  if [ "$unmount" = 1 ]; then
    if [ -z "$have" ]; then
      printf '%-8s %s is not mounted\n' "$role" "$mp"
    elif umount "$mp"; then
      printf '%-8s unmounted %s\n' "$role" "$mp"
    else
      printf '%-8s could not unmount %s (in use? lsof +D %s)\n' "$role" "$mp" "$mp"; rc=1
    fi
    continue
  fi

  if [ "$have" = "$src" ]; then
    printf '%-8s %s already mounted at %s\n' "$role" "$src" "$mp"
    continue
  fi
  if [ -n "$have" ]; then
    printf '%-8s %s is already taken by %s; not mounting over it\n' "$role" "$mp" "$have"; rc=1
    continue
  fi
  # An empty directory is the mount point; anything in it means the path is
  # in use for something else, and mounting would hide it.
  if [ -d "$mp" ] && [ -n "$(ls -A "$mp")" ]; then
    printf '%-8s %s is not empty; not mounting over it\n' "$role" "$mp"; rc=1
    continue
  fi
  mkdir -p "$mp"
  chown "$owner" "$mp" "$(dirname "$mp")"
  if mount_nfs -o "$opts" "$src" "$mp"; then
    printf '%-8s mounted %s at %s (%s)\n' "$role" "$src" "$mp" "$opts"
  else
    printf '%-8s could not mount %s at %s\n' "$role" "$src" "$mp"; rc=1
  fi
done

if [ "$unmount" = 0 ] && [ "$rc" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
  printf '\nCheck them with: ./mount-shares.sh --check\n'
fi
exit "$rc"
