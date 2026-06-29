#!/usr/bin/env bash
# scripts/do-release.sh — publie une release GitHub pour une PR DEJA mergee.
#
# Usage:
#   bash scripts/do-release.sh <version> [<commit-sha>]
#     <version>     ex: v0.29.4  (format obligatoire vX.Y.Z)
#     <commit-sha>  optionnel; defaut = HEAD de origin/main apres fetch.
#
# Sur par design : refuse d'ecraser un tag ou une release existante.
# Ne touche jamais a main, ne merge rien. Tag + push tag + gh release create.
set -euo pipefail

die(){ echo "ERREUR: $*" >&2; exit 1; }

# Se placer a la racine du repo (depuis l'emplacement du script).
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)" || die "pas dans un repo git"
cd "$ROOT"

VERSION="${1:-}"
SHA="${2:-}"

[ -n "$VERSION" ] || die "version manquante. Ex: bash scripts/do-release.sh v0.29.4"
echo "$VERSION" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$' || die "version invalide '$VERSION' (attendu vX.Y.Z)"

# Preflight outils + auth AVANT toute etape irreversible (fail-closed).
# Sans ca, un gh manquant/non-authentifie ferait fail-open le check remote ci-dessous
# (set -e est neutralise dans une condition if) -> tag pousse puis release en echec.
command -v gh  >/dev/null 2>&1 || die "gh absent (installer GitHub CLI)"
command -v git >/dev/null 2>&1 || die "git absent"
gh auth status >/dev/null 2>&1 || die "gh non authentifie (gh auth login)"

echo "==> fetch main + tags"
git fetch origin main --tags --quiet || die "git fetch echoue (reseau/auth ?)"

# Anti-ecrasement : tag absent en local.
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1 && die "tag $VERSION existe deja en local"

# Anti-ecrasement : tag absent sur le remote, FAIL-CLOSED.
# git ls-remote --exit-code distingue rc=0 (trouve) / rc=2 (absent) / autre (erreur reseau).
# (gh api dans un if faisait fail-open : toute erreur gh => "absent" => tag a l'aveugle.)
if git ls-remote --exit-code --tags origin "refs/tags/$VERSION" >/dev/null 2>&1; then
  die "tag $VERSION existe deja sur le remote -> STOP (re-derive une version libre)"
else
  LS_RC=$?
  [ "$LS_RC" -eq 2 ] || die "remote tag probe a echoue (rc=$LS_RC) — reseau/remote, STOP (pas de tag a l'aveugle)"
fi

# Anti-ecrasement : release absente (evite tag pousse puis collision release trop tard).
if gh release view "$VERSION" >/dev/null 2>&1; then
  die "release $VERSION existe deja -> STOP"
fi

# SHA cible.
if [ -z "$SHA" ]; then
  SHA="$(git rev-parse origin/main)"
  echo "WARN: pas de sha fourni -> origin/main HEAD = $SHA"
fi
git rev-parse -q --verify "${SHA}^{commit}" >/dev/null 2>&1 || die "sha $SHA introuvable"

echo "==> tag annote $VERSION sur $SHA"
git tag -a "$VERSION" -m "Release $VERSION" "$SHA"

echo "==> push tag"
git push origin "$VERSION"

echo "==> gh release create $VERSION (notes auto-generees)"
gh release create "$VERSION" --verify-tag --title "$VERSION" --generate-notes

echo ""
echo "OK: release $VERSION publiee -> https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$VERSION"
