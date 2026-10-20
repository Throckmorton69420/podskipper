#!/usr/bin/env python3
"""Pass 44: print transcript lines a–b of one exported episode (for labelling).

    show_lines.py <results.json> <guid prefix> a-b [a-b …]
"""
import json, sys

d = json.load(open(sys.argv[1]))
e = next(e for e in d["episodes"] if e["guid"].startswith(sys.argv[2]))
for r in sys.argv[3:]:
    a, b = map(int, r.split("-"))
    print(f"---- {a}-{b}")
    for i in range(a, min(b, len(e["transcript"]) - 1) + 1):
        l = e["transcript"][i]
        print(f"{i} {l['start'] / 60:.1f}m {l['text'].strip()[:220]}")
