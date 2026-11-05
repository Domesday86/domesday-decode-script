#!/usr/bin/env bash
#
# Check lib/stage.sh: the write guard, stamp-and-skip, and keeping two
# versions. Run from the dev shell with both shares mounted:
#
#   tests/stage-test.sh
#
# Everything it makes is under decode-script/.work on the decodes share, and
# is removed afterwards.
#
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/shares.sh
. "$ROOT/lib/shares.sh"
# shellcheck source=lib/stage.sh
. "$ROOT/lib/stage.sh"
ensure_shares library decodes 2>/dev/null || { echo "stage-test: the shares must pass first" >&2; exit 2; }

T=$(mktemp -d "$DD_DECODES/decode-script/.work/stage-test.XXXXXX")
trap 'rm -rf -- "$T"' EXIT

pass=0; fail=0
ok()  { printf 'ok    %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$(( fail + 1 )); }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else bad "$what"; fi; }
refuses() { local what="$1"; shift; if "$@" 2>/dev/null; then bad "$what"; else ok "$what"; fi; }

# --- the guard -------------------------------------------------------------

check   "a path on the decodes share may be written"     stage_guard "$T/a/b/c"
refuses "a path in the library may not"                  stage_guard "$DD_LIBRARY/BBC_AIV/new"
refuses "the library root may not"                       stage_guard "$DD_LIBRARY"
refuses "local disk may not"                             stage_guard /tmp/x
refuses "nor may a relative path that leaves the share"  stage_guard "$T/../../../../../tmp/x"
if ln -s "$DD_LIBRARY" "$T/lib-link" 2>/dev/null; then
  refuses "nor a symlink on the share into the library"  stage_guard "$T/lib-link/x"
else
  printf 'skip  a symlink into the library (this share holds no symlinks)\n'
fi

# --- stamps ----------------------------------------------------------------

describe() {
  stage_begin "test" "$T/v-1"
  stage_input "param" "$PARAM"
  stage_input_file "conf" "$T/conf"
  stage_output out.txt
}

PARAM=1
printf 'a = 1\n' > "$T/conf"
describe
s=$(stage_state); check "a stage never built is stale: $s" [ "$s" = "stale: never built" ]

t=$(stage_tmp out.txt) && printf 'hello\n' > "$t"
stage_commit
s=$(stage_state); check "after commit it is up to date: $s" [ "$s" = "up to date" ]
check "the output was moved into place" [ -f "$T/v-1/out.txt" ] && [ ! -e "$T/v-1/out.txt.partial" ]

printf '# a comment\na = 1   \n\n' > "$T/conf"
describe
s=$(stage_state); check "a comment or whitespace in a file changes nothing: $s" [ "$s" = "up to date" ]

PARAM=2; describe
s=$(stage_state); check "a changed parameter makes it stale, by name: $s" [ "$s" = "stale: changed param" ]
PARAM=1

printf 'a = 2\n' > "$T/conf"; describe
s=$(stage_state); check "a changed file makes it stale, by name: $s" [ "$s" = "stale: changed file conf" ]
printf 'a = 1\n' > "$T/conf"; describe

rm "$T/v-1/out.txt"
s=$(stage_state); check "a missing output makes it stale: $s" [ "$s" = "stale: out.txt is missing" ]
printf 'hello\n' > "$T/v-1/out.txt"

# Downstream stages chain on the upstream key.
stage_begin "down" "$T/down"; stage_input_stamp up "$T/v-1"; stage_commit
stage_begin "down" "$T/down"; stage_input_stamp up "$T/v-1"
s=$(stage_state); check "a downstream stage is up to date while its upstream is: $s" [ "$s" = "up to date" ]
PARAM=3; describe; t=$(stage_tmp out.txt) && printf 'x\n' > "$t"; stage_commit
stage_begin "down" "$T/down"; stage_input_stamp up "$T/v-1"
s=$(stage_state); check "and stale once the upstream is rebuilt: $s" [ "$s" = "stale: changed upstream up" ]

# An interrupted stage leaves no stamp.
stage_begin "broken" "$T/broken"; stage_output never.txt
t=$(stage_tmp other.txt) && printf 'x\n' > "$t"
refuses "a commit without its outputs fails" stage_commit
check "and leaves no stamp" [ ! -e "$T/broken/stage.stamp" ]
stage_begin "unstamped" "$T/unstamped"; stage_output out.txt
mkdir -p "$T/unstamped"; printf 'x\n' > "$T/unstamped/out.txt"
s=$(stage_state); check "outputs with no stamp are stale, and say so: $s" [ "${s#stale: not stamped}" != "$s" ]

# shellcheck disable=SC2016 # expanded by the inner shell
refuses "a stage outside the share cannot commit" bash -c '. "$0/lib/shares.sh"; . "$0/lib/stage.sh"; shares_load; stage_begin x /tmp/stage-test-x; stage_commit' "$ROOT"
check "and nothing was written there" [ ! -e /tmp/stage-test-x ]

# --- two versions ----------------------------------------------------------

P="$T/versions"
for v in 1 2 3; do
  mkdir -p "$P/tool-$v"
  printf 'stage: t\nkey: k\nstamped: %s\n' "$(( 1000 + v ))" > "$P/tool-$v/stage.stamp"
done
mkdir -p "$P/tool-0"   # incomplete: no stamp
stage_prune "$P" tool stage.stamp >/dev/null
check "pruning keeps the newest two complete versions" [ -d "$P/tool-3" ] && [ -d "$P/tool-2" ]
check "and removes the oldest" [ ! -e "$P/tool-1" ]
check "and removes an incomplete one" [ ! -e "$P/tool-0" ]
stage_prune "$P" tool stage.stamp >/dev/null
check "pruning again removes nothing more" [ -d "$P/tool-3" ] && [ -d "$P/tool-2" ]
mkdir -p "$P/tool-4"   # the run's current version, not complete yet
stage_prune "$P" tool stage.stamp "$P/tool-4" >/dev/null
check "a current version is kept, incomplete, with the newest complete one" [ -d "$P/tool-4" ] && [ -d "$P/tool-3" ]
check "and the one before that goes" [ ! -e "$P/tool-2" ]
stage_prune "$P" tool stage.stamp "$P/tool-9" >/dev/null
check "a current version not made yet counts as none: the newest complete one stays" [ -d "$P/tool-3" ]
check "and the incomplete one, no longer current, goes" [ ! -e "$P/tool-4" ]
E="$T/none"; mkdir -p "$E/tool-0"
stage_prune "$E" tool stage.stamp >/dev/null
check "with nothing complete and no current version, nothing is removed" [ -d "$E/tool-0" ]

# --- dated versions --------------------------------------------------------

D="$T/dated"
mkdir -p "$D"
check "the run is dated YYYYMMDD-HHMMSS: $STAGE_RUN_TIME" grep -Eqx '[0-9]{8}-[0-9]{6}' <<< "$STAGE_RUN_TIME"
n=$(stage_version_name "$D" orc-abc1234)
check "a new version is dated by the run: $n" [ "$n" = "orc-abc1234-$STAGE_RUN_TIME" ]
mkdir -p "$D/orc-abc1234-20200101-000000"
n=$(stage_version_name "$D" orc-abc1234)
check "a dated version already there is reused with its date: $n" [ "$n" = orc-abc1234-20200101-000000 ]
mkdir -p "$D/orc-old0000"
n=$(stage_version_name "$D" orc-old0000)
check "and so is one from before dates: $n" [ "$n" = orc-old0000 ]
n=$(stage_version_name "$D" orc-abc)
check "a shorter revision does not take another's version: $n" [ "$n" = "orc-abc-$STAGE_RUN_TIME" ]
n=$(bash -c '. "$0/lib/shares.sh"; . "$0/lib/stage.sh"; printf %s "$STAGE_RUN_TIME"' "$ROOT")
check "a script this one runs is dated the same: $n" [ "$n" = "$STAGE_RUN_TIME" ]

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
