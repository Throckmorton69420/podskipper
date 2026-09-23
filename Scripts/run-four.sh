#!/bin/zsh
#
# Run the detection lab on the six fixtures (four shows) and score each.
#
#   ./Scripts/run-four.sh            all six
#   ./Scripts/run-four.sh stav199    just one fixture
#
# Real show names are passed on purpose: the prompts include the show title,
# and an empty title once looked like a regression.
# Output: build/seg-<fixture>.log. Tuning via LAB_SIZE, LAB_STEP, LAB_PAD,
# LAB_CUEPAD, LAB_WALK, LAB_PAR in the environment.
# Runs in the foreground; start it with Desktop Commander's start_process.
cd "$(dirname "$0")/.."
mkdir -p build
typeset -A SHOW
SHOW=(mssp633 "Matt and Shane's Secret Podcast"
      mssp636 "Matt and Shane's Secret Podcast"
      stav199 "Stavvy's World"
      los952  "Legion of Skanks"
      los956  "Legion of Skanks"
      conanjm "Conan O'Brien Needs A Friend")
run() {
  echo "── $1 ($SHOW[$1])"
  Tools/DetectionLab/lab.sh segments "$1" "$SHOW[$1]" > "build/seg-$1.log" 2>&1
  Tools/DetectionLab/lab.sh score "$1" >> "build/seg-$1.log" 2>&1
  grep -E "^(PASS|FAIL|  (PASS|FAIL)|work:|per cut|edges:|per hour)|failing" "build/seg-$1.log"
}
if [ $# -gt 0 ]; then for f in "$@"; do run "$f"; done
else for f in mssp633 mssp636 stav199 los952 los956 conanjm; do run "$f"; done; fi
