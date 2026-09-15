#!/bin/bash
#
# Pull the frame where the timeline is being held out of the test run's video.
#
# Some things in this app only exist while a finger is down: the label naming
# the segment under it, and the cropped time scale that a press-and-hold puts
# around that moment. A screenshot taken after the gesture shows neither, and
# XCUIElement gestures throw "Must be called on the main thread" if you try to
# run the press on another queue and photograph it from the test's own.
#
# So the test drops a timestamped marker attachment, presses, and this reads
# the marker's timestamp out of the result bundle, works out how far into the
# run's screen recording that was, and extracts a frame a second later.
#
#   ./Scripts/hold-frame.sh <exported-attachments-dir> <output.png> [offset]
#
# The attachments directory is what
# `xcrun xcresulttool export attachments` produced, manifest.json and all.

set -uo pipefail

DIR="${1:?usage: hold-frame.sh <attachments-dir> <output.png> [offset-seconds]}"
OUT="${2:?usage: hold-frame.sh <attachments-dir> <output.png> [offset-seconds]}"
OFFSET="${3:-1.0}"

command -v ffmpeg >/dev/null 2>&1 || { echo "✗ ffmpeg not installed"; exit 1; }

read -r VIDEO SECONDS_IN < <(python3 - "$DIR" "$OFFSET" <<'PY'
import json, os, sys
directory, offset = sys.argv[1], float(sys.argv[2])
manifest = json.load(open(os.path.join(directory, "manifest.json")))

video = None          # (file, timestamp) of the screen recording
marker = None         # timestamp of the marker attachment

def walk(node):
    global video, marker
    if isinstance(node, dict):
        name = node.get("suggestedHumanReadableName", "")
        stamp = node.get("timestamp")
        if "Screen Recording" in name or "Screen-Recording" in name:
            if video is None or stamp < video[1]:
                video = (node["exportedFileName"], stamp)
        if name.startswith("15c-marker-before-hold"):
            marker = stamp
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)

walk(manifest)

if video is None or marker is None:
    # Nothing to say beyond "can't": the caller prints the message.
    print("", 0)
    raise SystemExit

# The recording's own attachment timestamp is when it was written, not when it
# started — but both it and the marker are on the same clock, and a run's
# recording starts at the first attachment. Anchored on the earliest timestamp
# in the bundle instead, which is that moment.
earliest = []
def collect(node):
    if isinstance(node, dict):
        if "timestamp" in node:
            earliest.append(node["timestamp"])
        for value in node.values():
            collect(value)
    elif isinstance(node, list):
        for value in node:
            collect(value)
collect(manifest)

start = min(earliest) if earliest else marker
print(os.path.join(directory, video[0]), max(0.0, marker - start + offset))
PY
)

[ -z "${VIDEO:-}" ] && { echo "✗ no screen recording or no marker in that bundle"; exit 1; }
[ -f "$VIDEO" ] || { echo "✗ recording file missing: $VIDEO"; exit 1; }

# The recording has no extension in the export; ffmpeg sniffs the container.
ffmpeg -loglevel error -y -ss "$SECONDS_IN" -i "$VIDEO" -frames:v 1 "$OUT" \
  || { echo "✗ ffmpeg could not read the recording"; exit 1; }

echo "✓ frame at ${SECONDS_IN}s → $OUT"
