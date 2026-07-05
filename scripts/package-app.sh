#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$REPO_ROOT"

echo "Building release..."
swift build -c release

APP_DIR="$REPO_ROOT/AgentPet.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "Copying binary..."
cp ".build/release/apet" "$APP_DIR/Contents/MacOS/apet"
chmod +x "$APP_DIR/Contents/MacOS/apet"

echo "Writing Info.plist..."
cat > "$APP_DIR/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AgentPet</string>
    <key>CFBundleIdentifier</key>
    <string>com.clsaa.apet</string>
    <key>CFBundleExecutable</key>
    <string>apet</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSUserNotificationsUsageDescription</key>
    <string>AgentPet uses notifications to alert you about AI agent session events.</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST

# Copy hook script if it exists
if [ -f "$REPO_ROOT/Resources/apet-emit-event.sh" ]; then
    cp "$REPO_ROOT/Resources/apet-emit-event.sh" "$APP_DIR/Contents/Resources/"
    cp "$REPO_ROOT/Resources/apet-codex-notify.sh" "$APP_DIR/Contents/Resources/" 2>/dev/null || true
    chmod +x "$APP_DIR/Contents/Resources/apet-codex-notify.sh" 2>/dev/null || true
fi

# Copy pet assets
if [ -d "$REPO_ROOT/Resources/pets" ]; then
    cp -r "$REPO_ROOT/Resources/pets" "$APP_DIR/Contents/Resources/"
fi

echo "Done: $APP_DIR"
