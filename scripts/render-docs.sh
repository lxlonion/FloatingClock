#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_DIR="$PROJECT_DIR/work/documentation-previews"
IMAGE_DIR="$PROJECT_DIR/docs/images"

mkdir -p "$PREVIEW_DIR" "$IMAGE_DIR"
"$PROJECT_DIR/scripts/dev.sh" --render-documentation-previews "$PREVIEW_DIR"

cp "$PREVIEW_DIR/styles-light.png" "$IMAGE_DIR/dials-light.png"
cp "$PREVIEW_DIR/styles-dark.png" "$IMAGE_DIR/dials-dark.png"
cp "$PREVIEW_DIR/style1-plain-light-260.png" "$IMAGE_DIR/minimal-dial.png"
cp "$PREVIEW_DIR/style2-plain-light-260.png" "$IMAGE_DIR/numbered-dial.png"
cp "$PREVIEW_DIR/quick-light-topRight.png" "$IMAGE_DIR/quick-access-top-right.png"
cp "$PREVIEW_DIR/quick-light-bottomLeft.png" "$IMAGE_DIR/quick-access-bottom-left.png"
cp "$PREVIEW_DIR/advanced-settings.png" "$IMAGE_DIR/advanced-settings.png"
cp "$PREVIEW_DIR/advanced-settings-disabled.png" "$IMAGE_DIR/advanced-settings-disabled.png"
cp "$PREVIEW_DIR/timer-editors-light-2-below.png" "$IMAGE_DIR/timers-light.png"
cp "$PREVIEW_DIR/timer-editors-dark-1-above.png" "$IMAGE_DIR/timers-dark.png"
printf 'Rendered documentation images: %s\n' "$IMAGE_DIR"
