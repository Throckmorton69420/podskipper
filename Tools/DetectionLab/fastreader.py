#!/usr/bin/env python3
"""The fast reader (pass 23): a sentence classifier that needs no language model.

Why: on his phone, locked and on battery, iOS refuses almost every question to
Apple's on-device model (29 Sep: 165 refusals in 12 minutes, 0 % progress).
Anything that must finish while locked has to work without it. This reads every
sentence with a logistic regression over hashed words of the sentence and its
neighbours. It runs in well under a second per episode on the phone's CPU and
iOS doesn't limit it.

    fastreader.py eval             leave-one-fixture-out on the lab fixtures
    fastreader.py export <out>     train on everything, write the app's weights

Training data: the lab fixtures (labels in build/lab/<key>.regions.json) plus
his phone's own results (build/phone-*/results.json), whose cuts are the
detector's, not his: weak labels, weighted lower.
"""
import json, re, sys, os, glob, math, subprocess, struct
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAB = os.path.join(ROOT, "build", "lab")
OUT = os.path.join(ROOT, "build", "fast")
KEYS = ["stav199", "stavb199", "mssp633", "mssp636", "los952", "los956", "los957", "ymh1", "bears1",
        "bears2", "badf1", "theo1", "wg1", "afs2", "ct262", "ct284", "chaos1"]
LABELS = "CASNIO"           # content, ad, self-promo, network promo, opening, closing
DIM = 1 << 18

# ---------------------------------------------------------------- sentences

def sentences(segments):
    """The same sentences SegmentDetector.sentences builds."""
    out = []
    for seg in segments:
        words = seg.get("words") or []
        if not words:
            t = seg["text"].strip()
            if t: out.append({"text": t, "start": seg["start"], "end": seg["end"]})
            continue
        cur = []
        def flush():
            if cur:
                text = " ".join(w["text"] for w in cur).replace(" ,", ",")
                out.append({"text": text, "start": cur[0]["start"], "end": cur[-1]["end"]})
                cur.clear()
        for w in words:
            if cur and w["start"] - cur[-1]["end"] > 1.2: flush()
            cur.append(w)
            if w["text"] and w["text"][-1] in ".?!" and len(cur) >= 2: flush()
        flush()
    out.sort(key=lambda s: s["start"])
    return out

# ---------------------------------------------------------------- features

def tokens(text):
    t = text.lower().replace(".com", " dotcom ").replace("dot com", " dotcom ")
    t = re.sub(r"[0-9]", "0", t)
    return re.findall(r"[a-z0-9']+", t)

def fnv(s):
    h = 0x811C9DC5
    for b in s.encode("utf-8"):
        h ^= b
        h = (h * 0x01000193) & 0xFFFFFFFF
    return h

def bucket(v, edges):
    for i, e in enumerate(edges):
        if v < e: return i
    return len(edges)

def features(sents, i, duration):
    s = sents[i]
    toks = [tokens(x["text"]) for x in sents[max(0, i - 2): i + 3]]
    me = tokens(s["text"])
    f = set()
    for w in me: f.add("s|" + w)
    for a, b in zip(me, me[1:]): f.add("b|" + a + " " + b)
    for k in (1, 2):
        if i - k >= 0:
            for w in tokens(sents[i - k]["text"]): f.add("p|" + w)
        if i + k < len(sents):
            for w in tokens(sents[i + k]["text"]): f.add("n|" + w)
    # The stretch around it: an ad break reads as one.
    j = i - 3
    while j >= 0 and s["start"] - sents[j]["end"] < 45:
        for w in tokens(sents[j]["text"]): f.add("w|" + w)
        j -= 1
    j = i + 3
    while j < len(sents) and sents[j]["start"] - s["end"] < 45:
        for w in tokens(sents[j]["text"]): f.add("w|" + w)
        j += 1
    n = len(me)
    f.add("len|%d" % bucket(n, [2, 3, 6, 11, 21]))
    gap_before = s["start"] - sents[i - 1]["end"] if i > 0 else 9
    gap_after = sents[i + 1]["start"] - s["end"] if i + 1 < len(sents) else 9
    f.add("gb|%d" % bucket(gap_before, [0.2, 0.5, 1.0, 2.0]))
    f.add("ga|%d" % bucket(gap_after, [0.2, 0.5, 1.0, 2.0]))
    dur = max(0.3, s["end"] - s["start"])
    f.add("rate|%d" % bucket(n / dur, [1.5, 2.5, 3.2, 4.0]))
    if s["start"] < 120: f.add("pos|start2")
    if s["start"] < 600: f.add("pos|start10")
    if s["end"] > duration - 180: f.add("pos|end3")
    if s["end"] > duration - 600: f.add("pos|end10")
    f.add("bias")
    return f

def row(fs):
    idx, val = [], []
    for name in fs:
        h = fnv(name)
        idx.append(h % DIM)
        val.append(1.0 if (h >> 20) & 1 == 0 else -1.0)
    return idx, val

# ---------------------------------------------------------------- data

def label_by(sents, regions, kinds):
    out = []
    for s in sents:
        mid = (s["start"] + s["end"]) / 2
        lab = "C"
        for r in regions:
            if r["start"] <= mid <= r["end"]:
                lab = kinds.get(r["label"], None)
                break
        out.append(lab)
    return out

LAB_KINDS = {"ADVERTISEMENT": "A", "SELF_PROMOTION": "S", "NETWORK_PROMOTION": "N", "INTRO": "I",
             "OUTRO": "O", "CREDITS": "O", "EITHER": None, "NORMAL": "C"}
APP_KINDS = {"ad": "A", "selfPromo": "S", "crossPromo": "N", "intro": "I", "outro": "O", "credits": "O"}

def lab_episode(key):
    segs = json.load(open(os.path.join(LAB, key + ".json")))
    sents = sentences(segs)
    rpath = os.path.join(LAB, key + ".regions.json")
    regions = json.load(open(rpath)) if os.path.exists(rpath) else []
    title = open(os.path.join(LAB, key + ".title")).read().strip() if os.path.exists(os.path.join(LAB, key + ".title")) else key
    return {"key": key, "title": title, "sents": sents, "labels": label_by(sents, regions, LAB_KINDS),
            "duration": sents[-1]["end"] if sents else 0, "weight": 1.0}

def phone_episodes():
    seen, out = set(), []
    for path in sorted(glob.glob(os.path.join(ROOT, "build", "phone-*", "results.json")), reverse=True):
        for e in json.load(open(path))["episodes"]:
            if e["guid"] in seen or not e.get("transcript"): continue
            seen.add(e["guid"])
            # Known catastrophic results are not teaching material.
            if "We Are Garbage" in e["title"]: continue
            if e.get("detectorVersion", 0) < 17: continue
            sents = sentences(e["transcript"])
            if not sents: continue
            regions = []
            for s in e["segments"]:
                kind = "C" if s.get("verdict") == "notAnAd" else APP_KINDS.get(s["kind"])
                if kind: regions.append({"start": s["start"], "end": s["end"], "label": kind})
            labels = []
            for s in sents:
                mid = (s["start"] + s["end"]) / 2
                lab = next((r["label"] for r in regions if r["start"] <= mid <= r["end"]), "C")
                labels.append(lab)
            out.append({"key": "phone:" + e["guid"], "title": e["title"], "sents": sents, "labels": labels,
                        "duration": sents[-1]["end"], "weight": float(os.environ.get("FAST_PHONE", "0.5"))})
    if float(os.environ.get("FAST_PHONE", "0.5")) <= 0: return []
    return out

def matrix(episodes):
    from scipy.sparse import vstack
    Xs, ys, ws = [], [], []
    cw = float(os.environ.get("FAST_CW", "1"))
    for ep in episodes:
        X = episode_matrix(ep)
        keep = [i for i, l in enumerate(ep["labels"]) if l is not None]
        Xs.append(X[keep])
        for i in keep:
            lab = ep["labels"][i]
            ys.append(LABELS.index(lab))
            ws.append(ep["weight"] * (1 if lab == "C" else cw))
    return vstack(Xs).tocsr(), np.array(ys), np.array(ws)

_cache = {}
def episode_matrix(ep):
    if ep["key"] in _cache: return _cache[ep["key"]]
    from scipy.sparse import csr_matrix
    rows, cols, vals = [], [], []
    for i in range(len(ep["sents"])):
        idx, val = row(features(ep["sents"], i, ep["duration"]))
        rows += [i] * len(idx); cols += idx; vals += val
    X = csr_matrix((vals, (rows, cols)), shape=(len(ep["sents"]), DIM), dtype=np.float32)
    X.sum_duplicates()
    _cache[ep["key"]] = X
    return X

# ---------------------------------------------------------------- model

def train(X, y, w, C=0.5):
    import time
    t0 = time.time()
    if os.environ.get("FAST_SOLVER", "sgd") == "sgd":
        # Multinomial logistic regression by plain minibatch gradient descent
        # (Adam), which is what the app's softmax expects, in seconds rather
        # than lbfgs's minutes over 2^18 features.
        W, b = sgd_softmax(X, y, w, l2=float(os.environ.get("FAST_L2", "1e-6")),
                           epochs=int(os.environ.get("FAST_EPOCHS", "6")))
        print("   trained in %.0f s" % (time.time() - t0), flush=True)
        return W, b
    from sklearn.linear_model import LogisticRegression
    m = LogisticRegression(C=C, max_iter=300, solver="lbfgs")
    m.fit(X, y, sample_weight=w)
    # Every class present, in LABELS order.
    W = np.zeros((len(LABELS), DIM), dtype=np.float32); b = np.full(len(LABELS), -20.0, dtype=np.float32)
    for k, cls in enumerate(m.classes_):
        W[cls] = m.coef_[k]; b[cls] = m.intercept_[k]
    return W, b

def sgd_softmax(X, y, w, l2=1e-6, epochs=6, batch=512, lr=0.01):
    """Softmax regression with Adam on minibatches of a CSR matrix."""
    rng = np.random.default_rng(7)
    n, d = X.shape; K = len(LABELS)
    W = np.zeros((K, d), dtype=np.float32); b = np.zeros(K, dtype=np.float32)
    mW = np.zeros_like(W); vW = np.zeros_like(W); mb = np.zeros_like(b); vb = np.zeros_like(b)
    b1, b2, eps, t = 0.9, 0.999, 1e-8, 0
    Y = np.zeros((n, K), dtype=np.float32); Y[np.arange(n), y] = 1
    w = (w / w.mean()).astype(np.float32)
    for epoch in range(epochs):
        order = rng.permutation(n)
        for start in range(0, n, batch):
            idx = order[start:start + batch]
            Xb = X[idx]; z = (Xb @ W.T) + b
            z -= z.max(axis=1, keepdims=True); p = np.exp(z); p /= p.sum(axis=1, keepdims=True)
            g = (p - Y[idx]) * w[idx][:, None] / len(idx)            # batch × K
            gW = np.asarray((Xb.T @ g).T, dtype=np.float32)            # K × d (dense)
            gW += l2 * W
            gb = g.sum(axis=0)
            t += 1
            mW = b1 * mW + (1 - b1) * gW; vW = b2 * vW + (1 - b2) * gW * gW
            mb = b1 * mb + (1 - b1) * gb; vb = b2 * vb + (1 - b2) * gb * gb
            step = lr * math.sqrt(1 - b2 ** t) / (1 - b1 ** t)
            W -= step * mW / (np.sqrt(vW) + eps); b -= step * mb / (np.sqrt(vb) + eps)
    return W, b

def write_weights(path, W, b):
    """The app's format (FastReader.swift): "PSFR", version, dim, classes,
    bias as float32, then the weights class by class as float16."""
    with open(path, "wb") as f:
        f.write(b"PSFR")
        f.write(struct.pack("<III", 1, DIM, len(LABELS)))
        f.write(np.asarray(b, dtype="<f4").tobytes())
        f.write(np.asarray(W, dtype="<f2").tobytes())

def probs(W, b, X):
    # As the app computes them: float16 weights.
    W = np.asarray(W, dtype=np.float16).astype(np.float32)
    z = X @ W.T + b
    z -= z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)

# ---------------------------------------------------------------- spans

def smooth(P, sents, duration, switch=3.0, between=1.2, boost=1.0):
    n, K = P.shape
    logp = np.log(0.02 + 0.98 * P)
    # The model is trained on ~9 % promotion, so it under-calls it; a prior
    # boost on every non-conversation label moves the decision point.
    logp[:, 1:] += math.log(boost)
    for i, s in enumerate(sents):
        if s["start"] > 240: logp[i, LABELS.index("I")] = -30
        if s["end"] < duration - 360: logp[i, LABELS.index("O")] = -30
    trans = np.full((K, K), -between)
    for a in range(K):
        trans[a, a] = 0
        if a != 0:
            trans[a, 0] = trans[0, a] = -switch
    score = np.full((n, K), -np.inf); back = np.zeros((n, K), dtype=int)
    score[0] = logp[0] + np.array([0] + [-1] * (K - 1))
    for i in range(1, n):
        cand = score[i - 1][:, None] + trans
        back[i] = cand.argmax(axis=0)
        score[i] = cand.max(axis=0) + logp[i]
    k = int(score[-1].argmax()); path = [0] * n
    for i in range(n - 1, -1, -1):
        path[i] = k; k = back[i][k]
    return [LABELS[k] for k in path]

def spans(path, sents):
    out, i = [], 0
    names = {"A": "ad", "S": "selfPromo", "N": "crossPromo", "I": "intro", "O": "outro"}
    while i < len(path):
        if path[i] == "C": i += 1; continue
        j = i
        while j + 1 < len(path) and path[j + 1] == path[i]: j += 1
        start, end = sents[i]["start"], sents[j]["end"]
        floor = 10 if path[i] == "A" else 2.5
        if end - start >= floor: out.append((names[path[i]], start, end))
        i = j + 1
    return out

def clock(t):
    t = max(0.0, t); h = int(t // 3600); m = int(t % 3600 // 60); s = t % 60
    return "%d:%02d:%05.2f" % (h, m, s)

def write_detect(path, cuts):
    with open(path, "w") as f:
        f.write("fast reader\n")
        for kind, a, b in cuts:
            f.write("[%s] %s–%s (%ds)\n" % (kind, clock(a), clock(b), round(b - a)))

def score(key, detect):
    fx = os.path.join(ROOT, "Tools", "DetectionLab", "regression", key + ".json")
    r = subprocess.run([sys.executable, os.path.join(ROOT, "Tools", "DetectionLab", "regression", "score.py"),
                        os.path.join(LAB, key + ".json"), detect, fx], capture_output=True, text=True)
    m = re.search(r"^SUMMARY (.*)$", r.stdout, re.M)
    return json.loads(m.group(1)) if m else None

# ---------------------------------------------------------------- screening check

def screening(ep, P, taus=(0.05, 0.1, 0.2, 0.3)):
    """Per threshold: the share of labelled promo seconds with a flagged
    sentence within 30 s, and the share of the episode the flags (±60 s) cover."""
    promo = 1 - P[:, 0]
    out = {}
    lab = ep["labels"]
    total = sum(s["end"] - s["start"] for s, l in zip(ep["sents"], lab) if l not in (None, "C"))
    for tau in taus:
        hits = [s for s, p in zip(ep["sents"], promo) if p >= tau]
        covered = 0.0
        for s, l in zip(ep["sents"], lab):
            if l in (None, "C"): continue
            if any(h["start"] - 30 <= s["end"] and h["end"] + 30 >= s["start"] for h in hits):
                covered += s["end"] - s["start"]
        ranges = sorted((max(0, h["start"] - 60), h["end"] + 60) for h in hits)
        merged = []
        for a, b in ranges:
            if merged and a <= merged[-1][1]: merged[-1][1] = max(merged[-1][1], b)
            else: merged.append([a, b])
        look = sum(b - a for a, b in merged)
        out[tau] = (covered / total if total else 1.0, look / ep["duration"])
    return out

# ---------------------------------------------------------------- main

def main():
    os.makedirs(OUT, exist_ok=True)
    mode = sys.argv[1] if len(sys.argv) > 1 else "eval"
    C = float(os.environ.get("FAST_C", "0.5"))
    phone = phone_episodes()
    labs = {k: lab_episode(k) for k in KEYS if os.path.exists(os.path.join(LAB, k + ".json"))}
    print("phone episodes:", len(phone), "lab fixtures:", len(labs), flush=True)
    if mode == "export":
        X, y, w = matrix(list(labs.values()) + phone)
        W, b = train(X, y, w, C)
        write_weights(sys.argv[2], W, b)
        print("wrote", sys.argv[2], os.path.getsize(sys.argv[2]), "bytes")
        return
    if mode == "oof":
        # Out-of-fold probabilities for every fixture, saved for `tune`.
        # Leave one SHOW out: a model that has seen another episode of the
        # same show has seen its sponsors and its sign-off, and the phone
        # meets new episodes of known shows — but new sponsors too. Holding
        # out the whole show is the harder, more honest test. The weights
        # for each held-out show are kept (folds/<key>.bin) so the lab's
        # detector reads each fixture with a model that never saw it.
        tag = os.environ.get("FAST_TAG", "base")
        groups = {}
        for k in labs: groups.setdefault(re.sub(r"\d+$", "", k.replace("stavb", "stav")), []).append(k)
        saved = {}
        norm = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())[:40]
        fold_dir = os.path.join(OUT, "folds-%s" % tag); os.makedirs(fold_dir, exist_ok=True)
        for g, members in sorted(groups.items()):
            titles = {norm(labs[k]["title"]) for k in members}
            train_eps = [e for k, e in labs.items() if k not in members] + [e for e in phone if norm(e["title"]) not in titles]
            X, y, w = matrix(train_eps)
            W, b = train(X, y, w, C)
            for k in members:
                saved[k] = probs(W, b, episode_matrix(labs[k]))
                write_weights(os.path.join(fold_dir, k + ".bin"), W, b)
            print("oof", g, members, flush=True)
        np.savez_compressed(os.path.join(OUT, "oof-%s.npz" % tag), **saved)
        return
    if mode == "tune":
        tag = os.environ.get("FAST_TAG", "base")
        oof = np.load(os.path.join(OUT, "oof-%s.npz" % tag))
        grid = [(b, s) for b in (1, 2, 3, 5, 8) for s in (1.5, 3.0)]
        for boost, switch in grid:
            H = heard = skipped = 0.0
            per = []
            for key in oof.files:
                held = labs[key]
                path = smooth(oof[key], held["sents"], held["duration"], switch=switch, boost=boost)
                d = os.path.join(OUT, "tune"); os.makedirs(d, exist_ok=True)
                detect = os.path.join(d, key + ".detect.txt")
                cuts = spans(path, held["sents"])
                # What the app has without any model: the ad-free comparison
                # and the repeated-audio fingerprints (dai.py cuts), exact.
                cheap = os.path.join(LAB, key + ".cheap.json")
                if os.path.exists(cheap):
                    exact = [(float(c["start"]), float(c["end"])) for c in json.load(open(cheap))]
                    cuts = [c for c in cuts if not any(a < c[2] and b > c[1] for a, b in exact)] + \
                           [("ad", a, b) for a, b in exact]
                    cuts.sort(key=lambda c: c[1])
                write_detect(detect, cuts)
                s = score(key, detect)
                if s and "ad_s_heard_per_h" in s:
                    h = s["hours"]; H += h; heard += s["ad_s_heard_per_h"] * h; skipped += s["content_s_skipped_per_h"] * h
                    per.append("%s %.0f/%.0f" % (key, s["ad_s_heard_per_h"], s["content_s_skipped_per_h"]))
            print("boost %g switch %g: heard %.1f s/h skipped %.1f s/h | %s" % (boost, switch, heard / H, skipped / H, "  ".join(per)), flush=True)
        return
    keys = sys.argv[2:] or list(labs)
    H = heard = skipped = 0.0
    scr = {}
    for key in keys:
        held = labs[key]
        norm = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())[:40]
        train_eps = [e for k, e in labs.items() if k != key] + [e for e in phone if norm(e["title"]) != norm(held["title"])]
        X, y, w = matrix(train_eps)
        W, b = train(X, y, w, C)
        P = probs(W, b, episode_matrix(held))
        from sklearn.metrics import roc_auc_score, average_precision_score
        truth = [(0 if l == "C" else 1) for l in held["labels"] if l is not None]
        pp = [1 - P[i, 0] for i, l in enumerate(held["labels"]) if l is not None]
        if 0 < sum(truth) < len(truth):
            print("   %s sentences: promo AUC %.3f  AP %.3f  (promo share %.2f)" % (
                key, roc_auc_score(truth, pp), average_precision_score(truth, pp), sum(truth) / len(truth)), flush=True)
        path = smooth(P, held["sents"], held["duration"], switch=float(os.environ.get("FAST_SWITCH", "3")))
        cuts = spans(path, held["sents"])
        tagdir = os.path.join(OUT, os.environ.get("FAST_TAG", "base"))
        os.makedirs(tagdir, exist_ok=True)
        detect = os.path.join(tagdir, key + ".detect.txt")
        write_detect(detect, cuts)
        s = score(key, detect)
        sc = screening(held, P)
        for tau, v in sc.items():
            scr.setdefault(tau, []).append((v, held["duration"]))
        if s and "ad_s_heard_per_h" in s:
            h = s["hours"]; H += h; heard += s["ad_s_heard_per_h"] * h; skipped += s["content_s_skipped_per_h"] * h
            print("%-9s heard %6.1f skipped %6.1f  adP %.2f adR %.2f  | screen@0.1 recall %.3f look %.2f" % (
                key, s["ad_s_heard_per_h"], s["content_s_skipped_per_h"], s.get("ad_precision") or 0,
                s.get("ad_recall") or 0, sc[0.1][0], sc[0.1][1]), flush=True)
        else:
            print("%-9s %s | screen@0.1 recall %.3f look %.2f" % (key, s, sc[0.1][0], sc[0.1][1]), flush=True)
    if H:
        print("ALL %.1f h: heard %.1f s/h, skipped %.1f s/h" % (H, heard / H, skipped / H))
    for tau, vals in sorted(scr.items()):
        tot = sum(d for _, d in vals)
        rec = sum(v[0] * d for v, d in vals) / tot; look = sum(v[1] * d for v, d in vals) / tot
        worst = min(v[0] for v, _ in vals)
        print("screen tau %.2f: promo seconds reached %.3f (worst %.3f), episode read %.2f" % (tau, rec, worst, look))

if __name__ == "__main__":
    main()
