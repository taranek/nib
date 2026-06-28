#!/usr/bin/env bash
# Package loco into a redistributable .app (+ zip). Unsigned beyond an ad-hoc
# signature (required so it launches on Apple Silicon); no Developer ID /
# notarization yet, and no model bundled — the user supplies a .gguf.
#
# Usage:
#   scripts/package.sh
#
# Optional:
#   LOCO_LLAMA_SERVER=/path/to/llama-server   # where to copy the server from
#   LOCO_VERSION=0.1.0                          # bundle version

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Notavo"
PRODUCT="loco"          # the SPM product/binary name
BUNDLE_ID="com.notavo.app"
VERSION="${LOCO_VERSION:-0.1.0}"
OUT="release"
APP="$OUT/$APP_NAME.app"
CONTENTS="$APP/Contents"

# llama-server source: env override, else loco's support dir (dev copy).
LLAMA_SRC="${LOCO_LLAMA_SERVER:-$HOME/Library/Application Support/loco/bin/llama-server}"

echo "▸ Building web…"
( cd web && npm run build )

echo "▸ Building ${PRODUCT} (release)…"
swift build -c release

echo "▸ Assembling ${APP}…"
rm -rf "$OUT"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/web" "$CONTENTS/Resources/bin"

cp .build/release/"$PRODUCT" "$CONTENTS/MacOS/$APP_NAME"
cp -R web/dist/. "$CONTENTS/Resources/web/"

# llama-server + its sibling dylibs (llama.cpp ships libllama/libggml*.dylib).
if [[ ! -x "$LLAMA_SRC" ]]; then
  echo "✗ llama-server not found at: $LLAMA_SRC" >&2
  echo "  Set LOCO_LLAMA_SERVER=/path/to/llama-server and re-run." >&2
  exit 1
fi
cp "$LLAMA_SRC" "$CONTENTS/Resources/bin/llama-server"
chmod +w "$CONTENTS/Resources/bin/llama-server"

# Bundle non-system dynamic deps (e.g. Homebrew openssl) next to the binary and
# rewrite their load paths to @loader_path, recursing into the copied dylibs so
# inter-deps (libssl → libcrypto) resolve too.
bundle_deps() {
  local target="$1" dir base deps dep
  dir="$(dirname "$1")"
  deps="$(otool -L "$target" | awk 'NR>1{print $1}' | grep -E '^(/opt/|/usr/local/)' || true)"
  [[ -z "$deps" ]] && return
  while read -r dep; do
    [[ -z "$dep" ]] && continue
    base="$(basename "$dep")"
    if [[ ! -f "$dir/$base" ]]; then
      cp "$dep" "$dir/$base"; chmod +w "$dir/$base"
      install_name_tool -id "@loader_path/$base" "$dir/$base"
      bundle_deps "$dir/$base"
    fi
    install_name_tool -change "$dep" "@loader_path/$base" "$target"
  done <<< "$deps"
}
bundle_deps "$CONTENTS/Resources/bin/llama-server"
chmod +x "$CONTENTS/Resources/bin/llama-server"

# App icon (optional — drop assets/AppIcon.icns to include it).
ICON_LINE=""
if [[ -f assets/AppIcon.icns ]]; then
  cp assets/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
  ICON_LINE="  <key>CFBundleIconFile</key><string>AppIcon</string>"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
$ICON_LINE
</dict>
</plist>
PLIST

echo "▸ Ad-hoc signing (so it runs on Apple Silicon)…"
for f in "$CONTENTS"/Resources/bin/*.dylib "$CONTENTS/Resources/bin/llama-server"; do
  [[ -e "$f" ]] && codesign --force -s - "$f"
done
codesign --force -s - "$CONTENTS/MacOS/$APP_NAME"
codesign --force -s - "$APP"

echo "▸ Zipping…"
( cd "$OUT" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip" )

echo "▸ Building DMG…"
STAGE="$OUT/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO \
  "$OUT/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"

cat <<DONE

✓ Built $APP
  $OUT/$APP_NAME.dmg   (drag-to-install)
  $OUT/$APP_NAME.zip

Share the DMG. On the recipient's Mac (unsigned, so Gatekeeper will warn):
  1. Open the DMG, drag $APP_NAME into Applications.
  2. First launch: right-click → Open (or: xattr -dr com.apple.quarantine /Applications/$APP_NAME.app).
  3. Grant Accessibility when prompted (Settings → Open).
  4. Download a .gguf model and pick it in $APP_NAME's Settings → Change.
DONE
