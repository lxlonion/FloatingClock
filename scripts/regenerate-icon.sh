#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/.build/ModuleCache"
swift -module-cache-path "$PROJECT_DIR/.build/ModuleCache" "$PROJECT_DIR/scripts/generate-icon.swift" "$PROJECT_DIR/.build/AppIcon.iconset"
python3 - "$PROJECT_DIR" <<'PY'
from pathlib import Path
import struct
import sys

project = Path(sys.argv[1])
entries = [('icp4', '16x16'), ('icp5', '32x32'), ('icp6', '32x32@2x'),
           ('ic07', '128x128'), ('ic08', '256x256'), ('ic09', '512x512'),
           ('ic10', '512x512@2x'), ('ic11', '16x16@2x'), ('ic12', '32x32@2x'),
           ('ic13', '128x128@2x'), ('ic14', '256x256@2x')]
chunks = []
for kind, name in entries:
    data = (project / '.build/AppIcon.iconset' / ('icon_' + name + '.png')).read_bytes()
    chunks.append(struct.pack('>4sI', kind.encode('ascii'), len(data) + 8) + data)
body = b''.join(chunks)
(project / 'Resources/AppIcon.icns').write_bytes(struct.pack('>4sI', b'icns', len(body) + 8) + body)
PY
