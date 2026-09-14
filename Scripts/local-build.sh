#!/bin/bash
#
# Build PodSkipper on this Mac, and optionally photograph it in a simulator.
#
# This exists to take a person out of a loop they should never have been in.
# The cycle used to be: push to GitHub, wait for a runner, download the logs,
# paste them back into a conversation, read them, fix, push again — with a human
# doing the carrying at four separate points, and every compiler error costing a
# full round trip through someone's attention.
#
# The runners are still the ship gate. This is the inner loop.
#
#   ./Scripts/local-build.sh build          compile only, errors only  (~40s)
#   ./Scripts/local-build.sh shots          build, run, photograph every tab
#   ./Scripts/local-build.sh shots iPad     the same on an iPad
#
# Output goes to build/ and build/screenshots/, both git-ignored.

set -uo pipefail
export PATH="/opt/homebrew/bin:$PATH"

MODE="${1:-build}"
FAMILY="${2:-iPhone}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DERIVED="$ROOT/build/DerivedData"
SHOTS="$ROOT/build/screenshots"
LOG="$ROOT/build/xcodebuild.log"
mkdir -p "$ROOT/build"

# --- The asset catalog XcodeGen expects -------------------------------------
# `Generated/` is not in the repository — the CI workflows build it before
# generating the project, so a fresh clone has no such directory and XcodeGen
# refuses the spec. Same steps, locally.
build_catalog() {
  local catalog="Generated/Assets.xcassets"
  rm -rf Generated
  mkdir -p "$catalog/AppIcon.appiconset"
  printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$catalog/Contents.json"
  local icon
  icon=$(find . -path ./.git -prune -o -name 'AppIcon-1024.png' -print 2>/dev/null | head -1)
  if [ -n "$icon" ]; then
    cp "$icon" "$catalog/AppIcon.appiconset/AppIcon-1024.png"
    cat > "$catalog/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "AppIcon-1024.png", "idiom" : "universal",
      "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
  else
    printf '{\n  "images" : [],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' \
      > "$catalog/AppIcon.appiconset/Contents.json"
  fi
}

# --- Pick a simulator --------------------------------------------------------
pick_simulator() {
  python3 - "$1" <<'PY'
import json, re, subprocess, sys
want = sys.argv[1]
raw = subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                     capture_output=True, text=True).stdout
best = None
for runtime, entries in json.loads(raw)["devices"].items():
    if "iOS" not in runtime:
        continue
    for device in entries:
        if not device.get("isAvailable") or not device["name"].startswith(want):
            continue
        name = device["name"]
        score = 200 if "Pro" in name else 0
        score += 100 if "Max" in name else 0
        nums = re.findall(r"\d+", name)
        if nums:
            score += int(nums[0])
        if best is None or score > best[0]:
            best = (score, device["udid"], name)
if best:
    print(best[1]); print(best[2])
PY
}

echo "▸ Generating the project"
build_catalog
xcodegen generate --spec project.yml --quiet || { echo "✗ xcodegen failed"; exit 1; }

SIM_UDID=$(pick_simulator "$FAMILY" | sed -n '1p')
SIM_NAME=$(pick_simulator "$FAMILY" | sed -n '2p')
[ -z "$SIM_UDID" ] && { echo "✗ no $FAMILY simulator available"; exit 1; }
echo "▸ Simulator: $SIM_NAME"

echo "▸ Building"
xcodebuild \
  -project PodSkipper.xcodeproj \
  -scheme PodSkipper \
  -configuration Debug \
  -destination "id=$SIM_UDID" \
  -derivedDataPath "$DERIVED" \
  -quiet \
  build > "$LOG" 2>&1
STATUS=$?

# Only the lines worth a person's — or a model's — attention. A full xcodebuild
# log is tens of thousands of lines and almost none of it is the problem.
echo "──────── errors ────────"
grep -E "error:|error :" "$LOG" | sed 's|^/Users/[^/]*/Documents/GitHub/podskipper/||' | sort -u | head -40
if [ $STATUS -ne 0 ]; then
  if ! grep -qE "error:" "$LOG"; then
    echo "(no 'error:' lines — tail of the log:)"
    tail -25 "$LOG"
  fi
  echo "✗ BUILD FAILED (exit $STATUS) — full log: build/xcodebuild.log"
  exit $STATUS
fi

WARNINGS=$(grep -cE "warning:" "$LOG" 2>/dev/null || echo 0)
echo "✓ BUILD SUCCEEDED  ($WARNINGS warnings)"
[ "$MODE" = "build" ] && exit 0

# --- Run it and take pictures ------------------------------------------------
APP=$(find "$DERIVED/Build/Products" -name "PodSkipper.app" -maxdepth 3 | head -1)
[ -z "$APP" ] && { echo "✗ built product not found"; exit 1; }

echo "▸ Booting $SIM_NAME"
xcrun simctl boot "$SIM_UDID" 2>/dev/null
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1

# Dark, because the app is an AMOLED-black design and a light-mode photograph
# says nothing about how it actually looks.
xcrun simctl ui "$SIM_UDID" appearance dark >/dev/null 2>&1

xcrun simctl uninstall "$SIM_UDID" com.yourname.podskipper >/dev/null 2>&1
xcrun simctl install "$SIM_UDID" "$APP" || { echo "✗ install failed"; exit 1; }

rm -rf "$SHOTS"; mkdir -p "$SHOTS"

# The same launch argument the CI screenshot job uses, so the simulator has
# demo shows to photograph rather than an empty library.
xcrun simctl launch "$SIM_UDID" com.yourname.podskipper -PodSkipperDemoData YES >/dev/null
sleep 6
xcrun simctl io "$SIM_UDID" screenshot "$SHOTS/01-library.png" >/dev/null 2>&1

echo "✓ $(ls "$SHOTS" | wc -l | tr -d ' ') screenshot(s) in build/screenshots/"
echo "  (deeper navigation comes from the UI test target — see Scripts/local-shots.sh)"
