#!/usr/bin/env python3
"""Pass 57: a second reading of the Reader's answers — the boundary refiner.

The Reader judges each sentence from the ~500 tokens around it; most of the
show it cuts sits right next to a break (the cut runs into the talk before
or after it) or is a stretch it is sure of with nothing selling in it. The
refiner looks at each sentence's answer next to its neighbours' answers
(up to ten sentences either side), the pauses, where it is in the episode,
and a few phrases that mark the edges of a break (the hand-off into a read,
"anyway, back to…", codes and addresses, a plug round's question) and gives
a new chance that it is to be skipped. The kind among the skippable ones is
left as the Reader said.

It is trained only on held-out answers: for each show-held-out fold, on the
other folds' answers (readers that never saw those episodes' shows), so no
episode it is scored on, nor its show, was in its training or the Reader's.

    refiner.py cv <out dir> <probs dir> [model] [--exclude test]
        model: linear (default; what ships: one weight per feature) or gbm
        writes <out dir>/probs/ for frontier.py, and the fitted weights
    refiner.py fit <out.json> <probs dir> [--exclude test]
        the shipping refiner: one linear model on every fold's answers
"""
import json, os, re, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import phone_eval  # noqa: E402
import tagger  # noqa: E402
import reader_consensus as rc  # noqa: E402

RESULTS = os.path.join(ROOT, "build", "phone-1031b", "results.json")
REACH = 10
# Phrases (lower case) — the same lists the Swift refiner carries.
CUES = {
    "handoff": r"brought to you by|sponsored by|support for (this|the) (show|podcast|episode)|thank (our|today's) sponsor|"
               r"quick (moment|break)|word from (our|today's) sponsor|this episode is (brought|presented|supported)|"
               r"in partnership with|after (this|the) break|we'll be right back|take a (quick |short )?break",
    "back": r"\b(anyway|anyways|back to (the|it|our|my)|let's get back|where were we|so yeah|all right,? so|okay,? so)\b",
    "offer": r"promo code|use code|code [a-z]{3,}|% off|percent off|free trial|\.com\b|dot com|slash [a-z]+|terms apply|"
             r"free shipping|first (month|order)|money.back|download (the|it)|app store|go to [a-z]+",
    "plug": r"tickets|on tour|tour dates|come see|go see|patreon|merch|new special|subscribe|my website|"
            r"follow (me|us)|instagram|youtube|where can (people|we|everyone|folks|they) find|what are you plugging|plug",
    "preview": r"my guest|on (today's|this) (show|episode)|we talk about|we discuss|in this episode|without further delay|"
               r"please enjoy|let's get into it|welcome (back )?to",
    "credits": r"produced by|executive produc|edited by|mixed by|music by|theme music|fact.?check|special thanks",
}
CUE_RX = {k: re.compile(v, re.I) for k, v in CUES.items()}


def features(rows, sents, duration):
    """One row of numbers per sentence (FEATURES names them)."""
    P = np.array([r[2:] for r in rows], dtype=np.float64)
    n = len(P)
    p = np.clip(1 - P[:, 0], 1e-4, 1 - 1e-4)
    lg = np.log(p / (1 - p))
    starts = np.array([r[0] for r in rows]); ends = np.array([r[1] for r in rows])
    cue = {k: np.array([1.0 if rx.search(s["text"]) else 0.0 for s in sents]) for k, rx in CUE_RX.items()}
    pad = lambda a, v: np.concatenate([np.full(REACH, v), a, np.full(REACH, v)])
    lp = pad(lg, -6.0)
    F, names = [], []

    def add(name, col):
        names.append(name); F.append(col)
    add("logit", lg)
    for d in (1, 2, 3, 5, 8):
        add(f"logit-{d}", lp[REACH - d:REACH - d + n]); add(f"logit+{d}", lp[REACH + d:REACH + d + n])
    pp = pad(p, 0.0)
    for w in (3, 10):
        left = np.stack([pp[REACH - d:REACH - d + n] for d in range(1, w + 1)], 1)
        right = np.stack([pp[REACH + d:REACH + d + n] for d in range(1, w + 1)], 1)
        add(f"left{w}mean", left.mean(1)); add(f"right{w}mean", right.mean(1))
        add(f"left{w}max", left.max(1)); add(f"right{w}max", right.max(1))
        add(f"inside{w}", np.minimum(left.mean(1), right.mean(1)))
    for k in range(1, 6):
        add("kind" + "CASNIO"[k], P[:, k] / (1 - P[:, 0] + 1e-6))
    gap_b = np.concatenate([[9.0], starts[1:] - ends[:-1]]); gap_a = np.concatenate([starts[1:] - ends[:-1], [9.0]])
    add("gapBefore", np.minimum(gap_b, 5.0)); add("gapAfter", np.minimum(gap_a, 5.0))
    add("seconds", np.minimum(ends - starts, 20.0) / 10)
    add("nearStart", (starts < 180).astype(float)); add("nearEnd", (ends > duration - 240).astype(float))
    for k, c in cue.items():
        cp = pad(c, 0.0)
        add(k, c)
        add(k + "Before3", np.stack([cp[REACH - d:REACH - d + n] for d in range(1, 4)], 1).max(1))
        add(k + "After3", np.stack([cp[REACH + d:REACH + d + n] for d in range(1, 4)], 1).max(1))
        add(k + "Near10", np.stack([cp[REACH + d:REACH + d + n] for d in range(-10, 11)], 1).sum(1) / 5)
    # Interactions a linear model can't make itself: sure answers next to
    # an edge phrase.
    add("logit×back", lg * cue["back"]); add("logit×preview", lg * cue["preview"])
    add("logit×offerNear", lg * np.minimum(1, np.stack([pad(cue["offer"], 0)[REACH + d:REACH + d + n] for d in range(-10, 11)], 1).sum(1)))
    add("bias", np.ones(n))
    return np.stack(F, 1), names


def episode_data(probs_dir, exclude=frozenset()):
    """Per held-out episode: fold, features, labels (1 skip, 0 show, -1 left
    out), seconds, and the rows."""
    labels = phone_eval.load_labels()
    data = json.load(open(RESULTS))
    bykey = {rc.key_of(e): e for e in data["episodes"]}
    out = []
    for name in sorted(os.listdir(probs_dir)):
        k = name[:-5]
        e = bykey.get(k)
        if not e or e["guid"] not in labels or e["guid"] in exclude:
            continue
        d = json.load(open(os.path.join(probs_dir, name)))
        rows = d["rows"]
        sents = tagger.sentences(e["transcript"])
        by_start = {round(s["start"], 2): s for s in sents}
        sents = [by_start.get(round(r[0], 2), {"text": "", "start": r[0], "end": r[1]}) for r in rows]
        X, names = features(rows, sents, e["transcript"][-1]["end"])
        spans = phone_eval.spans(labels[e["guid"]], e["transcript"])
        y = np.zeros(len(rows))
        for i, r in enumerate(rows):
            m = (r[0] + r[1]) / 2
            hit = next((s for s in spans if s[0] <= m <= s[1]), None)
            y[i] = -1 if hit and hit[2] == "EITHER" else (1 if hit and hit[2] in phone_eval.SKIP else 0)
        w = np.array([max(0.5, r[1] - r[0]) for r in rows])
        out.append({"key": k, "guid": e["guid"], "fold": d["fold"], "X": X, "y": y, "w": w, "rows": rows,
                    "names": names})
    return out


def fit_linear(eps, C=1.0):
    from sklearn.linear_model import LogisticRegression
    X = np.concatenate([e["X"] for e in eps]); y = np.concatenate([e["y"] for e in eps])
    w = np.concatenate([e["w"] for e in eps])
    keep = y >= 0
    mu = X[keep].mean(0); sd = X[keep].std(0) + 1e-6
    mu[-1], sd[-1] = 0.0, 1.0
    m = LogisticRegression(C=C, max_iter=3000, fit_intercept=False)
    m.fit((X[keep] - mu) / sd, y[keep], sample_weight=w[keep])
    coef = m.coef_[0] / sd
    coef[-1] = m.coef_[0][-1] - float((m.coef_[0] * mu / sd).sum()) + m.coef_[0][-1] * 0  # bias absorbs centring
    return coef


def apply_linear(coef, X):
    z = X @ coef
    return 1 / (1 + np.exp(-z))


def fit_gbm(eps):
    from sklearn.ensemble import HistGradientBoostingClassifier
    X = np.concatenate([e["X"] for e in eps]); y = np.concatenate([e["y"] for e in eps])
    w = np.concatenate([e["w"] for e in eps])
    keep = y >= 0
    return HistGradientBoostingClassifier(max_iter=300, learning_rate=0.05, max_leaf_nodes=31,
                                          l2_regularization=1.0).fit(X[keep], y[keep], sample_weight=w[keep])


def refined_rows(rows, q):
    out = []
    for r, qi in zip(rows, q):
        P = np.array(r[2:], dtype=np.float64)
        promo = max(1e-9, 1 - P[0])
        out.append(r[:2] + [float(1 - qi)] + [float(qi * x / promo) for x in P[1:]])
    return out


def exclusion(flag):
    if flag != "test":
        return frozenset()
    return frozenset(g for g, m in corpus.load_manifest()["episodes"].items() if m["testEpisode"])


def cv(out, probs_dir, model="linear", exclude=frozenset()):
    eps = episode_data(probs_dir)
    os.makedirs(os.path.join(out, "probs"), exist_ok=True)
    folds = sorted({e["fold"] for e in eps})
    fitted = {}
    for f in folds:
        train = [e for e in eps if e["fold"] != f and e["guid"] not in exclude]
        if model == "gbm":
            g = fit_gbm(train)
            predict = lambda X: g.predict_proba(X)[:, 1]
        else:
            coef = fit_linear(train)
            fitted[f] = coef.tolist()
            predict = lambda X, c=coef: apply_linear(c, X)
        for e in eps:
            if e["fold"] != f:
                continue
            json.dump({"fold": f, "rows": refined_rows(e["rows"], predict(e["X"]))},
                      open(os.path.join(out, "probs", e["key"] + ".json"), "w"))
    json.dump({"model": model, "names": eps[0]["names"], "folds": fitted}, open(os.path.join(out, "refiner.json"), "w"))
    print(f"refined {len(eps)} episodes in {len(folds)} folds ({model}) → {out}/probs")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    ex = exclusion(sys.argv[sys.argv.index("--exclude") + 1]) if "--exclude" in sys.argv else frozenset()
    args = [a for a in args if a != "test"] if "--exclude" in sys.argv else args
    if args[0] == "cv":
        cv(args[1], args[2], args[3] if len(args) > 3 else "linear", ex)
    elif args[0] == "fit":
        eps = [e for e in episode_data(args[2]) if e["guid"] not in ex]
        coef = fit_linear(eps)
        json.dump({"names": eps[0]["names"], "weights": coef.tolist(), "reach": REACH, "cues": CUES,
                   "episodes": len(eps)}, open(args[1], "w"), indent=1)
        print("fitted on", len(eps), "episodes →", args[1])
    else:
        raise SystemExit(__doc__)
