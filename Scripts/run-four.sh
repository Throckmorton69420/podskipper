#!/bin/zsh
#
# Run the detection lab on every fixture (episodes of shows in his library)
# and score each. The name is historical; it runs all of them.
#
#   ./Scripts/run-four.sh            all fixtures
#   ./Scripts/run-four.sh stav199    just the named ones
#
# The detector is compiled ONCE, at the start, from a snapshot of the sources,
# so editing Services/ while this runs does not change later fixtures.
# Real show names are passed on purpose: the prompts include the show title.
# The ad-free comparison and fingerprint evidence (<key>.cheap.json, from
# `dai.py cuts`) is used whenever it exists, as the app does (LAB_INSERTED=1).
# Output: build/seg-<fixture>.log; one summary line per fixture at the end.
# Tuning via LAB_SIZE, LAB_STEP, LAB_PAD, LAB_CUEPAD, LAB_WALK, LAB_PAR.
cd "$(dirname "$0")/.."
mkdir -p build
typeset -A SHOW
SHOW=(stav199 "Stavvy's World"
      mssp633 "Matt and Shane's Secret Podcast"
      mssp636 "Matt and Shane's Secret Podcast"
      los952  "Legion of Skanks"
      los956  "Legion of Skanks"
      ymh1    "Your Mom's House with Christina P. and Tom Segura"
      bears1  "2 Bears, 1 Cave with Tom Segura & Bert Kreischer"
      badf1   "Bad Friends"
      theo1   "This Past Weekend w/ Theo Von"
      wg1     "Whiskey Ginger with Andrew Santino"
      afs2    "The Adam Friedland Show")
ALL=(stav199 mssp633 mssp636 los952 los956 ymh1 bears1 badf1 theo1 wg1 afs2)
SNAP="build/lab-snapshot"; rm -rf "$SNAP"; mkdir -p "$SNAP/Tools"
cp -R Services Models "$SNAP/"; cp -R Tools/DetectionLab "$SNAP/Tools/"
Tools/DetectionLab/lab.sh build-segments "$PWD/build/lab/lab-segments-snap" "$PWD/$SNAP" || exit 1
export LAB_BIN="$PWD/build/lab/lab-segments-snap"
export LAB_INSERTED=${LAB_INSERTED:-1}
# Audio that plays again (<key>.produced.json from `lab-prints produced`).
export LAB_PRODUCED=${LAB_PRODUCED:-1}
run() {
  [ -f "build/lab/$1.dai.json" ] && (cd build/lab && python3 ../../Tools/DetectionLab/dai.py cuts "$1" >/dev/null)
  Tools/DetectionLab/lab.sh segments "$1" "$SHOW[$1]" > "build/seg-$1.log" 2>&1
  Tools/DetectionLab/lab.sh score "$1" >> "build/seg-$1.log" 2>&1
  echo "── $1: $(grep -E '^per hour' build/seg-$1.log | head -1) | $(grep -E '^per cut' build/seg-$1.log | head -1) | $(grep -E '^work:' build/seg-$1.log | head -1)"
}
if [ $# -gt 0 ]; then for f in "$@"; do run "$f"; done
else for f in $ALL; do run "$f"; done; fi
