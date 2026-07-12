#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/dist"
APP="$BUILD_DIR/ZwZ.app"
DMG="$BUILD_DIR/ZwZ.dmg"
STAGE="$BUILD_DIR/dmg-root"
BUNDLE_ID="com.jiangzhiwan.zwz"
export COPYFILE_DISABLE=1

cd "$ROOT"
swift build -c release --product ZwzGUI
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP" "$STAGE" "$DMG"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$STAGE"
cp "$BIN_DIR/ZwzGUI" "$APP/Contents/MacOS/ZwZ"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Sources/ZwzGUI/Resources/ZwZLogo.png" "$APP/Contents/Resources/ZwZLogo.png"
if [[ -d "$BIN_DIR/zwz_ZwzGUI.bundle" ]]; then
  cp -R "$BIN_DIR/zwz_ZwzGUI.bundle" "$APP/Contents/Resources/zwz_ZwzGUI.bundle"
fi
if [[ -f "$ROOT/Packaging/ZwZ.icns" ]]; then
  cp "$ROOT/Packaging/ZwZ.icns" "$APP/Contents/Resources/ZwZ.icns"
fi
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -type d -exec chmod 755 {} +
find "$APP" -type f -exec chmod 644 {} +
chmod 755 "$APP/Contents/MacOS/ZwZ"
"$ROOT/scripts/check-app-bundle.sh" "$APP"
codesign --force --deep --sign - "$APP"
xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete

cp -R "$APP" "$STAGE/ZwZ.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ZwZ" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -f "$APP"

printf 'Created:\n  %s\n  %s\n' "$APP" "$DMG"
