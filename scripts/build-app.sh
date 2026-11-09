#!/bin/zsh
# Builds build/Margin.app. Pass --install to copy it to /Applications, and
# --dev for your own copy, which adds diagnostics and keeps Accessibility across
# rebuilds. Never ship that.
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal: Apple silicon and Intel in one binary.
FLAGS=(--arch arm64 --arch x86_64)
[[ " $* " == *" --dev "* ]] && FLAGS+=(-Xswiftc -DMARGIN_DEV)
swift build -c release "${FLAGS[@]}"
BIN=$(swift build -c release "${FLAGS[@]}" --show-bin-path)/Margin
APP=${MARGIN_APP:-build/Margin.app}  # build-site.sh sets its own path

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Margin"
cp plugins/blender/margin_bridge.py "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Margin</string>
  <key>CFBundleDisplayName</key><string>Margin</string>
  <key>CFBundleIdentifier</key><string>dev.margin.app</string>
  <key>CFBundleExecutable</key><string>Margin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
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
ENTITLEMENTS=$(dirname "$APP")/Margin.entitlements
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

# Ad-hoc signing. Each rebuild changes the signature, so macOS treats it as a
# new app and Accessibility must be re-granted. A Developer ID fixes that.
if [[ " $* " == *" --dev "* ]]; then
  # Keeps Accessibility across your own rebuilds: macOS matches this rule, not
  # the build's hash. Only for your own copy, since anything with this ID would pass.
  codesign "${SIGN[@]}" -i dev.margin.app -r='designated => identifier "dev.margin.app"' "$APP"
else
  codesign "${SIGN[@]}" "$APP"
fi
echo "Built $APP"

if [[ " $* " == *" --install "* ]]; then
  rm -rf /Applications/Margin.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Margin.app"
fi
