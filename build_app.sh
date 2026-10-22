#!/bin/bash
# Builds "RhythmCore AutoCue.app" (Apple Silicon + Intel) into ./dist
#
#   ./build_app.sh                         ad-hoc signed, runs on this Mac
#   SIGN_IDENTITY="Developer ID Application: RhythmCore Industries (TEAMID)" ./build_app.sh
#   SIGN_IDENTITY=... NOTARY_PROFILE=rhythmcore ./build_app.sh   also notarizes + staples
#   UNIVERSAL=0 ./build_app.sh             build for this Mac's architecture only (faster)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="RhythmCore AutoCue"
BUNDLE_ID="com.rhythmcore.autocue"
VERSION="${VERSION:-2.0.0}"
BUILD="${BUILD:-1}"
SIGN="${SIGN_IDENTITY:--}"

if [ "${UNIVERSAL:-1}" = "1" ]; then
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release"
else
  swift build -c release
  BIN=".build/release"
fi

APP="dist/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/RhythmCoreAutoCue" "$APP/Contents/MacOS/RhythmCoreAutoCue"
cp "$BIN/autocue-worker" "$APP/Contents/MacOS/autocue-worker"   # crash-isolated decoder helper
cp "$BIN/autocue-cli" "dist/autocue-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>RhythmCoreAutoCue</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

if [ "$SIGN" = "-" ]; then
  codesign --force --sign - "$APP/Contents/MacOS/autocue-worker"
  codesign --force --deep --sign - "$APP"
  codesign --force --sign - "dist/autocue-cli"
else
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP/Contents/MacOS/autocue-worker"
  codesign --force --options runtime --timestamp --sign "$SIGN" "$APP"
  codesign --force --options runtime --timestamp --sign "$SIGN" "dist/autocue-cli"
fi
codesign --verify --deep --strict "$APP"

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$SIGN" != "-" ]; then
  ditto -c -k --keepParent "$APP" "dist/AutoCue-notarize.zip"
  xcrun notarytool submit "dist/AutoCue-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "dist/AutoCue-notarize.zip"
fi

echo "Built: $(pwd)/$APP"
lipo -info "$APP/Contents/MacOS/RhythmCoreAutoCue" || true
