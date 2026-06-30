#!/usr/bin/env bash
set -euo pipefail

# .claude/hooks/block-force-push.sh
#
# PreToolUse:Bash hook. Reads Claude Code tool-input JSON from stdin, extracts
# the bash command via jq, exits 2 (blocking error) if the command matches any
# destructive pattern (enumerated below) :
#
#   - git push --force / -f / --force-with-lease (any form)
#   - git reset --hard
#   - git push to protected branches main/master :
#       * standalone token (git push origin main, git push -u origin main,
#         git -C <repo> push origin main, git -c <k=v> push origin main)
#       * colon refspec (git push origin HEAD:main, feature:main)
#       * fully qualified refname (refs/heads/main, refs/heads/master)
#   - rm in any recursive-and-force combination (-rf, -fr, mixed -r --force,
#     --recursive -f, etc.)
#
# Implicit `git push` (no branch specified) is NOT covered here ; a sibling bash guard (not shipped in this minimal set).
#
# Exit codes :
#   0  allow
#   2  block (stderr emitted to agent context — agent must STOP)
#
# Negative guardrail catching dangerous variants of common commands.

if ! command -v jq >/dev/null 2>&1; then
  echo "[block-force-push] BLOCKED : jq missing, hook unreliable" >&2
  exit 2
fi

INPUT="$(cat)"

# Fail-closed JSON parse. If jq fails (malformed input), exit 2 with
# explicit diagnostic — never silently pass through with jq's error code.
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)" || {
  echo "[block-force-push] BLOCKED : tool input JSON invalid (jq parse failed)" >&2
  exit 2
}

# No command → allow (defensive — empty input is not a destructive op)
if [ -z "$CMD" ]; then
  exit 0
fi

block() {
  printf '[block-force-push] BLOCKED : %s\n' "$1" >&2
  printf '[block-force-push] Command  : %s\n' "$CMD" >&2
  printf '[block-force-push] Reason   : forbidden: destructive git/rm command\n' >&2
  exit 2
}

# Normalize whitespace (tabs/newlines → space, collapse runs)

# strip_heredocs — extracted verbatim from the upstream lib. Heredoc
# bodies are documentation, not the executed command, so we do not scan them.
# ponytail: a heredoc piped INTO a shell could slip a real command; accepted —
# vibeguard is footgun prevention, not an adversarial sandbox.
strip_heredocs() {
  awk '
    function extract_label(s,   m, lbl) {
      match(s, /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)
      if (RSTART == 0) return ""
      lbl = substr(s, RSTART, RLENGTH)
      gsub(/^<<-?[[:space:]]*['"'"'"]?/, "", lbl)
      gsub(/['"'"'"]?$/, "", lbl)
      return lbl
    }
    {
      if (!in_heredoc) {
        lbl = extract_label($0)
        if (lbl != "") {
          heredoc_label = lbl
          in_heredoc = 1
        }
        print
        next
      }
      if (in_heredoc && $0 == heredoc_label) {
        in_heredoc = 0
        print
        next
      }
    }
  ' <<<"$1"
}
CMD_NORM="$(printf '%s' "$(strip_heredocs "$CMD")" | tr '\n\t' '  ' | tr -s ' ')"

# git prefix : `git` followed by zero or more option tokens (-C <path>,
# -c <k=v>, --git-dir=..., --work-tree=..., etc.) then the subcommand.
# Lets `git -C <repo> push ...` and `git -c k=v push ...` patterns match.
# Tokens between git and subcommand must not contain shell separators
# (; & |) to avoid catastrophic over-matching.

# 1. git push --force / -f / --force-with-lease
if printf '%s' "$CMD_NORM" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+([^[:space:];|&]+[[:space:]]+)*push[[:space:]].*(-f([[:space:]]|$)|--force([[:space:]]|=|$)|--force-with-lease)'; then
  block "git push --force / -f / --force-with-lease forbidden"
fi

# 2. git reset --hard
if printf '%s' "$CMD_NORM" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+([^[:space:];|&]+[[:space:]]+)*reset([[:space:]]|$).*--hard'; then
  block "git reset --hard forbidden"
fi

# 3a. git push <args>... main/master as standalone token. Covers :
#  - `git push origin main`
#  - `git push -u origin main` / `git push --tags origin main`
#  - `git -C <repo> push origin main` (qodo finding L66)
#  - `git -c safe.directory=... push origin main`
# Refspec form `main:other` is allowed (pushes local main → remote other).
if printf '%s' "$CMD_NORM" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+([^[:space:];|&]+[[:space:]]+)*push[[:space:]].*[[:space:]](main|master)([[:space:]]|$)'; then
  block "git push to main/master forbidden"
fi

# 3b. git push origin HEAD:main / feature:main (colon refspec, short form)
if printf '%s' "$CMD_NORM" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+([^[:space:];|&]+[[:space:]]+)*push[[:space:]].*:(main|master)([[:space:]]|:|$)'; then
  block "git push <src>:main / <src>:master forbidden"
fi

# 3c. Fully qualified refname refs/heads/main(|master), both as standalone
# token AND as right-hand side of colon refspec (Copilot L64 + qodo L66
# findings : git push origin refs/heads/main, git push origin HEAD:refs/heads/main).
if printf '%s' "$CMD_NORM" | grep -qE '(^|[^a-zA-Z0-9_-])git[[:space:]]+([^[:space:];|&]+[[:space:]]+)*push[[:space:]].*([[:space:]]|:)refs/heads/(main|master)([[:space:]]|$)'; then
  block "git push refs/heads/main / refs/heads/master forbidden"
fi

# 4. rm in any recursive-AND-force combination. Accepts :
#  - clusters in any order : -rf, -fr, -Rf, -fR, -rRf, -rRF, etc.
#  - mixed short+long : `-r --force`, `--recursive -f`, `-f --recursive`,
#    `--force -r`, `--force -R`, `-R --force` (Copilot L69 finding)
#  - dual long : `--recursive --force`, `--force --recursive`
RM_CLUSTER_RF='-[a-zA-Z]*[rR][a-zA-Z]*f[a-zA-Z]*'
RM_CLUSTER_FR='-[a-zA-Z]*f[a-zA-Z]*[rR][a-zA-Z]*'
RM_RECURSIVE='(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)'
RM_FORCE='(-[a-zA-Z]*f[a-zA-Z]*|--force)'
if printf '%s' "$CMD_NORM" | grep -qE "(^|[^a-zA-Z0-9_-])rm[[:space:]]+(${RM_CLUSTER_RF}([[:space:]]|$)|${RM_CLUSTER_FR}([[:space:]]|$)|${RM_RECURSIVE}[[:space:]]+([^[:space:]]+[[:space:]]+)*${RM_FORCE}|${RM_FORCE}[[:space:]]+([^[:space:]]+[[:space:]]+)*${RM_RECURSIVE})"; then
  block "rm with recursive AND force flag combination forbidden"
fi

exit 0
