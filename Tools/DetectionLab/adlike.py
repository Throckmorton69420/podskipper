#!/usr/bin/env python3
"""How ad-like each transcript line is, from Apple's on-device sentence
embedding (lab-embed → <key>.emb.bin) and a logistic regression trained on the
labelled fixtures. Lab only; the app ships the weights (AdLikeness.swift).

    adlike.py eval            leave-one-show-out: window recall vs windows flagged
    adlike.py train out.json  fit on every fixture, write the weights

Run in build/lab. Needs <key>.regions.json (score.py with SCORE_DUMP).
"""
import json, os, sys
import numpy as np

KEYS = ["stav199", "mssp633", "mssp636", "los952", "los956", "ymh1", "bears1", "badf1", "theo1", "wg1", "afs2"]
SHOW = {"stav199": "stav", "mssp633": "mssp", "mssp636": "mssp", "los952": "los", "los956": "los",
        "ymh1": "ymh", "bears1": "bears", "badf1": "badf", "theo1": "theo", "wg1": "wg", "afs2": "afs"}
SKIP = {"ADVERTISEMENT", "SELF_PROMOTION", "NETWORK_PROMOTION", "INTRO", "OUTRO", "CREDITS"}

def load(key):
    lines = json.load(open(key + ".json"))
    X = np.fromfile(key + ".emb.bin", dtype=np.float32).reshape(len(lines), -1)
    regions = json.load(open(key + ".regions.json"))
    dai = json.load(open(key + ".dai.json")).get("inserted", []) if os.path.exists(key + ".dai.json") else []
    y = np.zeros(len(lines)); w = np.ones(len(lines)); inserted = np.zeros(len(lines), bool)
    for i, l in enumerate(lines):
        mid = (l["start"] + l["end"]) / 2
        for r in regions:
            if r["start"] <= mid <= r["end"]:
                if r["label"] in SKIP: y[i] = 1
                elif r["label"] == "EITHER": w[i] = 0
        if any(d["start"] <= mid <= d["end"] for d in dai): inserted[i] = True
    return lines, X, y, w, regions, inserted

def features(X):
    # The line, and the mean of its neighbours: an ad is a run of lines.
    n = len(X)
    ctx = np.zeros_like(X)
    for i in range(n):
        a, b = max(0, i - 3), min(n, i + 4)
        ctx[i] = X[a:b].mean(0)
    return np.hstack([X, ctx])

def fit(X, y, w, l2=50.0):
    """Weighted ridge regression on standardised features, classes balanced:
    one linear solve, so a fold takes a second rather than minutes."""
    X = X.astype(np.float64)
    mu, sd = X.mean(0), X.std(0) + 1e-6
    Z = np.hstack([(X - mu) / sd, np.ones((len(X), 1))])
    pos = (y * w).sum(); neg = ((1 - y) * w).sum()
    cw = np.where(y == 1, neg / max(pos, 1), 1.0) * w
    A = (Z * cw[:, None]).T @ Z + l2 * np.eye(Z.shape[1])
    theta = np.linalg.solve(A, (Z * cw[:, None]).T @ (2 * y - 1))
    return mu, sd, theta[:-1], theta[-1]

def predict(model, X):
    mu, sd, theta, b = model
    return 1 / (1 + np.exp(-4 * (((X - mu) / sd) @ theta + b)))

CUES = ["sponsor", "brought to you", "support for", "promo code", "use code", "offer code",
        "code ", ".com", "dot com", " slash ", "percent off", "% off", "free trial", "terms apply",
        "restrictions apply", "offer details", "patreon", "merch", "tickets", "tour", "on sale",
        "subscribe", "rate and review", "wherever you get", "spotify", "download the", "app store",
        "free shipping", "first order", "first purchase", "save ", "drink responsibly", "21 plus",
        "must be 21", "visit ", "go to ", "head to ", "sign up", "limited time", "new episodes",
        "listen to", "this episode", "today's episode", "thanks for listening", "produced by",
        "welcome to", "goodbye", "see you next", "you've been listening to", "you have been listening to",
        "you are listening to", "you're listening to"]

def windows(lines, length=45, overlap=10):
    out, cursor, last = [], 0.0, lines[-1]["end"]
    while cursor < last:
        idx = [i for i, l in enumerate(lines) if l["start"] < cursor + length and l["end"] > cursor]
        if idx: out.append(idx)
        cursor += length - overlap
    return out

def evaluate(thresholds=(0.3, 0.5, 0.7, 0.8, 0.9, 0.95)):
    data = {k: load(k) for k in KEYS if os.path.exists(k + ".emb.bin") and os.path.exists(k + ".regions.json")}
    feats = {k: features(v[1]) for k, v in data.items()}
    rows = {t: [0, 0, 0, 0] for t in ("cues",) + thresholds}   # regions hit, regions, windows flagged, windows
    for k, (lines, X, y, w, regions, inserted) in data.items():
        train = [j for j in data if SHOW[j] != SHOW[k]]
        m = fit(np.vstack([feats[j] for j in train]), np.concatenate([data[j][2] for j in train]),
                np.concatenate([data[j][3] * ~data[j][5] for j in train]))
        p = predict(m, feats[k])
        wins = windows(lines)
        end = lines[-1]["end"]
        cue = [any(c in " ".join(lines[i]["text"] for i in win).lower() for c in CUES)
               or lines[win[0]]["start"] < 120 or lines[win[-1]]["end"] > end - 180 for win in wins]
        targets = [r for r in regions if r["label"] in SKIP and r.get("delivery") != "inserted"]
        for t in rows:
            flag = cue if t == "cues" else [c or max(p[i] for i in win) >= t for c, win in zip(cue, wins)]
            hit = 0
            missed = []
            for r in targets:
                if any(f and lines[win[0]]["start"] < r["end"] and lines[win[-1]]["end"] > r["start"]
                       for f, win in zip(flag, wins)):
                    hit += 1
                else:
                    missed.append(r["id"])
            rows[t][0] += hit; rows[t][1] += len(targets); rows[t][2] += sum(flag); rows[t][3] += len(flag)
            if t in ("cues", 0.7): print(f"  {k:8} {str(t):5} hit {hit}/{len(targets)} flagged {sum(flag)}/{len(flag)} missed {missed}")
    for t, (h, n, f, nw) in rows.items():
        print(f"{str(t):6} regions {h}/{n}  windows asked {f}/{nw} ({100 * f / nw:.0f} %)")

if __name__ == "__main__":
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "lab"))
    if sys.argv[1] == "eval":
        evaluate()
