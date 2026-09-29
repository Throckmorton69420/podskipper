#!/usr/bin/env python3
"""Per-fixture and total heard/skipped per hour for fastlab.sh configs, side by side.

    fastsum.py base fast nomodel
"""
import json, re, sys, os
KEYS = ["stav199", "stavb199", "mssp633", "mssp636", "los952", "los956", "los957", "ymh1", "bears1",
        "bears2", "badf1", "theo1", "wg1", "afs2", "ct262", "ct284", "chaos1"]
configs = sys.argv[1:] or ["base", "fast", "nomodel"]
rows, totals = {}, {}
for c in configs:
    H = heard = skipped = q = 0.0
    for k in KEYS:
        path = f"build/fast/lab-{c}/seg-{k}.log"
        if not os.path.exists(path): continue
        m = re.search(r"^SUMMARY (.*)$", open(path).read(), re.M)
        if not m: continue
        s = json.loads(m.group(1))
        if "ad_s_heard_per_h" not in s: continue
        rows.setdefault(k, {})[c] = (s["ad_s_heard_per_h"], s["content_s_skipped_per_h"], s.get("questions") or 0)
        h = s["hours"]; H += h; heard += s["ad_s_heard_per_h"] * h; skipped += s["content_s_skipped_per_h"] * h
        q += s.get("questions") or 0
    if H: totals[c] = (heard / H, skipped / H, q / H, H)
print("%-9s " % "fixture" + "".join("%-24s" % c for c in configs))
for k in KEYS:
    if k not in rows: continue
    print("%-9s " % k + "".join(("%6.1f /%6.1f  q%-5d  " % rows[k][c]) if c in rows[k] else "%-24s" % "-" for c in configs))
print("%-9s " % "ALL" + "".join(("%6.1f /%6.1f  q%-5.0f  " % totals[c][:3]) if c in totals else "%-24s" % "-" for c in configs))
print("(heard / skipped seconds per hour; q = model questions per hour of audio; %s h)" %
      ", ".join("%s %.1f" % (c, totals[c][3]) for c in totals))
