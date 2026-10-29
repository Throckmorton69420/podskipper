#!/usr/bin/env python3
"""Pass 44: retrain PodSkipper's reader as a whole — the 14 M-parameter body
that reads the conversation, not only the small head on top — from what the
stronger readers know, and measure it the way the app runs it.

Pass 43 showed the head alone is at its limit: every head-only variant moved
along the same trade-off (fewer ads heard for more show cut). What the reader
lacks is understanding — which sentences are a hand-off, a plug, a credit,
a produced spot — and that lives in the body. So the body is trained again,
from ELECTRA-small, on:

  lab        the 17 lab fixtures (Claude-labelled, pass 25) — as shipped
  labelled   his phone's episodes labelled from their transcripts
             (Tools/DetectionLab/phone-labels/, Claude-labelled, passes 43–44);
             EITHER sentences are left out (either answer is fine)
  his        what he reviewed (locked, confirmed, added, "not an ad") —
             overrides any other label, at REVIEW_W
  agreement  episodes no one labelled: sentences where two model families
             cut the same kind (or the ad-free copy proves it stitched in),
             and show sentences every engine left alone, 30 s from any cut —
             at AGREE_W (Pass 43: 98 % / 99.9 % precise against the labels);
             everything the engines disagree on is left out
  older      LAB_OLDER=1: episodes from older exports, by agreement only

Nothing a single engine said is taken as a label.

    reader_distill.py prepare <results.json>
    reader_distill.py folds <results.json> <tag> [folds] [variant]
        k-fold over the labelled episodes: each fold's readers never see its
        episodes (nor any copy of them); the app's detector (`lab-segments`
        with LAB_TAGPROBS) cuts them; scored with phone_eval against the
        labels, next to the shipped readers → build/p44/<tag>/
    reader_distill.py train <results.json> <tag>
        both readers on everything → build/p44/<tag>/TaggerWeights{,-2}.bin
        (then `tagger.py style` per reader adds the delivery reader)

Settings: EPOCHS, LR, SEEDS (default "7,11"), REVIEW_W, AGREE_W, WARM=1 (start
from the shipped readers instead of ELECTRA-small). Run with
~/Developer/pk-ml/bin/python -I -u.
"""
import collections, gzip, glob, json, os, re, struct, subprocess, sys, time
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import phone_eval  # noqa: E402
import tagger  # noqa: E402
import reader_consensus as rc  # noqa: E402

E = os.environ.get
OUT = os.path.join(ROOT, "build", E("READER_OUT", "p44"))
DATA = os.path.join(OUT, "reader")
SHIPPED = [os.path.join(ROOT, "Resources", "Detection", "TaggerWeights.bin"),
           os.path.join(ROOT, "Resources", "Detection", "TaggerWeights-2.bin")]
BIN = E("LAB_SEGMENTS", os.path.join(ROOT, "build", "p43-reader", "lab-segments"))
REVIEW_W = float(E("REVIEW_W", "2.0"))
AGREE_W = float(E("AGREE_W", "0.6"))
EXT_W = float(E("EXT_W", "0.5"))
SEEDS = [int(s) for s in E("SEEDS", "7,11").split(",")]
LETTER = {"AD": "A", "SELF": "S", "NETWORK": "N", "INTRO": "I", "OUTRO": "O"}
APP = {"ad": "A", "selfPromo": "S", "crossPromo": "N", "intro": "I", "outro": "O", "credits": "O"}


def key_of(e):
    return rc.key_of(e)


def norm(t):
    return re.sub(r"[^a-z0-9]", "", t.lower())[:30]


# ------------------------------------------------------------------ labels

def labelled_sentences(e, label):
    """Sentence letters from a phone-labels file: inside a region to skip →
    its letter, inside EITHER → None (left out), elsewhere → C."""
    lines = e["transcript"]
    spans = phone_eval.spans(label, lines)
    sents = tagger.sentences(lines)
    out = []
    for s in sents:
        m = (s["start"] + s["end"]) / 2
        hit = next((sp for sp in spans if sp[0] <= m <= sp[1]), None)
        if hit is None:
            out.append("C")
        elif hit[2] == "EITHER":
            out.append(None)
        else:
            out.append(LETTER.get(hit[2]))
    return sents, out


def his_reviews(e, sents):
    """index → letter for sentences inside what he reviewed."""
    out = {}
    for seg in e.get("segments", []):
        if not tagger.reviewed(seg):
            continue
        letter = "C" if seg.get("verdict") == "notAnAd" else APP.get(seg["kind"])
        if not letter:
            continue
        for i, s in enumerate(sents):
            m = (s["start"] + s["end"]) / 2
            if seg["start"] <= m <= seg["end"]:
                out[i] = letter
    return out


def agreement_sentences(e, sents):
    starts = [s["start"] for s in sents]
    ends = [s["end"] for s in sents]
    lab = rc.consensus_labels(e, starts, ends, [s["text"] for s in sents], prior=0.395)
    letters = [None] * len(sents)
    weights = [0.0] * len(sents)
    for i, (cls, w) in lab.items():
        letters[i] = tagger.LABELS[cls]
        weights[i] = w
    return letters, weights


def episode(e, kind, sents, letters, weights):
    return {"key": f"{kind}:{e['guid']}", "guid": e["guid"], "title": e["title"], "show": e.get("show", ""),
            "sents": sents, "labels": letters, "weight": 1.0, "sw": weights, "gold": kind == "labelled",
            "kind": kind}


def show_key(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def external_episodes(held_shows=frozenset()):
    """Pass 53: EXTERNAL=<episodes.json>[,…] (Tools/ReaderData), at EXT_W."""
    out = []
    for path in filter(None, E("EXTERNAL", "").split(",")):
        for ep in json.load(open(path)):
            if show_key(ep["show"]) in held_shows:
                continue
            ep = dict(ep, weight=EXT_W, gold=False, kind="external")
            ep["sw"] = [1.0 if l is not None else 0.0 for l in ep["labels"]]
            out.append(ep)
    return out


def build_training(results, held=frozenset(), held_shows=frozenset()):
    """Every training episode, none of them (or a copy of them) held out.
    Pass 53: `held_shows` keeps out every episode of those shows too."""
    labels = phone_eval.load_labels()
    data = json.load(open(results))
    held_titles = {norm(e["title"]) for e in data["episodes"] if e["guid"] in held}
    eps, counts = [], collections.Counter()
    seen = set()

    def add(e):
        if e["guid"] in held or norm(e["title"]) in held_titles or e["guid"] in seen:
            return
        if show_key(e.get("show", "")) in held_shows:
            return
        if not e.get("transcript") or "We Are Garbage" in e["title"]:
            return
        sents = tagger.sentences(e["transcript"])
        if len(sents) < 20:
            return
        seen.add(e["guid"])
        reviews = his_reviews(e, sents)
        if e["guid"] in labels:
            sents, letters = labelled_sentences(e, labels[e["guid"]])
            weights = [1.0 if l is not None else 0.0 for l in letters]
            kind = "labelled"
        else:
            letters, weights = agreement_sentences(e, sents)
            weights = [w * AGREE_W for w in weights]
            kind = "agreement"
        for i, letter in reviews.items():
            letters[i] = letter
            weights[i] = REVIEW_W
        if not any(w > 0 for w in weights):
            return
        letters = [l if w > 0 else None for l, w in zip(letters, weights)]
        eps.append(episode(e, kind, sents, letters, weights))
        counts[kind] += 1
        counts[kind + " sentences"] += sum(1 for w in weights if w > 0)
        counts["his sentences"] += len(reviews)

    for e in data["episodes"]:
        add(e)
    if E("LAB_OLDER") == "1":
        for path in tagger.phone_files():
            if os.path.abspath(path) == os.path.abspath(results):
                continue
            older = json.load(gzip.open(path) if path.endswith(".gz") else open(path))
            for e in older["episodes"]:
                add(e)
    lab = [tagger.lab_episode(k) for k in tagger.KEYS if os.path.exists(os.path.join(tagger.LAB, k + ".json"))]
    for ep in lab:
        if norm(ep["title"]) in held_titles:
            continue
        words = tagger.SHOWWORDS.get(tagger.group_of(ep.get("key", "")) or "", "\x00")
        if any(words.replace(" ", "") in h for h in held_shows):
            continue
        ep["kind"] = "lab"
        eps.append(ep)
        counts["lab"] += 1
    for ep in external_episodes(held_shows):
        eps.append(ep)
        counts["external"] += 1
        counts["external sentences"] += sum(1 for l in ep["labels"] if l is not None)
    return eps, counts


# ------------------------------------------------------------------ weights

def load_pstg(model, path):
    """The app's weights file back into the training model (WARM=1)."""
    import torch
    data = open(path, "rb").read()
    n = struct.unpack("<I", data[8:12])[0]
    header = json.loads(data[12:12 + n])
    base = 12 + n
    sd = model.state_dict()
    loaded = 0
    with torch.no_grad():
        for t in header["tensors"]:
            name = t["name"] if t["name"] in sd else "enc." + t["name"]
            if name not in sd:
                continue
            count = int(np.prod(t["shape"]))
            arr = np.frombuffer(data, dtype="<f2", count=count, offset=base + t["offset"]).astype(np.float32)
            sd[name].copy_(torch.from_numpy(arr.reshape(t["shape"])))
            loaded += 1
    return loaded


def train_pair(eps, tok, log):
    models = []
    for seed in SEEDS:
        tagger.SEED = seed
        if E("WARM") == "1":
            # tagger.train_model builds a fresh model; warm start by loading
            # the shipped reader of the same slot into it first.
            orig = tagger.build_model
            slot = len(models)

            def warm(backbone, orig=orig, slot=slot):
                m = orig(backbone)
                log("   warm start from", os.path.basename(SHIPPED[slot % 2]), load_pstg(m, SHIPPED[slot % 2]), "tensors")
                return m
            tagger.build_model = warm
            try:
                models.append(tagger.half_rounded(tagger.train_model(eps, tok, log)))
            finally:
                tagger.build_model = orig
        else:
            models.append(tagger.half_rounded(tagger.train_model(eps, tok, log)))
    return models


# ------------------------------------------------------------------ the app's detector

def prepare(results):
    os.makedirs(DATA, exist_ok=True)
    for e in json.load(open(results))["episodes"]:
        if not e.get("transcript"):
            continue
        path = os.path.join(DATA, key_of(e) + ".json")
        if not os.path.exists(path):
            json.dump([{"text": l["text"], "start": l["start"], "end": l["end"], "words": l.get("words") or []}
                       for l in e["transcript"]], open(path, "w"))


def detect(k, rows=None, weights=None):
    """The app's cuts for one prepared transcript, from given probabilities
    (rows of start, end, six) or from given weights files."""
    env = dict(os.environ, LAB_TAGGER=":".join(weights or SHIPPED))
    if rows is not None:
        path = os.path.join(DATA, f"{k}.{os.getpid()}.probs.json")
        json.dump(rows, open(path, "w"))
        env["LAB_TAGPROBS"] = path
    r = subprocess.run([BIN, os.path.join(DATA, k + ".json"), "", "", ""], env=env, capture_output=True, text=True)
    if rows is not None:
        os.remove(path)
    cuts = []
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):([\d.]+)–(\d+):(\d+):([\d.]+)", r.stdout, re.M):
        kind, h1, m1, s1, h2, m2, s2 = m.groups()
        cuts.append((int(h1) * 3600 + int(m1) * 60 + float(s1), int(h2) * 3600 + int(m2) * 60 + float(s2), kind))
    return cuts


def probs_rows(models, e, tok):
    ep = {"sents": tagger.sentences(e["transcript"]), "labels": None, "weight": 1.0}
    ep["labels"] = ["C"] * len(ep["sents"])
    P = np.mean([tagger.predict(m, ep, tok) for m in models], axis=0)
    return [[s["start"], s["end"]] + [float(x) for x in p] for s, p in zip(ep["sents"], P)]


def block_edges(label_spans, cuts):
    """Where a listener's skip starts and ends against the labelled break:
    labelled skips (and EITHER) within 3 s of each other are one break, and
    the cuts touching it one skip — so a break of three spots cut as one
    isn't counted as two wrong edges. (start error, end error) per break
    that is at least half cut."""
    spans = sorted((a, b, k) for a, b, k, _ in label_spans if k in phone_eval.SKIP or k == "EITHER")
    blocks = []
    for a, b, k in spans:
        if blocks and a <= blocks[-1][1] + 3:
            blocks[-1][1] = max(blocks[-1][1], b); blocks[-1][2] |= k != "EITHER"
        else:
            blocks.append([a, b, k != "EITHER"])
    cut_ivs = phone_eval.union([(c[0], c[1]) for c in cuts])
    out = []
    for a, b, real in blocks:
        if not real:
            continue
        touching = [iv for iv in cut_ivs if iv[1] > a and iv[0] < b]
        if not touching or phone_eval.covered(a, b, cut_ivs) / max(0.1, b - a) < 0.5:
            continue
        out.append((abs(touching[0][0] - a), abs(touching[-1][1] - b)))
    return out


def summary(scored, results):
    labels = phone_eval.load_labels()
    episodes = {e["guid"]: e for e in json.load(open(results))["episodes"]}
    totals = collections.defaultdict(collections.Counter)
    edges = collections.defaultdict(list)
    for guid, sets in scored.items():
        e = episodes[guid]
        ls = phone_eval.spans(labels[guid], e["transcript"])
        audio = e["transcript"][-1]["end"]
        for name, cuts in sets.items():
            s = phone_eval.score(ls, [tuple(c) for c in cuts], audio)
            t = totals[name]
            t["audio"] += audio; t["heard"] += s["heard"]; t["show"] += s["show_cut"]
            t["missed"] += len(s["missed"]); t["regions"] += s["regions"]; t["kind"] += s["wrong_kind"]
            edges[name] += block_edges(ls, cuts)
    lines = [f"{'reader':34} {'heard s/h':>9} {'show s/h':>9} {'missed':>8} {'kind✗':>6} {'break start±':>12} {'end±':>6}"]
    for name, t in sorted(totals.items()):
        h = t["audio"] / 3600
        ed = edges[name]
        lines.append(f"{name:34} {t['heard'] / h:9.1f} {t['show'] / h:9.1f} {t['missed']:4d}/{t['regions']:<3d} "
                     f"{t['kind']:6d} {np.median([abs(x[0]) for x in ed]) if ed else 0:12.1f} "
                     f"{np.median([abs(x[1]) for x in ed]) if ed else 0:6.1f}")
    return "\n".join(lines)


def folds(results, tag, k=2):
    from transformers import AutoTokenizer
    out = os.path.join(OUT, tag)
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "log.txt"), "a")

    def log(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True); logf.write(s + "\n"); logf.flush()
    prepare(results)
    tok = AutoTokenizer.from_pretrained(tagger.BACKBONE)
    labels = phone_eval.load_labels()
    episodes = {e["guid"]: e for e in json.load(open(results))["episodes"]}
    labelled = sorted(g for g in labels if g in episodes)
    log(f"== {time.strftime('%H:%M:%S')} folds {tag}: {len(labelled)} labelled episodes, {k} folds, "
        f"epochs {tagger.EPOCHS} lr {tagger.LR} seeds {SEEDS} review_w {REVIEW_W} agree_w {AGREE_W} "
        f"warm {E('WARM', '0')} older {E('LAB_OLDER', '0')}")
    scored_path = os.path.join(out, "cuts.json")
    scored = json.load(open(scored_path)) if os.path.exists(scored_path) else {}
    for f in range(k):
        held = set(labelled[f::k])
        if all(tag in scored.get(g, {}) for g in held):
            continue
        eps, counts = build_training(results, frozenset(held))
        log(f"fold {f}: hold out {len(held)}; train on {dict(counts)}")
        models = train_pair(eps, tok, log)
        probs_dir = os.path.join(out, "probs")
        os.makedirs(probs_dir, exist_ok=True)
        for g in sorted(held):
            e = episodes[g]
            kk = key_of(e)
            sets = scored.setdefault(g, {})
            if "shipped" not in sets:
                sets["shipped"] = detect(kk)
            rows = probs_rows(models, e, tok)
            # Kept, so the detector's own settings can be tuned on these
            # held-out answers without training again (`sweep`).
            json.dump({"fold": f, "rows": rows}, open(os.path.join(probs_dir, kk + ".json"), "w"))
            sets[tag] = detect(kk, rows=rows)
        json.dump(scored, open(scored_path, "w"))
        del models
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    log(summary(scored, results))


def show_groups(episodes, labelled, k):
    """Pass 53: the labelled episodes' shows in k groups of about equal
    episode counts (largest show first), so a fold holds out whole shows."""
    by = collections.defaultdict(list)
    for g in labelled:
        by[show_key(episodes[g].get("show", ""))].append(g)
    groups = [[] for _ in range(k)]
    for show, gs in sorted(by.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        min(groups, key=lambda x: sum(len(by[s]) for s in x)).append(show)
    return groups, by


def showfolds(results, tag, k=3):
    """`folds`, but each fold holds out whole shows — none of their
    episodes, labelled or not, and no lab fixture of them, is trained on."""
    from transformers import AutoTokenizer
    out = os.path.join(OUT, tag)
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "log.txt"), "a")

    def log(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True); logf.write(s + "\n"); logf.flush()
    prepare(results)
    tok = AutoTokenizer.from_pretrained(tagger.BACKBONE)
    labels = phone_eval.load_labels()
    episodes = {e["guid"]: e for e in json.load(open(results))["episodes"]}
    labelled = sorted(g for g in labels if g in episodes)
    groups, by = show_groups(episodes, labelled, k)
    log(f"== {time.strftime('%H:%M:%S')} showfolds {tag}: {len(labelled)} labelled episodes, shows "
        f"{[len(g) for g in groups]}, epochs {tagger.EPOCHS} lr {tagger.LR} seeds {SEEDS} ctx {tagger.CTX} "
        f"external {E('EXTERNAL', '')} ext_w {EXT_W}")
    scored_path = os.path.join(out, "cuts.json")
    scored = json.load(open(scored_path)) if os.path.exists(scored_path) else {}
    for f, shows in enumerate(groups):
        held = {g for s in shows for g in by[s]}
        if all(tag in scored.get(g, {}) for g in held):
            continue
        eps, counts = build_training(results, frozenset(held), frozenset(shows))
        log(f"fold {f}: hold out {len(held)} episodes of {len(shows)} shows {shows}; train on {dict(counts)}")
        models = train_pair(eps, tok, log)
        probs_dir = os.path.join(out, "probs")
        os.makedirs(probs_dir, exist_ok=True)
        for g in sorted(held):
            e = episodes[g]
            kk = key_of(e)
            rows = probs_rows(models, e, tok)
            json.dump({"fold": f, "rows": rows}, open(os.path.join(probs_dir, kk + ".json"), "w"))
            scored.setdefault(g, {})[tag] = detect(kk, rows=rows)
        json.dump(scored, open(scored_path, "w"))
        del models
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
    log(summary(scored, results))


def train(results, tag):
    from transformers import AutoTokenizer
    import torch
    out = os.path.join(OUT, tag)
    os.makedirs(out, exist_ok=True)
    logf = open(os.path.join(out, "log.txt"), "a")

    def log(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True); logf.write(s + "\n"); logf.flush()
    tok = AutoTokenizer.from_pretrained(tagger.BACKBONE)
    eps, counts = build_training(results)
    log(f"== {time.strftime('%H:%M:%S')} train {tag}: {dict(counts)} seeds {SEEDS}")
    for n, seed in enumerate(SEEDS):
        tagger.SEED = seed
        model = tagger.train_model(eps, tok, log)
        torch.save(model.state_dict(), os.path.join(out, f"model-{n + 1}.pt"))
        tagger.export(model.cpu(), tok, os.path.join(out, f"reader-{n + 1}-nostyle.bin"), log)
        del model
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()


def sweep(results, tag, grid):
    """The detector's own settings over the saved held-out answers of
    `folds` (`<tag>/probs`): folds 1–2 choose, fold 0 checks. Grid entries
    are `NAME=v1,v2,…` for LAB_SWITCH, LAB_TAGBOOST, LAB_KEEPFLOOR,
    LAB_JOINFLOOR, LAB_BETWEEN."""
    import itertools
    out = os.path.join(OUT, tag)
    probs = {}
    for name in os.listdir(os.path.join(out, "probs")):
        d = json.load(open(os.path.join(out, "probs", name)))
        probs[name[:-5]] = d
    episodes = {key_of(e): e for e in json.load(open(results))["episodes"]}
    axes = [(k, v.split(",")) for k, v in (g.split("=") for g in grid)]
    for combo in itertools.product(*[v for _, v in axes]):
        setting = dict(zip([k for k, _ in axes], combo))
        for k, v in setting.items():
            os.environ[k] = v
        name = " ".join(f"{k[4:].lower()}={v}" for k, v in setting.items())
        tune, check = {}, {}
        for kk, d in probs.items():
            e = episodes[kk]
            (check if d["fold"] == 0 else tune).setdefault(e["guid"], {})[name] = detect(kk, rows=d["rows"])
        if tune:
            print("tune ", summary(tune, results).splitlines()[1], flush=True)
        if check:
            print("check", summary(check, results).splitlines()[1], flush=True)
        for k in setting:
            del os.environ[k]


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "prepare":
        prepare(sys.argv[2])
    elif mode == "folds":
        folds(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 2)
    elif mode == "showfolds":
        showfolds(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 3)
    elif mode == "train":
        train(sys.argv[2], sys.argv[3])
    elif mode == "sweep":
        sweep(sys.argv[2], sys.argv[3], sys.argv[4:])
    else:
        raise SystemExit(__doc__)
