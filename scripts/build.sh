#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${FLOATING_CLOCK_BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${FLOATING_CLOCK_OUTPUT_DIR:-$PROJECT_DIR/dist}"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"

SWIFT_OPTIONS=(--disable-sandbox --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --cache-path "$BUILD_DIR/cache" --config-path "$BUILD_DIR/config" --security-path "$BUILD_DIR/security")
swift build "${SWIFT_OPTIONS[@]}" --configuration release
BIN_DIR="$(swift build "${SWIFT_OPTIONS[@]}" --configuration release --show-bin-path)"
APP_DIR="$OUTPUT_DIR/FloatingClock.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/FloatingClock" "$APP_DIR/Contents/MacOS/FloatingClock"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
codesign --force --deep --sign - "$APP_DIR"
printf 'Built: %s\n' "$APP_DIR"
