#!/bin/bash
# Wraps dist/memterm.app (scripts/make-app.sh) in a compressed DMG at
# dist/memterm-<version>.dmg with the customary /Applications shortcut.
# Prints the DMG path last. Ad-hoc signed app inside; Gatekeeper on other
# Macs needs right-click ▸ Open until a Developer ID + notarization exist.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/memterm.app"
[ -d "$APP" ] || { echo "make-dmg.sh: $APP missing — run scripts/make-app.sh first" >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="dist/memterm-$VERSION.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/memterm.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "memterm $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >&2
rm -rf "$STAGE"
echo "make-dmg.sh: $(du -h "$DMG" | cut -f1) $DMG" >&2
echo "$DMG"
