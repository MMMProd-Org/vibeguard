#!/usr/bin/env bash
#
# scripts/test-block-force-push.sh — regression harness for #1032.
#
# Exercises .claude/hooks/block-force-push.sh against the destructive-command
# patterns it must block (exit 2) and the benign commands it must allow (exit 0).
# Run from repo root :
#
#   bash scripts/test-block-force-push.sh
#
# Override the hook under test (red/green mutation check) :
#
#   HOOK_PATH=/tmp/mutated-hook.sh bash scripts/test-block-force-push.sh
#
# Exits 0 on all-pass, 1 on any fail. jq is required by the hook itself.

set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
REPO_ROOT="$PWD"

HOOK="${HOOK_PATH:-$REPO_ROOT/hooks/block-force-push.sh}"

if [ ! -f "$HOOK" ]; then
  echo "ERROR: hook not found: $HOOK" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required to exercise block-force-push.sh" >&2
  exit 1
fi

PASS=0
FAIL=0
check() {
  if [ "$1" = "$2" ]; then
    PASS=$((PASS + 1))
    echo "  PASS"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL (expected exit $2, got $1)"
  fi
}

# Feed a bash command (arg 1) to the hook as PreToolUse JSON, return its exit.
# jq -nc encodes the command safely (quotes, backslashes, spaces).
run_cmd() {
  local cmd="$1"
  local payload
  payload=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  printf '%s' "$payload" | bash "$HOOK" >/dev/null 2>&1
}

# The commands below are test DATA fed to the hook as JSON on stdin. The hook
# only greps the string and exits a status code — it never executes the command
# — so the literal destructive patterns here are inert (never run).

echo "=== block-force-push.sh regression test ==="

echo "T1 : benign 'ls -la' -> allow (0)"
run_cmd "ls -la"; check $? 0

echo "T2 : git push --force -> block (2)"
run_cmd "git push --force"; check $? 2

echo "T3 : git push -f origin feature -> block (2)"
run_cmd "git push -f origin feature"; check $? 2

echo "T4 : git push --force-with-lease -> block (2)"
run_cmd "git push --force-with-lease origin feature"; check $? 2

echo "T5 : git reset --hard -> block (2)"
run_cmd "git reset --hard HEAD~1"; check $? 2

echo "T6 : git push origin main -> block (2)"
run_cmd "git push origin main"; check $? 2

echo "T7 : git push -u origin main -> block (2)"
run_cmd "git push -u origin main"; check $? 2

echo "T8 : git -C /repo push origin main -> block (2)"
run_cmd "git -C /repo push origin main"; check $? 2

echo "T9 : git push origin HEAD:main (colon refspec) -> block (2)"
run_cmd "git push origin HEAD:main"; check $? 2

echo "T10 : git push origin refs/heads/main -> block (2)"
run_cmd "git push origin refs/heads/main"; check $? 2

echo "T11 : rm -rf /tmp/x -> block (2)"
run_cmd "rm -rf /tmp/x"; check $? 2

echo "T12 : rm -fr /tmp/x (cluster order) -> block (2)"
run_cmd "rm -fr /tmp/x"; check $? 2

echo "T13 : rm -r --force /tmp/x (split flags) -> block (2)"
run_cmd "rm -r --force /tmp/x"; check $? 2

echo "T14 : empty command -> allow (0)"
run_cmd ""; check $? 0

echo "T15 : invalid JSON -> block (2)"
printf 'not json' | bash "$HOOK" >/dev/null 2>&1; check $? 2

echo "T16 : negative 'git reset --soft HEAD~1' -> allow (0)"
run_cmd "git reset --soft HEAD~1"; check $? 0

echo "T17 : negative 'git push origin feature-branch' -> allow (0)"
run_cmd "git push origin feature-branch"; check $? 0

echo "T18 : negative 'git commit -m wip' -> allow (0)"
run_cmd "git commit -m wip"; check $? 0

echo ""
echo "=== RESULTS : $PASS pass, $FAIL fail ==="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
