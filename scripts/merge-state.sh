#!/usr/bin/env bash
set -uo pipefail
#
# vibeguard scripts/merge-state.sh - read-only PR merge-state dump (helper, not a hook).
#
# Prints a stable JSON snapshot of a PR's merge readiness on stdout:
#   { pr, title, head, base, mergeable, merge_state, review_decision,
#     ci:{pass,fail,pending}, unresolved_bot_threads,
#     blockers:[...], next_action, reason }
# blockers = every active gate in priority order; next_action = blockers[0] or "ready".
# It NEVER blocks, mutates, or merges anything -- it only reads via `gh`.
#
#   merge-state.sh <PR> [-R owner/repo]
#
# owner/repo comes from `gh` (or -R); no hardcoded default. Errors (missing gh/jq,
# unresolvable repo, `gh pr view` failure, bad PR arg) print to stderr + exit != 0.
# A review-thread fetch failure is fail-soft: unresolved_bot_threads=null, dump still emitted.
#
#   bot regex: VIBEGUARD_BOT_PATTERN (default below)
#
# Optional decision policy: $VIBEGUARD_MERGE_POLICY (a JSON file path) or, if unset,
# <repo-root>/.vibeguard/merge-policy.json. Keys (all optional):
#   bot_pattern      -> override the bot regex (an explicit VIBEGUARD_BOT_PATTERN still wins)
#   disabled_gates   -> [action,...] gates to drop (CAUTION: disabling a real gate can make a
#                       genuinely-blocked PR report next_action:"ready"; opt-in, use with care)
#   action_labels    -> {action: label} rename action tokens in the output
# A malformed policy is ignored (defaults, stderr note); it never bricks.

BOT_PATTERN_DEFAULT="coderabbit|qodo|copilot|sourcery|vercel|cursor|greptile|github-code-quality"
BOT_PATTERN="${VIBEGUARD_BOT_PATTERN:-}"   # empty unless env-set; policy or default fills it after policy load

usage(){ echo "usage: $0 <PR> [-R owner/repo]" >&"${1:-2}"; }  # arg 1 = target fd (1=stdout for --help)

# ---- args: a positional numeric PR + optional -R/--repo owner/repo ----
PR=""; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo)
      REPO="${2:-}"
      case "$REPO" in ''|-*) echo "merge-state: $1 requires an owner/repo value." >&2; exit 1 ;; esac
      shift 2 ;;
    -R*)       REPO="${1#-R}"; REPO="${REPO#=}"                # glued -Rowner/repo or -R=owner/repo
               [ -n "$REPO" ] || { echo "merge-state: -R requires an owner/repo value." >&2; exit 1; }
               shift ;;
    --repo=*)  REPO="${1#--repo=}"
               [ -n "$REPO" ] || { echo "merge-state: --repo requires an owner/repo value." >&2; exit 1; }
               shift ;;
    -h|--help) usage 1; exit 0 ;;                          # help -> stdout, exit 0 (not an error)
    -*)        echo "merge-state: unknown option '$1'." >&2; usage; exit 1 ;;
    *) if [ -n "$PR" ]; then echo "merge-state: unexpected extra argument '$1' (one PR only)." >&2; usage; exit 1; fi
       PR="$1"; shift ;;
  esac
done
# A non-empty repo must be exactly owner/repo: one slash, both parts non-empty
# (else -R swallowed the PR, or 'owner/repo/extra' would silently parse to owner+extra).
if [ -n "$REPO" ]; then
  case "$REPO" in
    */*/*|/*|*/) echo "merge-state: invalid repo '$REPO' (expected owner/repo)." >&2; exit 1 ;;
    */*)         : ;;
    *)           echo "merge-state: invalid repo '$REPO' (expected owner/repo)." >&2; exit 1 ;;
  esac
fi
case "$PR" in ''|*[!0-9]*) usage; exit 1 ;; esac

command -v jq >/dev/null 2>&1 || { echo "merge-state: jq required." >&2; exit 4; }
command -v gh >/dev/null 2>&1 || { echo "merge-state: gh required." >&2; exit 4; }

# ---- optional decision policy (needs jq) ----
POLICY='{}'
_pf="${VIBEGUARD_MERGE_POLICY:-}"
if [ -z "$_pf" ] && command -v git >/dev/null 2>&1; then
  _root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$_root" ] && [ -f "$_root/.vibeguard/merge-policy.json" ] && _pf="$_root/.vibeguard/merge-policy.json"
fi
if [ -n "$_pf" ] && [ -f "$_pf" ]; then
  if _p=$(jq -cs 'if length==1 then .[0] else error end' -- "$_pf" 2>/dev/null); then POLICY="$_p"
  else echo "merge-state: ignoring invalid policy '$_pf' (bad JSON); using defaults." >&2; fi
fi
# Coerce the policy SHAPE (not just its JSON syntax): a valid-but-wrong-typed policy
# must neither brick the tool nor silently mis-disable a gate. Non-object -> {};
# each key coerced to its expected type; drop any action_labels entry that would
# collapse a real gate onto the reserved "ready" sentinel.
POLICY=$(printf '%s' "$POLICY" | jq -c '
  (if type=="object" then . else {} end)
  | { bot_pattern:    (.bot_pattern    | if type=="string" then . else null end),
      disabled_gates: (.disabled_gates | if type=="array"  then map(select(type=="string")) else [] end),
      action_labels:  ((.action_labels | if type=="object" then . else {} end)
                       | with_entries(select((.value|type=="string") and .value != "ready" and .key != "ready"))) }' 2>/dev/null) || POLICY='{}'
[ -n "$POLICY" ] || POLICY='{}'
[ -n "$BOT_PATTERN" ] || BOT_PATTERN=$(printf '%s' "$POLICY" | jq -r '.bot_pattern // empty' 2>/dev/null)
[ -n "$BOT_PATTERN" ] || BOT_PATTERN="$BOT_PATTERN_DEFAULT"

[ -n "$REPO" ] || REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null || true)
[ -n "$REPO" ] || { echo "merge-state: cannot resolve owner/repo (pass -R owner/repo)." >&2; exit 3; }
OWNER=${REPO%%/*}; NAME=${REPO##*/}

PV=$(gh pr view "$PR" -R "$REPO" \
  --json number,title,headRefName,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup \
  2>/dev/null) || { echo "merge-state: 'gh pr view' failed for #$PR in $REPO." >&2; exit 2; }
[ -n "$PV" ] || { echo "merge-state: empty pr view for #$PR." >&2; exit 2; }

# Count UNRESOLVED review threads opened by a review bot. --paginate follows
# $endCursor (GraphQL caps pages at 100) so >100 threads are not truncated.
count_bot_threads(){
  local owner="$1" name="$2" pr="$3" raw
  raw=$(gh api graphql --paginate -f owner="$owner" -f repo="$name" -F pr="$pr" -f query='
    query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
      repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
        reviewThreads(first:100, after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{ isResolved comments(first:1){ nodes{ author{ login } } } } } } } }' 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -rs --arg re "$BOT_PATTERN" '
    [ .[].data.repository.pullRequest.reviewThreads.nodes[]?
      | select(.isResolved==false)
      | select((.comments.nodes[0].author.login // "")|test($re;"i")) ] | length' 2>/dev/null || return 1
}
if THREADS=$(count_bot_threads "$OWNER" "$NAME" "$PR"); then :; else THREADS=null; fi
case "$THREADS" in ''|*[!0-9]*) THREADS=null ;; esac

printf '%s' "$PV" | jq --argjson t "$THREADS" --argjson pol "$POLICY" '
  def bucket:
    (.conclusion // "") as $c | (.state // "") as $s |
    if   ($c=="SUCCESS" or $c=="NEUTRAL" or $c=="SKIPPED" or $s=="SUCCESS") then "pass"
    elif ($c=="FAILURE" or $c=="TIMED_OUT" or $c=="CANCELLED" or $c=="ACTION_REQUIRED"
          or $c=="STARTUP_FAILURE" or $c=="STALE" or $s=="FAILURE" or $s=="ERROR") then "fail"
    else "pending" end;
  { pr: .number, title: .title, head: .headRefName, base: .baseRefName,
    mergeable: .mergeable, merge_state: .mergeStateStatus,
    review_decision: (.reviewDecision // ""),
    ci: (reduce (.statusCheckRollup[]?) as $x ({pass:0,fail:0,pending:0}; .[($x|bucket)] += 1)),
    unresolved_bot_threads: $t } as $b
  | [ (if ($b.merge_state=="DIRTY" or $b.mergeable=="CONFLICTING") then "resolve_conflicts" else empty end),
      (if $b.merge_state=="DRAFT"  then "mark_ready"    else empty end),
      (if $b.merge_state=="BEHIND" then "update_branch" else empty end),
      (if ($b.mergeable=="UNKNOWN" or $b.merge_state=="UNKNOWN") then "wait_mergeability" else empty end),
      (if $b.ci.fail>0    then "fix_ci"  else empty end),
      (if $b.ci.pending>0 then "wait_ci" else empty end),
      (if $b.unresolved_bot_threads==null then "verify_threads"
       elif $b.unresolved_bot_threads>0   then "resolve_threads" else empty end),
      (if $b.review_decision=="CHANGES_REQUESTED" then "address_changes" else empty end),
      (if $b.review_decision=="REVIEW_REQUIRED"   then "request_review"  else empty end),
      (if $b.merge_state=="BLOCKED" then "resolve_block" else empty end)
    ] as $bl0
  | ($bl0 | map(. as $g | select( (($pol.disabled_gates) // []) | index($g) == null ))) as $bl
  | ($bl[0] // "ready") as $na
  | (($pol.action_labels) // {}) as $lab
  | $b + { blockers: ($bl | map($lab[.] // .)), next_action: ($lab[$na] // $na),
           reason:
             (if   $na=="fix_ci"            then "\($b.ci.fail) failing check(s)"
              elif $na=="wait_ci"           then "\($b.ci.pending) pending check(s)"
              elif $na=="resolve_threads"   then "\($b.unresolved_bot_threads) unresolved bot thread(s)"
              elif $na=="verify_threads"    then "bot-thread state unknown (fetch failed)"
              elif $na=="resolve_conflicts" then "merge conflict / dirty"
              elif $na=="mark_ready"        then "PR is a draft"
              elif $na=="update_branch"     then "branch is behind base"
              elif $na=="wait_mergeability" then "mergeability not yet known"
              elif $na=="address_changes"   then "changes requested"
              elif $na=="request_review"    then "review required"
              elif $na=="resolve_block"     then "blocked by branch protection (no visible cause)"
              else "clean, mergeable" end) }'
