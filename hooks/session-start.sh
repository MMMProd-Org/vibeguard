#!/usr/bin/env bash
#
# vibeguard session-start.sh - SessionStart worktree-lock acquisition.
#
# OPT-IN (installed only with `install.sh --with-worktree-lock`). Pairs with
# pre-tool-use-pwd-guard.sh.
#
# Writes .claude/.session-lock.json at the root of the current worktree. If a
# live lock owned by another session already exists (pid alive AND host match
# AND younger than the TTL) -> exit 2 with a warning. A stale lock is overwritten.
# Outside any git tree AND with no CLAUDE_PROJECT_DIR -> no-op.
#
# Lock fields: {lock_id, pid, host, started_at, project_dir, claude_session_id}.
#   - lock_id = "${pid}:${host}:${started_at_epoch}" (robust identity).
#   - stale check: started_at age > TTL, OR pid dead (same host), OR host mismatch.
#   - corrupted JSON (missing critical fields or jq parse fail) -> fail-closed BLOCK.
#   - claude_session_id is diagnostic only, never part of the lock identity.

set -euo pipefail

# Drain the SessionStart stdin payload (event JSON we ignore).
[ -t 0 ] || cat >/dev/null 2>&1 || true

LOCK_TTL_SECONDS="${WORKTREE_SESSION_LOCK_TTL_SECONDS:-86400}"  # 24h default; override for tests.
# Validate as an integer: a non-numeric override would error the numeric age
# comparison below. Fail-closed with a clear message.
case "$LOCK_TTL_SECONDS" in
  ''|*[!0-9]*)
    echo "BLOCKED: WORKTREE_SESSION_LOCK_TTL_SECONDS must be a non-negative integer (got '$LOCK_TTL_SECONDS')." >&2
    exit 2
    ;;
esac

acquire_session_lock() {
  local worktree_root lock_dir lock_file
  local lock_pid lock_host started_at_iso started_at_epoch lock_id
  local existing_pid existing_host existing_started_at existing_project_dir existing_lock_id
  local age_seconds elapsed stale kill_err

  # Resolve the current worktree root. Use CLAUDE_PROJECT_DIR first so the lock
  # is written where pre-tool-use-pwd-guard.sh looks for it, then fall back to the
  # git toplevel. Outside any repo and with no project dir -> skip lock (no-op).
  worktree_root="${CLAUDE_PROJECT_DIR:-}"
  if [ -z "$worktree_root" ]; then
    worktree_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  fi
  [ -z "$worktree_root" ] && return 0

  lock_dir="$worktree_root/.claude"
  lock_file="$lock_dir/.session-lock.json"

  # Use PPID (the parent that launched the hook = the long-lived agent session
  # process), not $$ (this short-lived hook shell, which exits immediately and
  # would make every later `kill -0` read the lock as stale -> never blocks).
  lock_pid="$PPID"
  lock_host=$(hostname 2>/dev/null || echo "unknown")
  started_at_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  started_at_epoch=$(date +%s)
  lock_id="${lock_pid}:${lock_host}:${started_at_epoch}"

  # jq required for fail-closed lock enforcement (matches the sibling hooks).
  if ! command -v jq >/dev/null 2>&1; then
    echo "BLOCKED: jq missing - session-lock cannot be acquired safely (security)." >&2
    echo "Install jq: apt install jq / brew install jq" >&2
    exit 2
  fi

  if [ -f "$lock_file" ]; then
    # JSON parse failure or critical fields missing -> fail-closed BLOCK.
    if ! existing_pid=$(jq -r '.pid // empty' "$lock_file" 2>/dev/null) \
      || ! existing_host=$(jq -r '.host // empty' "$lock_file" 2>/dev/null) \
      || ! existing_started_at=$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null) \
      || ! existing_project_dir=$(jq -r '.project_dir // empty' "$lock_file" 2>/dev/null); then
      echo "BLOCKED: $lock_file corrupted (jq parse fail). Inspect it, then delete it: rm -- \"$lock_file\"" >&2
      exit 2
    fi
    if [ -z "$existing_pid" ] || [ -z "$existing_host" ] || [ -z "$existing_started_at" ] || [ -z "$existing_project_dir" ]; then
      echo "BLOCKED: $lock_file corrupted (empty pid/host/started_at/project_dir). Inspect it, then delete it: rm -- \"$lock_file\"" >&2
      exit 2
    fi
    # Pid integer validation: non-numeric -> corrupted lock, fail-closed BLOCK
    # (otherwise kill -0 would error and the stale check would treat it as a
    # dead pid -> overwrite, which is a fail-open bypass).
    case "$existing_pid" in
      ''|*[!0-9]*)
        echo "BLOCKED: $lock_file corrupted (non-numeric pid: '$existing_pid'). Inspect it, then delete it: rm -- \"$lock_file\"" >&2
        exit 2
        ;;
    esac

    # Stale check.
    stale=0
    elapsed=""
    # Sub-check A: started_at age > TTL. GNU `date -d` first (Linux), BSD/macOS
    # `date -j -f` next, python3 as a last resort.
    age_seconds=$(date -d "$existing_started_at" +%s 2>/dev/null \
      || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$existing_started_at" +%s 2>/dev/null \
      || python3 -c "import datetime,sys; print(int(datetime.datetime.strptime(sys.argv[1],'%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc).timestamp()))" "$existing_started_at" 2>/dev/null \
      || echo "")
    if [ -n "$age_seconds" ]; then
      local now_epoch
      now_epoch=$(date +%s)
      elapsed=$((now_epoch - age_seconds))
      if [ "$elapsed" -gt "$LOCK_TTL_SECONDS" ]; then
        stale=1
      fi
    fi
    # Sub-check B: pid dead (only meaningful when the host matches - see C).
    # Distinguish ESRCH (no such process -> dead -> reclaim) from EPERM (process
    # alive but owned by another user -> keep the lock, fail-closed). kill -0
    # exposes no errno in shell, so match the message; an unrecognized failure is
    # treated as "still alive" rather than risk overwriting a live lock.
    if [ "$stale" = "0" ] && [ "$existing_host" = "$lock_host" ]; then
      if ! kill_err=$(kill -0 "$existing_pid" 2>&1); then
        case "$kill_err" in
          *"No such process"*|*"no such process"*|*ESRCH*) stale=1 ;;
          *) : ;;  # EPERM / unknown -> assume alive, do not overwrite
        esac
      fi
    fi
    # Sub-check C: host mismatch (cannot kill -0 across machines, treat as stale).
    if [ "$stale" = "0" ] && [ "$existing_host" != "$lock_host" ]; then
      stale=1
    fi

    if [ "$stale" = "0" ]; then
      # Live lock owned by another session -> BLOCK.
      existing_lock_id=$(jq -r '.lock_id // empty' "$lock_file" 2>/dev/null || echo "")
      local age_msg
      if [ -n "$elapsed" ]; then
        age_msg="for ${elapsed}s"
      else
        age_msg="started_at=${existing_started_at}"
      fi
      echo "BLOCKED: worktree ${worktree_root} held by lock_id ${existing_lock_id} ${age_msg}." >&2
      echo "If the owning session is dead/inactive, wait for the TTL or: rm -- \"$lock_file\"" >&2
      exit 2
    fi
    # Stale -> fall through to overwrite.
  fi

  # Write a fresh lock. Fail-closed on FS errors (read-only mount, disk full,
  # permission denied): a silent write failure would leave NO lock, letting
  # parallel sessions bypass enforcement.
  if ! mkdir -p "$lock_dir" 2>/dev/null; then
    echo "BLOCKED: cannot create $lock_dir (read-only FS? permission denied?)." >&2
    exit 2
  fi
  if ! jq -n \
    --arg lock_id "$lock_id" \
    --argjson pid "$lock_pid" \
    --arg host "$lock_host" \
    --arg started_at "$started_at_iso" \
    --arg project_dir "$worktree_root" \
    --arg claude_session_id "${CLAUDE_CODE_SESSION_ID:-}" \
    '{lock_id: $lock_id, pid: $pid, host: $host, started_at: $started_at, project_dir: $project_dir, claude_session_id: $claude_session_id}' \
    > "$lock_file" 2>/dev/null; then
    echo "BLOCKED: cannot write $lock_file (read-only FS? disk full?)." >&2
    # Best-effort cleanup of a possibly partial write so future sessions do not
    # fail-closed on a corrupted lock.
    rm -f "$lock_file" 2>/dev/null || true
    exit 2
  fi
}

acquire_session_lock
exit 0
