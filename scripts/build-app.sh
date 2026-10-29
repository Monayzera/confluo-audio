#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${CONFLUO_SIGN_IDENTITY:--}"
VERSION="${CONFLUO_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD="${CONFLUO_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
OUTPUT="$ROOT/build"
APP="$OUTPUT/Confluo.app"
ARCHS=(--arch arm64 --arch x86_64)

cd "$ROOT"
swift build -c release --product Confluo "${ARCHS[@]}"
BIN_DIR="$(swift build -c release --product Confluo "${ARCHS[@]}" --show-bin-path)"
FRAMEWORK="$(find "$BIN_DIR" -maxdepth 2 -name Sparkle.framework -type d | head -1)"
if [ -z "$FRAMEWORK" ]; then
    FRAMEWORK="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Confluo" "$APP/Contents/MacOS/Confluo"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Confluo"
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/pt-BR.lproj" "$APP/Contents/Resources/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
KEYCHAIN_ARGS=()
if [ -n "${CONFLUO_KEYCHAIN:-}" ]; then
    KEYCHAIN_ARGS=(--keychain "$CONFLUO_KEYCHAIN")
fi
sign() {
    codesign --force --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"}" --timestamp=none "$@"
}
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign "$APP"
codesign --verify --strict --deep "$APP"

echo "Built $APP ($VERSION, build $BUILD)"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Confluo.app"
    ditto "$APP" "/Applications/Confluo.app"
    echo "Installed /Applications/Confluo.app"
fi
