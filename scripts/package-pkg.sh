#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/dist"
PKG_WORK="$BUILD_DIR/pkg-work"
APP_ROOT="$PKG_WORK/app-root"
CLI_ROOT="$PKG_WORK/cli-root"
COMPONENTS="$PKG_WORK/components"
APP_BUNDLE="$APP_ROOT/Applications/ZwZ.app"
APP_SCRIPTS="$ROOT/Packaging/AppScripts"
VERSION="1.0"
export COPYFILE_DISABLE=1

APP_PKG="$COMPONENTS/ZwZ-App.pkg"
CLI_PKG="$COMPONENTS/ZwZ-CLI.pkg"
INSTALLER="$BUILD_DIR/ZwZ-Installer.pkg"

cd "$ROOT"
swift build -c release --product ZwzGUI
swift build -c release --product zwz
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$PKG_WORK" "$INSTALLER"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$CLI_ROOT/usr/local/bin" "$COMPONENTS"

cp "$BIN_DIR/ZwzGUI" "$APP_BUNDLE/Contents/MacOS/ZwZ"
cp "$ROOT/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$ROOT/Sources/ZwzGUI/Resources/ZwZLogo.png" "$APP_BUNDLE/Contents/Resources/ZwZLogo.png"
if [[ -d "$BIN_DIR/zwz_ZwzGUI.bundle" ]]; then
  cp -R "$BIN_DIR/zwz_ZwzGUI.bundle" "$APP_BUNDLE/Contents/Resources/zwz_ZwzGUI.bundle"
fi
if [[ -f "$ROOT/Packaging/ZwZ.icns" ]]; then
  cp "$ROOT/Packaging/ZwZ.icns" "$APP_BUNDLE/Contents/Resources/ZwZ.icns"
fi
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_BUNDLE" -type d -exec chmod 755 {} +
find "$APP_BUNDLE" -type f -exec chmod 644 {} +
chmod 755 "$APP_BUNDLE/Contents/MacOS/ZwZ"
"$ROOT/scripts/check-app-bundle.sh" "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true
find "$APP_ROOT" -name '._*' -delete

cp "$BIN_DIR/zwz" "$CLI_ROOT/usr/local/bin/zwz"
chmod 755 "$CLI_ROOT/usr/local/bin/zwz"
codesign --force --sign - "$CLI_ROOT/usr/local/bin/zwz"
xattr -cr "$CLI_ROOT/usr/local/bin/zwz" 2>/dev/null || true
find "$CLI_ROOT" -name '._*' -delete

pkgbuild \
  --root "$APP_ROOT" \
  --scripts "$APP_SCRIPTS" \
  --identifier "com.jiangzhiwan.zwz.app" \
  --version "$VERSION" \
  --install-location "/" \
  "$APP_PKG"

pkgbuild \
  --root "$CLI_ROOT" \
  --identifier "com.jiangzhiwan.zwz.cli" \
  --version "$VERSION" \
  --install-location "/" \
  "$CLI_PKG"

cat > "$PKG_WORK/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>ZwZ</title>
    <options customize="always" require-scripts="false"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <choices-outline>
        <line choice="app"/>
        <line choice="cli"/>
    </choices-outline>
    <choice id="app" title="ZwZ App" description="Install ZwZ.app to /Applications." selected="true" enabled="true" visible="true">
        <pkg-ref id="com.jiangzhiwan.zwz.app"/>
    </choice>
    <choice id="cli" title="Command Line Tool" description="Install the zwz command to /usr/local/bin/zwz." selected="true" enabled="true" visible="true">
        <pkg-ref id="com.jiangzhiwan.zwz.cli"/>
    </choice>
    <pkg-ref id="com.jiangzhiwan.zwz.app" version="$VERSION" auth="Root">ZwZ-App.pkg</pkg-ref>
    <pkg-ref id="com.jiangzhiwan.zwz.cli" version="$VERSION" auth="Root">ZwZ-CLI.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild \
  --distribution "$PKG_WORK/Distribution.xml" \
  --package-path "$COMPONENTS" \
  "$INSTALLER"

rm -rf "$PKG_WORK"

printf 'Created:\n  %s\n' "$INSTALLER"
