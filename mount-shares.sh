#!/usr/bin/env bash
#
# Check the network shares the scripts use, and mount any that are not up.
#
# Every script does this for itself before it starts (lib/shares.sh), so this
# is for doing it by hand: to bring the shares up ahead of a run, to see why a
# check fails, or to mark a new decodes share as the right one.
#
# The shares, their mount points and how to mount them are in shares.conf
# (and shares.local.conf for this host). On macOS a share is mounted the way
# Finder mounts it, with the credentials from the Keychain. On Linux only a
# mount the host already defines is brought up; otherwise the command to run
# is printed, since nothing here calls sudo.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [library|decodes ...]

Check each share (both by default) and mount any that is not mounted.

Options:
      --check          check only; mount nothing
      --mark-decodes   write the .domesday86-decodes marker at the root of
                       the decodes share. Do this once, on the share itself:
                       the marker is how a check tells the decodes share from
                       an empty directory or another share
  -h, --help           this message

Environment: DD_LIBRARY DD_DECODES (mount points), DD_NO_MOUNT=1 (as --check)

Exits non-zero if any share does not pass.
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

check_only=0
mark=0
roles=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check)        check_only=1; shift ;;
    --mark-decodes) mark=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    library|decodes) roles+=("$1"); shift ;;
    *)              die "unknown argument: $1" ;;
  esac
done
[ "${#roles[@]}" -gt 0 ] || roles=(library decodes)
[ "${DD_NO_MOUNT:-0}" != 1 ] || check_only=1

shares_load || exit 1

if [ "$mark" = 1 ]; then
  # The marker is written only to a share that passes every check before the
  # content check: mounted, the configured source, answering. Anything less
  # and the marker could land on the wrong filesystem.
  rc=0; share_check decodes || rc=$?
  if [ "$rc" = "$SHARE_ABSENT" ] && [ "$check_only" = 0 ]; then
    share_mount decodes && { rc=0; share_check decodes || rc=$?; }
  fi
  case "$rc" in
    0)               printf 'decodes  %s already carries %s\n' "$DD_DECODES" "$SHARES_MARKER" ;;
    "$SHARE_CONTENT")
      printf 'Marks the decodes share (%s on %s) for the content check.\n' \
        "$(share_mount_entry decodes | cut -f1)" "$DD_DECODES" > "$DD_DECODES/$SHARES_MARKER"
      printf 'decodes  wrote %s/%s\n' "$DD_DECODES" "$SHARES_MARKER" ;;
    *)               die "not marking $DD_DECODES: $SHARE_PROBLEM" ;;
  esac
fi

rc=0
for role in "${roles[@]}"; do
  r=0; share_check "$role" || r=$?
  if [ "$r" = "$SHARE_ABSENT" ] && [ "$check_only" = 0 ]; then
    if share_mount "$role"; then
      r=0; share_check "$role" || r=$?
    fi
  fi
  share_report "$role" || rc=1
done
exit "$rc"
