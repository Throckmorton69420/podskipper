#!/usr/bin/env python3
"""Totals over fixtures from the SUMMARY lines: python3 totals.py [suffix]
suffix '' reads build/seg-<k>.log, 'base' reads build/seg-<k>.base.score."""
import json, sys, re
keys = ['stav199', 'mssp633', 'mssp636', 'los952', 'los956', 'ymh1', 'bears1', 'badf1', 'theo1', 'wg1', 'afs2']
suffix = sys.argv[1] if len(sys.argv) > 1 else ''
H = heard = skipped = 0.0
rows = []
for k in keys:
    path = f'build/seg-{k}.base.score' if suffix == 'base' else f'build/seg-{k}.log'
    m = re.search(r'^SUMMARY (.*)$', open(path).read(), re.M)
    s = json.loads(m.group(1))
    h = s['hours']; H += h
    heard += s['ad_s_heard_per_h'] * h; skipped += s['content_s_skipped_per_h'] * h
    rows.append((k, s['ad_s_heard_per_h'], s['content_s_skipped_per_h'], s['ad_precision'], s['ad_recall'],
                 s['edge_median_s'], s.get('break_precision'), s.get('break_recall')))
for r in rows:
    print('%-8s heard %6.1f  skipped %5.1f  adP %.2f adR %.2f  edge med %.2f  breakP %s breakR %s' % r)
print('ALL %.1f h: heard %.1f s/h, skipped %.1f s/h' % (H, heard / H, skipped / H))
