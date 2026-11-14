#!/usr/bin/env python3
"""Pass 65 rule 5 step A: show cut at matched heard 40/44 s/h (interpolated along delta) for sx13/sx17 against
Pass 58's ext13/ext17, and the verdict. matched.py <frontier output text>"""
import re, sys, collections
rows = collections.defaultdict(list)
for line in open(sys.argv[1]):
    m = re.match(r"(\S+)@(-?[\d.]+)\s+\d+\s+([\d.]+) \([^)]*\)\s+([\d.]+) \(", line)
    if m:
        rows[m.group(1)].append((float(m.group(2)), float(m.group(3)), float(m.group(4))))
def at(points, target):
    pts = sorted(points, key=lambda p: p[1])
    for (d1, h1, s1), (d2, h2, s2) in zip(pts, pts[1:]):
        if h1 <= target <= h2 and h2 > h1:
            return s1 + (s2 - s1) * (target - h1) / (h2 - h1)
    return None
res = {name: {t: at(pts, t) for t in (40, 44)} for name, pts in sorted(rows.items())}
for name, v in res.items():
    print(name, {t: (round(x, 2) if x is not None else None) for t, x in v.items()})
gains = {}
for new, old in (("sx13", "ext13"), ("sx17", "ext17")):
    if new in res and old in res:
        gains[new] = {t: (res[old][t] - res[new][t]) if None not in (res[old][t], res[new][t]) else None for t in (40, 44)}
        print(new, "vs", old, {t: (round(g, 2) if g is not None else None) for t, g in gains[new].items()}, "(positive = less show cut)")
if len(gains) == 2 and all(g is not None for v in gains.values() for g in v.values()):
    both = all(g > 0 for v in gains.values() for g in v.values())
    mean = {t: sum(v[t] for v in gains.values()) / 2 for t in (40, 44)}
    ok = both and all(m >= 1.0 for m in mean.values())
    print("mean gain", {t: round(m, 2) for t, m in mean.items()}, "→ step A", "PASSES" if ok else "FAILS")
else:
    print("step A: not every point reached heard 40/44 — FAILS (reported)")
