#!/bin/zsh
# Pass 23: the whole detector on every fixture, three ways, results kept apart.
#   base    — as before pass 23 (no fast reader)
#   fast    — the fast reader voting on every sentence (the app's default)
#   nomodel — every model question refused: what a locked phone on battery gets
#   Tools/DetectionLab/fastlab.sh [config …]   (default: all three)
# Fold weights: build/fast/folds-${FAST_TAG:-sgd}/<key>.bin (fastreader.py oof).
cd "$(dirname "$0")/../.."
TAG=${FAST_TAG:-sgd}
CONFIGS=(${@:-base fast nomodel})
for c in $CONFIGS; do
  unset LAB_NOFAST LAB_NOMODEL LAB_FAST_DIR
  case $c in
    base) export LAB_NOFAST=1 ;;
    fast) export LAB_FAST_DIR=build/fast/folds-$TAG ;;
    nomodel) export LAB_FAST_DIR=build/fast/folds-$TAG LAB_NOMODEL=1 ;;
    fastscreen) export LAB_FAST_DIR=build/fast/folds-$TAG LAB_FASTSCREEN=${LAB_FASTSCREEN:-0.15} ;;
  esac
  echo "=== $c"
  ./Scripts/run-four.sh > build/fast/lab-$c.out 2>&1
  mkdir -p build/fast/lab-$c && cp build/seg-*.log build/fast/lab-$c/
  python3 - "$c" <<'PY'
import json, re, sys, glob
c = sys.argv[1]
H = heard = skipped = q = 0.0
for path in sorted(glob.glob(f"build/fast/lab-{c}/seg-*.log")):
    m = re.search(r"^SUMMARY (.*)$", open(path).read(), re.M)
    if not m: print(path, "no summary"); continue
    s = json.loads(m.group(1))
    if "ad_s_heard_per_h" not in s: continue
    h = s["hours"]; H += h; heard += s["ad_s_heard_per_h"] * h; skipped += s["content_s_skipped_per_h"] * h
    q += s.get("questions") or 0
    print("%-9s heard %6.1f skipped %6.1f questions %s" % (s["fixture"], s["ad_s_heard_per_h"], s["content_s_skipped_per_h"], s.get("questions")))
print("ALL %s %.1f h: heard %.1f s/h, skipped %.1f s/h, questions %.0f (%.0f per hour)" % (c, H, heard / H, skipped / H, q, q / H))
PY
done
