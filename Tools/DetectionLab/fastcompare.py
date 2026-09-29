#!/usr/bin/env python3
"""Compares fast-reader variants (build/fast/oof-<tag>.npz) on the lab labels.

    fastcompare.py <tag> [<tag> …]

Per variant: sentence AUC (promotion vs conversation) over all fixtures, and
for thresholds 0.05/0.15/0.3 the share of labelled regions (by kind) that
would be screened in (some sentence at or above the threshold) and the share
of the episode those screens read (±60 s)."""
import sys, os, json, numpy as np
sys.path.insert(0, os.path.dirname(__file__))
import fastreader as fr
from sklearn.metrics import roc_auc_score

labs = {k: fr.lab_episode(k) for k in fr.KEYS if os.path.exists(os.path.join(fr.LAB, k + ".json"))}
for tag in sys.argv[1:]:
    oof = np.load(os.path.join(fr.OUT, "oof-%s.npz" % tag))
    truth, score = [], []
    reg = {}
    look = {0.05: [0, 0], 0.15: [0, 0], 0.3: [0, 0]}
    for key in oof.files:
        ep = labs[key]; P = oof[key]
        for i, l in enumerate(ep["labels"]):
            if l is None: continue
            truth.append(0 if l == "C" else 1); score.append(1 - P[i, 0])
        rp = os.path.join(fr.LAB, key + ".regions.json")
        regions = json.load(open(rp)) if os.path.exists(rp) else []
        for r in regions:
            if r["label"] in ("EITHER", "NORMAL"): continue
            idx = [i for i, s in enumerate(ep["sents"]) if r["start"] <= (s["start"] + s["end"]) / 2 <= r["end"]]
            if not idx: continue
            m = max(1 - P[i, 0] for i in idx)
            kind = r["label"] + ("/" + r["delivery"] if r.get("delivery") in ("host", "produced") else "")
            for t in look:
                reg.setdefault((kind, t), [0, 0])
                reg[(kind, t)][0] += m >= t; reg[(kind, t)][1] += 1
        for t in look:
            hits = sorted((max(0, s["start"] - 60), s["end"] + 60) for s, p in zip(ep["sents"], P[:, 0]) if 1 - p >= t)
            merged = []
            for a, b in hits:
                if merged and a <= merged[-1][1]: merged[-1][1] = max(merged[-1][1], b)
                else: merged.append([a, b])
            look[t][0] += sum(b - a for a, b in merged); look[t][1] += ep["duration"]
    print("== %s: sentence AUC %.3f" % (tag, roc_auc_score(truth, score)))
    for t in look:
        parts = ["%s %d/%d" % (k, v[0], v[1]) for (k, tt), v in sorted(reg.items()) if tt == t]
        print("  τ %.2f read %.0f%% of audio | %s" % (t, 100 * look[t][0] / look[t][1], "  ".join(parts)))
