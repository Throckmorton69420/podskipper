#!/usr/bin/env python3
"""Cross-show repeats: for each fixture, which stretches also play in another
show's episode (fixtures and their previous episodes). Pass 19 measurement for
the cross-show fingerprint library. Run in build/lab."""
import json, subprocess, sys, os
SHOW = {'stav199': 'stav', 'mssp633': 'mssp', 'mssp636': 'mssp', 'los952': 'los', 'los956': 'los',
        'ymh1': 'ymh', 'bears1': 'bears', 'badf1': 'badf', 'theo1': 'theo', 'wg1': 'wg', 'afs2': 'afs'}
keys = sys.argv[1:] or list(SHOW)
pool = [k for k in SHOW] + [k + 'p' for k in SHOW if os.path.exists(k + 'p.mp3') or os.path.exists(k + 'p.lm.bin')]
def show_of(k):
    return SHOW.get(k, SHOW.get(k[:-1], k))
def regions(key):
    try:
        return json.load(open(key + '.regions.json'))
    except Exception:
        return []
for key in keys:
    others = [o for o in pool if show_of(o) != show_of(key)]
    found = []
    for o in others:
        r = subprocess.run(['./lab-prints', 'pair', key, o], capture_output=True, text=True)
        path = f'{key}.pair-{o}.json'
        if os.path.exists(path):
            for x in json.load(open(path)):
                if x['end'] - x['start'] >= 8:
                    found.append((x['start'], x['end'], o, x['votes']))
            os.remove(path)
    found.sort()
    regs = regions(key)
    print(f'== {key}: {len(found)} cross-show repeats')
    for s, e, o, v in found:
        lab = [r for r in regs if isinstance(r, dict) and r.get('start', 0) < e and r.get('end', 0) > s]
        names = ','.join(f"{r.get('id')}:{r.get('label')}" for r in lab)
        print(f'  {int(s)//60}:{int(s)%60:02d}-{int(e)//60}:{int(e)%60:02d} ({e-s:.0f}s) in {o} votes {v}  | {names}')
