#!/usr/bin/env bash
#
# Cut a Nib release end-to-end: package, tag, push, publish on GitHub.
#
# Usage:
#   scripts/release.sh 0.1.2                        # notes = commits since last tag
#   scripts/release.sh 0.1.2 "- New: dark mode"     # explicit notes
#
# Optional:
#   LOCO_NOTARY_PROFILE=nib   # notarize the DMG (needs Developer ID; see package.sh)

set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [notes]}"
NOTES="${2:-}"
TAG="v$VERSION"
OUT="release"

# Guards: clean tree, tag free, gh reachable.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Working tree not clean — commit or stash first." >&2; exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "✗ Tag $TAG already exists." >&2; exit 1
fi
gh auth status >/dev/null 2>&1 || { echo "✗ gh not authenticated — run: gh auth login" >&2; exit 1; }

# Default notes: the commit subjects since the previous tag.
if [[ -z "$NOTES" ]]; then
  PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  RANGE="${PREV:+$PREV..}HEAD"
  NOTES="$(git log --no-merges --pretty='- %s' "$RANGE")"
fi

echo "▸ Packaging ${TAG}…"
LOCO_VERSION="$VERSION" scripts/package.sh

echo "▸ Verifying…"
codesign --verify --deep --strict "$OUT/Nib.app"
BUILT="$(plutil -extract CFBundleShortVersionString raw "$OUT/Nib.app/Contents/Info.plist")"
[[ "$BUILT" == "$VERSION" ]] || { echo "✗ Built version $BUILT != $VERSION" >&2; exit 1; }

# Non-notarized builds need the Gatekeeper walkthrough in the notes.
if [[ -z "${LOCO_NOTARY_PROFILE:-}" ]]; then
  NOTES="$NOTES

**Install:** download \`Nib.dmg\` and drag Nib into Applications.

This build isn't notarized yet, so first launch shows *\"Apple could not verify 'Nib' is free of malware\"*. To open it anyway:

1. In the dialog, click **Done** (not \"Move to Trash\").
2. Open **System Settings → Privacy & Security**, scroll down to *\"Nib\" was blocked* → **Open Anyway**, then confirm.

Or from a terminal: \`xattr -dr com.apple.quarantine /Applications/Nib.app\`"
else
  NOTES="$NOTES

**Install:** download \`Nib.dmg\` and drag Nib into Applications."
fi

echo "▸ Tagging + pushing ${TAG}…"
git tag -a "$TAG" -m "Nib $VERSION"
git push origin master "$TAG"

echo "▸ Publishing GitHub release…"
gh release create "$TAG" "$OUT/Nib.dmg" "$OUT/Nib.zip" \
  --title "Nib $VERSION" --notes "$NOTES"

echo ""
echo "✓ Released: https://github.com/taranek/nib/releases/tag/$TAG"
