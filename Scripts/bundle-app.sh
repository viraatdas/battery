#!/bin/bash
#
# bundle-app.sh — build BatteryScope and assemble dist/BatteryScope.app.
#
# Idempotent: run it as often as you like. The app bundle is rebuilt from
# scratch each time so a rename or a removed resource can never linger.
#
#   ./Scripts/bundle-app.sh
#   open dist/BatteryScope.app
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SCRATCH=".build-release"
APP="dist/BatteryScope.app"
BINARY_NAME="BatteryScopeApp"
BUNDLE_ID="com.batteryscope.app"
VERSION="0.1.0"

echo "==> Building release binary (scratch: $SCRATCH)"
swift build -c release --scratch-path "$SCRATCH" --product "$BINARY_NAME"

BUILT="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/$BINARY_NAME"
if [[ ! -x "$BUILT" ]]; then
  echo "error: expected binary not found at $BUILT" >&2
  exit 1
fi
echo "    built $BUILT"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The bundle executable is named BatteryScope even though the SwiftPM product is
# BatteryScopeApp: the process name is what shows up in Activity Monitor.
cp "$BUILT" "$APP/Contents/MacOS/BatteryScope"
chmod +x "$APP/Contents/MacOS/BatteryScope"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>BatteryScope</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>BatteryScope</string>
	<key>CFBundleDisplayName</key>
	<string>BatteryScope</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>BatteryScope</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" > /dev/null
echo "    Info.plist valid (LSUIElement=true, menu bar only)"

echo "==> Ad-hoc signing"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
echo "    signed"

echo "==> Done: $APP"
echo "    open $APP    # or double-click it in Finder"
