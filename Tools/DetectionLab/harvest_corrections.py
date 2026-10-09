#!/usr/bin/env python3
"""Pass 32: collect what he actually settled on his phone, as labels.

    harvest_corrections.py <results export.json> [more exports…] [--out DIR]

Reads the ad-finding results exports (Settings → Diagnostics → Prepare
Ad-Finding Results) and keeps ONLY his own decisions — the stretches he
locked, edited, added, confirmed or marked "not an ad" — with the original
predictions they were graded against and the words they cover. A model's
or the reader's output is never written as a label; it is kept only as the
prediction a label was compared with.

Writes one JSON file per episode (merged across exports, newest decision for
a stretch wins) and prints how much labelled material exists per show, so a
decision to retrain the reader can be made on the numbers (spec D07: only
with reliable corrections across diverse, held-out shows).
"""
import json, os, sys, argparse, collections

ap = argparse.ArgumentParser()
ap.add_argument('exports', nargs='+')
ap.add_argument('--out', default=os.path.join(os.path.dirname(__file__), 'corrections'))
args = ap.parse_args()
os.makedirs(args.out, exist_ok=True)

def words(transcript, start, end):
    return ' '.join(l['text'].strip() for l in transcript if l['end'] > start and l['start'] < end)

episodes = {}
for path in args.exports:
    data = json.load(open(path))
    build = data.get('build', '?')
    for e in data.get('episodes', []):
        corr = e.get('corrections') or []
        # Pass 33: decisions made before the correction ledger existed (his
        # 5 Oct review of LoS "Pete Lee & Jeremiah Watkins": 6 confirmed, 1
        # not an ad, 4 locked) live only on the stretches themselves. Only a
        # verdict he gave or a lock he set counts; an edge that moved on its
        # own (the reader's fingerprint refinement) is not his decision.
        segment_decisions = [s for s in e.get('segments') or []
                             if s.get('verdict') in ('confirmed', 'notAnAd') or s.get('locked')]
        if not corr and not segment_decisions:
            continue
        key = e.get('guid') or e['title']
        rec = episodes.setdefault(key, dict(guid=key, show=e['show'], title=e['title'], duration=e.get('duration'),
                                            labels={}, sources=[]))
        rec['sources'].append(dict(file=os.path.basename(path), build=build, exportedAt=data.get('exportedAt')))
        tr = e.get('transcript') or []
        for c in corr:
            label = dict(action=c['action'], start=c['start'], end=c['end'], kind=c['kind'],
                         contains=c.get('contains', []), date=c['date'], finder=c.get('finder', ''),
                         grade=c.get('grade'), predictions=c.get('predictions', []),
                         words=words(tr, c['start'], c['end'])[:4000], provenance='user', build=build)
            old = rec['labels'].get(c['key'])
            if old is None or old['date'] <= c['date']:
                rec['labels'][c['key']] = label
        ledger_spans = [(c['start'], c['end']) for c in corr]
        for s in segment_decisions:
            # A stretch the ledger already holds is not counted twice.
            if any(min(b, s['end']) - max(a, s['start']) > 0.5 * (s['end'] - s['start']) for a, b in ledger_spans):
                continue
            action = 'notAnAd' if s.get('verdict') == 'notAnAd' else ('lock' if s.get('locked') else 'confirm')
            key = f"segment-{round(s['start'], 1)}-{round(s['end'], 1)}"
            rec['labels'].setdefault(key, dict(
                action=action, start=s['start'], end=s['end'], kind=s['kind'], contains=s.get('contains', []),
                date=e.get('processedAt') or '', finder=s.get('stage', ''), grade=None,
                predictions=[dict(start=s.get('detectedStart'), end=s.get('detectedEnd'), kind=s.get('detectedKind'))],
                words=words(tr, s['start'], s['end'])[:4000], provenance='user (stretch verdict, before the ledger)',
                build=build))

per_show = collections.defaultdict(lambda: collections.Counter())
for key, rec in episodes.items():
    rec['labels'] = sorted(rec['labels'].values(), key=lambda l: l['start'])
    name = ''.join(ch if ch.isalnum() else '_' for ch in key)[-80:]
    json.dump(rec, open(os.path.join(args.out, name + '.json'), 'w'), indent=1)
    for l in rec['labels']:
        per_show[rec['show']][l['action']] += 1
        per_show[rec['show']]['seconds'] += int(l['end'] - l['start'])

print(f"{len(episodes)} episodes with decisions of his")
for show, c in sorted(per_show.items()):
    acts = ', '.join(f"{k} {v}" for k, v in sorted(c.items()) if k != 'seconds')
    print(f"  {show}: {acts} · {c['seconds']} s settled")
