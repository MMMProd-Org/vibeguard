#!/usr/bin/env bash
#
# .claude/hooks/pre-tool-use-scope.sh — V4.0 (walk-up-tree scope resolution)
#
# PreToolUse hook (Edit|Write|NotebookEdit): blocks writes outside the project.
# Opt-in by default: without a .session-scope.json, writes INSIDE the project are
# allowed (anti-brick); with a scope file, writes outside scopePaths are refused.
# Fail-closed on out-of-project writes and under VIBEGUARD_SCOPE_STRICT=1.
#
# V4.0 changes vs V3.2:
#   LOCK-V4-1 : Walk-up order leaf→root, first .session-scope.json wins
#   LOCK-V4-2 : Worktree without .session-scope.json → BLOCK with bootstrap message
#   LOCK-V4-3 : No inheritance — scope file sees only its own scopePaths/forbiddenPaths
#   LOCK-V4-4 : REL relative to dirname(SCOPE_FILE), not always $CLAUDE_PROJECT_DIR
#   LOCK-V4-5 : V3.2 stderr message family preserved
#   LOCK-V4-6 : V3.2 stdin JSON contract preserved (.tool_input.file_path or .tool_input.path)
#   LOCK-V4-7 : forbiddenPaths always evaluated BEFORE scopePaths
#   LOCK-V4-8 : The governing .session-scope.json is always repairable

set -euo pipefail

# LOCK-V4-15: fail-closed on empty/unset CLAUDE_PROJECT_DIR.
# Without explicit guard, set -u catches unset (T11), but empty string ("") would
# degrade case "${CLAUDE_PROJECT_DIR}"/*) to "/*" matching any absolute path
# (SECURITY: attacker-controlled scope file via walk-up).
if [ -z "${CLAUDE_PROJECT_DIR:-}" ] || [ ! -d "${CLAUDE_PROJECT_DIR}" ]; then
  echo "BLOCKED : CLAUDE_PROJECT_DIR not set or invalid." >&2
  exit 2
fi
# M3: normalize CLAUDE_PROJECT_DIR trailing slash to prevent prefix-match failures.
CLAUDE_PROJECT_DIR="${CLAUDE_PROJECT_DIR%/}"

# B2-portable: canonicalize symlinks across platforms. Older macOS ships a readlink
# without -f, where `readlink -f ... || echo ""` silently yields "" and SKIPS the
# symlink-escape checks below (fail-open). Prefer realpath/python3/greadlink, fall
# back to readlink -f. Prints the resolved path; empty + nonzero if nothing resolves.
# ponytail: these 4 cover the macOS/Linux matrix; perl omitted (rarely the sole resolver).
realpath_portable() {
  if command -v realpath  >/dev/null 2>&1; then realpath  "$1" 2>/dev/null && return 0; fi
  if command -v python3   >/dev/null 2>&1; then python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1" 2>/dev/null && return 0; fi
  if command -v greadlink >/dev/null 2>&1; then greadlink -f "$1" 2>/dev/null && return 0; fi
  readlink -f "$1" 2>/dev/null && return 0
  return 1
}

if ! command -v jq >/dev/null 2>&1; then
  echo "BLOCKED : jq missing, security hook unreliable." >&2
  exit 2
fi

# B4: opt-in telemetry on every exit path (CLAUDE_HOOK_TELEMETRY=1).
# Globals REL + SCOPE_FILE captured at point of EXIT trap (may be unset for early exits).
REL=""
SCOPE_FILE=""
log_telemetry() {
  local rc=$?
  if [ "${CLAUDE_HOOK_TELEMETRY:-0}" = "1" ] && [ -d "${CLAUDE_PROJECT_DIR:-}" ]; then
    mkdir -p "${CLAUDE_PROJECT_DIR}/.claude" 2>/dev/null || true
    printf '%s|%s|%s|rc=%d\n' "$(date -Iseconds 2>/dev/null || echo unknown)" "${REL:-?}" "${SCOPE_FILE:-?}" "$rc" \
      >> "${CLAUDE_PROJECT_DIR}/.claude/.scope-hook.log" 2>/dev/null || true
  fi
  return $rc
}
trap log_telemetry EXIT

INPUT=$(cat)

TARGET=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || {
  echo "BLOCKED : invalid input JSON." >&2
  exit 2
}

if [ -z "$TARGET" ]; then
  # apply_patch (Codex) carries no .tool_input.file_path — its target paths live in
  # the V4A patch body (.tool_input.command, same field Bash uses). The single-path
  # logic below can't see them, so without this branch an out-of-scope apply_patch
  # write would slip through (empty TARGET -> exit 0). Parse every target path and
  # validate each by re-invoking this hook with a synthesized single-file payload
  # (reuses the full scope logic, no duplication). Fail-closed if a path is present
  # but unparseable. Claude never emits apply_patch, so this is Codex-only-effective.
  TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
  if [ "$TOOL" = "apply_patch" ]; then
    PATCH=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .tool_input.input // .tool_input.patch // empty' 2>/dev/null || echo "")
    PATHS=$(printf '%s\n' "$PATCH" | sed -nE 's/^\*\*\* (Add|Update|Delete) File: (.+)$/\2/p; s/^\*\*\* Move to: (.+)$/\1/p')
    if [ -z "$PATHS" ]; then
      echo "BLOCKED : apply_patch with no parseable path — scope unverifiable, fail-closed." >&2
      exit 2
    fi
    # Guard against recursion (synthesized subcall payloads carry file_path, so they
    # take the single-path branch and never re-enter here — belt-and-suspenders).
    [ "${SCOPE_HOOK_PATCH_SUBCALL:-0}" = "1" ] && exit 0
    SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")
    while IFS= read -r _p; do
      [ -z "$_p" ] && continue
      _sub=$(jq -nc --arg fp "$_p" '{tool_name:"Edit",tool_input:{file_path:$fp}}')
      printf '%s' "$_sub" | SCOPE_HOOK_PATCH_SUBCALL=1 bash "$SELF" || exit 2
    done <<EOF
$PATHS
EOF
    exit 0
  fi
  exit 0
fi

# Normalize TARGET to absolute path under project root
if [[ "$TARGET" != /* ]]; then
  TARGET="${CLAUDE_PROJECT_DIR}/${TARGET}"
fi

# P7 : refuse path traversal BEFORE walk-up
case "$TARGET" in
  *..*)
    echo "BLOCKED : path traversal detected ($TARGET)." >&2
    exit 2
    ;;
esac

# P7 : refuse absolute path outside project
case "$TARGET" in
  "${CLAUDE_PROJECT_DIR}"/*) ;;
  *)
    echo "BLOCKED : absolute path outside project ($TARGET)." >&2
    exit 2
    ;;
esac

# EC-2: a .session-scope.json symlink is never repairable through the escape
# hatch. Resolve/repair only real scope files; otherwise an attacker can edit a
# governing scope through an alias that bypasses the symlinked-scope refusal in
# walk-up resolution.
if [ "${TARGET##*/}" = ".session-scope.json" ] && [ -L "$TARGET" ]; then
  echo "BLOCKED : $TARGET is a symlink scope file (EC-2)." >&2
  exit 2
fi

# B2: resolve symlinks in TARGET to block symlink-to-outside attacks.
# realpath_portable follows the chain across platforms (see helper above). For
# new-file writes, resolve the parent directory so a symlinked .worktrees/ parent
# cannot turn a control-plane repair into an outside-project write.
if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
  RESOLVED=$(realpath_portable "$TARGET" || echo "")
  if [ -n "$RESOLVED" ]; then
    case "$RESOLVED" in
      "${CLAUDE_PROJECT_DIR}"|"${CLAUDE_PROJECT_DIR}"/*) TARGET="$RESOLVED" ;;
      *)
        echo "BLOCKED : symlink resolves outside project ($TARGET -> $RESOLVED)." >&2
        exit 2
        ;;
    esac
  elif [ -L "$TARGET" ]; then
    # fail-closed: an unresolvable symlink could escape the project; refuse.
    echo "BLOCKED : cannot canonicalize symlink ($TARGET) — no path resolver (install coreutils)." >&2
    exit 2
  fi
else
  TARGET_DIR="${TARGET%/*}"
  TARGET_BASENAME="${TARGET##*/}"
  RESOLVED_DIR=$(realpath_portable "$TARGET_DIR" || echo "")
  if [ -n "$RESOLVED_DIR" ]; then
    case "$RESOLVED_DIR" in
      "${CLAUDE_PROJECT_DIR}"|"${CLAUDE_PROJECT_DIR}"/*) TARGET="${RESOLVED_DIR}/${TARGET_BASENAME}" ;;
      *)
        echo "BLOCKED : symlink parent resolves outside project ($TARGET_DIR -> $RESOLVED_DIR)." >&2
        exit 2
        ;;
    esac
  elif [ -L "$TARGET_DIR" ]; then
    # fail-closed: an unresolvable symlinked parent could escape; refuse.
    echo "BLOCKED : cannot canonicalize symlink parent ($TARGET_DIR) — no path resolver (install coreutils)." >&2
    exit 2
  fi
fi

# V4.0 — Detect if TARGET is inside a worktree (.worktrees/<name>/)
# If yes, the search scope is bounded by that worktree root (no fallback to primary).
WORKTREE_ROOT=""
case "$TARGET" in
  "${CLAUDE_PROJECT_DIR}"/.worktrees/*)
    # Extract worktree root path : ${CLAUDE_PROJECT_DIR}/.worktrees/<name>/
    REL_AFTER_WT="${TARGET#${CLAUDE_PROJECT_DIR}/.worktrees/}"
    WT_NAME="${REL_AFTER_WT%%/*}"
    WORKTREE_ROOT="${CLAUDE_PROJECT_DIR}/.worktrees/${WT_NAME}"
    ;;
esac

# LOCK-V4-8 : control-plane escape hatch.
# The scope file is the guardrail's own control plane. If it is absent, stale,
# empty, corrupt, or forgot to include itself, blocking writes to it deadlocks
# the session. Keep the escape hatch narrow:
# - primary worktree root scope can always be created/repaired;
# - nested worktree root scope can always be created/repaired;
# - arbitrary new nested scope files are NOT allowed here, because minting a
#   nearest scope in an out-of-scope directory would bypass the active scope.
if [ "$TARGET" = "${CLAUDE_PROJECT_DIR}/.session-scope.json" ]; then
  SCOPE_FILE="$TARGET"
  REL=".session-scope.json"
  # LOCK-V4.1-9 : multi-LLM takeover guard. A VALID primary scope owned by
  # another LLM session must not be extended/overwritten by this session —
  # that write-race is how parallel agents clobber each other's guardrails.
  # Narrow by design:
  #   - absent file        → allowed (bootstrap, T18)
  #   - corrupt JSON       → allowed (repairable, LOCK-V4-8 precedence)
  #   - llm missing/empty  → allowed (legacy scope files, T19)
  #   - llm == "claude"    → allowed (same runtime; cross-Claude sessions are
  #                          not distinguishable at this layer)
  #   - SCOPE_TAKEOVER=1   → allowed (audit-visible kill-switch, human-approved only)
  if [ -f "$TARGET" ] && [ "${SCOPE_TAKEOVER:-0}" != "1" ] \
    && jq empty "$TARGET" >/dev/null 2>&1; then
    OWNER_LLM=$(jq -r '.llm // empty' "$TARGET" 2>/dev/null || echo "")
    if [ -n "$OWNER_LLM" ] && [ "$OWNER_LLM" != "claude" ]; then
      echo "BLOCKED : primary scope owned by another LLM session (llm=$OWNER_LLM)." >&2
      echo "Multiple LLMs detected → a dedicated worktree is required:" >&2
      echo "  git worktree add ${CLAUDE_PROJECT_DIR}/.worktrees/<name> -b <branch> origin/main" >&2
      echo "  bash <your-worktree-bootstrap> ${CLAUDE_PROJECT_DIR}/.worktrees/<name> --scope-template \"<objective>\"" >&2
      echo "Audited kill-switch: SCOPE_TAKEOVER=1 (only on explicit human request)." >&2
      exit 2
    fi
  fi
  exit 0
fi
if [ -n "$WORKTREE_ROOT" ] && [ "$TARGET" = "$WORKTREE_ROOT/.session-scope.json" ]; then
  if [ -L "${CLAUDE_PROJECT_DIR}/.worktrees" ] || [ -L "$WORKTREE_ROOT" ]; then
    echo "BLOCKED : worktree root symlink ($WORKTREE_ROOT)." >&2
    exit 2
  fi
  # Cross-session guard also fences the worktree's OWN scope file: the
  # control-plane repair hatch must NOT let a foreign session rewrite a VALID owned scope —
  # dropping/replacing sessionId there would defeat the guard for every later edit (the exact
  # reused-worktree bypass this guard closes). Block ONLY when the scope is valid AND owned by a
  # different live session ; absent / corrupt / unstamped / own-session scopes stay repairable
  # (fail-OPEN, never self-lock). Mirrors LOCK-V4.1-9 above, keyed on sessionId instead of llm.
  if [ "${SCOPE_TAKEOVER:-0}" != "1" ] && [ -f "$TARGET" ] && jq empty "$TARGET" >/dev/null 2>&1; then
    _cur_session="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
    _owner_session=$(jq -r '.sessionId // empty' "$TARGET" 2>/dev/null || echo "")
    if [ -n "$_cur_session" ] && [ -n "$_owner_session" ] && [ "$_owner_session" != "$_cur_session" ]; then
      echo "BLOCKED : worktree scope ${WORKTREE_ROOT##*/} owned by another Claude session (sessionId=${_owner_session}, current=${_cur_session}) [cross-session guard]." >&2
      echo "Another session's worktree scope is not repairable here — create your own." >&2
      echo "Audited kill-switch: SCOPE_TAKEOVER=1 (explicit human request only)." >&2
      exit 2
    fi
  fi
  SCOPE_FILE="$TARGET"
  REL=".session-scope.json"
  exit 0
fi

# Walk-up from target's parent directory to find nearest .session-scope.json
# Stop at WORKTREE_ROOT if inside a worktree, else stop at ${CLAUDE_PROJECT_DIR}
find_scope_file() {
  local dir parent
  # Builtin parameter expansion (replaces fork: dirname).
  # Edge case: target at filesystem root (e.g. "/x") yields empty result, normalize to "/".
  dir="${1%/*}"
  [ -z "$dir" ] && dir="/"
  local upper_bound
  if [ -n "$WORKTREE_ROOT" ]; then
    upper_bound="$WORKTREE_ROOT"
  else
    upper_bound="${CLAUDE_PROJECT_DIR}"
  fi

  while [ "$dir" != "/" ]; do
    # EC-2 hardening : refuse symlinked .session-scope.json (attacker-planted symlink to wide-scope target).
    # Split test : if symlink, emit diagnostic + continue walk-up (LOCK-V4-1 leaf→root preserved).
    # No readlink -f canonicalize on candidate — surgical refusal avoids LOCK-V4-1 walk-up semantics drift.
    if [ -L "$dir/.session-scope.json" ]; then
      echo "REJECTED : $dir/.session-scope.json is a symlink (refused EC-2, walk-up continues)." >&2
    elif [ -f "$dir/.session-scope.json" ]; then
      printf '%s\n' "$dir/.session-scope.json"
      return 0
    fi
    if [ "$dir" = "$upper_bound" ]; then
      # Reached upper bound without finding scope file
      return 1
    fi
    # Builtin parameter expansion (replaces fork: dirname).
    parent="${dir%/*}"
    [ -z "$parent" ] && parent="/"
    dir="$parent"
  done
  return 1
}

if ! SCOPE_FILE=$(find_scope_file "$TARGET"); then
  if [ -n "$WORKTREE_ROOT" ]; then
    # LOCK-V4-2 : worktree without scope file → BLOCK with bootstrap message
    # Builtin parameter expansion (replaces fork: basename).
    WT_NAME="${WORKTREE_ROOT##*/}"
    echo "BLOCKED : worktree ${WT_NAME} without .session-scope.json." >&2
    echo "Run:" >&2
    echo "  bash <your-worktree-bootstrap> ${CLAUDE_PROJECT_DIR}/.worktrees/${WT_NAME} --scope-template \"<objective>\"" >&2
    echo "" >&2
    echo "Falling back to the primary scope is forbidden for worktrees (LOCK-V4-2)." >&2
    exit 2
  else
    # Outside .worktrees/ — fallback to primary scope file.
    # EC-2 hardening : symlinked primary scope refused with explicit diagnostic.
    if [ -L "${CLAUDE_PROJECT_DIR}/.session-scope.json" ]; then
      echo "BLOCKED : ${CLAUDE_PROJECT_DIR}/.session-scope.json is a symlink (refused EC-2)." >&2
      exit 2
    elif [ -f "${CLAUDE_PROJECT_DIR}/.session-scope.json" ]; then
      SCOPE_FILE="${CLAUDE_PROJECT_DIR}/.session-scope.json"
    elif [ "${VIBEGUARD_SCOPE_STRICT:-0}" = "1" ]; then
      echo "BLOCKED : .session-scope.json missing (VIBEGUARD_SCOPE_STRICT=1). Create the scope before writing." >&2
      exit 2
    else
      # vibeguard: scope restriction is OPT-IN. No .session-scope.json => feature
      # off => allow writes WITHIN project (out-of-project already blocked above).
      # Create .session-scope.json to enable strict path restriction.
      exit 0
    fi
  fi
fi

# Existing nested scope files also govern their subtree and must remain
# repairable, including when their JSON is corrupt. Creation of new nested
# scope files stays governed by the active parent scope because SCOPE_FILE
# would not equal TARGET.
if [ "$TARGET" = "$SCOPE_FILE" ]; then
  SCOPE_DIR="${SCOPE_FILE%/*}"
  REL="${TARGET#${SCOPE_DIR}/}"
  exit 0
fi

# Scope file corrupted ?
if ! jq empty "$SCOPE_FILE" >/dev/null 2>&1; then
  echo "BLOCKED : $SCOPE_FILE corrupt (invalid JSON)." >&2
  exit 2
fi

# Validate path format. Accepted shapes :
#   /$                                       -> directory (trailing slash)
#   \.[a-zA-Z0-9]+$                          -> file with extension
#   ^\.?[A-Za-z0-9_][A-Za-z0-9._-]*$         -> BD-1: root-level extensionless safe name (Dockerfile, .envrc, Makefile, LICENSE, .dockerignore)
#   /[A-Za-z0-9_][A-Za-z0-9._-]*$            -> BD-1: extensionless safe name at path tail (e.g. subdir/Dockerfile)
# Strict char-class on bare names prevents spaces, control chars, leading `-` (option injection),
# `~`, `$`, `*`, `?`, `[`, `]`. Entries containing `..` are rejected explicitly here at the format
# layer (defense-in-depth — downstream target traversal check still applies, but scope entries
# themselves should never contain `..` regardless of whether they ever match a target).
SCOPE_ENTRIES=$(jq -r '(.scopePaths // [])[], (.forbiddenPaths // [])[] | select(. != "")' "$SCOPE_FILE")
# Only validate entry shapes when there ARE entries. With neither scopePaths nor
# forbiddenPaths, SCOPE_ENTRIES is empty; skip here so the clearer "scopePaths empty"
# diagnostic below handles that misconfig instead of a confusing "invalid paths" list.
if [ -n "$SCOPE_ENTRIES" ]; then
  INVALID=$(printf '%s\n' "$SCOPE_ENTRIES" \
    | grep -vE '/$|\.[a-zA-Z0-9]+$|^\.?[A-Za-z0-9_][A-Za-z0-9._-]*$|/[A-Za-z0-9_][A-Za-z0-9._-]*$' || true)
  # Match `..` only as a complete path SEGMENT (start-of-string or after `/`, then `..`, then
  # end-of-string or before `/`). Avoids false-positives on legitimate names like `version..bak`
  # or `foo..orig` while still catching `..`, `../foo`, `lib/..`, `lib/../etc`.
  TRAVERSAL=$(printf '%s\n' "$SCOPE_ENTRIES" | grep -E '(^|/)\.\.($|/)' || true)
  if [ -n "$INVALID" ] || [ -n "$TRAVERSAL" ]; then
    echo "BLOCKED : invalid paths in $SCOPE_FILE :" >&2
    [ -n "$INVALID" ] && echo "$INVALID" >&2
    [ -n "$TRAVERSAL" ] && echo "$TRAVERSAL  (path traversal in scope entry)" >&2
    echo "Required format: trailing / for directories, .ext for files, or a safe extensionless name (Dockerfile, .envrc, etc.). No .. segment allowed in scope entries." >&2
    exit 2
  fi
fi

# LOCK-V4-4 : REL relative to dirname(SCOPE_FILE), NOT always CLAUDE_PROJECT_DIR
# Builtin parameter expansion (replaces fork: dirname). Scope file always under project root, never at filesystem root.
SCOPE_DIR="${SCOPE_FILE%/*}"
REL="${TARGET#${SCOPE_DIR}/}"

# Tripwire: forbid dev on the primary tree under a foreign scope.
# When governing a PRIMARY-tree edit (TARGET not under .worktrees/) via the PRIMARY root
# scope, AND that root scope is owned by a FOREIGN/stale LLM session (.llm set, != claude),
# forbid dev edits on the shared primary tree : the agent must use its own dedicated
# .worktrees/<name> instead. This is the technical half of the hybrid guard that stops
# multi-agent collision on the shared working tree. Narrow by design,
# mirroring LOCK-V4.1-9 : empty/legacy .llm OR .llm==claude → NOT a tripwire (cross-claude
# sessions are indistinguishable at this layer) ; SCOPE_TAKEOVER=1 → audit-visible human
# kill-switch. Control-plane / governance paths stay editable in primary even under a
# foreign scope — they are intentionally maintained there.
if [ -z "$WORKTREE_ROOT" ] && [ "$SCOPE_FILE" = "${CLAUDE_PROJECT_DIR}/.session-scope.json" ] \
  && [ "${SCOPE_TAKEOVER:-0}" != "1" ]; then
  TRIPWIRE_LLM=$(jq -r '.llm // empty' "$SCOPE_FILE" 2>/dev/null || echo "")
  if [ -n "$TRIPWIRE_LLM" ] && [ "$TRIPWIRE_LLM" != "claude" ]; then
    case "$REL" in
      # Control-plane allow-list : governance docs MUST stay editable in the primary
      # tree even under a foreign scope. `exit 0` (allow) — NOT a bare `;;` : a foreign
      # scope's narrow scopePaths (e.g. ["lib/"]) would otherwise block these downstream
      # at the scopePaths check, and the foreign root scope itself can't be amended
      # (foreign-owner guard), leaving governance fixes deadlocked.
      CLAUDE.md|AGENTS.md|.session-scope.json) exit 0 ;;
      *)
        echo "BLOCKED : dev on the primary tree forbidden under a foreign scope (llm=$TRIPWIRE_LLM)." >&2
        echo "The primary repo is not a dev area while another agent owns the scope." >&2
        echo "Create a dedicated worktree:" >&2
        echo "  git worktree add ${CLAUDE_PROJECT_DIR}/.worktrees/<name> -b <branch> origin/main" >&2
        echo "  SCOPE_LLM=claude bash <your-worktree-bootstrap> ${CLAUDE_PROJECT_DIR}/.worktrees/<name> --scope-template \"<objective>\"" >&2
        echo "Audited kill-switch: SCOPE_TAKEOVER=1 (explicit human request only)." >&2
        exit 2
        ;;
    esac
  fi
fi

# Cross-session worktree ownership guard.
# Inside a worktree, ownership belongs to exactly ONE Claude session : the one that
# bootstrapped it (sessionId stamped at bootstrap from ${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}). A DIFFERENT
# session reusing this worktree is the exact collision CLAUDE.md forbids ("chaque agent =
# son propre worktree") and that the .llm field CANNOT catch — two parallel Claude
# sessions both carry llm=claude (see AC3/LOCK-V4.1-9 : "cross-Claude sessions are not
# distinguishable at this layer"). The session id closes that hole.
# Fail-OPEN by design — never self-lock the legitimate owner :
#   - not inside a worktree          → skip (primary tree handled by AC3 above)
#   - live session id unknown        → skip (hook env lacks CLAUDE_SESSION_ID / CLAUDE_CODE_SESSION_ID)
#   - worktree root scope absent      → skip (LOCK-V4-2 already BLOCKED upstream)
#   - worktree root scope corrupt/symlink → skip (corrupt/EC-2 checks own those paths)
#   - sessionId unstamped (legacy)    → skip (pre-guard worktrees drain naturally)
#   - SCOPE_TAKEOVER=1                → skip (audit-visible human kill-switch)
# Read sessionId from the WORKTREE ROOT scope (where bootstrap stamps it), not the
# walk-up SCOPE_FILE which may be a nested scope without the owner field. Both sides
# resolve the SAME env expression (bootstrap stamps it, hook compares it) so a session
# always matches its own worktree.
if [ -n "$WORKTREE_ROOT" ] && [ "${SCOPE_TAKEOVER:-0}" != "1" ]; then
  CUR_SESSION="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  WT_ROOT_SCOPE="$WORKTREE_ROOT/.session-scope.json"
  if [ -n "$CUR_SESSION" ] && [ -f "$WT_ROOT_SCOPE" ] && [ ! -L "$WT_ROOT_SCOPE" ] \
    && jq empty "$WT_ROOT_SCOPE" >/dev/null 2>&1; then
    OWNER_SESSION=$(jq -r '.sessionId // empty' "$WT_ROOT_SCOPE" 2>/dev/null || echo "")
    if [ -n "$OWNER_SESSION" ] && [ "$OWNER_SESSION" != "$CUR_SESSION" ]; then
      WT_NAME="${WORKTREE_ROOT##*/}"
      echo "BLOCKED : worktree ${WT_NAME} belongs to another Claude session (sessionId=${OWNER_SESSION}, current session=${CUR_SESSION}) [cross-session guard]." >&2
      echo "Each agent gets its own worktree (NEVER share them)." >&2
      echo "Create your own:" >&2
      echo "  git worktree add ${CLAUDE_PROJECT_DIR}/.worktrees/<name> -b <branch> origin/main" >&2
      echo "  SCOPE_LLM=claude bash <your-worktree-bootstrap> ${CLAUDE_PROJECT_DIR}/.worktrees/<name> --scope-template \"<objective>\"" >&2
      echo "Audited kill-switch: SCOPE_TAKEOVER=1 (explicit human request only)." >&2
      exit 2
    fi
  fi
fi

# LOCK-V4-7 : forbiddenPaths evaluated BEFORE scopePaths.
# B3: quoted iteration via read prevents IFS word-split + glob expansion on entries with spaces or wildcards.
while IFS= read -r F; do
  [ -z "$F" ] && continue
  case "$REL" in
    "$F"*)
      echo "BLOCKED : $REL in forbiddenPaths ($F) [scope=$SCOPE_FILE]." >&2
      exit 2
      ;;
  esac
done < <(jq -r '.forbiddenPaths[]? // empty' "$SCOPE_FILE")

# scopePaths empty → BLOCK (V3.2 contract preserved).
# B3: quoted iteration. Read entries first to detect emptiness, then iterate same array.
SCOPED_ENTRIES=()
while IFS= read -r S; do
  [ -z "$S" ] && continue
  SCOPED_ENTRIES+=("$S")
done < <(jq -r '.scopePaths[]? // empty' "$SCOPE_FILE")

if [ ${#SCOPED_ENTRIES[@]} -eq 0 ]; then
  echo "BLOCKED : scopePaths empty in $SCOPE_FILE." >&2
  echo "Define at least one allowed path before writing." >&2
  exit 2
fi

# M9 : boundary-aware allow-list match. A bare unbounded prefix ("$S"*) let an
# extensionless entry like "lib" wrongly authorize "library/x" (over-grant). Bound
# the match by entry shape :
#   - dir entry (trailing "/")        -> prefix match (already bounded by the slash)
#   - file / extensionless-name entry -> EXACT, or directory-boundary ("$S"/*) so
#     an entry used as a dir-without-slash still authorizes its subtree, but never
#     a sibling sharing the prefix ("lib" no longer matches "library/x").
# forbiddenPaths (deny-list) deliberately keeps its broad prefix match above:
# tightening a deny is the unsafe direction (it would un-block paths).
for S in "${SCOPED_ENTRIES[@]}"; do
  case "$S" in
    */)
      case "$REL" in "$S"*) exit 0 ;; esac
      ;;
    *)
      case "$REL" in "$S"|"$S"/*) exit 0 ;; esac
      ;;
  esac
done

echo "BLOCKED : $REL outside scopePaths [scope=$SCOPE_FILE]." >&2
echo "Current scope:" >&2
printf '  %s\n' "${SCOPED_ENTRIES[@]}" >&2
echo "To extend: edit $SCOPE_FILE explicitly, then retry." >&2
exit 2
