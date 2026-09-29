#!/bin/zsh
# Pass 24: run one compiled detector on fixtures in a private copy of their
# files, so two versions can be compared side by side without touching the
# lab's own reply caches (build/lab/<key>.replies.json is copied, not shared).
#   Tools/DetectionLab/cmprun.sh <binary> <tag> key…
# Output: build/cmp/<tag>/<key>.detect.txt and .score.txt; a summary at the end.
# Uses the fixture's fast-reader fold (build/fast/folds-sgd/<key>.bin) as run-four.sh does.
cd "$(dirname "$0")/../.."
BIN="$1"; TAG="$2"; shift 2
typeset -A SHOW
SHOW=(stav199 "Stavvy's World" stavb199 "Stavvy's World"
      mssp633 "Matt and Shane's Secret Podcast" mssp636 "Matt and Shane's Secret Podcast"
      los952 "Legion of Skanks" los956 "Legion of Skanks" los957 "Legion of Skanks"
      ymh1 "Your Mom's House with Christina P. and Tom Segura"
      bears1 "2 Bears, 1 Cave with Tom Segura & Bert Kreischer" bears2 "2 Bears, 1 Cave with Tom Segura & Bert Kreischer"
      badf1 "Bad Friends" theo1 "This Past Weekend w/ Theo Von" tpw685p "This Past Weekend w/ Theo Von"
      wg1 "Whiskey Ginger with Andrew Santino" wg2p "Whiskey Ginger with Andrew Santino" wg3p "Whiskey Ginger with Andrew Santino"
      afs2 "The Adam Friedland Show" chaos1 "Chris Distefano Presents: Chrissy Chaos" ct284 "CumTown" ct262 "CumTown")
OUT="build/cmp/$TAG"; mkdir -p "$OUT"
for k in "$@"; do
  for ext in json replies.json notes.txt title cheap.json produced.json dai.json; do
    [ -f "build/lab/$k.$ext" ] && cp "build/lab/$k.$ext" "$OUT/$k.$ext"
  done
  if [ -f "build/fast/folds-sgd/$k.bin" ]; then export LAB_FAST="$PWD/build/fast/folds-sgd/$k.bin"; else unset LAB_FAST; fi
  (cd "$OUT" && LAB_INSERTED=1 LAB_PRODUCED=1 "$BIN" "$k.json" "$k.notes.txt" "$SHOW[$k]" "$(cat "$k.title" 2>/dev/null)" > "$k.detect.txt" 2> "$k.detect.err")
  if [ -f "Tools/DetectionLab/regression/$k.json" ]; then
    python3 Tools/DetectionLab/regression/score.py "$OUT/$k.json" "$OUT/$k.detect.txt" "Tools/DetectionLab/regression/$k.json" > "$OUT/$k.score.txt" 2>&1
  fi
  echo "── $k: $(grep -E '^questions asked|questions asked' "$OUT/$k.detect.txt" | head -1) | $(grep -E '^per hour' "$OUT/$k.score.txt" 2>/dev/null | head -1)"
done
