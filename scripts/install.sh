#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Utena"
BUNDLE_ID="com.molesquad.utena-term"
INSTALL_DIR="$HOME/Applications"
GHOSTTY_DIR=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --ghostty-dir=*) GHOSTTY_DIR="${1#*=}"; shift ;;
        --ghostty-dir)   GHOSTTY_DIR="$2"; shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Dependencies ---
require() {
    if ! command -v "$1" &>/dev/null; then
        echo "error: '$1' not found. $2" >&2; exit 1
    fi
}
require swift "Install Xcode or the Swift toolchain."
require zig   "Install via: brew install zig"
require git   "Install Xcode Command Line Tools."

# --- Ghostty source ---
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

if [[ -n "$GHOSTTY_DIR" ]]; then
    GHOSTTY_DIR="$(cd "$GHOSTTY_DIR" && pwd)"
else
    GHOSTTY_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/utena/ghostty"
    if [[ -d "$GHOSTTY_CACHE/.git" ]]; then
        echo "Updating cached ghostty..."
        git -C "$GHOSTTY_CACHE" fetch --depth=1 origin HEAD
        git -C "$GHOSTTY_CACHE" reset --hard FETCH_HEAD
    else
        echo "Cloning ghostty..."
        git clone --depth=1 https://github.com/ghostty-org/ghostty "$GHOSTTY_CACHE"
    fi
    GHOSTTY_DIR="$GHOSTTY_CACHE"
fi

# --- Fix Frameworks (broken symlink on fresh clone) ---
FRAMEWORKS="$REPO_DIR/Frameworks"
if [[ -L "$FRAMEWORKS" ]]; then
    rm "$FRAMEWORKS"
    mkdir "$FRAMEWORKS"
elif [[ ! -d "$FRAMEWORKS" ]]; then
    mkdir "$FRAMEWORKS"
fi

# --- Build xcframework ---
echo "Building ghostty-vt XCFramework..."
"$REPO_DIR/scripts/build-framework.sh" "$GHOSTTY_DIR"

# --- Build app ---
echo "Building utena..."
swift build -c release --package-path "$REPO_DIR"

# --- Assemble .app bundle ---
APP_STAGE="$WORK_DIR/$APP_NAME.app"
mkdir -p "$APP_STAGE/Contents/MacOS"

cp "$REPO_DIR/.build/release/utena-term" "$APP_STAGE/Contents/MacOS/utena"

cat > "$APP_STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>utena</string>
    <key>CFBundleName</key>            <string>$APP_NAME</string>
    <key>CFBundleVersion</key>         <string>1.0</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
</dict>
</plist>
PLIST

# --- Ad-hoc sign ---
echo "Signing (ad-hoc)..."
codesign --deep --force --sign - "$APP_STAGE"

# --- Install ---
mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$APP_NAME.app"
[[ -d "$DEST" ]] && rm -rf "$DEST"
cp -r "$APP_STAGE" "$DEST"

echo "Installed: $DEST"
echo "Run with:  open '$DEST'"
