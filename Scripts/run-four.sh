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
set -uo pipefail
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
      afs2    "The Adam Friedland Show"
      chaos1  "Chris Distefano Presents: Chrissy Chaos"
      bears2  "2 Bears, 1 Cave with Tom Segura & Bert Kreischer"
      stavb199 "Stavvy's World"
      los957  "Legion of Skanks"
      ct284   "CumTown"
      ct262   "CumTown"
      tpw685p "This Past Weekend w/ Theo Von"
      wg2p    "Whiskey Ginger with Andrew Santino"
      wg3p    "Whiskey Ginger with Andrew Santino")
# tpw685p, wg2p, wg3p (pass 24): his phone's own transcripts, no labels yet —
# run by name to read their cuts (guest plugs at the end).
ALL=(stav199 mssp633 mssp636 los952 los956 ymh1 bears1 badf1 theo1 wg1 afs2 chaos1 bears2 stavb199 los957 ct284 ct262)
SNAP="build/lab-snapshot"; rm -rf "$SNAP"; mkdir -p "$SNAP/Tools"
cp -R Services Models "$SNAP/"; cp -R Tools/DetectionLab "$SNAP/Tools/"
Tools/DetectionLab/lab.sh build-segments "$PWD/build/lab/lab-segments-snap" "$PWD/$SNAP" || exit 1
export LAB_BIN="$PWD/build/lab/lab-segments-snap"
export LAB_INSERTED=${LAB_INSERTED:-1}
# Audio that plays again (<key>.produced.json from `lab-prints produced`).
export LAB_PRODUCED=${LAB_PRODUCED:-1}
# Pass 23: the fast reader for each fixture is the fold trained without its
# show (fastreader.py oof → build/fast/folds-<tag>/<key>.bin). LAB_FAST_DIR
# picks the set; without it the detector runs with no fast reader.
LAB_FAST_DIR=${LAB_FAST_DIR:-}
# A command-line executable has no app resource bundle. Load the actual
# shipped Reader weights explicitly, unless a held-out fold was requested.
export LAB_TAGGER=${LAB_TAGGER:-"$PWD/Resources/Detection/TaggerWeights.bin:$PWD/Resources/Detection/TaggerWeights-2.bin"}
FAILURES=0
run() {
  [ -f "build/lab/$1.dai.json" ] && (cd build/lab && python3 ../../Tools/DetectionLab/dai.py cuts "$1" >/dev/null)
  if [ -n "$LAB_FAST_DIR" ]; then export LAB_FAST="$PWD/$LAB_FAST_DIR/$1.bin"; else unset LAB_FAST; fi
  if ! Tools/DetectionLab/lab.sh segments "$1" "$SHOW[$1]" > "build/seg-$1.log" 2>&1; then
    FAILURES=$((FAILURES + 1))
    echo "$1: detector failed; see build/seg-$1.log"
    return
  fi
  if ! Tools/DetectionLab/lab.sh score "$1" >> "build/seg-$1.log" 2>&1; then
    FAILURES=$((FAILURES + 1))
  fi
  echo "── $1: $(grep -E '^per hour' build/seg-$1.log | head -1) | $(grep -E '^per cut' build/seg-$1.log | head -1) | $(grep -E '^work:' build/seg-$1.log | head -1)"
}
if [ $# -gt 0 ]; then for f in "$@"; do run "$f"; done
else for f in $ALL; do run "$f"; done; fi

[ "$FAILURES" -eq 0 ] || { echo "$FAILURES fixture(s) failed acceptance"; exit 1; }
