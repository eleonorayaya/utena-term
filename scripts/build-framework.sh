#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/build-framework.sh <path-to-ghostty-repo>
GHOSTTY_DIR="${1:-}"
if [[ -z "$GHOSTTY_DIR" ]]; then
    echo "usage: $0 <path-to-ghostty-repo>" >&2
    exit 1
fi

GHOSTTY_DIR="$(cd "$GHOSTTY_DIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Building ghostty-vt XCFramework from $GHOSTTY_DIR..."
cd "$GHOSTTY_DIR"
zig build -Demit-lib-vt

SRC="$GHOSTTY_DIR/zig-out/lib/ghostty-vt.xcframework"
DST="$SCRIPT_DIR/Frameworks/ghostty-vt.xcframework"

mkdir -p "$SCRIPT_DIR/Frameworks"
rm -rf "$DST"
cp -r "$SRC" "$DST"
echo "Copied to $DST"
