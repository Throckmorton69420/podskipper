#!/bin/bash
#
# The detection lab: run the app's own ad detector on a real episode, on this
# Mac, with the same on-device model the phone uses.
#
#   Tools/DetectionLab/lab.sh fetch <feed-url> <item-index> <key>
#       downloads episode <item-index> (0 = newest) of a feed as build/lab/<key>.mp3,
#       with its title and show notes. Uses a Podcasts user agent, because
#       dynamically inserted ads are only served to podcast apps — a plain curl
#       gets an ad-free file and nothing to detect.
#   Tools/DetectionLab/lab.sh transcribe <key>      ~1 minute per hour of audio
#   Tools/DetectionLab/lab.sh detect <key> "<show title>"
#       prints every cut with its text, then a log of every decision.
#   Tools/DetectionLab/lab.sh score <key> [fixture]
#       scores that output against Tools/DetectionLab/regression/<fixture>.json,
#       whose regions are anchored to words so any download of the episode works.
#
# The detector is compiled straight from Services/ and Models/, so what runs
# here is exactly what ships. Output goes to build/lab/, which is git-ignored.
# The Mac needs Apple Intelligence turned on for the language model.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LAB="$ROOT/build/lab"; mkdir -p "$LAB"
cd "$LAB" || exit 1

case "${1:-}" in
  fetch)
    FEED="$2"; INDEX="$3"; KEY="$4"
    curl -sSL "$FEED" -o "$KEY.feed.xml" || exit 1
    python3 - "$KEY" "$INDEX" <<'PY'
import sys, xml.etree.ElementTree as ET
key, index = sys.argv[1], int(sys.argv[2])
item = ET.parse(key + ".feed.xml").getroot().find("channel").findall("item")[index]
open(key + ".url", "w").write(item.find("enclosure").get("url"))
open(key + ".title", "w").write(item.findtext("title") or "")
open(key + ".notes.txt", "w").write(item.findtext("description") or "")
print(item.findtext("title"))
PY
    curl -sSL -A "Podcasts/1740.2 CFNetwork/3826.500.62.2.1 Darwin/24.0.0" -o "$KEY.mp3" "$(cat "$KEY.url")"
    ls -la "$KEY.mp3"
    ;;
  transcribe)
    KEY="$2"
    xcrun swiftc -O -parse-as-library -o lab-transcribe \
      "$ROOT/Tools/DetectionLab/LabTranscribe.swift" "$ROOT/Services/TranscriptionService.swift" || exit 1
    ./lab-transcribe "$KEY.mp3" "$KEY.json"
    ;;
  detect)
    KEY="$2"; SHOW="${3:-}"
    xcrun swiftc -O -parse-as-library -o lab-detect \
      "$ROOT/Tools/DetectionLab/LabDetect.swift" "$ROOT/Services/TranscriptionService.swift" \
      "$ROOT/Services/AdDetector.swift" "$ROOT/Services/FeedbackMemory.swift" \
      "$ROOT/Models/DetectionTypes.swift" || exit 1
    ./lab-detect "$KEY.json" "$KEY.notes.txt" "$(cat "$KEY.title" 2>/dev/null)" "$SHOW" \
      > "$KEY.detect.txt" 2> "$KEY.detect.err"
    echo "results: build/lab/$KEY.detect.txt"
    ;;
  score)
    # Checks the last `detect` against a word-anchored regression file in
    # Tools/DetectionLab/regression/. Exits non-zero on any failing region.
    KEY="$2"; FIXTURE="${3:-$KEY}"
    python3 "$ROOT/Tools/DetectionLab/regression/score.py" "$KEY.json" "$KEY.detect.txt" \
      "$ROOT/Tools/DetectionLab/regression/$FIXTURE.json"
    ;;
  *)
    sed -n '3,24p' "$0"; exit 1 ;;
esac
