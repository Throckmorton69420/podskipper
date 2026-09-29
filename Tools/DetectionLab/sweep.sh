#!/bin/zsh
# Pass 25: the own reader's settings, tried on every fixture from tagger.py's
# out-of-fold answers. One line per setting: seconds of ads heard and of the
# show skipped per hour, over all 17 fixtures, then per fixture.
#   Tools/DetectionLab/sweep.sh <tag> "LAB_TAGBOOST=1.5 LAB_SWITCH=2" "…" …
cd "$(dirname "$0")/../.."
TAG="$1"; shift
for setting in "$@"; do
  name="sw-$TAG-$(echo "$setting" | tr ' =' '_-')"
  env ${=setting} OWN_OUT="$name" Tools/DetectionLab/ownlab.sh "$TAG" ${=SWEEP_KEYS:-} > "build/own/$name.out" 2>&1
  all=$(grep '^ALL' "build/own/$name.out")
  per=$(grep -v '^ALL' "build/own/$name.out" | awk '{printf "%s %s/%s  ", $1, $3, $5}')
  echo "$setting :: $all :: $per"
done
