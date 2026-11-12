#!/usr/bin/env python3
"""Pass 63: his corrections, as the learner's gold requests.

    gold_requests.py <results export.json> <out.json>

One entry per corrected episode of a Results export: its transcript, the
correction ledger as exported, and the episode's cuts as they stand (not ones
marked Not an Ad) — what `CorrectionLedger` hands `OnDeviceReaderLearner`.
The output holds his transcripts: it stays in build/ (git-ignored).
"""
import json, sys

src, out = sys.argv[1], sys.argv[2]
rows = []
for e in json.load(open(src))["episodes"]:
    if not e.get("corrections") or not e.get("transcript"):
        continue
    rows.append({
        "episode": e["guid"], "show": e["show"], "title": e["title"],
        "transcript": [{"text": l["text"], "start": l["start"], "end": l["end"],
                        "words": [{"text": w["text"], "start": w["start"], "end": w["end"]} for w in l.get("words") or []]}
                       for l in e["transcript"]],
        "corrections": e["corrections"],
        "current": [{"start": s["start"], "end": s["end"], "kind": s["kind"]}
                    for s in e.get("segments") or [] if s.get("verdict") != "notAnAd"],
    })
json.dump(rows, open(out, "w"))
print(f"{len(rows)} corrected episodes, {sum(len(r['corrections']) for r in rows)} corrections -> {out}")
