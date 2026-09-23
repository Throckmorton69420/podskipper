#!/usr/bin/env python3
"""Where each second of ad heard (or show skipped) was lost, stage by stage,
from the detector's own log in <key>.detect.txt and the fixture's regions.

    why.py <key>...        (run anywhere; reads build/lab)
"""
import json, os, re, sys

SKIP = {"ADVERTISEMENT", "SELF_PROMOTION", "NETWORK_PROMOTION", "INTRO", "OUTRO", "CREDITS"}
T = r"(\d+):(\d\d):(\d\d)"

def secs(h, m, s): return int(h) * 3600 + int(m) * 60 + int(s)

def spans(log, pattern):
    out = []
    for line in log:
        m = re.search(pattern + r".*?" + T + "–" + T, line)
        if m: out.append((secs(*m.groups()[-6:-3]), secs(*m.groups()[-3:]), line.strip()))
    return out

def overlap(a0, a1, b0, b1): return max(0, min(a1, b1) - max(a0, b0))

def main(key):
    lab = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "lab")
    text = open(os.path.join(lab, key + ".detect.txt")).read()
    log = text.split("---- log ----")[-1].splitlines()
    regions = json.load(open(os.path.join(lab, key + ".regions.json")))
    hits = spans(log, r"^hit ")
    reads = spans(log, r"^read ")
    labelled = spans(log, r"^span \w+")
    verifies = spans(log, r"^verify ")
    finals = spans(log, r"^final \w+")
    drops = [l for l in log if "dropped" in l]
    print(f"== {key}")
    for r in regions:
        a, b = r["start"], r["end"]
        cut = sum(overlap(a, b, f[0], f[1]) for f in finals)
        if r["label"] in SKIP and r.get("delivery") != "inserted":
            heard = (b - a) - cut
            if heard < 4: continue
            stage = ("never screened" if not any(overlap(a, b, h[0], h[1]) for h in hits) else "screened")
            stage += ", read" if any(overlap(a, b, x[0], x[1]) > 0.5 * (b - a) for x in reads) else ", NOT read"
            sp = [x[2] for x in labelled if overlap(a, b, x[0], x[1])]
            ve = [x[2] for x in verifies if overlap(a, b, x[0], x[1])]
            dr = [d for d in drops if any(f"{h}:{m}" in d for h, m in [(int(a) // 3600, f"{int(a) % 3600 // 60:02d}")])]
            print(f"  HEARD {heard:5.0f}s {r['id']:<18} {r['label']:<17} {int(a)//60}:{int(a)%60:02d} | {stage}")
            for s in sp[:4]: print(f"      {s}")
            for s in ve[:4]: print(f"      {s}")
    # Every cut second outside skippable or either-way regions is show skipped.
    ok = [(r["start"], r["end"]) for r in regions if r["label"] in SKIP or r["label"] == "EITHER"]
    for f in finals:
        a, b = f[0], f[1]
        inside = sum(overlap(a, b, x, y) for x, y in ok)
        extra = (b - a) - inside
        if extra > 2:
            print(f"  SKIPPED {extra:4.0f}s of cut {f[2][6:60]}")

if __name__ == "__main__":
    for k in sys.argv[1:]: main(k)
