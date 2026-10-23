# shellcheck shell=bash
#
# Small helpers shared by lib/shares.sh and lib/stage.sh. Sourced, not run.
#
# Each one is written for both GNU and BSD userlands: the dev shell puts GNU
# coreutils on PATH, but a script run outside it gets macOS's BSD tools.

# sha256 of standard input, as bare hex. GNU sha256sum is in the dev shell;
# shasum is the fallback on a stock macOS.
sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# GNU stat first, then BSD stat: the two disagree on the flag. -L follows a
# symlink, as a reader of the file would.
file_size() { stat -L -c %s -- "$1" 2>/dev/null || stat -L -f %z -- "$1"; }
file_dev()  { stat -L -c %d -- "$1" 2>/dev/null || stat -L -f %d -- "$1"; }

# The physical path of a directory that exists.
phys_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# The physical path of a path that need not exist yet: the deepest ancestor
# that does exist is resolved, and the rest is appended as written. ".." in the
# part that does not exist is refused rather than guessed at.
phys_path() {
  local p="$1" tail="" head
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "$p" != / ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  while [ ! -d "$p" ]; do
    head="${p%/*}"
    case "${p##*/}" in ..) return 1 ;; esac
    tail="/${p##*/}$tail"
    p="${head:-/}"
  done
  head=$(phys_dir "$p") || return 1
  printf '%s%s\n' "${head%/}" "$tail"
}

# path_under <path> <root>: true if the physical <path> is <root> or lies
# beneath it. Both are resolved first, so a symlink cannot route around it.
path_under() {
  local p r
  p=$(phys_path "$1") || return 1
  r=$(phys_path "$2") || return 1
  case "$p/" in "${r%/}/"*) return 0 ;; esac
  return 1
}
