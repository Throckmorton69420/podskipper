#!/bin/zsh
# Pass 25: the whole detector with PodSkipper's own reader (no Apple model),
# on every lab fixture, each read by a reader that never saw its show.
#
#   Tools/DetectionLab/ownlab.sh <tag> [key…]
#
# The reader's answers come from tagger.py's out-of-fold file
# (build/tagger/<tag>/oof/<key>.json), or, with OWN_WEIGHTS=folds, from the
# Swift reader itself running the fold's weights (build/tagger/<tag>/folds/…).
# Files are copied to build/own/<out>/ so the lab's own caches are untouched.
# Settings: OWN_BIN (the lab binary), OWN_OUT (output name), and the LAB_*
# tuning variables (LAB_TAGBOOST, LAB_JOINFLOOR, LAB_KEEPFLOOR).
cd "$(dirname "$0")/../.."
TAG="$1"; shift
KEYS=("$@")
[ ${#KEYS} -eq 0 ] && KEYS=(stav199 stavb199 mssp633 mssp636 los952 los956 los957 ymh1 bears1 bears2 badf1 theo1 wg1 afs2 ct262 ct284 chaos1)
BIN="${OWN_BIN:-$PWD/build/lab/lab-segments-p25}"
OUT="build/own/${OWN_OUT:-$TAG}"; mkdir -p "$OUT"
typeset -A SHOW FOLD
SHOW=(stav199 "Stavvy's World" stavb199 "Stavvy's World"
      mssp633 "Matt and Shane's Secret Podcast" mssp636 "Matt and Shane's Secret Podcast"
      los952 "Legion of Skanks" los956 "Legion of Skanks" los957 "Legion of Skanks"
      ymh1 "Your Mom's House with Christina P. and Tom Segura"
      bears1 "2 Bears, 1 Cave with Tom Segura & Bert Kreischer" bears2 "2 Bears, 1 Cave with Tom Segura & Bert Kreischer"
      badf1 "Bad Friends" theo1 "This Past Weekend w/ Theo Von" tpw685p "This Past Weekend w/ Theo Von"
      wg1 "Whiskey Ginger with Andrew Santino" wg2p "Whiskey Ginger with Andrew Santino" wg3p "Whiskey Ginger with Andrew Santino"
      afs2 "The Adam Friedland Show" chaos1 "Chris Distefano Presents: Chrissy Chaos" ct284 "CumTown" ct262 "CumTown")
FOLD=(stav199 "stav+ymh+theo" stavb199 "stav+ymh+theo" ymh1 "stav+ymh+theo" theo1 "stav+ymh+theo"
      mssp633 "mssp+wg" mssp636 "mssp+wg" wg1 "mssp+wg" los952 los los956 los los957 los
      bears1 "bears+badf+afs" bears2 "bears+badf+afs" badf1 "bears+badf+afs" afs2 "bears+badf+afs"
      ct262 "ct+chaos" ct284 "ct+chaos" chaos1 "ct+chaos")
for k in $KEYS; do
  # dai.json too: score.py takes an inserted ad's exact edges from it. The
  # reply cache only matters for LAB_OWN=0 (the old detector, for comparison).
  for ext in json notes.txt title cheap.json produced.json dai.json replies.json; do
    [ -f "build/lab/$k.$ext" ] && cp "build/lab/$k.$ext" "$OUT/$k.$ext"
  done
  unset LAB_TAGPROBS LAB_TAGGER LAB_FAST
  if [ "${LAB_OWN:-}" = 0 ]; then
    # The old detector as the app ran it: the fast reader's fold for this show.
    [ -f "build/fast/folds-sgd/$k.bin" ] && export LAB_FAST="$PWD/build/fast/folds-sgd/$k.bin"
  elif [ "${OWN_WEIGHTS:-}" = folds ]; then
    export LAB_TAGGER="$PWD/build/tagger/$TAG/folds/$FOLD[$k].bin"
  elif [ "${OWN_WEIGHTS:-}" != "" ]; then
    export LAB_TAGGER="$OWN_WEIGHTS"
  else
    export LAB_TAGPROBS="$PWD/build/tagger/$TAG/oof/$k.json"
  fi
  (cd "$OUT" && LAB_INSERTED=1 LAB_PRODUCED=1 "$BIN" "$k.json" "$k.notes.txt" "$SHOW[$k]" "$(cat "$k.title" 2>/dev/null)" > "$k.detect.txt" 2> "$k.detect.err")
  if [ -f "Tools/DetectionLab/regression/$k.json" ]; then
    python3 Tools/DetectionLab/regression/score.py "$OUT/$k.json" "$OUT/$k.detect.txt" "Tools/DetectionLab/regression/$k.json" > "$OUT/$k.score.txt" 2>&1
  fi
done
python3 - "$OUT" $KEYS <<'PY'
import json, re, sys, os
out, keys = sys.argv[1], sys.argv[2:]
H = heard = skipped = 0.0
for k in keys:
    p = os.path.join(out, k + ".score.txt")
    if not os.path.exists(p): print("%-9s (no labels)" % k); continue
    m = re.search(r"^SUMMARY (.*)$", open(p).read(), re.M)
    if not m: print("%-9s no summary" % k); continue
    s = json.loads(m.group(1))
    if "ad_s_heard_per_h" not in s: print("%-9s %s" % (k, s)); continue
    h = s["hours"]; H += h; heard += s["ad_s_heard_per_h"] * h; skipped += s["content_s_skipped_per_h"] * h
    print("%-9s heard %6.1f skipped %6.1f  (%.2f h)" % (k, s["ad_s_heard_per_h"], s["content_s_skipped_per_h"], h))
if H: print("ALL %.1f h: heard %.1f s/h, skipped %.1f s/h" % (H, heard / H, skipped / H))
PY
