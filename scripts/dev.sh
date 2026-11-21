#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TOOL="$("$PROJECT_DIR/scripts/build-dev.sh")"
exec "$TOOL" "$@"
