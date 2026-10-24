#!/bin/bash
# Wraps the swift build product in a minimal real .app bundle (LSUIElement,
# so it's menu-bar only / no Dock icon) and relaunches it via `open`.
# Status item popover positioning depends on the app having a real bundle
# identity; a bare executable can misposition NSPopover relative to the
# status item.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/VolumeControl"
APP="$HOME/Applications/VolumeControl.app"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/VolumeControl"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Volume Control</string>
    <key>CFBundleDisplayName</key>
    <string>Volume Control</string>
    <key>CFBundleIdentifier</key>
    <string>com.volumecontrol.app</string>
    <key>CFBundleExecutable</key>
    <string>VolumeControl</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Volume Control captures per-app audio to route and mix it (e.g. into a call microphone).</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
