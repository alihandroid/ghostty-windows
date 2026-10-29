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

bash "$SCRIPT_DIR/build.sh" \
    -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -Doptimize="$OPTIMIZE"

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
    -File "$(wslpath -w "$SCRIPT_DIR/install-dev.ps1")" \
    -BuildDir "$(wslpath -w "$REPO_DIR/zig-out")"
