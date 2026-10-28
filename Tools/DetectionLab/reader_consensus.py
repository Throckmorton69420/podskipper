#!/usr/bin/env python3
"""Pass 43: does PodSkipper's reader get better when its head learns from
what several independent models agreed on?

    reader_consensus.py prepare <results.json> <out dir>
        every exported episode's transcript as the lab reads it, and every
        sentence's features as the app's two readers see them (the Swift
        reader itself, `lab-segments` LAB_FEATDUMP) → <out>/<key>.feat.npz
    reader_consensus.py run <results.json> <out dir> [variant …]
        trains a head per variant on episodes the labels don't cover (and on
        the labelled ones of the other fold), runs the app's own detector
        (`lab-segments` LAB_TAGPROBS) on the held-out fold, and scores the
        cuts against Tools/DetectionLab/phone-labels with phone_eval.

Variants (the on-device learner's recipe, OnDeviceReaderLearner, unless named):
  base        the shipped heads, no learning (the reference)
  single      Pass 38's silver: one model's checked cuts, positives at weight
              1, up to 3 negatives each at 0.5 — what his phone did
  consensus   Pass 43: sentence labels only where independent engines agree;
              each episode's labels weighted so the show/promo share matches
              the lab's (prior kept); ambiguous sentences left out
  consensus+hard  consensus, plus show sentences that name a brand, a web
              address or a code that every engine left alone, at double weight
  <variant>@0.4   promos keep that share of each episode's weight (the
              anchor's is 0.395, so the reader's ad/show balance holds)
  <variant>~1     his sentences, all together, weigh that many times the
              replayed lab sentences

  gold46      Pass 47: his corrections as the phone's learner used them
              (every delta in the ledger, the delta's main kind at weight 5,
              ±45 s edges as the show at 2; no cap), plus consensus@0.395~0.5
  gold47      Pass 47: only corrections still in force (a current cut covers
              half of it, or a Not an Ad still clear), each sentence the kind
              of the current cut over it; the show from the reviewed
              episode, far from every cut, so promos keep 0.395 of each
              episode's weight; one episode at most 150 gold sentences'
              weight; all learning together at most the replayed lab
              sentences; the epoch kept is the last whose held-out lab loss
              stays within 1 % (none: the shipped head)

Nothing here uses the hand labels for training; they only score.
"""
import collections, json, os, re, struct, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import phone_eval  # noqa: E402

LABELS = "CASNIO"
KIND_INDEX = {"ad": 1, "selfPromo": 2, "crossPromo": 3, "intro": 4, "outro": 5, "credits": 5}
WEIGHTS = [os.path.join(ROOT, "Resources", "Detection", "TaggerWeights.bin"),
           os.path.join(ROOT, "Resources", "Detection", "TaggerWeights-2.bin")]
BIN = os.environ.get("LAB_SEGMENTS", os.path.join(ROOT, "build", "p43-reader", "lab-segments"))


def key_of(e):
    return re.sub(r"[^A-Za-z0-9]+", "_", e["guid"])[-60:]


def sentences(lines):
    """SegmentDetector.sentences: words joined until a pause > 1.2 s or an
    end mark after two words; lines without words are one sentence."""
    out = []
    for seg in lines:
        words = seg.get("words") or []
        if not words:
            t = seg["text"].strip()
            if t:
                out.append({"text": t, "start": seg["start"], "end": seg["end"]})
            continue
        cur = []

        def flush():
            if cur:
                out.append({"text": " ".join(w["text"] for w in cur).replace(" ,", ","),
                            "start": cur[0]["start"], "end": cur[-1]["end"]})
                cur.clear()
        for w in words:
            if cur and w["start"] - cur[-1]["end"] > 1.2:
                flush()
            cur.append(w)
            if w["text"] and w["text"][-1] in ".?!" and len(cur) >= 2:
                flush()
        flush()
    out.sort(key=lambda s: s["start"])
    return out


# ------------------------------------------------------------------ heads

def read_head(path):
    """The shipped head of one reader: mid (in × mid), out (mid × 6)."""
    data = open(path, "rb").read()
    assert data[:4] == b"PSTG"
    n = struct.unpack("<I", data[8:12])[0]
    header = json.loads(data[12:12 + n])
    base = 12 + n
    t = {x["name"]: x for x in header["tensors"]}

    def get(name):
        x = t[name]
        count = int(np.prod(x["shape"]))
        arr = np.frombuffer(data, dtype="<f2", count=count, offset=base + x["offset"]).astype(np.float32)
        return arr.reshape(x["shape"])
    # torch Linear stores (out, in); the app multiplies in × out.
    return {"w1": get("mid.weight").T.copy(), "b1": get("mid.bias").copy(),
            "w2": get("out.weight").T.copy(), "b2": get("out.bias").copy()}


def gelu(x):
    from math import sqrt
    return 0.5 * x * (1 + erf(x / sqrt(2)))


try:
    from scipy.special import erf  # the pk-ml venv has it
except ImportError:
    def erf(x):
        return np.vectorize(__import__("math").erf, otypes=[np.float32])(x)


def forward(h, x):
    pre = x @ h["w1"] + h["b1"]
    hid = 0.5 * pre * (1 + erf(pre / np.sqrt(2)))
    return pre, hid, hid @ h["w2"] + h["b2"]


def softmax(z):
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def fit(start, base, X, y, w, epochs=8, lr=1e-3, anchor=1e-2, batch=64, seed=7, each_epoch=None):
    """OnDeviceReaderLearner.fit: AdamW-style Adam steps with λ(θ − θ₀).
    Pass 47: `each_epoch(k, head)` after every epoch (the head as it is)."""
    h = {k: v.copy() for k, v in start.items()}
    m = {k: np.zeros_like(v) for k, v in h.items()}
    v_ = {k: np.zeros_like(v) for k, v in h.items()}
    t = 0
    rng = np.random.default_rng(seed)
    n = len(y)
    for epoch in range(epochs):
        order = rng.permutation(n)
        for i in range(0, n, batch):
            idx = order[i:i + batch]
            xb, yb, wb = X[idx], y[idx], w[idx]
            pre, hid, logits = forward(h, xb)
            p = softmax(logits)
            onehot = np.zeros_like(p)
            onehot[np.arange(len(yb)), yb] = 1
            dl = (p - onehot) * (wb / max(wb.sum(), 1e-6))[:, None]
            g = {"w2": hid.T @ dl, "b2": dl.sum(0)}
            dh = dl @ h["w2"].T
            cdf = 0.5 * (1 + erf(pre / np.sqrt(2)))
            pdf = np.exp(-0.5 * pre * pre) / np.sqrt(2 * np.pi)
            dh *= cdf + pre * pdf
            g["w1"] = xb.T @ dh
            g["b1"] = dh.sum(0)
            t += 1
            for k in h:
                g[k] += anchor * (h[k] - base[k])
                m[k] = 0.9 * m[k] + 0.1 * g[k]
                v_[k] = 0.999 * v_[k] + 0.001 * g[k] * g[k]
                mh, vh = m[k] / (1 - 0.9 ** t), v_[k] / (1 - 0.999 ** t)
                h[k] -= lr * mh / (np.sqrt(vh) + 1e-8)
        if each_epoch:
            each_epoch(epoch + 1, {k: v.copy() for k, v in h.items()})
    return h


def loss(h, X, y, w):
    p = softmax(forward(h, X)[2])
    return float(-(w * np.log(p[np.arange(len(y)), y] + 1e-9)).sum() / max(w.sum(), 1e-6))


# ------------------------------------------------------------------ anchor

def read_anchor():
    """ReaderAnchor.bin: lab sentences as the shipped readers see them."""
    path = os.path.join(ROOT, "Resources", "Detection", "ReaderAnchor.bin")
    data = open(path, "rb").read()
    n = struct.unpack("<I", data[8:12])[0]
    entries = json.loads(data[12:12 + n])
    off = 12 + n
    X = [[], []]
    y, w = [], []
    for e in entries:
        for r, d in enumerate(e["dims"]):
            X[r].append(np.frombuffer(data, dtype="<f2", count=d, offset=off).astype(np.float32))
            off += 2 * d
        y.append(e["l"]); w.append(e["w"])
    return [np.array(x) for x in X], np.array(y), np.array(w, dtype=np.float32)


# ------------------------------------------------------------------ prepare

def prepare(results, out):
    os.makedirs(out, exist_ok=True)
    d = json.load(open(results))
    todo = []
    for e in d["episodes"]:
        k = key_of(e)
        lines = e["transcript"]
        if not lines:
            continue
        json.dump([{"text": l["text"], "start": l["start"], "end": l["end"], "words": l.get("words") or []}
                   for l in lines], open(os.path.join(out, k + ".json"), "w"))
        sents = sentences(lines)
        json.dump([s["start"] for s in sents], open(os.path.join(out, k + ".pick.json"), "w"))
        if not os.path.exists(os.path.join(out, k + ".feat.npz")):
            todo.append((k, sents))
    print(f"{len(todo)} episodes to read")
    for k, sents in todo:
        dump = os.path.join(out, k + ".featdump.json")
        env = dict(os.environ, LAB_TAGGER=":".join(WEIGHTS), LAB_FEATPICK=os.path.join(out, k + ".pick.json"),
                   LAB_FEATDUMP=dump)
        subprocess.run([BIN, os.path.join(out, k + ".json"), "", "", ""], env=env, check=True, capture_output=True)
        rows = json.load(open(dump))
        by = {round(r[0] * 100): r[1:] for r in rows}
        per = (len(rows[0]) - 1) // 2
        F0 = np.zeros((len(sents), per), np.float16)
        F1 = np.zeros((len(sents), per), np.float16)
        for i, s in enumerate(sents):
            f = by.get(round(s["start"] * 100))
            if f is not None:
                F0[i] = f[:per]; F1[i] = f[per:]
        np.savez_compressed(os.path.join(out, k + ".feat.npz"), f0=F0, f1=F1,
                            start=np.array([s["start"] for s in sents]), end=np.array([s["end"] for s in sents]))
        os.remove(dump)
        print("   ", k, len(sents), "sentences")


# ------------------------------------------------------------------ teachers

ENGINES = ("MLX · Qwen3.5 4B", "MLX · Qwen3.5 4B Instruct (6-bit)", "Core AI · Qwen3 4B",
           "Core AI · MiniCPM5 2B", "MLX · Qwen3.5 2B", "Apple Intelligence")
SELL = re.compile(r"promo code|use code|\bcode [a-z]{3,}|\.com\b|dot com|slash|sponsor|brought to you by|"
                  r"support for|free trial|% off|percent off|terms apply|tickets|on tour|subscribe", re.I)


def engine_cuts(e):
    """Each engine's newest saved cuts (model engines) on this episode."""
    out = {}
    for a in sorted(e.get("attempts", []), key=lambda a: a["date"], reverse=True):
        m = a.get("method", "")
        if m in ENGINES and m not in out:
            cuts = a.get("savedCuts") or []
            if m == "Apple Intelligence" or cuts or a.get("parts"):
                out[m] = [(c["start"], c["end"], KIND_INDEX.get(c["kind"])) for c in cuts]
    return out


def mid(s):
    return (s[0] + s[1]) / 2


def single_labels(e, starts, ends):
    """Pass 38 silver: the newest model attempt's cuts; show far from them."""
    cuts = None
    for a in sorted(e.get("attempts", []), key=lambda a: a["date"], reverse=True):
        if a.get("method", "") in ENGINES and a.get("method") != "Apple Intelligence":
            cuts = [(c["start"], c["end"], KIND_INDEX.get(c["kind"])) for c in a.get("savedCuts", [])]
            break
    if cuts is None:
        return {}
    out, neg = {}, []
    for i in range(len(starts)):
        m = (starts[i] + ends[i]) / 2
        hit = next((c for c in cuts if c[0] <= m <= c[1] and c[2]), None)
        if hit:
            out[i] = (hit[2], 1.0)
        elif all(m < c[0] - 60 or m > c[1] + 60 for c in cuts):
            neg.append(i)
    keep = min(len(neg), max(60, 3 * len(out)), 300)
    if keep:
        step = len(neg) / keep
        for j in range(keep):
            out[neg[int(j * step)]] = (0, 0.5)
    return out


def consensus_labels(e, starts, ends, texts, hard=False, prior=0.12):
    """Pass 43: a sentence is a promo of kind k when at least two engines
    from different families cut it and most of those say k (or the ad-free
    comparison proved it stitched in); the show when every engine that read
    it left it alone and it is 30 s from any engine's cut. Everything else is
    left out. Weighted so promos are `prior` of the episode's weight."""
    engines = engine_cuts(e)
    inserted = []
    for a in e.get("attempts", []):
        inserted += [(c["start"], c["end"]) for c in a.get("readerCuts", []) if c.get("insertedAtDownload")]
    families = {m: ("qwen" if "Qwen" in m else "minicpm" if "MiniCPM" in m else "apple" if "Apple" in m else m)
                for m in engines}
    if len(set(families.values())) < 2 and not inserted:
        return {}
    pos, neg = {}, []
    for i in range(len(starts)):
        m = (starts[i] + ends[i]) / 2
        if any(a <= m <= b for a, b in inserted):
            pos[i] = (1, 2.0)
            continue
        votes = collections.Counter()
        fams = set()
        for name, cuts in engines.items():
            hit = next((c for c in cuts if c[0] <= m <= c[1]), None)
            if hit and hit[2]:
                votes[hit[2]] += 1
                fams.add(families[name])
        if len(fams) >= 2:
            kind, n = votes.most_common(1)[0]
            if n * 2 > sum(votes.values()):
                pos[i] = (kind, 1.0 + 0.5 * (len(fams) - 2))
            continue
        if not votes and all(all(m < c[0] - 30 or m > c[1] + 30 for c in cuts) for cuts in engines.values()):
            neg.append(i)
    out = dict(pos)
    if not neg:
        return out
    # Promos keep `prior` of the weight, whatever share they are here.
    wp = sum(w for _, w in pos.values())
    wn_total = wp * (1 - prior) / prior if wp > 0 else len(neg) * 0.5
    per = wn_total / len(neg)
    for i in neg:
        boost = 2.0 if hard and SELL.search(texts[i]) else 1.0
        out[i] = (0, per * boost)
    return out



def gold46_labels(e, starts, ends):
    """OnDeviceReaderLearner.goldLabels as Pass 46 shipped it."""
    out = {}
    deltas = e.get("corrections") or []
    settled = [(d["start"], d["end"]) for d in deltas]
    for d in deltas:
        label = 0 if d["action"] == "notAnAd" else KIND_INDEX.get(d["kind"])
        if label is None:
            continue
        for i in range(len(starts)):
            if d["start"] <= mid((starts[i], ends[i])) <= d["end"]:
                out[i] = (label, 5.0)
        if d["action"] not in ("lock", "edit", "add") or label == 0:
            continue
        for i in range(len(starts)):
            if i in out:
                continue
            m = mid((starts[i], ends[i]))
            near = d["start"] - 45 <= m < d["start"] or d["end"] < m <= d["end"] + 45
            if near and not any(a <= m <= b for a, b in settled):
                out[i] = (0, 2.0)
    return out


def in_force(d, current):
    """A correction still says what the episode says now."""
    length = max(d["end"] - d["start"], 1e-3)
    covered = sum(max(0.0, min(d["end"], c[1]) - max(d["start"], c[0])) for c in current)
    if d["action"] == "notAnAd":
        return covered < 0.2 * length
    return covered >= 0.5 * length


def gold47_labels(e, starts, ends, prior=0.395, cap=150):
    """Pass 47: OnDeviceReaderLearner.goldLabels(…current:)."""
    current = [(s["start"], s["end"], KIND_INDEX.get(s.get("kind"))) for s in e.get("segments") or []]
    live = [d for d in (e.get("corrections") or []) if in_force(d, current)]
    out = {}
    for d in live:
        for i in range(len(starts)):
            m = mid((starts[i], ends[i]))
            if not d["start"] <= m <= d["end"]:
                continue
            if d["action"] == "notAnAd":
                out[i] = (0, 5.0)
                continue
            over = next((c for c in current if c[0] <= m <= c[1] and c[2]), None)
            if over:
                out[i] = (over[2], 5.0)
        if d["action"] in ("lock", "edit", "add"):
            for i in range(len(starts)):
                m = mid((starts[i], ends[i]))
                near = d["start"] - 45 <= m < d["start"] or d["end"] < m <= d["end"] + 45
                if near and i not in out and not any(c[0] <= m <= c[1] for c in current):
                    out[i] = (0, 2.0)
    if not out:
        return out
    # The show he left alone in an episode he reviewed: far from every cut.
    spans = [(c[0], c[1]) for c in current] + [(d["start"], d["end"]) for d in live]
    far = [i for i in range(len(starts)) if i not in out
           and all(mid((starts[i], ends[i])) < a - 60 or mid((starts[i], ends[i])) > b + 60 for a, b in spans)]
    wp = sum(w for c, w in out.values() if c > 0)
    ws = sum(w for c, w in out.values() if c == 0)
    want = wp * (1 - prior) / prior - ws
    if far and want > 0:
        keep = min(len(far), 300)
        step = len(far) / keep
        per = min(2.0, want / keep)
        for j in range(keep):
            out[far[int(j * step)]] = (0, per)
    total = sum(w for _, w in out.values())
    if total > cap * 5.0:
        scale = cap * 5.0 / total
        out = {i: (c, w * scale) for i, (c, w) in out.items()}
    return out


def fit_select(start, base, X, y, w, AXc, Ayc, Awc, epochs=8, tol=0.01, **kw):
    """Pass 47: one epoch at a time; the last epoch whose held-out lab loss
    stays within `tol` of the start's. None when no epoch does."""
    limit = loss(start, AXc, Ayc, Awc) * (1 + tol) + 1e-4
    kept = []

    def check(k, head):
        if loss(head, AXc, Ayc, Awc) <= limit:
            kept.append((k, head))
    fit(start, base, X, y, w, epochs=epochs, each_epoch=check, **kw)
    return kept[-1] if kept else None

# ------------------------------------------------------------------ run

def load_features(out, k):
    z = np.load(os.path.join(out, k + ".feat.npz"))
    return [z["f0"].astype(np.float32), z["f1"].astype(np.float32)], z["start"], z["end"]


def detect(out, k, probs, starts, ends, tag):
    rows = [[float(s), float(t)] + [float(x) for x in p] for s, t, p in zip(starts, ends, probs)]
    path = os.path.join(out, f"{k}.{tag}.probs.json")
    json.dump(rows, open(path, "w"))
    env = dict(os.environ, LAB_TAGGER=":".join(WEIGHTS), LAB_TAGPROBS=path)
    r = subprocess.run([BIN, os.path.join(out, k + ".json"), "", "", ""], env=env, capture_output=True, text=True)
    cuts = []
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):([\d.]+)–(\d+):(\d+):([\d.]+)", r.stdout, re.M):
        kind, h1, m1, s1, h2, m2, s2 = m.groups()
        cuts.append((int(h1) * 3600 + int(m1) * 60 + float(s1), int(h2) * 3600 + int(m2) * 60 + float(s2), kind))
    return cuts


def run(results, out, variants):
    d = json.load(open(results))
    labels = phone_eval.load_labels()
    episodes = [e for e in d["episodes"] if e["transcript"] and os.path.exists(os.path.join(out, key_of(e) + ".feat.npz"))]
    labelled = sorted([e for e in episodes if e["guid"] in labels], key=lambda e: e["guid"])
    folds = [labelled[0::2], labelled[1::2]]
    base = [read_head(w) for w in WEIGHTS]
    AX, Ay, Aw = read_anchor()
    a_train = np.arange(len(Ay)) % 2 == 0
    feats = {key_of(e): load_features(out, key_of(e)) for e in episodes}
    texts = {key_of(e): [s["text"] for s in sentences(e["transcript"])] for e in episodes}
    scored = {}
    for variant in variants:
        for f, held in enumerate(folds):
            held_ids = {e["guid"] for e in held}
            heads = base
            note = ""
            if variant != "base":
                X = [[], []]; y = []; w = []
                for e in episodes:
                    if e["guid"] in held_ids:
                        continue
                    k = key_of(e)
                    F, s, t = feats[k]
                    if variant == "single":
                        lab = single_labels(e, s, t)
                    elif variant.startswith("gold"):
                        lab = dict(consensus_labels(e, s, t, texts[k], prior=0.395))
                        if variant.startswith("gold47"):
                            silver = sum(wt for _, wt in lab.values())
                            gold = gold47_labels(e, s, t)
                        else:
                            gold = gold46_labels(e, s, t)
                        if gold:
                            lab = gold  # his word replaces the models' on that episode
                    else:
                        # "consensus@0.4": promos keep that share of the weight;
                        # "~1": his sentences weigh as much as the lab's in all.
                        name, _, share = variant.split("~")[0].partition("@")
                        lab = consensus_labels(e, s, t, texts[k], hard=name.endswith("hard"),
                                               prior=float(share) if share else 0.12)
                    for i, (cls, wt) in lab.items():
                        if not F[0][i].any():
                            continue
                        X[0].append(F[0][i]); X[1].append(F[1][i]); y.append(cls); w.append(wt)
                y = np.array(y); w = np.array(w, dtype=np.float32)
                if variant.startswith("gold47") and w.sum() > Aw[a_train].sum():
                    w *= Aw[a_train].sum() / w.sum()
                if "~" in variant:
                    w *= float(variant.split("~")[1]) * Aw[a_train].sum() / max(w.sum(), 1e-6)
                heads = []
                for r in range(2):
                    Xr = np.concatenate([np.array(X[r]), AX[r][a_train]])
                    yr = np.concatenate([y, Ay[a_train]])
                    wr = np.concatenate([w, Aw[a_train]])
                    if variant.startswith("gold47"):
                        kept = fit_select(base[r], base[r], Xr, yr, wr, AX[r][~a_train], Ay[~a_train], Aw[~a_train])
                        note_epochs = getattr(run, "epochs", [])
                        note_epochs.append(kept[0] if kept else 0); run.epochs = note_epochs
                        heads.append(kept[1] if kept else base[r])
                    else:
                        heads.append(fit(base[r], base[r], Xr, yr, wr))
                before = np.mean([loss(base[r], AX[r][~a_train], Ay[~a_train], Aw[~a_train]) for r in range(2)])
                after = np.mean([loss(heads[r], AX[r][~a_train], Ay[~a_train], Aw[~a_train]) for r in range(2)])
                note = f"{len(y)} examples ({(y > 0).mean():.0%} promo), anchor loss {before:.3f} → {after:.3f}"
            print(f"{variant} fold {f}: {note}")
            for e in held:
                k = key_of(e)
                F, s, t = feats[k]
                P = np.mean([softmax(forward(heads[r], F[r])[2]) for r in range(2)], axis=0)
                scored.setdefault(e["guid"], {})[variant] = detect(out, k, P, s, t, variant)
    path = os.path.join(out, "cuts.json")
    json.dump(scored, open(path, "w"))
    print("wrote", path)


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "prepare":
        prepare(sys.argv[2], sys.argv[3])
    elif mode == "run":
        run(sys.argv[2], sys.argv[3], sys.argv[4:] or ["base", "single", "consensus", "consensus+hard"])
    else:
        raise SystemExit(__doc__)
