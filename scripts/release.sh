#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="Monayzera/confluo-audio"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
TAG="v$VERSION"
OUTPUT="$ROOT/build"
ZIP="Confluo-$VERSION-update.zip"
DMG="Confluo-$VERSION.dmg"
DMGBUILD="${CONFLUO_DMGBUILD:-$(command -v dmgbuild || true)}"
SIGN_UPDATE="$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update"
NOTES="${1:-}"

cd "$ROOT"
if [ -z "$DMGBUILD" ]; then
    echo "dmgbuild not found: pip install dmgbuild, or set CONFLUO_DMGBUILD." >&2
    exit 1
fi
if [ -n "$(git status --porcelain -- Sources Resources Package.swift VERSION scripts)" ]; then
    echo "Commit source changes before releasing." >&2
    exit 1
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG already exists." >&2
    exit 1
fi

"$ROOT/scripts/build-app.sh"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$OUTPUT/Confluo.app/Contents/Info.plist")"
MINIMUM="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$OUTPUT/Confluo.app/Contents/Info.plist")"

rm -f "$OUTPUT/$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT/Confluo.app" "$OUTPUT/$ZIP"
rm -f "$OUTPUT/$DMG"
"$DMGBUILD" -s "$ROOT/scripts/dmg/settings.py" -D app="$OUTPUT/Confluo.app" -D assets="$ROOT/scripts/dmg" -D icon="$ROOT/Resources/AppIcon.icns" "Confluo" "$OUTPUT/$DMG"
SIGN_ARGS=(--account confluo)
if [ -n "${CONFLUO_ED_KEY_FILE:-}" ]; then
    SIGN_ARGS=(--ed-key-file "$CONFLUO_ED_KEY_FILE")
fi
SIGNATURE="$("$SIGN_UPDATE" "${SIGN_ARGS[@]}" "$OUTPUT/$ZIP")"

cat > "$OUTPUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Confluo</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Confluo $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$ZIP" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML

NOTES_ARGS=(--generate-notes)
if [ -n "$NOTES" ]; then
    NOTES_ARGS=(--notes-file "$NOTES")
fi
gh release create "$TAG" "$OUTPUT/$DMG" "$OUTPUT/$ZIP" "$OUTPUT/appcast.xml" --repo "$REPO" --target "$(git rev-parse HEAD)" --title "Confluo $VERSION" "${NOTES_ARGS[@]}"
echo "Released $TAG"
