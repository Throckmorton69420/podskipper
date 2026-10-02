#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "${1:-}" != "--simulator" ]; then
  exec xcodegen generate --spec project.yml --quiet
fi

# Apple ships Core AI in the device SDK, not the simulator SDK. Keep the
# shipping spec intact; the simulator exercises our presentation and fallback
# paths without compiling a device-only inference package.
mkdir -p build
xcodegen dump --spec project.yml --type json --file build/simulator-project.json
python3 - <<'PY'
import json
from pathlib import Path
p = Path('build/simulator-project.json')
spec = json.loads(p.read_text())
deps = spec['targets']['PodSkipper']['dependencies']
spec['targets']['PodSkipper']['dependencies'] = [
    d for d in deps if d.get('package') != 'coreai-kit'
]
p.write_text(json.dumps(spec, indent=2))
PY
xcodegen generate --spec build/simulator-project.json --project-root . --project . --quiet
