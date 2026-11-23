#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$HOME/Applications/ColabMonitor.app"
if [[ "${1:-}" == "--system" ]]; then
  APP_DIR="/Applications/ColabMonitor.app"
fi

BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
mkdir -p "$BIN_DIR" "$RES_DIR"

echo "[1/4] Compiling Swift release binary..."
swiftc -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework UserNotifications \
  "$SCRIPT_DIR/Sources/ColabMonitor.swift" \
  -o "$BIN_DIR/ColabMonitor"

echo "[2/4] Generating AppIcon.icns..."
TMP_ICONSET="$(mktemp -d)/AppIcon.iconset"
swift "$SCRIPT_DIR/scripts/generate_icns.swift" "$TMP_ICONSET"
iconutil -c icns "$TMP_ICONSET" -o "$RES_DIR/AppIcon.icns"
rm -rf "$(dirname "$TMP_ICONSET")"

echo "[3/4] Writing Info.plist (LSUIElement=true, no Dock icon)..."
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>ColabMonitor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.colabmonitor.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>ColabMonitor</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

echo "[4/4] Ad-hoc signing bundle..."
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "Built: $APP_DIR"
