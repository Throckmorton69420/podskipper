#!/bin/zsh
# Fetch a lab episode in 16 MB range requests from its final address (some
# hosts end a single long download after a few minutes). Lab only.
k=$1; cd ~/Developer/podskipper/build/lab
UA="Podcasts/1740.2 CFNetwork/3826.500.62.2.1 Darwin/24.0.0"
final=$(curl -sSL -A "$UA" -r 0-0 -o /dev/null -w '%{url_effective}' "$(cat $k.url)")
total=$(curl -sSL -A "$UA" -r 0-0 -D - -o /dev/null "$final" | grep -i '^content-range' | tail -1 | sed -E 's/.*\///' | tr -d '\r')
echo "$k final=${final:0:80} total=$total"
rm -f $k.mp3.part; start=0; step=16000000
while [ $start -lt $total ]; do
  end=$((start + step - 1)); [ $end -ge $total ] && end=$((total - 1))
  for try in 1 2 3; do
    curl -sS -A "$UA" -r $start-$end "$final" -o $k.chunk && [ $(stat -f %z $k.chunk) -eq $((end - start + 1)) ] && break
    sleep 2
  done
  cat $k.chunk >> $k.mp3.part; start=$((end + 1))
done
rm -f $k.chunk; mv $k.mp3.part $k.mp3; ls -la $k.mp3; echo RANGEDONE
