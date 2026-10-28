#!/bin/bash
# Builds Driftwall.app (universal: Apple Silicon + Intel) and packages it as dist/Driftwall.dmg.
# Also stops and removes the old LiveWallpaper LaunchAgent if it is still installed.
# Usage: ./scripts/build-dmg.sh   (or double-click "Build Driftwall DMG.command")
set -e
cd "$(dirname "$0")/.."
VERSION="1.0"
SRC="Sources/Driftwall.swift"
DIST="dist"
echo "== Driftwall builder =="

command -v swiftc >/dev/null || { echo "Swift compiler missing. Run:  xcode-select --install   then double-click this again."; read -n1 -p "Press any key to close"; exit 1; }

echo "Stopping the old LiveWallpaper runner..."
OLD_PLIST="$HOME/Library/LaunchAgents/com.local.livewallpaper.plist"
launchctl bootout gui/$(id -u)/com.local.livewallpaper 2>/dev/null || true
launchctl bootout gui/$(id -u) "$OLD_PLIST" 2>/dev/null || true
rm -f "$OLD_PLIST"
pkill -x LiveWallpaper 2>/dev/null || true
pkill -x Driftwall 2>/dev/null || true

BUILD="build"
APP="$BUILD/Driftwall.app"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling (this takes a minute)..."
SDK="$(xcrun --show-sdk-path 2>/dev/null || true)"
SDKARG=(); [ -n "$SDK" ] && SDKARG=(-sdk "$SDK")
if swiftc -O "${SDKARG[@]}" -target arm64-apple-macos12.0  "$SRC" -o "$BUILD/lw-arm64" 2>/dev/null && \
   swiftc -O "${SDKARG[@]}" -target x86_64-apple-macos12.0 "$SRC" -o "$BUILD/lw-x86_64" 2>/dev/null; then
    lipo -create "$BUILD/lw-arm64" "$BUILD/lw-x86_64" -output "$APP/Contents/MacOS/Driftwall"
else
    swiftc -O "$SRC" -o "$APP/Contents/MacOS/Driftwall"
fi
rm -f "$BUILD"/lw-*

ICONKEY=""
# macOS 26+ rounds icons itself (full-bleed art); older macOS needs the pre-rounded one.
ICONSRC="Resources/AppIcon.png"
OSMAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$OSMAJOR" -lt 26 ] && [ -f Resources/AppIcon-rounded.png ]; then ICONSRC="Resources/AppIcon-rounded.png"; fi
if [ -f "$ICONSRC" ]; then
    ICONSET="$BUILD/AppIcon.iconset"; mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$ICONSRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) "$ICONSRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && \
        ICONKEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
    rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Driftwall</string>
  <key>CFBundleDisplayName</key><string>Driftwall</string>
  <key>CFBundleIdentifier</key><string>com.tharindu.driftwall</string>
  <key>CFBundleExecutable</key><string>Driftwall</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  $ICONKEY
</dict></plist>
PL

echo "Signing..."
codesign --force --deep --sign - "$APP"

echo "Making the DMG..."
STAGE="$BUILD/dmg"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$DIST"
rm -f "$DIST/Driftwall.dmg"
hdiutil create -volname "Driftwall" -srcfolder "$STAGE" -ov -format UDZO "$DIST/Driftwall.dmg" >/dev/null
rm -rf "$STAGE"

echo
echo "Done! dist/Driftwall.dmg is ready. Opening it now —"
echo "drag Driftwall into Applications, then open it from Applications."
open "$DIST/Driftwall.dmg"
