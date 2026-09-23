#!/usr/bin/env python3
"""A readable transcript for labelling: one recognizer line per row with its
start time, plus markers where the ad-free comparison found inserted audio.

    compact.py <key> [out.txt]
"""
import json, os, sys

def clock(s):
    s = float(s); return f"{int(s // 3600)}:{int(s % 3600 // 60):02d}:{int(s % 60):02d}"

key = sys.argv[1]
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "lab"))
lines = json.load(open(key + ".json"))
dai = json.load(open(key + ".dai.json")).get("inserted", []) if os.path.exists(key + ".dai.json") else []
marks = sorted([(s["start"], f"==== INSERTED AUDIO STARTS ({s['seconds']:.0f} s, ends {clock(s['end'])}) ====") for s in dai] +
               [(s["end"], "==== INSERTED AUDIO ENDS ====") for s in dai])
out = []
for l in lines:
    while marks and marks[0][0] <= l["start"] + 0.05:
        out.append(marks.pop(0)[1])
    out.append(f"{clock(l['start'])} {l['text'].strip()}")
out += [m[1] for m in marks]
path = sys.argv[2] if len(sys.argv) > 2 else key + ".txt"
open(path, "w").write("\n".join(out) + "\n")
print(path, len(out), "rows", sum(len(o) for o in out) // 4, "tokens (approx)")
