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
# Sign the disk image with the same identity as the app (MEMTERM_SIGN_IDENTITY,
# else the Developer ID / Apple Development in the keychain, else nothing):
# Gatekeeper judges the app on launch, but a signed DMG also passes
# `spctl --type open` and looks right in Finder's Get Info.
IDENTITY="${MEMTERM_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for kind in "Developer ID Application" "Apple Development"; do
        cand="$(printf '%s\n' "$IDS" | grep -oE "\"$kind: [^\"]+\"" | head -1 | tr -d '"' || true)"
        if [ -n "$cand" ]; then IDENTITY="$cand"; break; fi
    done
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG" >&2
    echo "make-dmg.sh: signed DMG with $IDENTITY" >&2
fi
echo "make-dmg.sh: $(du -h "$DMG" | cut -f1) $DMG" >&2
echo "$DMG"
