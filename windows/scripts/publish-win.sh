#!/usr/bin/env bash
# Publishes Bifrost as a self-contained, single-file win-x64 executable.
# Can be run from macOS or Linux (Avalonia + .NET both cross-compile for
# Windows without needing a Windows machine or the Windows workload).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Prefer an explicit dotnet on PATH; fall back to the well-known local
# install location used on this machine.
if command -v dotnet >/dev/null 2>&1; then
    DOTNET_BIN="dotnet"
elif [ -x "$HOME/.dotnet/dotnet" ]; then
    DOTNET_BIN="$HOME/.dotnet/dotnet"
else
    echo "error: dotnet SDK not found on PATH or at ~/.dotnet/dotnet" >&2
    exit 1
fi

export DOTNET_CLI_TELEMETRY_OPTOUT=1

PROJECT="$REPO_ROOT/src/Bifrost"
CONFIGURATION="Release"
RUNTIME="win-x64"

echo "Publishing Bifrost ($RUNTIME, self-contained, single-file)..."
"$DOTNET_BIN" publish "$PROJECT" \
    -c "$CONFIGURATION" \
    -r "$RUNTIME" \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true

OUTPUT_DIR="$PROJECT/bin/$CONFIGURATION/net10.0/$RUNTIME/publish"
EXE_PATH="$OUTPUT_DIR/Bifrost.exe"

echo
if [ -f "$EXE_PATH" ]; then
    SIZE_BYTES=$(stat -f%z "$EXE_PATH" 2>/dev/null || stat -c%s "$EXE_PATH" 2>/dev/null)
    SIZE_HUMAN=$(du -h "$EXE_PATH" | cut -f1)
    echo "Published: $EXE_PATH"
    echo "Size: $SIZE_HUMAN ($SIZE_BYTES bytes)"
    echo "Output folder: $OUTPUT_DIR"
else
    echo "error: expected output not found at $EXE_PATH" >&2
    exit 1
fi
