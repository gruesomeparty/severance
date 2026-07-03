#!/usr/bin/env bash
# bundle-app.sh — build Severance.app from the SwiftPM executable (PRD §7).
# Produces a menu-bar-only (LSUIElement) app, ad-hoc signed so arm64 runs without
# a developer certificate.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" # apps/menubar
cd "$HERE"

APP="${1:-Severance.app}"
VERSION="${SEVERANCE_APP_VERSION:-0.1.0}"

echo "==> swift build -c release"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Severance"
[ -x "$BIN" ] || {
	echo "no binary at $BIN" >&2
	exit 1
}

echo "==> assembling $APP ($VERSION)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Severance"

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Severance</string>
  <key>CFBundleDisplayName</key><string>Severance</string>
  <key>CFBundleIdentifier</key><string>com.gruesomeparty.severance</string>
  <key>CFBundleExecutable</key><string>Severance</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" || true

echo "built $APP"
