#!/usr/bin/env bash
set -euo pipefail
# vibeguard pre-tool-use-danger.sh - PreToolUse:Bash footgun blocker.
# PATTERNS regex below is extracted VERBATIM from the battle-tested upstream
# bash-guard (dangerous-command subset). Advanced Draft-Mode / review-receipt /
# husky parts of the original are intentionally excluded (shipped separately,
# opt-in). Exit 0 = allow, 2 = block.

command -v jq >/dev/null 2>&1 || { echo "BLOCKED : jq absent." >&2; exit 2; }
INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || { echo "BLOCKED : input JSON invalide." >&2; exit 2; }
[ -z "$CMD" ] && exit 0

PATTERNS='git add[[:space:]]+(\.($|[[:space:]/]|&&|;)|\./|-A|--all|--[[:space:]]+\.)|git commit[^|;&]*(--no-verify|[[:space:]]-n([[:space:]]|$))|git push[^|;&]*(--no-verify|--force|--force-with-lease|[[:space:]]-f([[:space:]]|$))|git[[:space:]][^|;&]*-c[[:space:]]+core\.hooksPath=[^|;&]*[[:space:]]push([[:space:]]|$)|HUSKY=0[[:space:]]+git[[:space:]]+push|git clean[[:space:]][^|;&]*(--force|-[A-Za-z]*f[A-Za-z]*)|git reset[[:space:]]+--hard|(^|[^[:alnum:]_-])rm[[:space:]]+([^|;&]*[[:space:]'\''"])?((-[A-Za-z]*[rR][A-Za-z]*f[A-Za-z]*)|(-[A-Za-z]*f[A-Za-z]*[rR][A-Za-z]*)|((--recursive|-[A-Za-z]*[rR][A-Za-z]*)[[:space:]'\''"]([^|;&]*[[:space:]'\''"])?(--force|-[A-Za-z]*f[A-Za-z]*))|((--force|-[A-Za-z]*f[A-Za-z]*)[[:space:]'\''"]([^|;&]*[[:space:]'\''"])?(--recursive|-[A-Za-z]*[rR][A-Za-z]*)))|chmod[[:space:]]+[0-7]?777'


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
SCAN="$(strip_heredocs "$CMD")"
SCAN_NORM="${SCAN//\\/}"
SCAN_NORM="${SCAN_NORM//\"/}"
SCAN_NORM="${SCAN_NORM//\'/}"
if printf '%s\n' "$SCAN" | grep -qE "$PATTERNS" || printf '%s\n' "$SCAN_NORM" | grep -qE "$PATTERNS"; then
  echo "BLOCKED : commande dangereuse :" >&2
  echo "$CMD" >&2
  exit 2
fi
exit 0
