#!/usr/bin/env bash
set -euo pipefail
#
# vibeguard pre-tool-use-pwd-guard.sh - PreToolUse:Bash worktree-lock guard.
#
# OPT-IN (installed only with `install.sh --with-worktree-lock`). Pairs with
# session-start.sh, which writes .claude/.session-lock.json at session start.
#
# MUST run BEFORE pre-tool-use-danger.sh in .claude/settings.json: it pins the
# session to the worktree recorded in the lock. If the Bash hook's pwd is not
# under the lock's project_dir, the command is blocked (exit 2). This stops a
# multi-agent setup from drifting one session into another session's worktree.
#
# Drift note: Claude Code's Bash tool persists pwd across calls, so a
# `cd ../other-wt && cmd` drift slips on the first call (hook pwd still = the
# original worktree) but is caught on the NEXT call. AST parsing of the command
# string is intentionally out of scope.

# Drain stdin (PreToolUse JSON payload - we don't need the command body).
[ -t 0 ] || cat >/dev/null 2>&1 || true

# Resolve worktree root via CLAUDE_PROJECT_DIR, falling back to git toplevel.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}"
if [ -z "$PROJECT_DIR" ]; then
  PROJECT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
fi
# No project dir resolved (no CLAUDE_PROJECT_DIR and not in a git tree) -> no lock
# to enforce; do not break tooling outside a project.
[ -z "$PROJECT_DIR" ] && exit 0

LOCK_FILE="$PROJECT_DIR/.claude/.session-lock.json"

# Absent lock -> no enforcement (session-start ran outside git or was skipped).
[ ! -f "$LOCK_FILE" ] && exit 0

# jq absent BUT lock file present -> fail-closed BLOCK. Without jq we cannot
# verify the project_dir, and allowing through would let the guard be bypassed
# by uninstalling jq. Matches the fail-closed convention of the sibling hooks.
if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED: jq missing - pwd-guard cannot verify $LOCK_FILE (security)." >&2
  echo "Install jq: apt install jq / brew install jq" >&2
  exit 2
fi

# Corrupted JSON OR missing project_dir -> fail-closed BLOCK.
if ! LOCK_PROJECT_DIR=$(jq -r '.project_dir // empty' "$LOCK_FILE" 2>/dev/null); then
  echo "BLOCKED: $LOCK_FILE parse failed (jq). Inspect it, then delete it: rm -- \"$LOCK_FILE\"" >&2
  exit 2
fi
if [ -z "$LOCK_PROJECT_DIR" ]; then
  echo "BLOCKED: $LOCK_FILE corrupted (empty project_dir). Inspect it, then delete it: rm -- \"$LOCK_FILE\"" >&2
  exit 2
fi

# Canonicalize both paths the same way. Older macOS readlink lacks -f, where a
# bare `readlink -f || echo` leaves the lock path unresolved while `pwd -P`
# resolves it, producing a false match/mismatch. realpath_portable tries
# realpath / python3 / greadlink / readlink -f (same helper as the scope guard).
realpath_portable() {
  if command -v realpath  >/dev/null 2>&1; then realpath  "$1" 2>/dev/null && return 0; fi
  if command -v python3   >/dev/null 2>&1; then python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null && return 0; fi
  if command -v greadlink >/dev/null 2>&1; then greadlink -f "$1" 2>/dev/null && return 0; fi
  readlink -f "$1" 2>/dev/null && return 0
  return 1
}
# realpath_portable resolves symlinks on macOS too (where readlink lacks -f). If
# no resolver exists at all (minimal system), fall back to the raw lock path
# rather than bricking the lock - same behavior as the scope guard. pwd -P is
# already physically canonical.
LOCK_CANON=$(realpath_portable "$LOCK_PROJECT_DIR" || echo "$LOCK_PROJECT_DIR")
PWD_CANON=$(pwd -P 2>/dev/null || pwd)

# Normalize trailing slash.
LOCK_CANON="${LOCK_CANON%/}"
PWD_CANON="${PWD_CANON%/}"

# Tamper check: the lock's project_dir must match the worktree the lock lives in.
# A parseable-but-tampered lock (e.g. project_dir "/") would otherwise make the
# prefix check below pass for any cwd, silently bypassing the drift guard.
PROJECT_CANON=$(realpath_portable "$PROJECT_DIR" || echo "$PROJECT_DIR")
PROJECT_CANON="${PROJECT_CANON%/}"
if [ "$LOCK_CANON" != "$PROJECT_CANON" ]; then
  echo "BLOCKED: lock project_dir ($LOCK_CANON) does not match this worktree ($PROJECT_CANON) - tampered/stale lock." >&2
  echo "Inspect it, then delete it: rm -- \"$LOCK_FILE\"" >&2
  exit 2
fi

# PASS if pwd == project_dir OR pwd is a subdirectory of project_dir.
case "$PWD_CANON" in
  "$LOCK_CANON"|"$LOCK_CANON"/*)
    exit 0
    ;;
  *)
    echo "BLOCKED: cwd ($PWD_CANON) is outside the worktree owned by the session lock ($LOCK_CANON)." >&2
    echo "Multi-agent PWD drift detected. cd $LOCK_CANON, or open a new session in the target worktree." >&2
    exit 2
    ;;
esac
