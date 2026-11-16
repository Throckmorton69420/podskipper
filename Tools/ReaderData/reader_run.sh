#!/bin/zsh
# Pass 65 rule 5 (build/p65/ship-rule-5.txt): stage 1 on Pass 58's SponsorBlock episodes + the SPoRC pairs, then the
# shipped recipe from it (show-held-out folds on the phone-1029 export), then step A against Pass 58's ext13/ext17.
#   reader_run.sh <suffix> <episodes.json[,…]> step…     steps: pre sx13 sx17 stepa stepb
cd /Users/shashankpandya/Developer/podskipper
setopt PIPE_FAIL
# One training run at a time on this Mac (Pass 65: three copies of route 1 started 14 Nov and trained stage 1 side by
# side on the GPU for 18 h, then two copies retrained sx13sb over each other). A second reader_run.sh waits for the
# first; a lock left by a run that was killed is taken over.
LOCK=$PWD/build/p65/reader_run.lock
mkdir -p build/p65
while ! mkdir $LOCK 2>/dev/null; do
  holder=$(cat $LOCK/pid 2>/dev/null)
  [ -z "$holder" ] && { sleep 3; holder=$(cat $LOCK/pid 2>/dev/null); }
  if [ -n "$holder" ] && kill -0 $holder 2>/dev/null; then
    echo "== $(date '+%d %b %T') waiting: reader_run.sh $(cat $LOCK/what 2>/dev/null) is running (pid $holder)"
    sleep 300
  else
    rm -rf $LOCK
  fi
done
echo $$ > $LOCK/pid; echo "$*" > $LOCK/what
trap 'rm -rf $LOCK' EXIT
export READER_OUT=p65 LAB_SEGMENTS=$PWD/build/p57/lab-segments
R=build/phone-1029/results.json
PY=~/Developer/pk-ml/bin/python
S=$1; EXT=$2; shift 2
# Pass 65 rule 6 run B: PRE = the stage 1 to start from, TWIN13/TWIN17 = the runs step A compares with; TEACHER (if set
# in the environment) gives his unlabelled episodes the teacher's silver labels in stage 2.
PRE=${PRE:-$PWD/build/p65/pre13$S.pt}; TWIN13=${TWIN13:-build/p58/ext13}; TWIN17=${TWIN17:-build/p58/ext17}
for step in "$@"; do
  echo "== $step$S $(date +%T)"
  case $step in
    pre) EXTERNAL=$EXT SEEDS=13 PRE_EPOCHS=${PRE_EPOCHS:-2} $PY -I -u Tools/DetectionLab/reader_distill.py pretrain build/p65/pre13$S.pt 2>&1 | grep --line-buffered -v "Loading weights" ;;
    sx13) INIT=$PRE SEEDS=13 $PY -I -u Tools/DetectionLab/reader_distill.py showfolds $R sx13$S 3 2>&1 | grep --line-buffered -v "Loading weights" ;;
    sx17) INIT=$PRE SEEDS=17 $PY -I -u Tools/DetectionLab/reader_distill.py showfolds $R sx17$S 3 2>&1 | grep --line-buffered -v "Loading weights" ;;
    stepa)
      $PY -I Tools/ReaderData/frontier.py build/p65/frontier$S.json ext13=$TWIN13 ext17=$TWIN17 sx13=build/p65/sx13$S sx17=build/p65/sx17$S \
        --deltas=-0.5,0,0.5,1,1.5,2,2.5,3,4 --bin build/p57/lab-segments --results $R --gaps > build/p65/frontier$S.txt 2>&1
      grep -E "^(ext1|sx1)" build/p65/frontier$S.txt
      python3 -I Tools/ReaderData/rule_matched.py build/p65/frontier$S.txt | tee build/p65/matched$S.txt ;;
    stepb)   # rule 4/6 step B: a HOLD_TEST pair from the same stage 1, delivery heads, parity, the 11 test episodes
      OUT=build/p65/final$S
      HOLD_TEST=1 INIT=$PRE SEEDS=13,17 $PY -I -u Tools/DetectionLab/reader_distill.py train build/phone-1031b/results.json final$S 2>&1 \
        | grep --line-buffered -v "Loading weights\|UNEXPECTED\|Notes\|^- \|Key \|^--\|discriminator_\|^$"
      for n in 1 2; do
        TAG=final$S-style-$n $PY -I -u Tools/DetectionLab/tagger.py style $OUT/model-$n.pt $OUT/TaggerWeights-$n.bin 2>&1 | grep -E "AUC|wrote|delivery examples"
      done
      TAG=final$S-dump $PY -I Tools/DetectionLab/tagger.py dump $OUT/model-1.pt bears1 $OUT/dump-py.json 2>&1 | tail -1
      LAB_TAGGER=$PWD/$OUT/TaggerWeights-1.bin LAB_TAGDUMP=$PWD/$OUT/dump-swift.json build/p57/lab-segments build/lab/bears1.json "" "" "" | tail -1
      python3 -I -c "
import json, numpy as np
a=np.array([r[2:] for r in json.load(open('$OUT/dump-py.json'))]); b=np.array([r[2:] for r in json.load(open('$OUT/dump-swift.json'))])
print('parity: sentences', len(a), len(b), 'max |dp|', float(np.abs(a-b).max()), 'argmax agree', float((a.argmax(1)==b.argmax(1)).mean()))"
      LAB_SEGMENTS=$PWD/build/p64/lab-segments $PY -I Tools/ReaderData/test_cuts.py build/p65/test-cuts-$S.json test \
        reader:shipped=$(ls $PWD/Resources/Detection/TaggerWeights.bin $PWD/Resources/Detection/TaggerWeights-[234].bin | paste -sd: -) \
        reader:final$S=$PWD/$OUT/TaggerWeights-1.bin:$PWD/$OUT/TaggerWeights-2.bin > build/p65/test-cuts-$S.log 2>&1
      # The heard / show-cut table step B is judged on is compare.py's (gaps EITHER); test_cuts.py only writes
      # the cuts (Pass 65: judging its log found no table). The PodSkipper test is reported beside it.
      $PY -I Tools/ReaderData/compare.py test shipped=build/p65/test-cuts-$S.json:shipped \
        final$S=build/p65/test-cuts-$S.json:final$S --gaps --shows > build/p65/compare-$S.txt 2>&1
      $PY -I Tools/ReaderData/podtest.py test shipped=build/p65/test-cuts-$S.json:shipped \
        final$S=build/p65/test-cuts-$S.json:final$S > build/p65/podtest-$S.txt 2>&1
      $PY -I Tools/ReaderData/sb_scale.py judge-b build/p65/compare-$S.txt | tee build/p65/stepb-$S.txt
      grep -E "^\| (shipped|final$S) " build/p65/podtest-$S.txt | tee -a build/p65/stepb-$S.txt ;;
    *) echo "unknown $step" ;;
  esac
done
echo "== done $(date +%T)"
