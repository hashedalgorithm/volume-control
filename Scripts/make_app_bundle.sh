#!/bin/bash
# Wraps the swift build product in a minimal real .app bundle (LSUIElement,
# so it's menu-bar only / no Dock icon) and relaunches it via `open`.
# Status item popover positioning depends on the app having a real bundle
# identity; a bare executable can misposition NSPopover relative to the
# status item.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
# Overridable so CI can inject the computed release version instead of a fixed
# placeholder; local dev builds keep the previous defaults unchanged.
VERSION="${VC_VERSION:-0.1}"
BUILD_NUMBER="${VC_BUILD:-1}"

swift build -c "$CONFIG"

# Build the virtual mic HAL plugin and embed it as a bundled resource so the app can
# offer a one-click install (MicMixInstaller.swift) instead of requiring a separate
# manual terminal step.
./HALPlugin/build.sh

BIN=".build/$CONFIG/VolumeControl"
APP="$HOME/Applications/VolumeControl.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/VolumeControl"
rm -rf "$APP/Contents/Resources/VolumeControlMicMix.driver"
cp -R "HALPlugin/VolumeControlMicMix.driver" "$APP/Contents/Resources/VolumeControlMicMix.driver"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Volume Control captures per-app audio to route and mix it (e.g. into a call microphone).</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Volume Control reads your microphone to mix it with selected apps' audio into a virtual call microphone.</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
