#!/bin/zsh
# Pass 65 route 1 end to end, in the background, no Claude needed (build/p65/ship-rule-6.txt):
#   select → fetch audio (yt-dlp, first 90 min) → transcribe (the app's TranscriptionService) → label from
#   SponsorBlock's human marks → stage 1 on sb58 + sb65 → the shipped recipe → step A → step B → REPORT.txt
#
#   Tools/ReaderData/sb_scale_run.sh [dir]        default ~/Developer/pk-data/sb65 (on the drive)
#   FETCHERS=3 TRANSCRIBERS=4 LIMIT=0 ...         workers; LIMIT>0 stops fetching after that many new episodes
#
# Resumable: run the same command again after a restart or Ctrl-C; finished files and steps are skipped.
# Needs: the drive mounted, ffmpeg + deno (Homebrew), yt-dlp[default] in ~/Developer/pk-ml.
setopt NULL_GLOB
set -u
ROOT=~/Developer/podskipper
D=${1:-$HOME/Developer/pk-data/sb65}
PY=~/Developer/pk-ml/bin/python
FETCHERS=${FETCHERS:-3}; TRANSCRIBERS=${TRANSCRIBERS:-4}; LIMIT=${LIMIT:-0}
export PATH=/opt/homebrew/bin:$PATH
export SSL_CERT_FILE=$($PY -c 'import certifi;print(certifi.where())')
mkdir -p $D/audio $D/tx $D/raw $D/logs $ROOT/build/p65
cd $D
say() { echo "== $(date '+%d %b %H:%M:%S') $*"; }

[ -d "/Volumes/Samsung PSSD T9 Media" ] || { echo "The drive isn't mounted."; exit 1; }
for tool in ffmpeg deno; do command -v $tool >/dev/null || { echo "$tool missing: brew install $tool"; exit 1; }; done

if [ ! -f picks.json ]; then say select; $PY -I $ROOT/Tools/ReaderData/sb_scale.py select $D || exit 1; fi

fetch_worker() {   # $1 = worker, of $FETCHERS
  local w=$1 i=0 got=0
  for v in $($PY -I -c "import json;print(' '.join(json.load(open('picks.json'))))"); do
    i=$((i+1)); [ $(( i % FETCHERS )) -ne $w ] && continue
    [ "$LIMIT" -gt 0 ] && [ $(ls audio/*.m4a 2>/dev/null | wc -l) -ge $LIMIT ] && break
    [ -f "audio/$v.m4a" ] && continue
    grep -q "^FAILED $v" logs/fetch*.log 2>/dev/null && continue
    rm -f raw/$v.*
    if ~/Developer/pk-ml/bin/yt-dlp -q --no-progress --no-playlist --sleep-requests 1 \
        -f "bestaudio[ext=m4a][abr<=80]/worstaudio[ext=m4a]/worstaudio" -o "raw/$v.%(ext)s" -- "$v" 2>>logs/fetch.err; then
      f=$(ls raw/$v.* | head -1)
      if [[ $f == *.m4a ]]; then ffmpeg -nostdin -loglevel error -y -i "$f" -t 5400 -vn -c copy "audio/$v.tmp.m4a"
      else ffmpeg -nostdin -loglevel error -y -i "$f" -t 5400 -vn -ac 1 -c:a aac -b:a 64k "audio/$v.tmp.m4a"; fi \
        && mv "audio/$v.tmp.m4a" "audio/$v.m4a" && echo "got $v $(date +%T)"
      rm -f "$f"
      sleep 2   # paced: one worker asks YouTube at most every few seconds
    else
      echo "FAILED $v"
      # Many failures in a row means YouTube is refusing: wait it out rather than burn the list.
      if [ $(tail -5 logs/fetch$w.log 2>/dev/null | grep -c "^FAILED") -ge 5 ]; then echo "pausing 30 min $(date +%T)"; sleep 1800; fi
    fi
  done
  echo DONE
}

tx_worker() {      # $1 = worker, of $TRANSCRIBERS; ends when every fetcher is done and nothing is left
  local w=$1
  while true; do
    local did=0
    for f in audio/*.m4a; do
      local v=${f:t:r}; [[ $v == *.tmp ]] && continue
      [ $(( $(printf "%d" "'${v[1]}") % TRANSCRIBERS )) -ne $w ] && continue
      [ -f "tx/$v.json" ] && continue
      ~/Developer/pk-data/bin/lab-transcribe "$f" "tx/$v.json.tmp" 2>/dev/null | tail -1 | sed "s/^/$v /"
      [ -s "tx/$v.json.tmp" ] && mv "tx/$v.json.tmp" "tx/$v.json"
      did=1
    done
    if [ $did = 0 ]; then
      [ $(ls logs/fetch*.done 2>/dev/null | wc -l) -ge $FETCHERS ] && { echo ALLDONE; break; }
      sleep 60
    fi
  done
}

if [ ! -f logs/transcribed.done ]; then
  say "fetch ($FETCHERS) + transcribe ($TRANSCRIBERS) — $($PY -I $ROOT/Tools/ReaderData/sb_scale.py status $D)"
  for w in $(seq 0 $((FETCHERS-1))); do
    [ -f logs/fetch$w.done ] || { fetch_worker $w >> logs/fetch$w.log 2>&1; touch logs/fetch$w.done; } &
  done
  for w in $(seq 0 $((TRANSCRIBERS-1))); do
    { tx_worker $w >> logs/tx$w.log 2>&1; } &
  done
  wait
  touch logs/transcribed.done
fi
say "transcribed — $($PY -I $ROOT/Tools/ReaderData/sb_scale.py status $D)"

if [ ! -f episodes.json ] || [ episodes.json -ot logs/transcribed.done ]; then
  say label; $PY -I $ROOT/Tools/ReaderData/sponsorblock_episodes.py $D | tail -1
fi

EXT=$HOME/Developer/pk-data/sb58/episodes.json,$D/episodes.json
R=$ROOT/Tools/ReaderData/reader_run.sh
cd $ROOT
[ -f build/p65/pre13sb.pt ] || { say "stage 1"; zsh $R sb $EXT pre; }
[ -f build/p65/sx13sb/done ] || { say "recipe seed 13"; zsh $R sb $EXT sx13 && touch build/p65/sx13sb/done; }
[ -f build/p65/sx17sb/done ] || { say "recipe seed 17"; zsh $R sb $EXT sx17 && touch build/p65/sx17sb/done; }
[ -f build/p65/matchedsb.txt ] || { say "step A"; zsh $R sb $EXT stepa; }
if grep -q "step A PASSES" build/p65/matchedsb.txt 2>/dev/null; then
  [ -f build/p65/stepb-sb.txt ] || { say "step B"; zsh $R sb $EXT stepb; }
else
  say "step A did not pass; step B not run (rule 6)"
fi
$PY -I Tools/ReaderData/sb_scale.py report $D
say "finished"
