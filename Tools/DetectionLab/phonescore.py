#!/usr/bin/env python3
"""Scores his phone's own cuts on the episodes that are also lab fixtures.

    phonescore.py build/phone-0929/results.json

For each lab fixture whose episode is in his results export, writes the
phone's transcript and cuts to build/phone-score/<key>.json/.detect.txt and
runs score.py against the fixture's labels. The labels are anchored on words,
so they find their place in the phone's own transcript (its copy of the
episode may have different stitched-in ads than the lab's). Prints heard /
skipped per hour per episode, the detector version that made the cuts and
when."""
import json, os, re, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAB = os.path.join(ROOT, "build", "lab")
OUT = os.path.join(ROOT, "build", "phone-score")
os.makedirs(OUT, exist_ok=True)
norm = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())[:40]
eps = json.load(open(sys.argv[1]))["episodes"]
by_title = {}
for e in eps:
    by_title.setdefault(norm(e["title"]), []).append(e)

def clock(t):
    t = max(0.0, t); return "%d:%02d:%05.2f" % (int(t // 3600), int(t % 3600 // 60), t % 60)

H = heard = skipped = 0.0
for key in sorted(os.listdir(os.path.join(ROOT, "Tools", "DetectionLab", "regression"))):
    if not key.endswith(".json"): continue
    key = key[:-5]
    tpath = os.path.join(LAB, key + ".title")
    if not os.path.exists(tpath): continue
    matches = by_title.get(norm(open(tpath).read().strip()))
    if not matches: continue
    e = max(matches, key=lambda x: x["processedAt"])
    if not e.get("transcript"): continue
    json.dump(e["transcript"], open(os.path.join(OUT, key + ".json"), "w"))
    with open(os.path.join(OUT, key + ".detect.txt"), "w") as f:
        f.write("phone v%s %s\n" % (e.get("detectorVersion"), e["processedAt"]))
        for s in e["segments"]:
            if s.get("verdict") == "notAnAd": continue
            f.write("[%s] %s–%s (%ds)\n" % (s["kind"], clock(s["start"]), clock(s["end"]), round(s["end"] - s["start"])))
    r = subprocess.run([sys.executable, os.path.join(ROOT, "Tools", "DetectionLab", "regression", "score.py"),
                        os.path.join(OUT, key + ".json"), os.path.join(OUT, key + ".detect.txt"),
                        os.path.join(ROOT, "Tools", "DetectionLab", "regression", key + ".json")],
                       capture_output=True, text=True)
    open(os.path.join(OUT, key + ".score.txt"), "w").write(r.stdout)
    m = re.search(r"^SUMMARY (.*)$", r.stdout, re.M)
    s = json.loads(m.group(1)) if m else {}
    if "ad_s_heard_per_h" in s:
        h = s["hours"]; H += h; heard += s["ad_s_heard_per_h"] * h; skipped += s["content_s_skipped_per_h"] * h
        print("%-9s v%-3s %s  heard %6.1f  skipped %6.1f  (%s)" % (key, e.get("detectorVersion"), e["processedAt"][:16],
              s["ad_s_heard_per_h"], s["content_s_skipped_per_h"], e["title"][:50]))
    else:
        print("%-9s v%-3s no score (%s)" % (key, e.get("detectorVersion"), r.stdout.strip().splitlines()[-1:] ))
if H:
    print("ALL %.1f h: heard %.1f s/h, skipped %.1f s/h" % (H, heard / H, skipped / H))
