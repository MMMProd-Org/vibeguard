#!/usr/bin/env bash
set -uo pipefail
#
# vibeguard hooks/check-merge-ack.sh - merge-ack writer + verifier (helper, not a hook).
#
# OPT-IN companion of pre-tool-use-merge-ack.sh (install.sh --with-merge-ack).
#   check-merge-ack.sh <PR> [verdicts]        -> WRITE a fresh ack for PR's bot threads
#   check-merge-ack.sh --verify <PR> [-R o/r]   -> exit 0 allow, 2 block (other = hook fail-open)
#
# The hash logic lives ONLY here; the hook delegates to --verify. Portable
# (sha256sum|shasum); freshness via ts_epoch (never parse ISO). Seatbelt, not a vault.

ACK_TTL="${VIBEGUARD_MERGE_ACK_TTL:-3600}"
case "$ACK_TTL" in ''|*[!0-9]*) ACK_TTL=3600 ;; esac
BOT_PATTERN="${VIBEGUARD_BOT_PATTERN:-coderabbit|qodo|copilot|sourcery|vercel|cursor|greptile|github-code-quality}"

command -v jq >/dev/null 2>&1 || { echo "merge-ack: jq required." >&2; exit 4; }
if command -v sha256sum >/dev/null 2>&1; then _SHA=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then _SHA=(shasum -a 256)
else echo "merge-ack: need sha256sum or shasum." >&2; exit 4; fi
_sha_stream(){ "${_SHA[@]}" | cut -d' ' -f1; }
_repo_root(){ git rev-parse --show-toplevel 2>/dev/null || true; }
_resolve_repo(){ local r="${1:-}"; [ -n "$r" ] && { printf '%s' "$r"; return 0; }; [ -n "${VIBEGUARD_ACK_THREADS_JSON:-}" ] && return 0; gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || true; }

# _thread_ids <repo> <pr> : sorted bot thread IDs (one/line). Honors the test hook.
_thread_ids(){
  local repo="$1" pr="$2" raw owner name
  if [ -n "${VIBEGUARD_ACK_THREADS_JSON:-}" ]; then
    printf '%s' "$VIBEGUARD_ACK_THREADS_JSON" \
      | jq -r --arg re "$BOT_PATTERN" '.[] | select((.author//"")|test($re;"i")) | (.id|tostring)' 2>/dev/null \
      | LC_ALL=C sort
    return 0
  fi
  command -v gh >/dev/null 2>&1 || return 1
  owner="${repo%%/*}"; name="${repo##*/}"
  raw=$(gh api graphql --paginate -f owner="$owner" -f repo="$name" -F pr="$pr" -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
        reviewThreads(first:100, after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{ comments(first:1){ nodes{ databaseId author{ login } } } } } } } }' 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -rs --arg re "$BOT_PATTERN" '
    .[].data.repository.pullRequest.reviewThreads.nodes[]?
    | select((.comments.nodes[0].author.login // "")|test($re;"i"))
    | (.comments.nodes[0].databaseId|tostring)' 2>/dev/null | LC_ALL=C sort
}

# ---- writer ----
write_ack(){
  local pr="" verdicts="pending-verdicts" repo="" root ids n hash now epoch dir f
  while [ $# -gt 0 ]; do
    case "$1" in
      -R|--repo) repo="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) if [ -z "$pr" ]; then pr="$1"; else verdicts="$1"; fi; shift ;;
    esac
  done
  case "$pr" in ''|*[!0-9]*) echo "Usage: $0 [-R owner/repo] <PR> [verdicts]" >&2; exit 1 ;; esac
  repo=$(_resolve_repo "$repo")
  if ! ids=$(_thread_ids "$repo" "$pr"); then
    echo "merge-ack: could not fetch bot threads for PR #$pr (gh/auth/API?)." >&2
    exit 1
  fi
  if [ -z "$ids" ]; then
    echo "PR #$pr: no bot threads; no ack needed." >&2
    exit 0
  fi
  n=$(printf '%s\n' "$ids" | grep -c .)
  hash=$(printf '%s\n' "$ids" | _sha_stream)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ); epoch=$(date -u +%s)
  root=$(_repo_root); [ -n "$root" ] || root="$(pwd)"
  dir="$root/.agent-backlog/triaged-prs"
  mkdir -p "$dir" 2>/dev/null || { echo "merge-ack: cannot create $dir" >&2; exit 1; }
  f="$dir/$pr.ack"
  if ! {
    echo "---"; echo "pr: $pr"; echo "timestamp: $now"; echo "ts_epoch: $epoch"
    echo "comments_hash: $hash"; echo "threads_triaged: $n"; echo "verdicts: $verdicts"; echo "---"; echo ""
    echo "# merge-ack -- PR #$pr"; echo ""
    echo "$n bot thread(s) triaged at $now. Record a verdict per thread:"
    printf '%s\n' "$ids" | while IFS= read -r id; do
      [ -n "$id" ] && echo "- thread $id -- verdict: ___ (fix | decline | defer | already-resolved)"
    done
  } > "$f.tmp"; then echo "merge-ack: cannot write $f.tmp" >&2; exit 1; fi
  mv -f "$f.tmp" "$f" || { echo "merge-ack: cannot finalize $f" >&2; exit 1; }
  echo "Wrote $f (hash=$hash, threads=$n). Re-run after new bot feedback; expires after ${ACK_TTL}s." >&2
  exit 0
}

# ---- verifier ----
verify_ack(){
  local pr="" repo="" ids cur root f hash_ack epoch_ack now age
  while [ $# -gt 0 ]; do
    case "$1" in
      -R|--repo) repo="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --) shift ;;
      *) [ -z "$pr" ] && pr="$1"; shift ;;
    esac
  done
  case "$pr" in ''|*[!0-9]*) exit 0 ;; esac
  repo=$(_resolve_repo "$repo")
  ids=$(_thread_ids "$repo" "$pr") || exit 0
  [ -n "$ids" ] || exit 0
  root=$(_repo_root); [ -n "$root" ] || exit 0
  f="$root/.agent-backlog/triaged-prs/$pr.ack"
  [ -f "$f" ] || exit 2
  epoch_ack=$(sed -nE 's/^ts_epoch: ([0-9]+)$/\1/p' "$f" | head -1)
  hash_ack=$(sed -nE 's/^comments_hash: ([0-9a-f]{64})$/\1/p' "$f" | head -1)
  [ -n "$epoch_ack" ] && [ -n "$hash_ack" ] || exit 2
  now=$(date -u +%s); age=$((now - epoch_ack))
  [ "$age" -le "$ACK_TTL" ] || exit 2
  cur=$(printf '%s\n' "$ids" | _sha_stream)
  [ "$cur" = "$hash_ack" ] || exit 2
  exit 0
}

# ---- dispatch ----
case "${1:-}" in
  --verify) shift; verify_ack "$@" ;;
  '' ) echo "Usage: $0 [-R owner/repo] <PR> [verdicts] | --verify <PR> [-R owner/repo]" >&2; exit 1 ;;
  * ) write_ack "$@" ;;
esac
