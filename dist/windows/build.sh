#!/usr/bin/env bash
# Run cache maintenance and a build while holding the project's cache guard.
# Usage: bash dist/windows/build.sh [zig build arguments...]
# Set ZIG to select a compiler, e.g. ZIG=/path/to/zig.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_DIR"

BUILD_ARGS=("$@")
CACHE_DIR="${ZIG_LOCAL_CACHE_DIR-$REPO_DIR/.zig-cache}"
CACHE_EXPLICIT=false
if [ "${ZIG_LOCAL_CACHE_DIR+x}" = x ]; then CACHE_EXPLICIT=true; fi
BUILD_FILE=""
BUILD_FILE_SET=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --) break ;;
        --cache-dir)
            shift
            if [ "$#" -eq 0 ]; then
                echo 'Expected a path after --cache-dir.' >&2
                exit 2
            fi
            CACHE_DIR="$1"
            CACHE_EXPLICIT=true
            ;;
        --cache-dir=*) CACHE_DIR="${1#--cache-dir=}"; CACHE_EXPLICIT=true ;;
        --build-file)
            shift
            if [ "$#" -eq 0 ]; then
                echo 'Expected a path after --build-file.' >&2
                exit 2
            fi
            BUILD_FILE="$1"
            BUILD_FILE_SET=true
            ;;
        --build-file=*) BUILD_FILE="${1#--build-file=}"; BUILD_FILE_SET=true ;;
    esac
    shift
done
if [ "$CACHE_EXPLICIT" = false ] && [ "$BUILD_FILE_SET" = true ]; then
    CACHE_DIR="$(dirname -- "$BUILD_FILE")/.zig-cache"
fi
CACHE_DIR="$(realpath -m -- "${CACHE_DIR:-.}")"

# Prefer the required version without changing the caller's toolchain or PATH.
ZIG_BIN="${ZIG:-zig}"
if [ -z "${ZIG:-}" ]; then
    REQUIRED_ZIG="$(sed -n 's/.*minimum_zig_version = "\([^"]*\)".*/\1/p' build.zig.zon)"
    LOCAL_ZIG="$HOME/.local/zig-versions/zig-$(uname -m)-linux-$REQUIRED_ZIG/zig"
    if [ -x "$LOCAL_ZIG" ]; then ZIG_BIN="$LOCAL_ZIG"; fi
fi

# Ignore unreadable Windows PATH entries during Zig's compiler probes. The
# calling desktop/package helper retains its original PATH for Windows interop.
BUILD_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | awk '!/^\/mnt\/[A-Za-z]\//' | paste -sd: -)"
if ! ZIG_BIN="$(PATH="$BUILD_PATH" command -v "$ZIG_BIN")"; then
    echo 'Zig compiler not found. Set ZIG=/path/to/zig.' >&2
    exit 127
fi
case "$ZIG_BIN" in
    /*) ;;
    *) ZIG_BIN="$REPO_DIR/$ZIG_BIN" ;;
esac

# Compile the launcher outside the cache it will inspect and prune. Its guard
# remains held until the actual Zig build exits, including failed builds.
exec env PATH="$BUILD_PATH" "$ZIG_BIN" run "$REPO_DIR/src/build/cache_prune.zig" -O safe \
    --cache-dir "$REPO_DIR/.zig-cache-maintenance" -- \
    "$CACHE_DIR" "$ZIG_BIN" build "${BUILD_ARGS[@]}"
