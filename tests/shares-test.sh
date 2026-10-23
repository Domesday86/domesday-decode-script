#!/usr/bin/env bash
#
# Check that ensure_shares refuses each kind of share that is not what it
# should be, and accepts the real ones. macOS only: the read-only and hung
# cases need a real mount, which is made from a small disk image.
#
# Run from the dev shell with both shares mounted:  tests/shares-test.sh
#
# The disk image goes in decode-script/.work on the decodes share, like any
# other scratch file, and is detached and removed afterwards. Only its mount
# point, an empty directory, is local: macOS lets a user attach an image only
# at a directory that user owns, and on an NFS share every directory belongs
# to the server's user, not this Mac's.
#
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(uname -s)" = Darwin ] || { echo "shares-test: macOS only" >&2; exit 2; }

pass=0; fail=0
# expect <want rc> <description> -- <env assignments> ...
# Each case runs ensure_shares in a fresh shell, so no state carries over.
expect() {
  local want="$1" what="$2"; shift 3
  local out rc
  # shellcheck disable=SC2016 # expanded by the inner shell
  out=$(env "$@" DD_NO_MOUNT=1 bash -c '. "$0/lib/shares.sh"; ensure_shares "${ROLE:-decodes}"; rc=$?; [ "$rc" = 0 ] || { share_check "${ROLE:-decodes}"; exit $?; }' "$ROOT" 2>&1)
  rc=$?
  if [ "$rc" = "$want" ]; then
    printf 'ok    %s\n' "$what"; pass=$(( pass + 1 ))
  else
    printf 'FAIL  %s: exit %s, wanted %s\n%s\n' "$what" "$rc" "$want" "$(printf '%s\n' "$out" | sed 's/^/      /')"
    fail=$(( fail + 1 ))
  fi
}

# Codes from lib/shares.sh.
OK=0 ELSEWHERE=11 BLOCKED=12 WRONG=13 HUNG=14 CONTENT=15 ACCESS=16

. "$ROOT/lib/shares.sh"
shares_load
ensure_shares library decodes || { echo "shares-test: the real shares must pass first" >&2; exit 2; }
WORK="$DD_DECODES/decode-script/.work"

T=$(mktemp -d "$WORK/shares-test.XXXXXX")
IMG="$T/ro.dmg"
MNT=$(mktemp -d /tmp/shares-test-mnt.XXXXXX)
DEV=""
cleanup() {
  [ -z "$DEV" ] || hdiutil detach -quiet "$DEV" 2>/dev/null || hdiutil detach -force -quiet "$DEV" 2>/dev/null
  rmdir -- "$MNT" 2>/dev/null
  rm -rf -- "$T"
}
trap cleanup EXIT

expect $OK      "the real library passes"        -- ROLE=library
expect $OK      "the real decodes share passes"  -- ROLE=decodes

# A plain directory where a share that is mounted nowhere should be. (With
# the share mounted elsewhere, that is the -1 case below.)
mkdir -p "$T/standin"
printf 'SHARE_decodes_darwin_source=//nobody@nowhere.invalid/None\n' > "$T/nowhere.conf"
expect $BLOCKED "an empty stand-in directory is refused" -- SHARES_LOCAL_CONF="$T/nowhere.conf" DD_DECODES="$T/standin"
expect $ELSEWHERE "a -1 mount is refused (the share is up, at another path)" -- DD_DECODES="$DD_DECODES-1"
expect $WRONG   "the wrong share at the path is refused" -- ROLE=decodes DD_DECODES="$DD_LIBRARY"

# A share that answers but has no marker, and one that has the marker but
# is read-only: a small HFS+ image, marked while writable, then attached
# read-only, with a local conf that names it as the decodes share.
hdiutil create -quiet -size 2m -fs HFS+ -volname ddtest "$IMG" || { echo "shares-test: hdiutil create failed" >&2; exit 2; }
DEV=$(hdiutil attach -nobrowse -mountpoint "$MNT" "$IMG" | awk '/\/dev\/disk/ { print $1; exit }')
# The mount table shows the physical path (/private/tmp, not /tmp), so the
# lookups and the conf use it too.
PMNT=$(cd -P "$MNT" && pwd -P)
SRC=$(/sbin/mount | awk -v m="$PMNT" '$3 == m { print $1 }')
FST=$(/sbin/mount | awk -v m="$PMNT" '$3 == m { sub(/^\(/, "", $4); sub(/,$/, "", $4); print $4 }')
cat > "$T/local.conf" <<EOF
SHARE_decodes_darwin_mount=$PMNT
SHARE_decodes_darwin_source=$SRC
SHARE_decodes_darwin_fstype=$FST
SHARE_TIMEOUT=3
EOF
expect $CONTENT "a share without the marker is refused" -- SHARES_LOCAL_CONF="$T/local.conf" DD_DECODES="$PMNT"
echo marker > "$MNT/.domesday86-decodes"
hdiutil detach -quiet "$DEV"; DEV=""
DEV=$(hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$IMG" | awk '/\/dev\/disk/ { print $1; exit }')
expect $ACCESS  "a read-only decodes share is refused" -- SHARES_LOCAL_CONF="$T/local.conf" DD_DECODES="$PMNT"

# A hung mount cannot be made to order, so the probe is replaced by one that
# never answers: what is tested is that the check gives up after the timeout
# instead of waiting.
start=$(date +%s)
# shellcheck disable=SC2016 # expanded by the inner shell
out=$(SHARES_LOCAL_CONF="$T/local.conf" DD_DECODES="$PMNT" bash -c '. "$0/lib/shares.sh"; _share_probe() { sleep 60; }; share_check decodes; echo "rc=$?"' "$ROOT" 2>&1)
took=$(( $(date +%s) - start ))
if [ "$out" = "rc=$HUNG" ] && [ "$took" -lt 10 ]; then
  printf 'ok    an unresponsive mount is refused within the timeout (%ss)\n' "$took"; pass=$(( pass + 1 ))
else
  printf 'FAIL  an unresponsive mount: %s after %ss\n' "$out" "$took"; fail=$(( fail + 1 ))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
