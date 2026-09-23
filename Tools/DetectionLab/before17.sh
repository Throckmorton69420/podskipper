#!/bin/zsh
# The pass-17 detector (b085d6c) on every fixture, with today's labels, so
# the before/after numbers compare like with like. Lab only.
cd ~/Developer/podskipper
S=build/lab-snapshot-p17; rm -rf $S; mkdir -p $S
git archive b085d6c Services Models Tools/DetectionLab | tar -x -C $S
xcrun swiftc -O -parse-as-library -o build/lab/lab-segments-p17 $S/Tools/DetectionLab/LabSegments.swift \
  $S/Services/SegmentDetector.swift $S/Services/SegmentEvidence.swift $S/Services/TranscriptionService.swift \
  $S/Services/AdDetector.swift $S/Services/FeedbackMemory.swift $S/Models/DetectionTypes.swift 2>&1 | grep error
typeset -A SHOW
SHOW=(stav199 "Stavvy's World" mssp633 "Matt and Shane's Secret Podcast" mssp636 "Matt and Shane's Secret Podcast"
      los952 "Legion of Skanks" los956 "Legion of Skanks" ymh1 "Your Mom's House with Christina P. and Tom Segura"
      bears1 "2 Bears, 1 Cave with Tom Segura & Bert Kreischer" badf1 "Bad Friends" theo1 "This Past Weekend w/ Theo Von"
      wg1 "Whiskey Ginger with Andrew Santino" afs2 "The Adam Friedland Show")
cd build/lab
for k in stav199 mssp633 mssp636 los952 los956 ymh1 bears1 badf1 theo1 wg1 afs2; do
  LAB_INSERTED=1 ./lab-segments-p17 $k.json $k.notes.txt "$SHOW[$k]" "$(cat $k.title)" > $k.detect17.txt 2> $k.detect17.err
  python3 ../../Tools/DetectionLab/regression/score.py $k.json $k.detect17.txt ../../Tools/DetectionLab/regression/$k.json > ../runs/before17-$k.log 2>&1
  echo "── $k: $(grep -E '^per hour' ../runs/before17-$k.log | head -1 | cut -c1-80)"
done
echo BEFOREDONE
