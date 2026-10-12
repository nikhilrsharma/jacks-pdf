#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
APP="$BUILD_DIR/Jack's PDF.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/ModuleCache"
SDK="$(xcrun --show-sdk-path)"
ARCH="${ARCH:-$(uname -m)}"
xcrun swiftc -swift-version 5 -parse-as-library -O -whole-module-optimization \
  -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -module-name JacksPDFViewer -framework AppKit -framework PDFKit -framework QuartzCore \
  Sources/*.swift -o "$APP/Contents/MacOS/JacksPDFViewer"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/Jack.jpg Resources/PrivacyInfo.xcprivacy "$APP/Contents/Resources/"
codesign --force --sign - --options runtime --entitlements Viewer.entitlements "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
