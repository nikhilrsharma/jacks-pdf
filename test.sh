#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUILD_DIR="${BUILD_DIR:-$PWD/build}"
TEST_DIR="$BUILD_DIR/tests"
mkdir -p "$TEST_DIR" "$BUILD_DIR/ModuleCache"
SDK="$(xcrun --show-sdk-path)"
ARCH="${ARCH:-$(uname -m)}"

xcrun swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -module-name DocumentSupportTests \
  -framework AppKit -framework PDFKit -framework CoreText -framework ImageIO \
  Sources/DocumentSupport.swift Tests/DocumentSupportTests.swift \
  -o "$TEST_DIR/DocumentSupportTests"

xcrun swiftc -swift-version 5 -parse-as-library -O \
  -sdk "$SDK" -target "$ARCH-apple-macos14.0" \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -module-name ReaderViewTests \
  -framework AppKit -framework PDFKit -framework CoreText -framework QuartzCore \
  Sources/ReaderPDFView.swift Tests/ReaderViewTests.swift \
  -o "$TEST_DIR/ReaderViewTests"

"$TEST_DIR/DocumentSupportTests"
"$TEST_DIR/ReaderViewTests"
