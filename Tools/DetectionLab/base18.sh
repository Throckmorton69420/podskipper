#!/bin/zsh
# Baseline (HEAD) detector on the named fixtures, outputs kept as <key>.base.txt / seg-<key>.base.log
cd "$(dirname "$0")/../.."
typeset -A SHOW
SHOW=(stav199 "Stavvy's World" mssp633 "Matt and Shane's Secret Podcast" mssp636 "Matt and Shane's Secret Podcast"
      los952 "Legion of Skanks" los956 "Legion of Skanks" ymh1 "Your Mom's House with Christina P. and Tom Segura"
      bears1 "2 Bears, 1 Cave with Tom Segura & Bert Kreischer" badf1 "Bad Friends" theo1 "This Past Weekend w/ Theo Von"
      wg1 "Whiskey Ginger with Andrew Santino" afs2 "The Adam Friedland Show")
export LAB_BIN="$PWD/build/lab/lab-segments-base" LAB_INSERTED=1 LAB_PRODUCED=1
for k in "$@"; do
  [ -f "build/lab/$k.dai.json" ] && (cd build/lab && python3 ../../Tools/DetectionLab/dai.py cuts "$k" >/dev/null)
  Tools/DetectionLab/lab.sh segments "$k" "$SHOW[$k]" > "build/seg-$k.base.log" 2>&1
  cp "build/lab/$k.detect.txt" "build/lab/$k.base.txt"
  (cd build/lab && python3 ../../Tools/DetectionLab/regression/score.py $k.json $k.base.txt ../../Tools/DetectionLab/regression/$k.json) > "build/seg-$k.base.score" 2>&1
  echo "── $k base: $(grep -E '^per hour' build/seg-$k.base.score)"
done
