#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${FLOATING_CLOCK_BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${FLOATING_CLOCK_OUTPUT_DIR:-$PROJECT_DIR/dist}"

swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --configuration release
BIN_DIR="$(swift build --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --configuration release --show-bin-path)"
APP_DIR="$OUTPUT_DIR/FloatingClock.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/FloatingClock" "$APP_DIR/Contents/MacOS/FloatingClock"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
