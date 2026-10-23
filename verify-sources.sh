#!/usr/bin/env bash
#
# Verify the source captures the decode scripts read against sources.sha256.
#
# A capture is fingerprinted by its exact size in bytes and the SHA-256 of its
# first 16 MiB. That is a verification, not a full checksum: hashing the whole of
# all 84 captures means reading 4.67 TB back from the capture store, which takes
# the best part of a day at the ~95 MB/s it serves, while the head of each file
# is read in about a minute for the lot. The two halves cover different failures.
# The head hash tells one capture from another -- each is FLAC-compressed RF of a
# different disc or a different pass, so no two share their first 16 MiB -- and
# the size catches the copy that stopped short or ran on, which a hash of the
# head alone would pass.
#
# sources.sha256 is keyed by the path relative to the library root, spelled
# exactly as the scripts' tables spell it, so a line names both what a capture
# is and where the scripts expect to find it. A capture that has been renamed or
# moved can therefore be identified by its fingerprint (--identify) and its new
# path put back in the table.
#
set -euo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SUMS="$SELF_DIR/sources.sha256"
# shellcheck source=lib/shares.sh
. "$SELF_DIR/lib/shares.sh"
shares_load || exit 1

LIBRARY="$DD_LIBRARY"

# Bytes hashed from the head of each capture. Recorded in sources.sha256 too,
# and read back from it when verifying, so a file generated with a different
# value is still checked the way it was made.
HEAD_BYTES=16777216

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [pattern ...]
       ${0##*/} --identify FILE ...
       ${0##*/} --generate

Check the source captures against sources.sha256. Each is fingerprinted by its
size and the SHA-256 of its first $HEAD_BYTES bytes, so the whole library is
checked in about a minute rather than read back in full.

With patterns, only the captures whose library path contains one of them are
checked, e.g. "Countryside" or "DS1_".

Options:
  -l, --library DIR     capture library root (default: $LIBRARY)
      --identify FILE   fingerprint FILE and name the capture it is, wherever
                        it is kept and whatever it is called
      --generate        write sources.sha256 afresh from the captures named in
                        the decode scripts' tables
  -h, --help            this message

Environment: DD_LIBRARY, DD_NO_MOUNT=1 (check the library share but do not
             mount it)

Exits non-zero if any capture is missing or does not match.
EOF
}

die() { printf '%s: %s\n' "${0##*/}" "$*" >&2; exit 1; }

# fingerprint <file> -> "<sha256> <size>"
fingerprint() {
  local f="$1" size hash
  size=$(file_size "$f") || return 1
  hash=$(head -c "$HEAD_BYTES" -- "$f" | sha256_stdin) || return 1
  [ "${#hash}" = 64 ] || return 1
  printf '%s %s\n' "$hash" "$size"
}

# The data lines of sources.sha256: "<sha256>  <size>  <path>", the path last
# so it may contain spaces.
sum_lines() { grep -v '^#' "$SUMS" | grep -v '^[[:space:]]*$'; }

head_bytes_from_sums() {
  local v
  v=$(sed -n 's/^# head-bytes: \([0-9][0-9]*\)$/\1/p' "$SUMS" | head -1)
  [ -n "$v" ] || die "$SUMS has no '# head-bytes:' line"
  printf '%s\n' "$v"
}

# --- argument parsing ------------------------------------------------------

MODE=verify
patterns=()
identify=()
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--library) LIBRARY="${2:?--library needs a directory}"; shift 2 ;;
    --identify)   MODE=identify; identify+=("${2:?--identify needs a file}"); shift 2 ;;
    --generate)   MODE=generate; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           die "unknown option: $1" ;;
    *)            if [ "$MODE" = identify ]; then identify+=("$1"); else patterns+=("$1"); fi
                  shift ;;
  esac
done

# The library is checked as a share (lib/shares.sh) before anything reads it:
# mounted, the right one, answering. --identify reads only the files named.
if [ "$MODE" != identify ]; then
  DD_LIBRARY="${LIBRARY%/}"
  ensure_shares library || die "the library is not ready (./mount-shares.sh says why)"
fi

# --- generate --------------------------------------------------------------
#
# The capture list is taken from the scripts themselves rather than kept by
# hand, so a capture added to a table cannot be left out of the sums. Lines are
# sorted by path, so regenerating after a change produces a readable diff.

if [ "$MODE" = generate ]; then
  mapfile -t paths < <(grep -ohE '(BBC_AIV|Calibration)/[^"|]*\.ldf' "$SELF_DIR"/decode-*.sh | sort -u)
  [ "${#paths[@]}" -gt 0 ] || die "no capture paths found in the decode scripts"

  # Written beside sources.sha256 and renamed over it, rather than in TMPDIR,
  # so the rename stays on one filesystem.
  tmp=$(mktemp "$SUMS.XXXXXX")
  trap 'rm -f -- "$tmp"' EXIT
  {
    printf '# Fingerprints of the source captures the decode scripts read.\n'
    printf '# <sha256 of the first head-bytes>  <size in bytes>  <path relative to the library root>\n'
    printf '# Check with ./verify-sources.sh; regenerate with ./verify-sources.sh --generate.\n'
    printf '# head-bytes: %s\n' "$HEAD_BYTES"
  } > "$tmp"

  n=0
  for p in "${paths[@]}"; do
    n=$(( n + 1 ))
    printf '[%d/%d] %s\n' "$n" "${#paths[@]}" "$p" >&2
    [ -f "$LIBRARY/$p" ] || die "source not found: $LIBRARY/$p"
    read -r hash size < <(fingerprint "$LIBRARY/$p") || die "could not read $LIBRARY/$p"
    printf '%s  %s  %s\n' "$hash" "$size" "$p" >> "$tmp"
  done

  # Two captures sharing a fingerprint would make --identify ambiguous, and
  # would mean the head is too short to tell them apart.
  dup=$(grep -v '^#' "$tmp" | cut -d' ' -f1 | sort | uniq -d)
  [ -z "$dup" ] || die "captures share a head fingerprint, so $HEAD_BYTES bytes is too few: $dup"

  mv -- "$tmp" "$SUMS"
  trap - EXIT
  printf 'wrote %s (%d captures)\n' "$SUMS" "${#paths[@]}"
  exit 0
fi

[ -f "$SUMS" ] || die "not found: $SUMS (run --generate)"
HEAD_BYTES=$(head_bytes_from_sums)

# --- identify --------------------------------------------------------------

if [ "$MODE" = identify ]; then
  rc=0
  for f in "${identify[@]}"; do
    [ -f "$f" ] || { printf '%s: not found\n' "$f"; rc=1; continue; }
    read -r hash size < <(fingerprint "$f") || { printf '%s: could not read\n' "$f"; rc=1; continue; }
    match=$(sum_lines | awk -v h="$hash" -v s="$size" '$1 == h && $2 == s { sub(/^[^ ]+  [^ ]+  /, ""); print }')
    if [ -n "$match" ]; then
      printf '%s: is %s\n' "$f" "$match"
    elif near=$(sum_lines | awk -v h="$hash" '$1 == h { sub(/^[^ ]+  [^ ]+  /, ""); print }') && [ -n "$near" ]; then
      printf '%s: starts like %s but its size (%s) differs: an incomplete or altered copy\n' "$f" "$near" "$size"
      rc=1
    else
      printf '%s: matches no capture in %s\n' "$f" "${SUMS##*/}"
      rc=1
    fi
  done
  exit "$rc"
fi

# --- verify ----------------------------------------------------------------

ok=0; bad=0
while IFS= read -r line; do
  want_hash="${line%%  *}"; rest="${line#*  }"
  want_size="${rest%%  *}"; p="${rest#*  }"

  if [ "${#patterns[@]}" -gt 0 ]; then
    hit=0
    for pat in "${patterns[@]}"; do
      case "$p" in *"$pat"*) hit=1; break ;; esac
    done
    [ "$hit" = 1 ] || continue
  fi

  f="$LIBRARY/$p"
  if [ ! -f "$f" ]; then
    printf 'MISSING  %s\n' "$p"; bad=$(( bad + 1 )); continue
  fi
  if ! read -r hash size < <(fingerprint "$f"); then
    printf 'UNREADABLE  %s\n' "$p"; bad=$(( bad + 1 )); continue
  fi
  if [ "$size" != "$want_size" ]; then
    printf 'SIZE     %s (%s bytes, expected %s)\n' "$p" "$size" "$want_size"; bad=$(( bad + 1 ))
  elif [ "$hash" != "$want_hash" ]; then
    printf 'HASH     %s\n' "$p"; bad=$(( bad + 1 ))
  else
    printf 'OK       %s\n' "$p"; ok=$(( ok + 1 ))
  fi
done < <(sum_lines)

[ $(( ok + bad )) -gt 0 ] || die "no capture matched ${patterns[*]}"
printf '\n%d ok, %d failed\n' "$ok" "$bad"
[ "$bad" = 0 ]
