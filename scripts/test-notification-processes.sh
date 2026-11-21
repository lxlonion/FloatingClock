#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
suite=""
cleanup() {
    if [[ -n "$suite" ]]; then
        "$TEMP_DIR/check" cleanup "$suite" || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT
export TZ=UTC
swiftc -emit-library -emit-module -module-name ClockCore \
    "$PROJECT_DIR"/Sources/ClockCore/*.swift -emit-module-path "$TEMP_DIR/ClockCore.swiftmodule" \
    -o "$TEMP_DIR/libClockCore.dylib"
swiftc -I "$TEMP_DIR" -L "$TEMP_DIR" -lClockCore -Xlinker -rpath -Xlinker "$TEMP_DIR" \
    "$PROJECT_DIR/Sources/FloatingClock/TimerCoordinator.swift" "$PROJECT_DIR/Tests/NotificationProcessChecks/main.swift" -o "$TEMP_DIR/check"
for scenario in pause delete keep legacy-pause legacy-delete observed-pause observed-delete \
    duration-reanchor target-adopt same-delivered new-same-time new-next-day delete-delivered; do
    archive="$TEMP_DIR/$scenario.plist"
    suite="FloatingClock.process-check.$(uuidgen)"
    "$TEMP_DIR/check" start "$suite" "$archive" "$scenario"
    if [[ "$scenario" == observed-* ]]; then
        "$TEMP_DIR/check" observe "$suite" "$archive" "$scenario"
    fi
    "$TEMP_DIR/check" restore "$suite" "$archive" "$scenario"
    if [[ "$scenario" == observed-* ]]; then
        "$TEMP_DIR/check" verify "$suite" "$archive" "$scenario"
    fi
    "$TEMP_DIR/check" cleanup "$suite"
    suite=""
done
