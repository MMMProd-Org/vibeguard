#!/usr/bin/env bash
# scripts/do-release.sh — publish a GitHub release for an ALREADY-merged PR.
#
# Usage:
#   bash scripts/do-release.sh <version> [<commit-sha>]
#     <version>     e.g. v0.29.4  (required format vX.Y.Z)
#     <commit-sha>  optional; default = HEAD of origin/main after fetch.
#
# Safe by design: refuses to overwrite an existing tag or release.
# Ne touche jamais a main, ne merge rien. Tag + push tag + gh release create.
set -euo pipefail

die(){ echo "ERROR: $*" >&2; exit 1; }

# Move to the repo root (relative to the script location).
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repo"
cd "$ROOT"

VERSION="${1:-}"
SHA="${2:-}"

[ -n "$VERSION" ] || die "missing version. e.g. bash scripts/do-release.sh v0.29.4"
echo "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "invalid version '$VERSION' (expected vX.Y.Z)"

# Preflight tools + auth BEFORE any irreversible step (fail-closed).
# Without this, a missing/unauthenticated gh would fail-open the remote check below
# (set -e is neutralized inside an if condition) -> tag pushed then release fails.
command -v gh  >/dev/null 2>&1 || die "gh missing (install GitHub CLI)"
command -v git >/dev/null 2>&1 || die "git missing"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (gh auth login)"

echo "==> fetch main + tags"
git fetch origin main --tags --quiet || die "git fetch failed (network/auth?)"

# Anti-overwrite: tag absent locally.
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1 && die "tag $VERSION already exists locally"

# Anti-overwrite: tag absent on the remote, FAIL-CLOSED.
# git ls-remote --exit-code distinguishes rc=0 (found) / rc=2 (absent) / other (network error).
# (gh api inside an if would fail-open: any gh error => "absent" => blind tag.)
if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
  die "tag $VERSION already exists on the remote -> STOP (re-derive a free version)"
else
  LS_RC=$?
  [ "$LS_RC" -eq 2 ] || die "remote tag probe failed (rc=$LS_RC) — network/remote, STOP (no blind tag)"
fi

# Anti-overwrite: release absent (avoids tag pushed then release collision too late).
if gh release view "$VERSION" >/dev/null 2>&1; then
  die "release $VERSION already exists -> STOP"
fi

# Target SHA.
if [ -z "$SHA" ]; then
  SHA="$(git rev-parse origin/main)"
  echo "WARN: no sha provided -> origin/main HEAD = $SHA"
fi
git rev-parse -q --verify "${SHA}^{commit}" >/dev/null 2>&1 || die "sha $SHA not found"

echo "==> annotated tag $VERSION on $SHA"
git tag -a "$VERSION" -m "Release $VERSION" "$SHA"

echo "==> push tag"
git push origin "$VERSION"

echo "==> gh release create $VERSION (auto-generated notes)"
gh release create "$VERSION" --verify-tag --title "$VERSION" --generate-notes

echo ""
echo "OK: release $VERSION published -> https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$VERSION"
