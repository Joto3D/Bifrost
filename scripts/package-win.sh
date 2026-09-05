#!/usr/bin/env bash
# Builds the self-contained win-x64 Bifrost.exe (via publish-win.sh) and
# packages it, together with a plain-English README for non-technical
# friends, into dist/Bifrost-win-x64.zip — the one file to hand someone
# who just wants to double-click and play modded Valheim.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "== Step 1/2: publish =="
"$SCRIPT_DIR/publish-win.sh"

PUBLISH_DIR="$REPO_ROOT/src/Bifrost/bin/Release/net10.0/win-x64/publish"
EXE_PATH="$PUBLISH_DIR/Bifrost.exe"

if [ ! -f "$EXE_PATH" ]; then
    echo "error: expected published exe not found at $EXE_PATH" >&2
    exit 1
fi

echo
echo "== Step 2/2: package =="

DIST_DIR="$REPO_ROOT/dist"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$DIST_DIR"
cp "$EXE_PATH" "$STAGE_DIR/Bifrost.exe"
cp "$SCRIPT_DIR/FRIENDS-README.txt" "$STAGE_DIR/README - READ ME FIRST.txt"

ZIP_PATH="$DIST_DIR/Bifrost-win-x64.zip"
rm -f "$ZIP_PATH"

# -X: skip macOS extended attributes/resource forks (AppleDouble ._* files)
# so the zip is clean for a Windows recipient; -j not used since we want
# both files at the zip root anyway (they already are, from $STAGE_DIR).
(cd "$STAGE_DIR" && zip -X -q "$ZIP_PATH" "Bifrost.exe" "README - READ ME FIRST.txt")

echo
if [ -f "$ZIP_PATH" ]; then
    SIZE_BYTES=$(stat -f%z "$ZIP_PATH" 2>/dev/null || stat -c%s "$ZIP_PATH" 2>/dev/null)
    SIZE_HUMAN=$(du -h "$ZIP_PATH" | cut -f1)
    echo "Packaged: $ZIP_PATH"
    echo "Size: $SIZE_HUMAN ($SIZE_BYTES bytes)"
else
    echo "error: expected zip not found at $ZIP_PATH" >&2
    exit 1
fi
