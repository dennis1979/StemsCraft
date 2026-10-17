#!/bin/zsh
# Package StemsApp as StemsCraft.app + StemsCraft.dmg (self-use).
# Everything lives under stem-osx/dist/ (git-ignored via *.dmg / Stems.app rules below).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="StemsCraft"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

echo "== build =="
swift build --package-path app -c release

echo "== bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/.build/release/StemsApp "$APP/Contents/MacOS/$APP_NAME"
cp spike2_split_middle.onnx spike2_split_middle.onnx.data "$APP/Contents/Resources/"

# Fonts (Barlow, SIL OFL): registered automatically via ATSApplicationFontsPath in Info.plist.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Assets/Fonts/*.ttf Assets/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

# Licence files (MIT text for this project, third-party notices incl. Demucs / ONNX Runtime).
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# App icon: rebuild .icns from the iconset when iconutil is available (always on macOS),
# otherwise fall back to the pre-built Assets/AppIcon.icns.
if command -v iconutil >/dev/null 2>&1 && [ -d Assets/AppIcon.iconset ]; then
    iconutil -c icns Assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
else
    cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>StemsCraft</string>
    <key>CFBundleDisplayName</key><string>StemsCraft</string>
    <key>CFBundleIdentifier</key><string>local.musiccraft.stems</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>StemsCraft</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>ATSApplicationFontsPath</key><string>Fonts</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Audio</string>
            <key>LSItemContentTypes</key><array><string>public.audio</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
        </dict>
    </array>
</dict>
</plist>
PLIST

echo "== sign (ad-hoc, self-use) =="
codesign --force --deep --sign - "$APP"

echo "== verify =="
codesign --verify --deep --strict "$APP"
otool -L "$APP/Contents/MacOS/$APP_NAME" | head -n 8

echo "== dmg =="
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null
ls -lh "$APP" "$DMG" | awk '{print $9, $5}'
echo OK
