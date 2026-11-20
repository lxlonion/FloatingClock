#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
swiftc -emit-library -emit-module -module-name ClockCore \
    "$PROJECT_DIR"/Sources/ClockCore/*.swift -emit-module-path "$TEMP_DIR/ClockCore.swiftmodule" \
    -o "$TEMP_DIR/libClockCore.dylib"
swiftc -I "$TEMP_DIR" -L "$TEMP_DIR" -lClockCore -Xlinker -rpath -Xlinker "$TEMP_DIR" \
    "$PROJECT_DIR/Sources/FloatingClock/TimerCoordinator.swift" "$PROJECT_DIR/Tests/NotificationProcessChecks/main.swift" -o "$TEMP_DIR/check"
for action in pause delete keep legacy-pause legacy-delete observed-pause observed-delete; do
    case_dir="$TEMP_DIR/$action"
    mkdir "$case_dir"
    suite="FloatingClock.process-check.$(uuidgen)"
    "$TEMP_DIR/check" start "$suite" "$case_dir" "$action"
    if [[ "$action" == observed-* ]]; then
        "$TEMP_DIR/check" observe "$suite" "$case_dir" "$action"
    fi
    "$TEMP_DIR/check" restore "$suite" "$case_dir" "$action"
    if [[ "$action" == observed-* ]]; then
        "$TEMP_DIR/check" verify "$suite" "$case_dir" "$action"
    fi
done
