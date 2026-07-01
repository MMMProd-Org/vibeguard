#!/usr/bin/env bash
set -euo pipefail

MAX_AGE_SECONDS=86400
ZERO_SHA="0000000000000000000000000000000000000000"

MODE="check"
REVIEW_NOTE=""
SIMPLIFY_NOTE=""
SIMPLIFY_STATUS=""

usage() {
  cat <<'EOF'
Usage:
  check-agent-review-gate.sh
  check-agent-review-gate.sh --write --review "<review result>" --simplify "<simplify result>"
  check-agent-review-gate.sh --write --review "<review result>" --simplify-na "<reason>"

Blocks push unless current review surface has a fresh local receipt proving:
  - code review / adversarial senior review ran
  - simplify / distill pass ran, or an explicit not-applicable fallback was recorded
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --write)
      MODE="write"
      shift
      ;;
    --review)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REVIEW_NOTE="$2"
      shift 2
      ;;
    --simplify)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SIMPLIFY_STATUS="pass"
      SIMPLIFY_NOTE="$2"
      shift 2
      ;;
    --simplify-na)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SIMPLIFY_STATUS="not-applicable"
      SIMPLIFY_NOTE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "AGENT REVIEW GATE: missing required command: $1" >&2
    exit 2
  }
}

# Portable sha256: GNU coreutils sha256sum, else BSD/macOS `shasum -a 256`.
SHA256=()
pick_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then SHA256=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then SHA256=(shasum -a 256)
  else echo "AGENT REVIEW GATE: need sha256sum or shasum." >&2; exit 2; fi
}

sha256_stream() {
  "${SHA256[@]}" | awk '{print $1}'
}

sanitize_line() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

should_skip_delete_only_push() {
  [ -t 0 ] && return 1

  local any=0
  local non_delete=0
  local local_ref local_sha remote_ref remote_sha

  while read -r local_ref local_sha remote_ref remote_sha; do
    [ -n "${local_ref}${local_sha}${remote_ref}${remote_sha}" ] || continue
    any=1
    case "$local_sha" in
      "$ZERO_SHA") ;;
      *) non_delete=1 ;;
    esac
  done

  [ "$any" = "1" ] && [ "$non_delete" = "0" ]
}

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || {
    echo "AGENT REVIEW GATE: not inside a git worktree." >&2
    exit 2
  }
}

receipt_path() {
  if [ -n "${AGENT_REVIEW_GATE_RECEIPT:-}" ]; then
    if [ "${AGENT_REVIEW_GATE_TEST:-}" != "1" ]; then
      echo "AGENT REVIEW GATE: AGENT_REVIEW_GATE_RECEIPT is test-only." >&2
      exit 2
    fi
    printf '%s\n' "$AGENT_REVIEW_GATE_RECEIPT"
    return 0
  fi

  git rev-parse --git-path agent-review-gate/latest.env
}

resolve_base_ref() {
  local upstream cur
  # Current branch name; empty on detached HEAD / worktree-on-commit checkouts.
  cur=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    # An upstream that is THIS branch's own remote-tracking ref (origin/<branch>)
    # is not a review base. Once the feature branch is pushed, @{upstream} points
    # at it, the merge-base collapses to HEAD, the review surface empties, and any
    # receipt written before the push is permanently invalidated (base mismatch).
    # Skip it and fall through to the integration base (origin/main) so the surface
    # stays anchored to where the branch merges. A genuinely different upstream
    # (e.g. a branch stacked on another feature, or one tracking main) is honoured.
    if [ -z "$cur" ] || [ "$upstream" != "origin/$cur" ]; then
      printf '%s\n' "$upstream"
      return 0
    fi
  fi

  if git rev-parse --verify --quiet origin/main >/dev/null; then
    printf '%s\n' "origin/main"
    return 0
  fi

  if git rev-parse --verify --quiet main >/dev/null; then
    printf '%s\n' "main"
    return 0
  fi

  git rev-list --max-parents=0 HEAD | tail -1
}

compute_context() {
  BASE_REF=$(resolve_base_ref)
  BASE_OID=$(git merge-base HEAD "$BASE_REF" 2>/dev/null || git rev-parse "$BASE_REF^{commit}")
  HEAD_OID=$(git rev-parse HEAD)
  RECEIPT_FILE=$(receipt_path)

  local untracked_count
  untracked_count=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')

  if git diff --quiet "$BASE_OID" -- && [ "$untracked_count" = "0" ]; then
    HAS_REVIEW_SURFACE=0
  else
    HAS_REVIEW_SURFACE=1
  fi

  SURFACE_SHA=$(
    {
      printf 'base:%s\n' "$BASE_OID"
      printf 'tracked-diff-binary:\n'
      git diff --binary --no-ext-diff "$BASE_OID" --
      printf '\nuntracked-files:\n'
      git ls-files --others --exclude-standard -z \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' path; do
            [ -f "$path" ] || continue
            printf 'path:%s\n' "$path"
            "${SHA256[@]}" -- "$path"
          done
    } | sha256_stream
  )

  PATHS_SHA=$(
    {
      git diff --name-status "$BASE_OID" --
      git ls-files --others --exclude-standard \
        | LC_ALL=C sort \
        | sed 's/^/??	/'
    } | LC_ALL=C sort | sha256_stream
  )
}

get_receipt_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$RECEIPT_FILE" | tail -1
}

block_missing_or_stale() {
  local reason="$1"
  cat >&2 <<EOF
AGENT REVIEW GATE: push blocked.
Reason: $reason

Required before push after dev:
  1. Run a code review (adversarial senior review of the current diff).
  2. Run a simplify/distill pass when applicable, or record a not-applicable reason.
  3. Fix blocking findings.
  4. Write the receipt for the current diff:
     check-agent-review-gate.sh --write --review "<review summary>" --simplify "<simplify summary>"

If simplify is not applicable:
     check-agent-review-gate.sh --write --review "<summary>" --simplify-na "<reason>"

Current base: $BASE_REF ($BASE_OID)
Receipt: $RECEIPT_FILE
EOF
  exit 1
}

write_receipt() {
  [ -n "$(sanitize_line "$REVIEW_NOTE")" ] || {
    echo "ERROR: --review is required for receipt write." >&2
    exit 2
  }

  case "$SIMPLIFY_STATUS" in
    pass|not-applicable) ;;
    *)
      echo "ERROR: pass exactly one of --simplify or --simplify-na." >&2
      exit 2
      ;;
  esac

  [ -n "$(sanitize_line "$SIMPLIFY_NOTE")" ] || {
    echo "ERROR: simplify note/reason cannot be empty." >&2
    exit 2
  }

  compute_context

  if [ "$HAS_REVIEW_SURFACE" = "0" ]; then
    echo "AGENT REVIEW GATE: no review surface; no receipt needed."
    exit 0
  fi

  local receipt_dir tmp now_epoch now_iso
  receipt_dir=$(dirname "$RECEIPT_FILE")
  mkdir -p "$receipt_dir"
  tmp="${RECEIPT_FILE}.tmp.$$"
  now_epoch=$(date -u +%s)
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  umask 077
  {
    printf 'review_gate_version=1\n'
    printf 'created_at=%s\n' "$now_iso"
    printf 'created_at_epoch=%s\n' "$now_epoch"
    printf 'base_ref=%s\n' "$BASE_REF"
    printf 'base_oid=%s\n' "$BASE_OID"
    printf 'head_oid=%s\n' "$HEAD_OID"
    printf 'surface_sha=%s\n' "$SURFACE_SHA"
    printf 'paths_sha=%s\n' "$PATHS_SHA"
    printf 'review_status=pass\n'
    printf 'simplify_status=%s\n' "$SIMPLIFY_STATUS"
    printf 'review_note=%s\n' "$(sanitize_line "$REVIEW_NOTE")"
    printf 'simplify_note=%s\n' "$(sanitize_line "$SIMPLIFY_NOTE")"
  } > "$tmp"
  mv "$tmp" "$RECEIPT_FILE"

  echo "AGENT REVIEW GATE: receipt written: $RECEIPT_FILE"
  echo "surface_sha=$SURFACE_SHA"
}

check_receipt() {
  compute_context

  if [ "$HAS_REVIEW_SURFACE" = "0" ]; then
    echo "AGENT REVIEW GATE: no review surface; allow."
    exit 0
  fi

  [ -f "$RECEIPT_FILE" ] || block_missing_or_stale "missing review/simplify receipt"

  local version created_epoch receipt_surface receipt_paths review_status simplify_status age now
  version=$(get_receipt_value "review_gate_version")
  created_epoch=$(get_receipt_value "created_at_epoch")
  receipt_surface=$(get_receipt_value "surface_sha")
  receipt_paths=$(get_receipt_value "paths_sha")
  review_status=$(get_receipt_value "review_status")
  simplify_status=$(get_receipt_value "simplify_status")

  [ "$version" = "1" ] || block_missing_or_stale "unsupported receipt version"
  [ "$review_status" = "pass" ] || block_missing_or_stale "code review status is not pass"
  case "$simplify_status" in
    pass|not-applicable) ;;
    *) block_missing_or_stale "simplify status is missing or invalid" ;;
  esac

  case "$created_epoch" in
    ''|*[!0-9]*) block_missing_or_stale "receipt timestamp is invalid" ;;
  esac

  now=$(date -u +%s)
  age=$((now - created_epoch))
  [ "$age" -le "$MAX_AGE_SECONDS" ] || block_missing_or_stale "receipt older than ${MAX_AGE_SECONDS}s"

  [ "$receipt_surface" = "$SURFACE_SHA" ] || block_missing_or_stale "diff changed after receipt"
  [ "$receipt_paths" = "$PATHS_SHA" ] || block_missing_or_stale "changed path set changed after receipt"

  echo "AGENT REVIEW GATE: receipt valid; allow."
}

require_cmd git
pick_sha256
require_cmd awk
require_cmd sed
require_cmd date

ROOT=$(repo_root)
cd "$ROOT"

if [ "$MODE" = "check" ] && should_skip_delete_only_push; then
  echo "AGENT REVIEW GATE: delete-only push; allow."
  exit 0
fi

case "$MODE" in
  write) write_receipt ;;
  check) check_receipt ;;
  *) usage >&2; exit 2 ;;
esac
