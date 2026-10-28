#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
IDENTITY="${CONFLUO_SIGN_IDENTITY:--}"
OUTPUT="$ROOT/build"
APP="$OUTPUT/Confluo.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product Confluo
BINARY="$(swift build -c "$CONFIGURATION" --product Confluo --show-bin-path)/Confluo"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Confluo"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/Resources/en.lproj" "$ROOT/Resources/pt-BR.lproj" "$APP/Contents/Resources/"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "/Applications/Confluo.app"
    cp -R "$APP" "/Applications/Confluo.app"
    echo "Installed /Applications/Confluo.app"
else
    echo "Built $APP"
fi
