#!/usr/bin/env bash
# Builds Hand.app into ./build. Usage: scripts/build-app.sh [--run] [--demo]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Hand"

APP=build/Hand.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hand"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.arjun.hand</string>
    <key>CFBundleName</key><string>Hand</string>
    <key>CFBundleExecutable</key><string>Hand</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Hand listens while you hold the talk key.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Hand turns your voice into commands.</string>
    <key>NSAppleEventsUsageDescription</key><string>Hand controls other apps on your behalf.</string>
</dict>
</plist>
PLIST

# A real identity keeps the code signature stable across rebuilds, so macOS
# remembers Accessibility/Microphone grants. Falls back to ad-hoc signing.
IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID/ {print $2; exit}')"
codesign --force --sign "${IDENTITY:--}" --identifier com.arjun.hand "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x Hand 2>/dev/null || true
    shift
    open "$APP" --args "$@"
fi
