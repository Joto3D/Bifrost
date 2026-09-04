#!/bin/bash
# Builds Bifrost in release mode and assembles it into a proper macOS
# .app bundle under build/Bifrost.app, then ad-hoc codesigns it.
#
# No Xcode is required (or used) — this is plain `swift build` plus
# manual bundle assembly, since this machine only has the Command Line
# Tools.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Bifrost"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building $APP_NAME (release)"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"

echo "==> Cleaning previous bundle"
rm -rf "$APP_BUNDLE"

echo "==> Assembling $APP_NAME.app"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

cp "$BIN_PATH/$APP_NAME" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

# Copy any other resources (icon assets, etc.) besides Info.plist itself.
for item in "$ROOT_DIR"/Resources/*; do
    name="$(basename "$item")"
    if [ "$name" != "Info.plist" ]; then
        cp -R "$item" "$RESOURCES_DIR/$name"
    fi
done

# Generate an .icns from Resources/icon.png if present. Skipped gracefully
# otherwise, since there's no app icon yet.
ICON_PNG="$ROOT_DIR/Resources/icon.png"
if [ -f "$ICON_PNG" ]; then
    echo "==> Generating app icon"
    ICONSET_DIR="$BUILD_DIR/Bifrost.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    sips -z 16 16     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16.png"      >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png"  >/dev/null
    sips -z 32 32     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32.png"     >/dev/null
    sips -z 64 64     "$ICON_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png"  >/dev/null
    sips -z 128 128   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128.png"   >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256.png"   >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512.png"   >/dev/null
    sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null

    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
else
    echo "==> No Resources/icon.png found, skipping app icon generation"
fi

echo "==> Ad-hoc codesigning $APP_NAME.app"
codesign --force -s - "$APP_BUNDLE"

echo "==> Done: $APP_BUNDLE"
