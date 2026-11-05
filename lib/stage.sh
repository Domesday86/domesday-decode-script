# shellcheck shell=bash
#
# Stamp-and-skip for the stages of build-pack.sh, the guard that keeps every
# write on the decodes share, and the two-versions retention rule. Sourced, not
# run; needs bash 4, and lib/shares.sh sourced first.
#
# A stage declares its inputs, and its stamp key is a hash of them:
#
#   stage_begin <name> <dir>          start describing a stage that writes <dir>
#   stage_input <label> <value>       a parameter
#   stage_input_stamp <label> <dir>   an upstream stage (its key, not its data)
#   stage_input_source <relpath>      a capture, by its sources.sha256 line
#   stage_input_tool <flake input>    a tool, by its locked revision
#   stage_input_file <label> <path>   a file, by its normalised content
#   stage_output <relpath>            a file the stage must leave in <dir>
#
# then asks whether it has anything to do:
#
#   stage_state                       prints "up to date" or "stale: <why>";
#                                     true when up to date
#
# and, if it has, writes each output to stage_tmp's name and finishes with
# stage_commit, which moves them into place and writes the stamp last. An
# interrupted stage therefore never looks complete.
#
# Stamps chain: a downstream stage takes its upstream stage's key as an input,
# so nothing ever rehashes a multi-gigabyte output to see whether it changed.
#
# The stamp is <dir>/stage.stamp:
#
#   stage: <name>
#   key: <sha256 of the input lines>
#   stamped: <unix time>
#   output: <relpath>        (one per output)
#   input: <label>: <value>  (one per input, sorted)

STAGE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/util.sh
. "$STAGE_ROOT/lib/util.sh"

STAGE_STAMP=stage.stamp

# --- where writes may go ---------------------------------------------------

# stage_guard <path>: true if <path> may be written. It must lie under the
# decodes share and not under the library, both judged on physical paths, so
# neither a symlink nor a mount point nested in the other can route around it.
stage_guard() {
  local p="$1"
  [ -n "${DD_DECODES:-}" ] || { printf 'stage: DD_DECODES is not set\n' >&2; return 1; }
  if [ -n "${DD_LIBRARY:-}" ] && path_under "$p" "$DD_LIBRARY"; then
    printf 'stage: refusing to write %s: it is in the capture library, which is read-only\n' "$p" >&2
    return 1
  fi
  if ! path_under "$p" "$DD_DECODES"; then
    printf 'stage: refusing to write %s: everything is written under the decodes share (%s)\n' "$p" "$DD_DECODES" >&2
    return 1
  fi
}

# stage_mkdir <dir>: mkdir -p, guarded.
stage_mkdir() { stage_guard "$1" && mkdir -p -- "$1"; }

# --- tools -----------------------------------------------------------------

# The short name a tool's outputs are filed under, and the flake package that
# provides it. Outputs are filed under the revision that made them.
stage_tool_prefix() {
  case "$1" in
    ld-decode)    printf 'ld-decode\n' ;;
    decode-orc)   printf 'orc\n' ;;
    vfs-verifier) printf 'vfs\n' ;;
    *)            return 1 ;;
  esac
}

# stage_tool_rev <flake input>: the locked revision, abbreviated to 7.
stage_tool_rev() {
  local rev
  rev=$(jq -r --arg n "$1" '.nodes[$n].locked.rev // empty' "$STAGE_ROOT/flake.lock" 2>/dev/null) || rev=""
  [ -n "$rev" ] || { printf 'stage: no locked revision for %s in flake.lock\n' "$1" >&2; return 1; }
  printf '%s\n' "${rev:0:7}"
}

# stage_tool_dir <flake input>: e.g. orc-31d22e6.
stage_tool_dir() {
  local prefix rev
  prefix=$(stage_tool_prefix "$1") || return 1
  rev=$(stage_tool_rev "$1") || return 1
  printf '%s-%s\n' "$prefix" "$rev"
}

# --- dating versions -------------------------------------------------------
#
# A version's name says what made it (orc-2611e5b, pack-<key>), which is what
# finds it again, and also when, for whoever reads the listing: the time the
# run that first made it started, as <name>-YYYYMMDD-HHMMSS. A run takes the
# time once, when it starts, so every version it makes carries the same one;
# it is exported, so a decode script build-pack.sh runs dates its decodes the
# same. A version that is already there keeps the date it was made with.
: "${STAGE_RUN_TIME:=$(date +%Y%m%d-%H%M%S)}"
export STAGE_RUN_TIME

# stage_version_name <parent> <name>: the directory in <parent> that version
# <name> is filed in, as a name: the dated one there (the newest, if a person
# has left more than one), or one made before versions were dated, or else a
# new one dated by this run.
stage_version_name() {
  local parent="$1" name="$2" d found=""
  for d in "$parent/$name"-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]/; do
    [ -d "$d" ] && found="${d%/}"
  done
  [ -n "$found" ] || { [ -d "$parent/$name" ] && [ ! -L "$parent/$name" ] && found="$parent/$name"; }
  [ -n "$found" ] || found="$name-$STAGE_RUN_TIME"
  printf '%s\n' "${found##*/}"
}

# stage_tool_verify <flake package> <command>: the command on PATH is the
# build flake.lock pins, so an output filed under a revision was made by it.
# Prints what is wrong and returns non-zero if not.
stage_tool_verify() {
  local pkg="$1" cmd="$2" bin expected
  bin=$(command -v "$cmd" 2>/dev/null) || { printf '%s is not on PATH (run: nix develop)\n' "$cmd"; return 1; }
  bin=$(readlink -f -- "$bin")
  expected=$(nix eval --raw "$STAGE_ROOT#$pkg.outPath" 2>/dev/null) \
    || { printf 'could not evaluate .#%s in the flake\n' "$pkg"; return 1; }
  case "$bin" in
    "$expected"/*) return 0 ;;
  esac
  printf '%s on PATH is %s, not the locked build %s (exit; nix develop)\n' "$cmd" "$bin" "$expected"
  return 1
}

# --- describing a stage ----------------------------------------------------

stage_begin() {
  STAGE_NAME="$1"
  STAGE_DIR="${2%/}"
  STAGE_INPUTS=()
  STAGE_OUTPUTS=()
}

stage_input() { STAGE_INPUTS+=("$1: $2"); }

stage_input_stamp() {
  local key
  key=$(stage_stamp_field "$2" key) || key="none"
  STAGE_INPUTS+=("upstream $1: $key")
}

stage_input_source() {
  local line
  line=$(grep -v '^#' "$STAGE_ROOT/sources.sha256" \
           | awk -v p="$1" '{ h = $1; s = $2; sub(/^[^ ]+  [^ ]+  /, ""); if ($0 == p) print h, s }')
  [ -n "$line" ] || line="not in sources.sha256"
  STAGE_INPUTS+=("source $1: $line")
}

# A tool by its locked revision, and by any patches flake.nix applies to it
# (patches/<flake input>-*.patch), so that changing a patch is a change of
# tool.
stage_input_tool() {
  local rev p
  rev=$(stage_tool_rev "$1") || rev="unlocked"
  for p in "$STAGE_ROOT/patches/$1"-*.patch; do
    [ -f "$p" ] || continue
    rev+=" +${p##*/}:$(sha256_stdin < "$p" | cut -c1-12)"
  done
  STAGE_INPUTS+=("tool $1: $rev")
}

# A file by its content, normalised so that only content counts: comments,
# blank lines and trailing whitespace do not change the key.
stage_input_file() {
  local hash
  if [ -f "$2" ]; then
    hash=$(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^$/d' "$2" | sha256_stdin)
  else
    hash="missing"
  fi
  STAGE_INPUTS+=("file $1: $hash")
}

stage_output() { STAGE_OUTPUTS+=("$1"); }

# The sorted input lines, one per line.
stage_inputs() { [ "${#STAGE_INPUTS[@]}" = 0 ] || printf '%s\n' "${STAGE_INPUTS[@]}" | LC_ALL=C sort; }

stage_key() { stage_inputs | sha256_stdin; }

# stage_stamp_field <dir> <field>: one field of a stage's stamp.
stage_stamp_field() {
  local f="$1/$STAGE_STAMP" v
  [ -f "$f" ] || return 1
  v=$(sed -n "s/^$2: //p" "$f" | head -1)
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# --- deciding --------------------------------------------------------------

# stage_state: prints "up to date" or "stale: <reason>"; true when up to date.
stage_state() {
  local f="$STAGE_DIR/$STAGE_STAMP" key old o changed
  if [ ! -f "$f" ]; then
    # Outputs with no stamp are an interrupted or unchecked run, or one made
    # before stamps: never taken as complete.
    for o in "${STAGE_OUTPUTS[@]}"; do
      [ -e "$STAGE_DIR/$o" ] || continue
      printf 'stale: not stamped (%s is there, but was never checked and stamped)\n' "$o"; return 1
    done
    printf 'stale: never built\n'; return 1
  fi
  key=$(stage_key)
  old=$(stage_stamp_field "$STAGE_DIR" key) || old=""
  if [ "$key" != "$old" ]; then
    # Name the inputs that differ from the ones the stamp records, by label.
    changed=$(LC_ALL=C comm -13 <(sed -n 's/^input: //p' "$f" | LC_ALL=C sort) <(stage_inputs) \
                | sed 's/: .*//' | paste -sd, - | sed 's/,/, /g')
    printf 'stale: changed %s\n' "${changed:-inputs}"; return 1
  fi
  for o in "${STAGE_OUTPUTS[@]}"; do
    [ -e "$STAGE_DIR/$o" ] || { printf 'stale: %s is missing\n' "$o"; return 1; }
  done
  printf 'up to date\n'
}

# --- building --------------------------------------------------------------

# stage_tmp <relpath>: the name to write an output to; stage_commit moves it
# into place. The directory is made if need be.
stage_tmp() {
  local p="$STAGE_DIR/$1.partial"
  stage_mkdir "$(dirname -- "$p")" || return 1
  printf '%s\n' "$p"
}

# stage_commit: move every output written to its stage_tmp name into place,
# check that every declared output is there, and write the stamp last. An
# output a tool wrote straight to its final name is accepted as it is.
stage_commit() {
  local o t tmp
  stage_mkdir "$STAGE_DIR" || return 1
  for o in "${STAGE_OUTPUTS[@]}"; do
    t="$STAGE_DIR/$o.partial"
    if [ -e "$t" ]; then
      rm -rf -- "${STAGE_DIR:?}/$o"
      mv -- "$t" "$STAGE_DIR/$o"
    fi
    [ -e "$STAGE_DIR/$o" ] || { printf 'stage: %s did not produce %s\n' "$STAGE_NAME" "$o" >&2; return 1; }
  done
  tmp="$STAGE_DIR/$STAGE_STAMP.partial"
  {
    printf 'stage: %s\n' "$STAGE_NAME"
    printf 'key: %s\n' "$(stage_key)"
    printf 'stamped: %s\n' "$(date +%s)"
    for o in "${STAGE_OUTPUTS[@]}"; do printf 'output: %s\n' "$o"; done
    stage_inputs | sed 's/^/input: /'
  } > "$tmp"
  mv -- "$tmp" "$STAGE_DIR/$STAGE_STAMP"
}

# stage_unstamp: remove a stage's stamp, so it is stale until rebuilt. Used by
# --force, and before a stage starts rewriting outputs in place.
stage_unstamp() {
  stage_guard "$STAGE_DIR" || return 1
  rm -f -- "$STAGE_DIR/$STAGE_STAMP"
}

# --- keeping two versions --------------------------------------------------
#
# Each rev-named output (ld-decode-<rev>, orc-<rev>, vfs-<rev>, pack-<key>,
# each dated as above) keeps the current version and the one before it, and no
# more. A version is complete when <version>/<marker> -- the stamp of the last
# stage that writes into it -- exists. Versions are ordered by that stamp's time.

# stage_versions <parent> <prefix> <marker>: complete versions, newest first,
# as "<stamped> <dir>".
stage_versions() {
  local parent="$1" prefix="$2" marker="$3" d t
  for d in "$parent/$prefix"-*/; do
    d="${d%/}"
    [ -d "$d" ] || continue
    t=$(stage_stamp_field "$(dirname -- "$d/$marker")" stamped) || continue
    printf '%s %s\n' "$t" "$d"
  done | sort -rn
}

# stage_prune <parent> <prefix> <marker> [<current>]: keep the current version
# and the newest complete one before it, and delete every other version,
# complete or not -- a failed or interrupted attempt included. <current> is
# the version a run is using, which is kept even if it is not complete yet;
# it defaults to the newest complete version, as it does when <current> has
# not been made. Run only once a run has succeeded, so a failed run never
# removes anything: its attempt stays for a person to look at until the next
# run that succeeds. With no version to keep, nothing is removed.
stage_prune() {
  local parent="$1" prefix="$2" marker="$3" current="${4:-}" previous="" t d
  current="${current%/}"
  [ -z "$current" ] || [ -d "$current" ] || current=""
  while read -r t d; do
    if [ -z "$current" ]; then current="$d"
    elif [ "$d" != "$current" ]; then previous="$d"; break
    fi
  done < <(stage_versions "$parent" "$prefix" "$marker")
  [ -n "$current" ] || return 0
  for d in "$parent/$prefix"-*/; do
    d="${d%/}"
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ "$d" != "$current" ] && [ "$d" != "$previous" ] || continue
    stage_guard "$d" || return 1
    case "${d##*/}" in "$prefix"-*) ;; *) return 1 ;; esac
    if t=$(stage_stamp_field "$(dirname -- "$d/$marker")" stamped); then
      printf 'removing old version %s (stamped %s)\n' "$d" "$(date -d "@$t" 2>/dev/null || date -r "$t")"
    else
      printf 'removing incomplete version %s (never stamped)\n' "$d"
    fi
    rm -rf -- "$d"
  done
}
