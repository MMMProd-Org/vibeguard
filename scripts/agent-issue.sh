#!/usr/bin/env bash
# vibeguard agent-issue.sh - file a de-duplicated GitHub issue for an out-of-scope
# finding an agent surfaces while working. NOT a hook: a helper you (or an agent)
# invoke explicitly. It fingerprints the finding (a loc-hash over its file/line/type
# frontmatter) and refuses to file a duplicate -- if an open `agent-finding` issue
# already carries that hash it comments on it instead. Caps runaway filing per
# story, and DEGRADES GRACEFULLY when gh is missing/unauthenticated by saving the
# finding under backlog/pending/ rather than failing.
#
# Usage:  agent-issue.sh <title> <labels> <body-file> <story-id>
#         agent-issue.sh --meta <title> <labels> <body-file> <story-id>
# Exit:   0=filed  10=duplicate  20=fallback(saved locally)  30=cap reached  1=usage
#
# owner/repo are resolved by gh from the current repo (the {owner}/{repo} tokens),
# so nothing is hardcoded. The body-file must carry YAML frontmatter with `type:`
# and (normal mode) a `files:` block of `- path:` + `lines:` entries -- the loc-hash
# is computed from those, so the same code location dedups to a single issue.

set -uo pipefail

# Portable 12-char sha256 prefix (GNU sha256sum, else BSD/macOS `shasum -a 256`).
sha256_12() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum
  else shasum -a 256; fi | cut -c1-12
}

META_MODE=0
if [[ "${1:-}" == "--meta" ]]; then
    META_MODE=1
    shift
fi

TITLE="${1:?title required}"
LABELS="${2:?labels required}"
BODY_FILE="${3:?body-file required}"
STORY_ID="${4:?story-id required}"

if [[ ! "$STORY_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: invalid STORY_ID '$STORY_ID' (allowed: a-zA-Z0-9_-)" >&2
    exit 1
fi

MAX_NORMAL=4
LIST_LIMIT=1000
# Anchor state to the repo root so `../scripts/agent-issue.sh` from a subdir uses
# the SAME .agent-backlog (else dedup silently splits per working directory).
ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STATE_DIR="$ROOT/.agent-backlog"
COUNT_FILE="$STATE_DIR/session-${STORY_ID}.count"
META_FILE="$STATE_DIR/session-${STORY_ID}.meta"
LOCK_DIR="$STATE_DIR/lock-${STORY_ID}"
PENDING_DIR="$ROOT/backlog/pending"

mkdir -p "$STATE_DIR" "$PENDING_DIR"

fallback_save() {
    local reason="$1"
    local fb
    fb="$PENDING_DIR/$(date -u +%Y%m%d-%H%M%S)-${STORY_ID}.md"
    {
        echo "# $TITLE"
        echo ""
        echo "Labels: $LABELS"
        echo "Meta mode: $META_MODE"
        echo "Fallback reason: $reason"
        echo ""
        echo "---"
        cat "$BODY_FILE" 2>/dev/null || echo "(body file unreadable)"
    } > "$fb"
    echo "FALLBACK $fb (reason: $reason)" >&2
    exit 20
}

cap_overflow() {
    echo "CAP_OVERFLOW: cap $MAX_NORMAL reached for $STORY_ID. Use --meta to group." >&2
    exit 30
}

# Re-check for the issue by hash via the REST API, tolerating the eventual
# consistency seen right after creation. Delays 0,1,2,4s; early-exit when found.
check_issue_exists_by_hash() {
    local hash="$1"
    local delays=(0 1 2 4)
    local d found
    for d in "${delays[@]}"; do
        [[ $d -gt 0 ]] && sleep "$d"
        found=$(gh api -X GET "repos/{owner}/{repo}/issues" \
            -f labels="agent-finding" \
            -f state="open" \
            -f per_page=100 \
            --paginate \
            --jq ".[] | select(.body != null and (.body | contains(\"loc-hash: $hash\"))) | .number" \
            2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            [[ $d -gt 0 ]] && echo "INFO: found on recheck after ${d}s (eventual consistency)" >&2
            echo "$found"
            return 0
        fi
    done
    return 0
}

LOCK_HELD=0
cleanup_lock() { [[ "$LOCK_HELD" == "1" ]] && rmdir "$LOCK_DIR" 2>/dev/null || true; }
trap cleanup_lock EXIT

# --- 1. Frontmatter validation ---
[[ -f "$BODY_FILE" ]] || fallback_save "body file not found: $BODY_FILE"

yaml_start=$(grep -n '^---$' "$BODY_FILE" | head -1 | cut -d: -f1)
yaml_end=$(grep -n '^---$' "$BODY_FILE" | sed -n '2p' | cut -d: -f1)

if [[ "$yaml_start" != "1" ]]; then
    fallback_save "YAML frontmatter must start at line 1 (top-anchored)"
fi
if [[ -z "$yaml_end" ]]; then
    fallback_save "YAML frontmatter missing its closing --- delimiter"
fi

yaml_block=$(sed -n "${yaml_start},${yaml_end}p" "$BODY_FILE")

if ! echo "$yaml_block" | grep -qE '^type:[[:space:]]'; then
    fallback_save "'type:' field missing from frontmatter"
fi

if [[ $META_MODE -eq 0 ]]; then
    if ! echo "$yaml_block" | grep -qE '^files:[[:space:]]*$'; then
        fallback_save "'files:' must be a key with no inline value (a YAML block of '- path:' entries, not inline JSON)"
    fi
    if ! echo "$yaml_block" | grep -qE '^[[:space:]]+-[[:space:]]+path:'; then
        fallback_save "files: must contain at least one '- path: ...'"
    fi
    if ! echo "$yaml_block" | grep -qE '^[[:space:]]+lines:'; then
        fallback_save "'lines:' field missing under files:"
    fi
fi

# --- 2. Atomic lock ---
attempts=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    attempts=$((attempts + 1))
    if [[ $attempts -gt 30 ]]; then
        fallback_save "could not acquire lock after 30s"
    fi
    sleep 1
done
LOCK_HELD=1

# --- 3. gh availability (graceful degradation) ---
command -v gh >/dev/null 2>&1 || fallback_save "gh not installed"
command -v jq >/dev/null 2>&1 || fallback_save "jq not installed"
gh auth status >/dev/null 2>&1 || fallback_save "gh not authenticated"

# --- 4. loc-hash dedup key ---
if [[ $META_MODE -eq 1 ]]; then
    LOC_HASH=$(printf 'META|%s' "$STORY_ID" | sha256_12)
else
    hash_input=$(echo "$yaml_block" | awk '
        /^[[:space:]]*-[[:space:]]*path:/ { print $0 }
        /^[[:space:]]*lines:/ { print $0 }
        /^type:/ { print $0 }
    ')
    if [[ -z "$hash_input" ]]; then
        fallback_save "hash extraction failed despite validation"
    fi
    LOC_HASH=$(printf '%s' "$hash_input" | sha256_12)
fi

# --- 5. Initial duplicate check via search ---
list_output=$(gh issue list \
    --label "agent-finding" \
    --state open \
    --search "\"loc-hash: $LOC_HASH\" in:body" \
    --limit "$LIST_LIMIT" \
    --json number 2>/dev/null)
list_exit=$?

if [[ $list_exit -ne 0 ]]; then
    fallback_save "gh issue list failed (exit=$list_exit)"
fi

existing=$(echo "$list_output" | jq -r '.[0].number // empty' 2>/dev/null) || \
    fallback_save "gh issue list JSON parse failed"

if [[ -n "$existing" ]]; then
    comment_output=$(gh issue comment "$existing" \
        --body "Re-detected $(date -u +%Y-%m-%dT%H:%M:%SZ) on story $STORY_ID. Loc-hash unchanged." 2>&1)
    comment_exit=$?
    if [[ $comment_exit -ne 0 ]]; then
        echo "WARNING: could not comment on duplicate #$existing (exit=$comment_exit): $comment_output" >&2
    fi
    echo "DUPLICATE comment added on #$existing"
    exit 10
fi

# --- 6. Cap NEW findings only -- a duplicate of an existing issue already exited
#         above, so a re-detection keeps de-duplicating even past the cap. ---
if [[ $META_MODE -eq 1 ]]; then
    if [[ -f "$META_FILE" ]]; then
        echo "CAP_OVERFLOW: meta already created for $STORY_ID (see $META_FILE)" >&2
        exit 30
    fi
    current_count=0
else
    current_count=0
    if [[ -f "$COUNT_FILE" ]]; then
        raw=$(cat "$COUNT_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ "$raw" =~ ^[0-9]+$ ]]; then
            current_count="$raw"
        else
            echo "WARNING: corrupt counter for $STORY_ID, reset to 0" >&2
            current_count=0
        fi
    fi
    if [[ $current_count -ge $MAX_NORMAL ]]; then
        cap_overflow
    fi
fi

# --- 7. Inject hash + create ---
tmp_body=$(mktemp)
cat "$BODY_FILE" > "$tmp_body"
echo "" >> "$tmp_body"
echo "<!-- loc-hash: $LOC_HASH -->" >> "$tmp_body"

final_labels="$LABELS"
[[ $META_MODE -eq 1 ]] && final_labels="${LABELS},meta-overflow"

issue_url=$(gh issue create \
    --title "$TITLE" \
    --label "$final_labels" \
    --body-file "$tmp_body" 2>&1)
gh_exit=$?
rm -f "$tmp_body"

if [[ $gh_exit -ne 0 ]]; then
    recheck=$(check_issue_exists_by_hash "$LOC_HASH")
    if [[ -n "$recheck" ]]; then
        echo "WARNING: gh issue create exit=$gh_exit but issue #$recheck exists (race detected via REST)" >&2
        gh issue comment "$recheck" \
            --body "Note: create returned an error but the issue exists (re-checked by hash via REST). Story: $STORY_ID." \
            >/dev/null 2>&1 || true
        echo "DUPLICATE recheck after error on #$recheck"
        exit 10
    fi
    fallback_save "gh issue create exit=$gh_exit: $issue_url"
fi

# --- 8. Counters ---
if [[ $META_MODE -eq 1 ]]; then
    touch "$META_FILE"
    echo "OK $issue_url (META for $STORY_ID)"
else
    echo $((current_count + 1)) > "$COUNT_FILE"
    echo "OK $issue_url ($((current_count + 1))/$MAX_NORMAL for $STORY_ID)"
fi
exit 0
