#!/bin/bash
# Run hosted unit tests against the simulator build; no phone installation.
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/prepare-build.sh --local >/dev/null
./Scripts/generate-project.sh --simulator
mkdir -p build
UNIT_SIM_ID="${1:-$(xcrun simctl list devices available -j | python3 -c 'import json,re,sys; ver=lambda r: tuple(int(x) for x in re.findall(r"iOS-(\d+)-(\d+)", r)[0]) if re.search(r"iOS-\d+-\d+$", r) else (0,0); runtimes=sorted(json.load(sys.stdin)["devices"].items(), key=lambda kv: ver(kv[0]), reverse=True); devices=[d for runtime,items in runtimes if "iOS" in runtime for d in items if d["name"].startswith("iPhone")]; match=next((d for d in devices if d["name"] == "iPhone 16 Pro"), devices[0] if devices else {}); print(match.get("udid", ""))')}"
[ -n "$UNIT_SIM_ID" ] || { echo 'No available iPhone simulator'; exit 1; }
xcodebuild test -collect-test-diagnostics never -project PodSkipper.xcodeproj -scheme PodSkipperTests \
  -destination "id=$UNIT_SIM_ID" \
  -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO \
  -resultBundlePath "build/unit-$(date +%Y%m%d-%H%M%S).xcresult" \
  > build/unit-test.log 2>&1 || { tail -60 build/unit-test.log; exit 1; }
sed -n '/Test Suite .* started/,$p' build/unit-test.log | tail -65
