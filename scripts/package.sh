#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/LilFinderPet.app"
DMG="$ROOT/dist/LilFinderPet.dmg"
STAGE="/tmp/LilFinderPetDMG"

cd "$ROOT"
swift build -c release --product LilFinderPet

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
/usr/bin/ditto ".build/arm64-apple-macosx/release/LilFinderPet" "$APP/Contents/MacOS/LilFinderPet"
/usr/bin/ditto "Sources/LilFinderPet/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/ditto "Sources/LilFinderPet/Resources/AppIcon.png" "$APP/Contents/Resources/AppIcon.png"
/usr/bin/ditto "Sources/LilFinderPet/Resources/lil-finder-spritesheet.png" "$APP/Contents/Resources/lil-finder-spritesheet.png"
/usr/bin/ditto "Sources/LilFinderPet/Resources/menubar-icon-template.png" "$APP/Contents/Resources/menubar-icon-template.png"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>LilFinderPet</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>com.kevinhowe.lilfinderpet</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Lil Finder Pet</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Lil Finder listens through the microphone only when Video Companion listening is enabled, so it can comment on videos you are watching.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Lil Finder uses on-device speech recognition for optional Video Companion comments and questions.</string>
</dict>
</plist>
PLIST

chmod +x "$APP/Contents/MacOS/LilFinderPet"
xattr -cr "$APP"
rm -rf "$APP/Contents/_CodeSignature"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
/usr/bin/ditto --norsrc "$APP" "$STAGE/LilFinderPet.app"
ln -s /Applications "$STAGE/Applications"
xattr -cr "$STAGE"
codesign --verify --deep --strict --verbose=2 "$STAGE/LilFinderPet.app"
hdiutil create -volname "Lil Finder Pet" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "$DMG"
