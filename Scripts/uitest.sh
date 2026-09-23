#!/bin/zsh
#
# Run one screenshot UI test and export its images.
#
#   ./Scripts/uitest.sh <TestName> <tag> [simulator name]
#
#   <TestName>  a method of ScreenshotTests, e.g. testPlayerTopBar
#   <tag>       names the output: build/shots-<tag>/, build/test-<tag>.log
#   simulator   default "iPhone 16 Pro" (his phone). Any available name works.
#
# Runs in the foreground; start it with Desktop Commander's start_process.
# Works from either checkout (podskipper or the pk-app worktree): it uses the
# checkout it lives in.
#
# Exit status is xcodebuild's. The last lines of the log say EXIT and EXPORTED.
set -u
# UITEST_ROOT=~/Developer/pk-app runs it in the worktree (e.g. to photograph
# origin/main while edits are in progress here).
ROOT="${UITEST_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
T="${1:?test name}"; G="${2:?tag}"; NAME="${3:-iPhone 16 Pro}"
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
m=[x['udid'] for k,v in d.items() if 'iOS' in k for x in v if x['name']==sys.argv[1]]
print(m[0] if m else '')" "$NAME")
[ -n "$UDID" ] || { echo "no simulator named '$NAME'"; exit 2; }
[ -d PodSkipper.xcodeproj ] || ./Scripts/prepare-build.sh >/dev/null
rm -rf "build/TR-$G.xcresult" "build/shots-$G"
mkdir -p build
echo "running $T on $NAME ($UDID)"
xcodebuild test -collect-test-diagnostics never \
  -project PodSkipper.xcodeproj -scheme PodSkipperScreens \
  -destination "id=$UDID" \
  -only-testing:"PodSkipperUITests/ScreenshotTests/$T" \
  -derivedDataPath build/DerivedData \
  -resultBundlePath "build/TR-$G.xcresult" > "build/test-$G.log" 2>&1
RC=$?
echo "EXIT $RC" | tee -a "build/test-$G.log"
grep -E "error:|failed|XCTAssert|Test Case .* (passed|failed)" "build/test-$G.log" | tail -15
xcrun xcresulttool export attachments --path "build/TR-$G.xcresult" \
  --output-path "build/shots-$G" >> "build/test-$G.log" 2>&1
# Readable names, plus a 1000px copy of each PNG for looking at.
# build/shots-<tag>/named/<attachment name>.png and named/small/<same>.png
python3 - "build/shots-$G" <<'PY'
import json, os, re, shutil, subprocess, sys
d = sys.argv[1]
try: m = json.load(open(os.path.join(d, "manifest.json")))
except Exception: raise SystemExit
out = os.path.join(d, "named"); small = os.path.join(out, "small")
os.makedirs(small, exist_ok=True)
for t in m:
    for a in t.get("attachments", []):
        f = a["exportedFileName"]
        if not f.endswith(".png"): continue
        n = re.sub(r"[^A-Za-z0-9._-]+", "-", a.get("suggestedHumanReadableName", f))
        n = re.sub(r"_\d+_[0-9A-F-]{36}", "", n)
        if not n.endswith(".png"): n += ".png"
        shutil.copy(os.path.join(d, f), os.path.join(out, n))
        subprocess.run(["sips", "-Z", "1000", os.path.join(out, n), "--out",
                        os.path.join(small, n)], capture_output=True)
        print("  ", n)
PY
echo "EXPORTED $(ls build/shots-$G/named 2>/dev/null | grep -c png) png → build/shots-$G/named"
exit $RC
