#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${FLOATING_CLOCK_BUILD_DIR:-$PROJECT_DIR/.build}/development"
mkdir -p "$BUILD_DIR"
TEMP_DIR="$(mktemp -d "$BUILD_DIR/.compile.XXXXXXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

SWIFT_OPTIONS=(-swift-version 5 -target "$(uname -m)-apple-macosx13.0" -O)
APP_SOURCES=()
for source in "$PROJECT_DIR"/Sources/FloatingClock/*.swift; do
    if [[ "${source##*/}" != main.swift ]]; then
        APP_SOURCES+=("$source")
    fi
done

swiftc "${SWIFT_OPTIONS[@]}" -emit-library -static -emit-module -module-name ClockCore \
    "$PROJECT_DIR"/Sources/ClockCore/*.swift -emit-module-path "$TEMP_DIR/ClockCore.swiftmodule" \
    -o "$TEMP_DIR/libClockCore.a"
swiftc "${SWIFT_OPTIONS[@]}" -module-name FloatingClockDevelopment -I "$TEMP_DIR" -L "$TEMP_DIR" -lClockCore \
    "${APP_SOURCES[@]}" "$PROJECT_DIR"/Development/*.swift -o "$TEMP_DIR/FloatingClockDevelopment"

TOOL="$BUILD_DIR/FloatingClockDevelopment"
mv -f "$TEMP_DIR/FloatingClockDevelopment" "$TOOL"
printf '%s\n' "$TOOL"
