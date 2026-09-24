#!/usr/bin/env python3
"""Pass 19: simulate the cross-show print library in the lab.

For each fixture, the library is every labelled ad/promo region of the OTHER
shows' fixtures (what the app would have confirmed there), fingerprinted.
Matches of this fixture against those regions are added to <key>.produced.json
as {"library": true} entries (originals kept as <key>.produced.orig.json).
  python3 libsim.py make     build augmented files
  python3 libsim.py restore  put the originals back
Run in build/lab."""
import json, subprocess, sys, os, shutil
SHOW = {'stav199': 'stav', 'mssp633': 'mssp', 'mssp636': 'mssp', 'los952': 'los', 'los956': 'los',
        'ymh1': 'ymh', 'bears1': 'bears', 'badf1': 'badf', 'theo1': 'theo', 'wg1': 'wg', 'afs2': 'afs'}
KEEP = {'ADVERTISEMENT', 'NETWORK_PROMOTION', 'SELF_PROMOTION', 'INTRO', 'OUTRO'}
def ad_regions(k):
    try:
        return [(r['start'], r['end'], r['label']) for r in json.load(open(k + '.regions.json'))
                if isinstance(r, dict) and r.get('label') in KEEP]
    except Exception:
        return []
mode = sys.argv[1]
for key in SHOW:
    orig, cur = key + '.produced.orig.json', key + '.produced.json'
    if mode == 'restore':
        if os.path.exists(orig): shutil.move(orig, cur)
        continue
    if not os.path.exists(orig): shutil.copy(cur, orig)
    base = json.load(open(orig))
    extra = []
    for other in SHOW:
        if SHOW[other] == SHOW[key]: continue
        regs = ad_regions(other)
        subprocess.run(['./lab-prints', 'pair', key, other], capture_output=True)
        path = f'{key}.pair-{other}.json'
        if not os.path.exists(path): continue
        for x in json.load(open(path)):
            off = x['offset']
            s2, e2 = x['start'] + off, x['end'] + off
            hit = [r for r in regs if min(e2, r[1]) - max(s2, r[0]) > 0.5 * (e2 - s2)]
            if hit and x['end'] - x['start'] >= 8:
                kinds = {'ADVERTISEMENT': 'ad', 'NETWORK_PROMOTION': 'crossPromo', 'SELF_PROMOTION': 'selfPromo',
                         'INTRO': 'intro', 'OUTRO': 'outro'}
                extra.append({'start': x['start'], 'end': x['end'], 'acrossEpisodes': True, 'known': kinds[hit[0][2]]})
        os.remove(path)
    print(key, len(extra), [(round(e['start']), round(e['end']), e['known']) for e in extra])
    json.dump(base + extra, open(cur, 'w'), indent=1)
