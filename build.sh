#!/bin/bash
# Builds ClickSwitch.app. Pass --install to also copy it to /Applications and launch it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClickSwitch"
BUNDLE_ID="com.tomwildenhain.clickswitch"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

echo "==> Compiling ($(uname -m), release)"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "==> Launched. Look for the stacked-squares icon in the menu bar."
else
    echo "==> Built $APP"
    echo "    Install with: ./build.sh --install"
fi
