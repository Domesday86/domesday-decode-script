# shellcheck shell=bash
#
# Check that the network shares the scripts use are mounted, and mount them
# when they are not. Sourced, not run; needs bash 4.
#
#   ensure_shares [--no-mount] <role> ...   check (and mount) each share
#   share_report <role>                     one line of status for a share
#
# A role is "library" or "decodes", as named in shares.conf.
#
# A share that has silently not mounted is worse than a missing tool. On macOS
# an unmounted /Volumes/<share> can still be an ordinary empty directory, and a
# decode written there fills the local disk while looking like progress; a
# second copy of the share gets mounted at /Volumes/<share>-1 when the expected
# path is taken; and a hung NFS mount blocks whatever touches it. So a share
# passes only if all of these hold, in this order:
#
#   1. it is a mount: the mount table lists the expected path;
#   2. it is the right mount: the table's source and type match shares.conf;
#   3. it responds: a stat and a listing finish within SHARE_TIMEOUT seconds;
#   4. it has the right content: for the library, the first capture in
#      sources.sha256 is there at its recorded size; for decodes, the marker
#      file .domesday86-decodes is at the root;
#   5. it has the right access: the library is readable (and is never
#      write-tested, since a write test is itself a write); decodes is
#      writable, tested in decode-script/.work.
#
# Checks 1 and 2 read only the mount table, so they cannot hang. Everything
# that touches the share itself runs under a timeout (share_timed).
#
# Once decodes passes, TMPDIR is pointed at decode-script/.work on it, so
# scratch files go to the share and not to local disk.

# Every script sources this first, so this is where an old bash is caught.
# macOS's /bin/bash is 3.2, which "#!/usr/bin/env bash" finds outside the dev
# shell; there the scripts fail later and obscurely (an empty array is unbound
# under set -u, and ${1,,} is a syntax error).
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  printf '%s: needs bash 4 or later, and this is bash %s; run it inside the dev shell (nix develop), or as: nix develop -c %s\n' \
    "${0##*/}" "${BASH_VERSION:-unknown}" "$0" >&2
  exit 1
fi

SHARES_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/util.sh
. "$SHARES_ROOT/lib/util.sh"

SHARES_MARKER=.domesday86-decodes

# Return codes of share_check. Only SHARE_ABSENT is mended by mounting.
SHARE_OK=0
SHARE_ABSENT=10       # nothing mounted at the path, nor anywhere else
SHARE_ELSEWHERE=11    # the share is mounted, but at another path
SHARE_BLOCKED=12      # a plain directory stands where the mount should be
SHARE_WRONG=13        # something else is mounted at the path
SHARE_HUNG=14         # mounted, but does not answer
SHARE_CONTENT=15      # answers, but is not the share it should be
SHARE_ACCESS=16       # the right share, without the access it needs

shares_load() {
  [ -z "${SHARES_LOADED:-}" ] || return 0
  case "$(uname -s)" in
    Darwin) SHARES_PLATFORM=darwin ;;
    Linux)  SHARES_PLATFORM=linux ;;
    *)      printf 'shares: unsupported platform: %s\n' "$(uname -s)" >&2; return 1 ;;
  esac
  SHARE_TIMEOUT=10
  # shellcheck source=shares.conf
  . "$SHARES_ROOT/shares.conf"
  # SHARES_LOCAL_CONF names another override file, for tests.
  local local_conf="${SHARES_LOCAL_CONF:-$SHARES_ROOT/shares.local.conf}"
  if [ -f "$local_conf" ]; then
    # shellcheck source=/dev/null
    . "$local_conf"
  fi
  DD_LIBRARY="${DD_LIBRARY:-$(share_conf library mount)}"
  DD_DECODES="${DD_DECODES:-$(share_conf decodes mount)}"
  DD_LIBRARY="${DD_LIBRARY%/}"
  DD_DECODES="${DD_DECODES%/}"
  export DD_LIBRARY DD_DECODES
  SHARES_LOADED=1
}

# share_conf <role> <field>: a value from shares.conf for this platform.
share_conf() {
  local v="SHARE_$1_${SHARES_PLATFORM}_$2"
  printf '%s\n' "${!v:-}"
}

share_mount_point() {
  case "$1" in
    library) printf '%s\n' "$DD_LIBRARY" ;;
    decodes) printf '%s\n' "$DD_DECODES" ;;
    *)       return 1 ;;
  esac
}

# The mount table as "source<TAB>mount point<TAB>type<TAB>options", options
# comma-separated without spaces. Read from the kernel's table, so listing it
# never touches a share and cannot hang on one.
shares_mount_table() {
  local line src mnt fstype opts _
  if [ "$SHARES_PLATFORM" = linux ]; then
    while read -r src mnt fstype opts _; do
      printf '%s\t%s\t%s\t%s\n' "$src" "${mnt//\\040/ }" "$fstype" "$opts"
    done < /proc/self/mounts
  else
    # "//sdi@raid._smb._tcp.local/Share on /Volumes/Share (smbfs, nodev, nosuid, mounted by sdi)"
    while IFS= read -r line; do
      if [[ $line =~ ^(.*)\ on\ (/.*)\ \(([^,\)]*)(,\ (.*))?\)$ ]]; then
        opts="${BASH_REMATCH[5]}"
        printf '%s\t%s\t%s\t%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
          "${BASH_REMATCH[3]}" "${opts//, /,}"
      fi
    done < <(/sbin/mount)
  fi
}

# A mount source reduced to what identifies the share: lower case, and for
# SMB without the user, since the same share mounted by another account is
# still the same share.
share_source_key() {
  local s="${1,,}"
  case "$s" in
    //*@*) s="//${s#//*@}" ;;
  esac
  printf '%s\n' "$s"
}

# share_mount_entry <role>: the mount table line for the role's mount point.
share_mount_entry() {
  local mp
  mp=$(share_mount_point "$1") || return 1
  shares_mount_table | awk -F'\t' -v mp="$mp" '$2 == mp { line = $0 } END { if (line != "") print line; else exit 1 }'
}

# share_mounted_elsewhere <role>: the mount points at which the role's source
# is mounted, other than the expected one.
share_mounted_elsewhere() {
  local mp want src mnt fstype opts
  mp=$(share_mount_point "$1")
  want=$(share_source_key "$(share_conf "$1" source)")
  while IFS=$'\t' read -r src mnt fstype opts; do
    [ "$mnt" != "$mp" ] || continue
    [ "$(share_source_key "$src")" = "$want" ] && printf '%s\n' "$mnt"
  done < <(shares_mount_table)
  return 0
}

# share_timed <command> ...: run a command that touches a share, and give up
# after SHARE_TIMEOUT seconds. Prints the command's first line of output.
#
# A process stuck on a hard NFS mount cannot be killed, so it is never waited
# for: it runs in a process substitution, and only its output is read, with a
# timeout. On a timeout the process is abandoned, not reaped. Returns 124 on a
# timeout, 1 if the command failed.
share_timed() {
  local fd out rc
  # Every descriptor but the pipe read here is closed in the probe, so an
  # abandoned process holds nothing open that a caller (a pipe, a command
  # substitution) would go on waiting for. That includes the copies bash
  # keeps of a redirected stream to restore later -- "share_timed ... >/dev/null"
  # leaves one of the caller's stdout -- which are why this closes everything
  # listed in /dev/fd rather than just stdin and stderr.
  exec {fd}< <(_share_detach; "$@" && printf '\n' || printf 'FAILED\n')
  if IFS= read -r -t "$SHARE_TIMEOUT" -u "$fd" out; then
    exec {fd}<&-
    [ "$out" != FAILED ] || return 1
    printf '%s\n' "$out"
    return 0
  else
    rc=$?
    exec {fd}<&-
    [ "$rc" -gt 128 ] && return 124
    return 1
  fi
}

# Close every descriptor but stdout, and point stdin and stderr at /dev/null.
_share_detach() {
  local f n
  exec 2>/dev/null </dev/null
  for f in /dev/fd/*; do
    n="${f##*/}"
    case "$n" in 0|1|2|*[!0-9]*) continue ;; esac
    eval "exec $n>&-" 2>/dev/null || true
  done
}

# The probe run under share_timed for check 3: the share's root must list, and
# must be on a different device from the directory it is mounted in.
_share_probe() {
  local d_root d_parent
  d_root=$(file_dev "$1") || return 1
  d_parent=$(file_dev "$1/..") || return 1
  ls -A -- "$1" >/dev/null || return 1
  [ "$d_root" != "$d_parent" ] || return 1
  printf 'ok'
}

# The first capture in sources.sha256, as "<size> <path>", for check 4.
_share_library_sentinel() {
  grep -v '^#' "$SHARES_ROOT/sources.sha256" | grep -v '^[[:space:]]*$' | head -1 \
    | awk '{ size = $2; sub(/^[^ ]+  [^ ]+  /, ""); print size, $0 }'
}

_share_size_is() { [ "$(file_size "$1")" = "$2" ] && printf 'ok'; }
_share_is_file() { [ -f "$1" ] && printf 'ok'; }
_share_readable() { [ -r "$1" ] && [ -x "$1" ] && printf 'ok'; }

_share_writable() {
  local work="$1/decode-script/.work" t
  mkdir -p -- "$work" || return 1
  t=$(mktemp "$work/.write-test.XXXXXX") || return 1
  rm -f -- "$t" || return 1
  printf 'ok'
}

# share_check <role>: run checks 1-5 on one share. Returns one of the SHARE_*
# codes, and leaves a sentence saying what is wrong in SHARE_PROBLEM (empty
# when the share passes) and any warning in SHARE_WARNING.
share_check() {
  local role="$1" mp entry src mnt fstype opts want_src want_type elsewhere sentinel size rel
  SHARE_PROBLEM=""
  SHARE_WARNING=""
  shares_load || return 1
  mp=$(share_mount_point "$role") || { SHARE_PROBLEM="unknown share role: $role"; return 1; }
  want_src=$(share_conf "$role" source)
  want_type=$(share_conf "$role" fstype)

  # 1. It is a mount.
  if ! entry=$(share_mount_entry "$role"); then
    elsewhere=$(share_mounted_elsewhere "$role" | head -1)
    if [ -n "$elsewhere" ]; then
      SHARE_PROBLEM="$want_src is mounted at $elsewhere, not at $mp"
      [ ! -e "$mp" ] || SHARE_PROBLEM="$SHARE_PROBLEM ($mp is taken by a plain directory, which is why)"
      return "$SHARE_ELSEWHERE"
    fi
    # On Linux an empty directory is simply where the mount goes. On macOS
    # /Volumes/<share> should not exist while the share is unmounted, and if
    # it does, mounting would put the share at <share>-1.
    if [ "$SHARES_PLATFORM" = darwin ] && [ -e "$mp" ]; then
      SHARE_PROBLEM="$mp is a plain directory, not a mount; mounting now would put the share at $mp-1. Remove it if it is empty (rmdir \"$mp\") and try again"
      return "$SHARE_BLOCKED"
    fi
    SHARE_PROBLEM="$mp is not mounted"
    return "$SHARE_ABSENT"
  fi

  # 2. It is the right mount.
  IFS=$'\t' read -r src mnt fstype opts <<< "$entry"
  if [ "$(share_source_key "$src")" != "$(share_source_key "$want_src")" ]; then
    SHARE_PROBLEM="$mp is $src, not $want_src"
    return "$SHARE_WRONG"
  fi
  case "$fstype" in
    "$want_type"*) ;;
    *) SHARE_PROBLEM="$mp is mounted as $fstype, not $want_type"; return "$SHARE_WRONG" ;;
  esac

  # 3. It responds.
  local trc=0
  share_timed _share_probe "$mp" >/dev/null || trc=$?
  if [ "$trc" != 0 ]; then
    case "$trc" in
      124) SHARE_PROBLEM="$mp did not answer within ${SHARE_TIMEOUT}s; the mount is hung" ;;
      *)   SHARE_PROBLEM="$mp is mounted but cannot be listed" ;;
    esac
    return "$SHARE_HUNG"
  fi

  # 4. It has the right content.
  case "$role" in
    library)
      sentinel=$(_share_library_sentinel)
      if [ -n "$sentinel" ]; then
        size="${sentinel%% *}"; rel="${sentinel#* }"
        if ! share_timed _share_size_is "$mp/$rel" "$size" >/dev/null; then
          SHARE_PROBLEM="$mp does not hold $rel at its recorded size ($size bytes), so it is not the capture library"
          return "$SHARE_CONTENT"
        fi
      else
        SHARE_WARNING="sources.sha256 lists no captures, so the library's content was not checked"
      fi
      ;;
    decodes)
      if ! share_timed _share_is_file "$mp/$SHARES_MARKER" >/dev/null; then
        SHARE_PROBLEM="$mp has no $SHARES_MARKER marker, so it is not known to be the decodes share (if it is, create it: ./mount-shares.sh --mark-decodes)"
        return "$SHARE_CONTENT"
      fi
      ;;
  esac

  # 5. It has the right access.
  case "$role" in
    library)
      if ! share_timed _share_readable "$mp" >/dev/null; then
        SHARE_PROBLEM="$mp is not readable"
        return "$SHARE_ACCESS"
      fi
      case ",$opts," in
        *,ro,*|*,read-only,*|*,rdonly,*) ;;
        *) SHARE_WARNING="$mp is mounted read-write; nothing here writes to it, but the share is meant to be read-only" ;;
      esac
      ;;
    decodes)
      if ! share_timed _share_writable "$mp" >/dev/null; then
        SHARE_PROBLEM="$mp is not writable (tested in decode-script/.work)"
        return "$SHARE_ACCESS"
      fi
      ;;
  esac
  return "$SHARE_OK"
}

# share_mount <role>: mount one share. Used only when share_check says it is
# absent; anything else is a problem mounting cannot mend.
share_mount() {
  local role="$1" mp src fstype
  shares_load || return 1
  mp=$(share_mount_point "$role")
  src=$(share_conf "$role" source)
  fstype=$(share_conf "$role" fstype)

  if [ "$SHARES_PLATFORM" = darwin ]; then
    local url
    case "$fstype" in
      smbfs) url="smb:$src" ;;
      nfs)
        # Only root can make an NFS mount on macOS, and nothing here calls
        # sudo, so the one script that needs it is named instead.
        printf '%s\n' \
          "shares: $mp is not mounted. NFS on macOS needs root; mount the shares with:" \
          "  sudo $SHARES_ROOT/mac-nfs-mount.sh" >&2
        return 1 ;;
      *)     printf 'shares: do not know how to mount a %s share on macOS\n' "$fstype" >&2; return 1 ;;
    esac
    # Finder's own mount: it takes the credentials from the Keychain, mounts
    # at /Volumes/<share>, and returns once the share is up.
    printf 'mounting %s (%s)\n' "$url" "$role" >&2
    osascript -e "mount volume \"$url\"" >/dev/null || return 1
    return 0
  fi

  # Linux: only a mount the host already defines (fstab, an automount unit)
  # can be brought up without root. The host's setup is its own; nothing here
  # adds to it or calls sudo.
  printf 'mounting %s (%s)\n' "$mp" "$role" >&2
  if mount -- "$mp" 2>/dev/null; then
    return 0
  fi
  local ro=""
  [ "$role" = library ] && ro="-o ro "
  printf '%s\n' \
    "shares: $mp is not mounted, and this host does not define a mount for it." \
    "Mount it with:" \
    "  sudo mkdir -p $mp && sudo mount -t $fstype $ro$src $mp" >&2
  return 1
}

# ensure_shares [--no-mount] <role> ...: every named share passes share_check,
# mounting it first if it is absent (unless --no-mount or DD_NO_MOUNT=1).
# Prints what is wrong and returns non-zero if any share does not pass.
ensure_shares() {
  local mount_ok=1 role rc bad=0
  [ "${DD_NO_MOUNT:-0}" = 1 ] && mount_ok=0
  if [ "${1:-}" = --no-mount ]; then mount_ok=0; shift; fi
  shares_load || return 1
  for role in "$@"; do
    rc=0; share_check "$role" || rc=$?
    if [ "$rc" = "$SHARE_ABSENT" ] && [ "$mount_ok" = 1 ]; then
      if share_mount "$role"; then
        # A share that mounts and then fails a check is an error, not
        # something to retry.
        rc=0; share_check "$role" || rc=$?
      fi
    fi
    if [ "$rc" != 0 ]; then
      printf 'shares: %s: %s\n' "$role" "$SHARE_PROBLEM" >&2
      bad=1
      continue
    fi
    if [ -n "$SHARE_WARNING" ]; then
      local seen="SHARES_WARNED_$role"
      if [ -z "${!seen:-}" ]; then
        printf 'shares: warning: %s: %s\n' "$role" "$SHARE_WARNING" >&2
        printf -v "$seen" 1
      fi
    fi
    if [ "$role" = decodes ]; then
      TMPDIR="$DD_DECODES/decode-script/.work"
      export TMPDIR
    fi
  done
  return "$bad"
}

# share_report <role>: one line saying where a share is and whether it passes.
share_report() {
  local role="$1" rc=0 entry src
  share_check "$role" || rc=$?
  if [ "$rc" = 0 ]; then
    entry=$(share_mount_entry "$role")
    src=$(printf '%s\n' "$entry" | cut -f1)
    printf '%-8s %-36s ok (%s)\n' "$role" "$(share_mount_point "$role")" "$src"
    [ -z "$SHARE_WARNING" ] || printf '%-8s %-36s warning: %s\n' "" "" "$SHARE_WARNING"
  else
    printf '%-8s %-36s FAIL: %s\n' "$role" "$(share_mount_point "$role")" "$SHARE_PROBLEM"
  fi
  return "$rc"
}
