#!/bin/bash
# Assembles memterm.app from the release binary: Contents/MacOS/memterm,
# Contents/Resources/memterm.icns, a minimal Info.plist, ad-hoc codesign.
# Run from the repo root (or anywhere — the script cd's to the repo root).
# Prints the .app path as its last line.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

swift build -c release >&2

APP_DIR="$REPO_ROOT/dist/memterm.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$REPO_ROOT/.build/release/memterm" "$APP_DIR/Contents/MacOS/memterm"
cp "$REPO_ROOT/Assets/memterm.icns" "$APP_DIR/Contents/Resources/memterm.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>com.memterm.app</string>
	<key>CFBundleName</key>
	<string>memterm</string>
	<key>CFBundleExecutable</key>
	<string>memterm</string>
	<key>CFBundleIconFile</key>
	<string>memterm</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR" >&2

echo "$APP_DIR"
