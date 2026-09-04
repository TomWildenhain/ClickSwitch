#!/bin/bash
# Builds ClickSwitch.app.
#
#   ./build.sh             build into ./build
#   ./build.sh --install   also copy to /Applications and launch it
#   ./build.sh --release   build a universal binary and zip it for distribution
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ClickSwitch"
BUNDLE_ID="com.tomwildenhain.clickswitch"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

MODE="${1:-}"
case "$MODE" in
    ""|--install|--release) ;;
    *) echo "unknown option: $MODE (expected --install or --release)" >&2; exit 1 ;;
esac

mkdir -p "$OUT_DIR"

if [[ "$MODE" == "--release" ]]; then
    # A downloaded build has to run on Intel Macs too, not just this machine. `swift build
    # --arch arm64 --arch x86_64` would do this in one step but needs Xcode's XCBuild, which the
    # Command Line Tools do not ship, so each slice is cross-compiled separately and stitched
    # together with lipo.
    MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
    SLICES=()
    for ARCH in arm64 x86_64; do
        echo "==> Compiling ($ARCH, release)"
        SLICE_FLAGS=(
            -c release --scratch-path ".build-$ARCH"
            -Xswiftc -target -Xswiftc "$ARCH-apple-macos$MIN_MACOS"
            -Xcc -target -Xcc "$ARCH-apple-macos$MIN_MACOS"
        )
        swift build "${SLICE_FLAGS[@]}"
        SLICES+=("$(swift build "${SLICE_FLAGS[@]}" --show-bin-path)/$APP_NAME")
    done
    BIN_PATH="$OUT_DIR/$APP_NAME-universal"
    lipo -create -output "$BIN_PATH" "${SLICES[@]}"
else
    echo "==> Compiling ($(uname -m), release)"
    swift build -c release
    BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
codesign --verify --strict "$APP"

case "$MODE" in
--install)
    DEST="/Applications/$APP_NAME.app"
    echo "==> Installing to $DEST"
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 1
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "==> Launched. Look for the stacked-squares icon in the menu bar."
    ;;

--release)
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
    STAGE="$OUT_DIR/release/$APP_NAME"
    ZIP="$OUT_DIR/$APP_NAME-$VERSION.zip"

    echo "==> Packaging $ZIP"
    rm -rf "$OUT_DIR/release" "$ZIP"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    # ditto, not zip: it is the only archiver that keeps the code signature intact.
    ditto -c -k --keepParent "$STAGE" "$ZIP"

    echo "==> Architectures: $(lipo -archs "$APP/Contents/MacOS/$APP_NAME")"
    echo "==> Contents:"
    unzip -l "$ZIP" | awk 'NR>3 && NF>3 {print "      " $4}' | head -8
    echo "==> $ZIP ($(du -h "$ZIP" | cut -f1)) ready to upload"
    ;;

*)
    echo "==> Built $APP"
    echo "    Install with: ./build.sh --install"
    ;;
esac
