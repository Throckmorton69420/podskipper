#!/usr/bin/env python3
"""Pass 57: apply LABEL-POLICY.md v2 fixes to phone-labels files, keeping the
history: each changed file gets "policy": 2 and a "revisions" entry naming
the rule, the lines and what they were before. Regions are line ranges of
the export the file names; a fix replaces whatever covered those lines.

    relabel.py <guid prefix> <rule> <first>-<last>=<LABEL>[,…]
"""
import json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LABELS = os.path.join(os.path.dirname(HERE), "DetectionLab", "phone-labels")


def find(prefix):
    for n in sorted(os.listdir(LABELS)):
        d = json.load(open(os.path.join(LABELS, n)))
        if d["guid"].startswith(prefix) or n.startswith(prefix):
            return os.path.join(LABELS, n), d
    raise SystemExit("no label file for " + prefix)


def apply(d, first, last, label, rule):
    before = [dict(r) for r in d["regions"] if "lines" in r and r["lines"][1] >= first and r["lines"][0] <= last]
    kept = []
    for r in d["regions"]:
        if "lines" not in r or r["lines"][1] < first or r["lines"][0] > last:
            kept.append(r); continue
        a, b = r["lines"]
        if a < first:
            kept.append(dict(r, lines=[a, first - 1]))
        if b > last:
            kept.append(dict(r, id=r["id"] + "b", lines=[last + 1, b]))
    new = {"id": f"v2-{first}", "label": label, "lines": [first, last], "note": f"policy 2: {rule}"}
    kept.append(new)
    kept.sort(key=lambda r: (r["lines"][0] if "lines" in r else r.get("start", 0)))
    d["regions"] = kept
    return before


if __name__ == "__main__":
    prefix, rule, specs = sys.argv[1], sys.argv[2], sys.argv[3]
    path, d = find(prefix)
    rev = {"policy": 2, "when": time.strftime("pass 57, %d %b %Y"), "rule": rule, "changes": []}
    for spec in specs.split(","):
        rng, label = spec.split("=")
        a, b = map(int, rng.split("-"))
        rev["changes"].append({"lines": [a, b], "label": label, "before": apply(d, a, b, label, rule)})
    d["policy"] = 2
    d.setdefault("revisions", []).append(rev)
    json.dump(d, open(path, "w"), indent=1, ensure_ascii=False)
    print("updated", os.path.basename(path), [c["lines"] + [c["label"]] for c in rev["changes"]])
