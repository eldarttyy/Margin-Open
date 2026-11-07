#!/bin/zsh
# Builds build/Margin.app, ad-hoc signed for your own Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal: Apple silicon and Intel in one binary.
FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${FLAGS[@]}"
BIN=$(swift build -c release "${FLAGS[@]}" --show-bin-path)/Margin
APP=build/Margin.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Margin"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Margin</string>
  <key>CFBundleDisplayName</key><string>Margin</string>
  <key>CFBundleIdentifier</key><string>dev.margin.open</string>
  <key>CFBundleExecutable</key><string>Margin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Margin asks Music and Spotify which song is playing, to show it in the menu bar.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The hardened runtime stops other programs from loading code into Margin, which
# would hand them its Accessibility permission. Keep it on every build.
ENTITLEMENTS=build/Margin.entitlements
cat > "$ENTITLEMENTS" <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENTITLEMENTS
SIGN=(--force --sign - --options runtime --entitlements "$ENTITLEMENTS")

codesign "${SIGN[@]}" "$APP"
echo "Built $APP"
