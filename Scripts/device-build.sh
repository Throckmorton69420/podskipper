#!/bin/bash
# Compile the actual Core AI device target without signing or installing.
# Its generated project is separate from the simulator/test project.
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/prepare-build.sh --local >/dev/null
mkdir -p build/device-project
xcodegen dump --spec project.yml --type json --file build/device-project.json
python3 - <<'PY'
import json
from pathlib import Path
root = Path.cwd()
p = root / 'build/device-project.json'
spec = json.loads(p.read_text())
for target in spec['targets'].values():
    if target.get('info', {}).get('path'):
        target['info']['path'] = str((root / target['info']['path']).resolve())
    settings = target.get('settings', {}).get('base', {})
    if settings.get('CODE_SIGN_ENTITLEMENTS'):
        settings['CODE_SIGN_ENTITLEMENTS'] = str((root / settings['CODE_SIGN_ENTITLEMENTS']).resolve())
p.write_text(json.dumps(spec, indent=2))
PY
xcodegen generate --spec build/device-project.json --project build/device-project --project-root . --quiet
xcodebuild -project build/device-project/PodSkipper.xcodeproj -scheme PodSkipper \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DeviceDerivedData \
  -clonedSourcePackagesDirPath build/DerivedData/SourcePackages \
  CODE_SIGN_IDENTITY='' CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_ENTITLEMENTS='' MTL_COMPILER_FLAGS='-Wno-c++17-extensions' \
  build > build/device-build.log 2>&1 || { tail -45 build/device-build.log; exit 1; }
grep -E 'warning:|BUILD SUCCEEDED' build/device-build.log | tail -15
