#!/usr/bin/env bash
# Build the working tree and refresh the Windows desktop development shortcut.
# Usage: bash dist/windows/build-desktop.sh [fast|debug|safe|small]
# Set ZIG to select a compiler, e.g. ZIG=/path/to/zig.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_DIR"

if [ "$#" -gt 1 ]; then
    echo 'Usage: bash dist/windows/build-desktop.sh [fast|debug|safe|small]' >&2
    exit 1
fi
OPTIMIZE="${1:-fast}"
case "$OPTIMIZE" in
    fast|debug|safe|small) ;;
    *) echo "Unsupported optimization mode: $OPTIMIZE" >&2; exit 1 ;;
esac

if ! command -v powershell.exe >/dev/null || ! command -v wslpath >/dev/null; then
    echo 'This helper requires WSL with Windows PowerShell interop.' >&2
    exit 1
fi

# Honor an explicit compiler, otherwise prefer the required version in a local
# versioned installation before falling back to PATH.
ZIG_BIN="${ZIG:-zig}"
if [ -z "${ZIG:-}" ]; then
    REQUIRED_ZIG="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon)"
    LOCAL_ZIG="$HOME/.local/zig-versions/zig-$(uname -m)-linux-$REQUIRED_ZIG/zig"
    if [ -x "$LOCAL_ZIG" ]; then ZIG_BIN="$LOCAL_ZIG"; fi
fi

# Ignore unreadable Windows PATH entries during Zig's compiler probes. Keep
# the original PATH for Windows interop after the build finishes.
BUILD_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | awk '!/^\/mnt\/[A-Za-z]\//' | paste -sd: -)"
PATH="$BUILD_PATH" "$ZIG_BIN" build \
    -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize="$OPTIMIZE"

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$SCRIPT_DIR/install-dev.ps1")" \
    -BuildDir "$(wslpath -w "$REPO_DIR/zig-out")"
