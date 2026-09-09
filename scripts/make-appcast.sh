#!/bin/bash
# Writes dist/appcast.xml for ONE release DMG — the Sparkle feed the app's
# SUFeedURL resolves (…/releases/latest/download/appcast.xml, so each release
# ships the appcast describing itself).
#   make-appcast.sh <dmg> <download-url> <sign_update-output>
# where <sign_update-output> is the `sparkle:edSignature="…" length="…"`
# line Sparkle's bin/sign_update prints for that DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
DMG="$1"; URL="$2"; SIG="$3"
APP="dist/memterm.app"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
MINOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
DATE="$(date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>memterm</title>
    <link>https://github.com/ril3y/memterm/releases</link>
    <item>
      <title>memterm $SHORT</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINOS</sparkle:minimumSystemVersion>
      <link>https://github.com/ril3y/memterm/releases/tag/v$SHORT</link>
      <enclosure url="$URL" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
XML
echo "make-appcast.sh: dist/appcast.xml version=$SHORT build=$BUILD" >&2
echo dist/appcast.xml
