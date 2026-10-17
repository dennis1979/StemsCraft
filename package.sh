#!/bin/zsh
# Package StemsApp as StemsCraft.app + StemsCraft-<version>.dmg (self-use).
# The DMG is built with diskutil (the hdiutil create path was deprecated).
# Version comes from the VERSION file and is written into Info.plist and the DMG name.
# Everything lives under dist/ (git-ignored).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="StemsCraft"
VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must look like 1.2.3, got: $VERSION"; exit 1; }
echo "== $APP_NAME $VERSION =="
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
RW_DMG="$DIST/$APP_NAME-rw.dmg"

echo "== build =="
swift build --package-path app -c release

echo "== bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp app/.build/release/StemsApp "$APP/Contents/MacOS/$APP_NAME"
# Drop debug symbols so build-machine paths are not left in the binary.
strip -S -x "$APP/Contents/MacOS/$APP_NAME"
cp spike2_split_middle.onnx spike2_split_middle.onnx.data "$APP/Contents/Resources/"

# Fonts (Barlow, SIL OFL): registered automatically via ATSApplicationFontsPath in Info.plist.
mkdir -p "$APP/Contents/Resources/Fonts"
cp Assets/Fonts/*.ttf Assets/Fonts/OFL.txt "$APP/Contents/Resources/Fonts/"

# Licence files (MIT text for this project, third-party notices incl. Demucs / ONNX Runtime).
cp LICENSE THIRD_PARTY_NOTICES.md CHANGELOG.md "$APP/Contents/Resources/"

# App icon: rebuild .icns from the iconset when iconutil is available (always on macOS),
# otherwise fall back to the pre-built Assets/AppIcon.icns.
if command -v iconutil >/dev/null 2>&1 && [ -d Assets/AppIcon.iconset ]; then
    iconutil -c icns Assets/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
else
    cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat <<'PLIST' | sed "s/__VERSION__/$VERSION/g" > "$APP/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>StemsCraft</string>
    <key>CFBundleDisplayName</key><string>StemsCraft</string>
    <key>CFBundleIdentifier</key><string>local.musiccraft.stems</string>
    <key>CFBundleVersion</key><string>__VERSION__</string>
    <key>CFBundleShortVersionString</key><string>__VERSION__</string>
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

echo "== privacy scan =="
# Local paths (the home folder of the machine that built the app) must not ship in the app.
# ONNX Runtime's prebuilt binary contains its CI path (/Users/runner/...), which is not personal.
LEAKS=$( { LC_ALL=C grep -rao -e "/Users/[^[:space:]\"']*" -e "$HOME[^[:space:]\"']*" "$APP" || true; } | LC_ALL=C grep -av '/Users/runner/' | head -n 10 || true)
if [[ -n "$LEAKS" ]]; then
    echo "ERROR: local paths found inside the app. Fix them before publishing:"
    echo "$LEAKS" | LC_ALL=C cut -c1-200
    exit 1
fi
echo "clean: no local paths in the app"

echo "== dmg =="
rm -f "$DMG" "$RW_DMG"
# Writable image sized to the app plus 30 MB headroom.
SIZE_MB=$(( $(du -sm "$APP" | awk '{print $1}') + 30 ))
diskutil image create blank -s "${SIZE_MB}MiB" --volumeName "$APP_NAME" "$RW_DMG"
MOUNT=$(hdiutil attach -nobrowse -noautoopen "$RW_DMG" | awk -F'\t' 'END{print $NF}')
echo "mounted at: $MOUNT"
ditto "$APP" "$MOUNT/$APP_NAME.app"
# Shortcut to /Applications so the DMG shows the drag-to-install layout.
ln -s /Applications "$MOUNT/Applications"
ls -la "$MOUNT"
[[ -L "$MOUNT/Applications" ]] || { echo "ERROR: Applications shortcut missing from DMG"; exit 1; }
hdiutil detach "$MOUNT" >/dev/null
# Convert to a compressed read-only image.
diskutil image create from "$RW_DMG" "$DMG"
rm -f "$RW_DMG"
ls -lhd "$APP" "$DMG" | awk '{print $9, $5}'
echo OK
