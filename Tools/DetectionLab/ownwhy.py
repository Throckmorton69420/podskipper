#!/usr/bin/env python3
"""Pass 25: where the seconds went for one run of ownlab.sh, fixture by
fixture — each labelled promotion's seconds heard and each cut's seconds of
show skipped, with the words, largest first.

    ownwhy.py <out dir> [key…] [--min 5]
"""
import json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SKIP = {"ADVERTISEMENT", "SELF_PROMOTION", "NETWORK_PROMOTION", "INTRO", "OUTRO", "CREDITS"}
KINDS = {"ad": "ADVERTISEMENT", "selfPromo": "SELF_PROMOTION", "crossPromo": "NETWORK_PROMOTION",
         "intro": "INTRO", "outro": "OUTRO", "credits": "CREDITS"}

def clock(s):
    s = int(round(s)); return "%d:%02d:%02d" % (s // 3600, s % 3600 // 60, s % 60)

def cuts(path):
    out = []
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):([\d.]+)–(\d+):(\d+):([\d.]+)", open(path).read(), re.M):
        k, h1, m1, s1, h2, m2, s2 = m.groups()
        out.append((k, int(h1) * 3600 + int(m1) * 60 + float(s1), int(h2) * 3600 + int(m2) * 60 + float(s2)))
    return out

def ov(a0, a1, b0, b1): return max(0.0, min(a1, b1) - max(a0, b0))

def words(lines, a, b, n=160):
    t = " ".join(l["text"] for l in lines if l["end"] > a and l["start"] < b)
    return (t[:n] + "…") if len(t) > n else t

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    floor = 5.0
    if "--min" in sys.argv: floor = float(sys.argv[sys.argv.index("--min") + 1])
    out = args[0]
    keys = args[1:] or sorted(f[:-11] for f in os.listdir(out) if f.endswith(".detect.txt"))
    for key in keys:
        fx = os.path.join(ROOT, "Tools", "DetectionLab", "regression", key + ".json")
        if not os.path.exists(fx): continue
        dump = os.path.join(out, key + ".regions-resolved.json")
        subprocess.run([sys.executable, os.path.join(ROOT, "Tools", "DetectionLab", "regression", "score.py"),
                        os.path.join(out, key + ".json"), os.path.join(out, key + ".detect.txt"), fx],
                       capture_output=True, env=dict(os.environ, SCORE_DUMP=dump))
        regions = json.load(open(dump))
        lines = json.load(open(os.path.join(out, key + ".json")))
        cs = cuts(os.path.join(out, key + ".detect.txt"))
        rows = []
        for r in regions:
            if r["label"] not in SKIP: continue
            got = sum(ov(r["start"], r["end"], c[1], c[2]) for c in cs)
            heard = (r["end"] - r["start"]) - got
            if heard >= floor:
                rows.append((heard, "HEARD  ", r["id"], r["start"], r["end"], words(lines, r["start"], r["end"])))
        ok = [(r["start"], r["end"]) for r in regions if r["label"] in SKIP or r["label"] == "EITHER"]
        for k, a, b in cs:
            extra = (b - a) - sum(ov(a, b, x, y) for x, y in ok)
            if extra >= floor:
                # The show parts of the cut.
                show = [(max(a, x), min(b, y)) for x, y in [(a, b)]]
                rows.append((extra, "SKIPPED", k, a, b, words(lines, a, b)))
        print("== %s" % key)
        for s, what, name, a, b, w in sorted(rows, reverse=True):
            print("  %s %5.0fs %-18s %s–%s  %s" % (what, s, name, clock(a), clock(b), w))

if __name__ == "__main__":
    main()
