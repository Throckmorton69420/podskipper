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
from the shipped readers instead of ELECTRA-small).

Pass 66 distillation: SOFT=<dir>[:<dir>…] of <guid key>.json probability files
(rows [start, end, p_show, p_ad, p_self, p_cross, p_intro, p_outro], as
LAB_TAGDUMP or a fold run's probs/) adds a KL term towards those probabilities
(tagger.SOFT_W) for every sentence that has a row. The first folder that has
an episode's file wins. With SOFT set, the corpus manifest's unlabelled
episodes (never a test episode) that have a file join training with soft
targets only (kind "soft", weight SOFT_UNLAB_W, default 1.0); EXTERNAL
episodes take theirs too, and SOFT_EXT_LIMIT=n keeps n of them (spread over
shows, fixed order). Without SOFT nothing changes. Run with
~/Developer/pk-ml/bin/python -I -u.

Pass 67 (the two Pass 66 gate B bugs, and the multi-genre benchmark):
  GOLD_SOFT_W (default 0.0): factor on the soft term of every sentence that
      carries a human label (a labelled episode's labelled sentences, his
      reviews). Pass 66 pulled those towards show-held-out four-Reader answers
      that contradict the gold label (78.7 on the folds against the gold);
      unlabelled (EITHER) sentences of the same episodes keep their soft row.
  EXTERNAL=<file>[@k/K],…: @k/K keeps every K-th episode of that file from the
      k-th (stage 1 in shards; replay slices).
  SOFT_EXT_LIMIT now spreads over shows in a fixed hashed order (Pass 66: file
      order, so a small limit took only the first file's shows).
  HOLD_MULTIGENRE=1: every episode of the channels in
      build/p67/multigenre-test.json (Tools/ReaderData/multigenre_bench.py) is
      left out of EXTERNAL (training and stage 1 alike). Pass 68: and of
      build/p68/multigenre-clean.json (select-clean) when it exists (a warning
      when it doesn't).
  WEAK=<file>[,…] (Tools/ReaderData/sporc_weak_labels.py): hard labels on
      external sentences ({guid: [[index, letter], …]}), at WEAK_W (default 1.0)
      per sentence, where the episode has no label of its own.
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
# The app's Readers in its own order (SentenceTagger.weightURLs): TaggerWeights.bin, then -2 … -4 where bundled
# (Pass 66: four). SHIPPED_PAIR is Pass 58's pair alone, for comparisons with it.
SHIPPED = [p for p in [os.path.join(ROOT, "Resources", "Detection", "TaggerWeights.bin")]
           + [os.path.join(ROOT, "Resources", "Detection", "TaggerWeights-%d.bin" % n) for n in (2, 3, 4)]
           if os.path.exists(p)]
SHIPPED_PAIR = SHIPPED[:2]
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


TEACHER = E("TEACHER", "")


def silver_for(e):
    sys.path.insert(0, os.path.join(ROOT, "Tools", "ReaderData"))
    import silver
    return silver.sentences_for(e, TEACHER, AGREE_W)


def episode(e, kind, sents, letters, weights):
    return {"key": f"{kind}:{e['guid']}", "guid": e["guid"], "title": e["title"], "show": e.get("show", ""),
            "sents": sents, "labels": letters, "weight": 1.0, "sw": weights, "gold": kind == "labelled",
            "kind": kind}


SOFT_DIRS = [d for d in E("SOFT", "").split(":") if d]
SOFT_UNLAB_W = float(E("SOFT_UNLAB_W", "1.0"))


def soft_file(guid):
    # Fold runs name files by key_of (runs of other characters as one "_", the
    # last 60); silver.py's SILVER_PROBS by each character as "_". Either.
    names = [rc.key_of({"guid": guid}) + ".json", re.sub(r"[^A-Za-z0-9]", "_", guid) + ".json"]
    for d in SOFT_DIRS:
        for name in names:
            path = os.path.join(d, name)
            if os.path.exists(path):
                return path
    return None


def soft_rows_for(guid, sents):
    """Pass 66: each sentence's distillation target (CASNIO probabilities) from
    the SOFT folders, matched by start time (to 0.01 s, else the nearest row
    within 0.06 s), or None when the episode has no file."""
    path = soft_file(guid)
    if path is None:
        return None
    rows = json.load(open(path))
    rows = rows["rows"] if isinstance(rows, dict) else rows
    if not rows:
        return None
    by = {round(r[0], 2): r[2:8] for r in rows}
    starts = np.array([r[0] for r in rows])
    out = []
    for s in sents:
        r = by.get(round(s["start"], 2))
        if r is None:
            j = int(np.abs(starts - s["start"]).argmin())
            r = rows[j][2:8] if abs(starts[j] - s["start"]) <= 0.06 else None
        out.append(list(r) if r is not None else None)
    return out if any(r is not None for r in out) else None


def show_key(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


GOLD_SOFT_W = float(E("GOLD_SOFT_W", "0.0"))
WEAK_W = float(E("WEAK_W", "1.0"))


# Pass 67: SponsorBlock channels that carry his own shows (Whiskey Ginger, The Adam Friedland Show, We Might Be
# Drunk: 4 episodes in sb58 + sb65, titles without the show's name). They leaked into the show-held-out folds'
# stage 1 (Passes 65–66); left out with HOLD_MULTIGENRE=1.
HIS_CHANNELS = frozenset({"UCNGbPFX8UOm7qk6kvnHKr0w", "UC6ext5UAbrLT2e5y5BC6RTQ", "UCy6A9WMN43DrtBkID7nMXJw"})
MULTIGENRE_BENCHES = [os.path.join(ROOT, "build", "p67", "multigenre-test.json"),
                      os.path.join(ROOT, "build", "p68", "multigenre-clean.json")]


def multigenre_held():
    """Pass 67: the multi-genre benchmark's channels and episodes (HOLD_MULTIGENRE=1), and his shows' channels."""
    if E("HOLD_MULTIGENRE") != "1":
        return frozenset(), frozenset()
    channels, guids = set(HIS_CHANNELS), set()
    # Pass 68: the clean benchmark (sb66's 53 new channels) is held out too whenever it is on disk.
    for path in MULTIGENRE_BENCHES:
        if not os.path.exists(path):
            print(f"   warning: HOLD_MULTIGENRE=1 but {os.path.relpath(path, ROOT)} is missing — not held out", flush=True)
            continue
        bench = json.load(open(path))
        channels |= set(bench["channels"])
        guids |= {e["guid"] for e in bench["episodes"]}
    return frozenset(channels), frozenset(guids)


def weak_labels():
    out = {}
    for path in filter(None, E("WEAK", "").split(",")):
        for g, rows in json.load(open(path)).items():
            out.setdefault(g, []).extend(rows)
    return out


def test_held():
    """Pass 68: HOLD_TEST=1 — the test episodes' guids, normalised titles and show keys (corpus manifest), so an
    external copy of a test episode or any episode of a test show is left out too, not only the results file's."""
    if E("HOLD_TEST") != "1":
        return frozenset(), frozenset(), frozenset()
    sys.path.insert(0, os.path.join(ROOT, "Tools", "ReaderData"))
    import corpus
    tests = [m for m in corpus.load_manifest()["episodes"].values() if m["testEpisode"]]
    return (frozenset(m["guid"] for m in tests), frozenset(norm(m["title"]) for m in tests),
            frozenset(show_key(m["show"]) for m in tests))


def external_episodes(held_shows=frozenset()):
    """Pass 53: EXTERNAL=<episodes.json>[@k/K][,…] (Tools/ReaderData), at EXT_W."""
    out = []
    held_channels, held_guids = multigenre_held()
    test_guids, test_titles, test_shows = test_held()
    weak = weak_labels()
    counts = collections.Counter()
    for spec in filter(None, E("EXTERNAL", "").split(",")):
        path, _, shard = spec.partition("@")
        k, K = (int(x) for x in shard.split("/")) if shard else (0, 1)
        for i, ep in enumerate(json.load(open(path))):
            if i % K != k or show_key(ep["show"]) in held_shows:
                continue
            if ep["guid"] in held_guids or ep["show"].replace("YouTube @", "") in held_channels:
                counts["multigenre held out"] += 1
                continue
            if ep["guid"] in test_guids or norm(ep["title"]) in test_titles or show_key(ep["show"]) in test_shows:
                counts["test held out"] += 1
                continue
            ep = dict(ep, weight=EXT_W, gold=False, kind="external")
            if tagger.PU and ep["guid"].startswith("sponsorblock:"):
                # Pass 72: what this episode's SponsorBlock users never marked (tagger.PU).
                observed = {l for l in ep["labels"] if l}
                ep["_U"] = [k for k in "SNIO" if k not in observed]
                counts["partial-label episodes"] += 1
            ep["sw"] = [1.0 if l is not None else 0.0 for l in ep["labels"]]
            if ep["guid"] in weak:
                labels = list(ep["labels"])
                for j, letter in weak[ep["guid"]]:
                    if 0 <= j < len(labels) and labels[j] is None:
                        labels[j] = letter
                        ep["sw"][j] = WEAK_W
                        counts["weak sentences"] += 1
                ep["labels"] = labels
            if SOFT_DIRS:
                ep["soft"] = soft_rows_for(ep["guid"], ep["sents"])
            out.append(ep)
    if counts:
        print("   external:", dict(counts), flush=True)
    if SOFT_DIRS and E("SOFT_EXT_LIMIT"):
        out = spread(out, int(E("SOFT_EXT_LIMIT")))
    return out


def spread(eps, n):
    """Pass 66: n episodes taken round-robin over shows (each show's in file
    order), only ones that have soft targets. Pass 67: shows in a fixed hashed
    order, so several files mix."""
    import hashlib
    by = collections.OrderedDict()
    for ep in eps:
        if ep.get("soft") is not None:
            by.setdefault(show_key(ep["show"]), []).append(ep)
    shows = sorted(by, key=lambda x: hashlib.sha256(x.encode()).hexdigest())
    out, k = [], 0
    while len(out) < n and any(len(by[x]) > k for x in shows):
        out += [by[x][k] for x in shows if len(by[x]) > k]
        k += 1
    return out[:n]


def soft_unlabelled(held, held_shows, seen):
    """Pass 66: the corpus manifest's unlabelled episodes that have soft
    targets, as soft-only training episodes (no hard label)."""
    sys.path.insert(0, os.path.join(ROOT, "Tools", "ReaderData"))
    import corpus
    out, cache = [], {}
    for g, m in corpus.load_manifest()["episodes"].items():
        if m["labelled"] or m["testEpisode"] or m["copyOf"] or g in held or g in seen:
            continue
        if show_key(m.get("show", "")) in held_shows or soft_file(g) is None:
            continue
        if m["source"] not in cache:
            cache[m["source"]] = json.load(open(os.path.join(ROOT, m["source"])))["episodes"]
        e = cache[m["source"]][m["index"]]
        if not e.get("transcript"):
            continue
        sents = tagger.sentences(e["transcript"])
        soft = soft_rows_for(g, sents)
        if soft is None:
            continue
        # Pass 67: with TEACHER set, a teacher's silver labels on these episodes too (route 2). They were only
        # read in build_training's loop over the results file, which doesn't hold the manifest's unlabelled pool,
        # so a TEACHER run trained on soft targets alone.
        silver = silver_for(e) if TEACHER else None
        if silver is not None:
            s2, letters, weights = silver
            if len(s2) == len(sents):
                letters = [l if w > 0 else None for l, w in zip(letters, weights)]
                ep = episode(e, "teacher", sents, letters, weights)
                ep["soft"] = soft
                out.append(ep)
                continue
        ep = episode(e, "soft", sents, [None] * len(sents), [0.0] * len(sents))
        ep["weight"] = SOFT_UNLAB_W
        ep["soft"] = soft
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
        elif TEACHER and silver_for(e) is not None:
            # Pass 57: an unlabelled episode a teacher read whole —
            # Tools/ReaderData/silver.py keeps what the evidence agrees on.
            sents, letters, weights = silver_for(e)
            kind = "teacher"
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
        if SOFT_DIRS:
            eps[-1]["soft"] = soft_rows_for(e["guid"], sents)
            counts["soft targets"] += eps[-1]["soft"] is not None
            # Pass 67: a human label (a labelled sentence, his review) is not pulled towards the soft row.
            human = set(reviews) | ({i for i, w in enumerate(weights) if w > 0} if kind == "labelled" else set())
            if eps[-1]["soft"] is not None and human and GOLD_SOFT_W != 1.0:
                eps[-1]["softsw"] = [GOLD_SOFT_W if i in human else 1.0 for i in range(len(sents))]
                counts["gold sentences without soft"] += len(human) if GOLD_SOFT_W == 0 else 0
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
        counts["soft targets"] += ep.get("soft") is not None
    if SOFT_DIRS:
        for ep in soft_unlabelled(held, held_shows, seen):
            eps.append(ep)
            counts[ep["kind"]] += 1
            counts["soft targets"] += 1
            if ep["kind"] == "teacher":
                counts["teacher sentences"] += sum(1 for l in ep["labels"] if l is not None)
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
    # Pass 57: HOLD_TEST=1 leaves out the test episodes of the corpus
    # manifest (Tools/ReaderData/corpus.py) and any copy of them, so the
    # readers can be judged against the shipped ones on episodes neither saw.
    held = frozenset()
    if E("HOLD_TEST") == "1":
        sys.path.insert(0, os.path.join(ROOT, "Tools", "ReaderData"))
        import corpus
        held = frozenset(g for g, m in corpus.load_manifest()["episodes"].items() if m["testEpisode"])
    eps, counts = build_training(results, held)
    log(f"== {time.strftime('%H:%M:%S')} train {tag}: {dict(counts)} seeds {SEEDS} backbone {tagger.BACKBONE} "
        f"held out {len(held)} test episodes")
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


def pretrain(out_path):
    """Pass 58: stage 1 — a tagger trained on EXTERNAL episodes only (none of
    his shows), saved as a state dict for INIT=. PRE_EPOCHS (default 2)."""
    from transformers import AutoTokenizer
    import torch
    tok = AutoTokenizer.from_pretrained(tagger.BACKBONE)
    eps = external_episodes()
    for ep in eps:
        ep["weight"] = 1.0
    sents = sum(sum(1 for l in ep["labels"] if l is not None) for ep in eps)
    print(f"pretrain on {len(eps)} external episodes, {sents} labelled sentences, "
          f"{len({ep['show'] for ep in eps})} shows, epochs {E('PRE_EPOCHS', '2')}, seed {SEEDS[0]}", flush=True)
    tagger.EPOCHS = float(E("PRE_EPOCHS", "2"))
    tagger.SEED = SEEDS[0]
    model = tagger.train_model(eps, tok, lambda *a: print(*a, flush=True))
    torch.save({k: v.detach().cpu() for k, v in model.state_dict().items()}, out_path)
    print("saved", out_path, flush=True)


def leakcheck(results):
    """Pass 68: before a launch, what EXTERNAL (with this environment's HOLD_TEST / HOLD_MULTIGENRE) would train on
    against (a) the 11 test episodes and their shows, (b) both multi-genre benchmarks, (c) each show-held-out fold's
    shows (and the channels and titles of his shows, since a SponsorBlock "show" is a channel id). Exits 1 on a leak."""
    sys.path.insert(0, os.path.join(ROOT, "Tools", "ReaderData"))
    import corpus
    import sponsorblock_select as sbs
    tests = [m for m in corpus.load_manifest()["episodes"].values() if m["testEpisode"]]
    t_guids, t_titles = {m["guid"] for m in tests}, {norm(m["title"]) for m in tests}
    t_shows = {show_key(m["show"]) for m in tests}
    bench_ch, bench_g = set(), set()
    for path in MULTIGENRE_BENCHES:
        b = json.load(open(path))
        bench_ch |= set(b["channels"]); bench_g |= {e["guid"] for e in b["episodes"]}
    episodes = {e["guid"]: e for e in json.load(open(results))["episodes"]}
    labelled = sorted(g for g in phone_eval.load_labels() if g in episodes)
    groups, _ = show_groups(episodes, labelled, 3)
    his = {show_key(m["show"]) for m in corpus.load_manifest()["episodes"].values()}
    leaks = collections.Counter()
    eps = external_episodes()
    for ep in eps:
        ch = ep["show"].replace("YouTube @", "")
        sk = show_key(ep["show"])
        leaks["(a) test guid"] += ep["guid"] in t_guids
        leaks["(a) test title"] += norm(ep["title"]) in t_titles
        leaks["(a) test show"] += sk in t_shows
        leaks["(b) multigenre guid"] += ep["guid"] in bench_g
        leaks["(b) multigenre channel"] += ch in bench_ch
        leaks["(c) his show key"] += sk in his
        leaks["(c) his channel"] += ch in HIS_CHANNELS
        leaks["(c) title names his show"] += bool(sbs.HIS_SHOWS.search(ep["title"]))
    for f, shows in enumerate(groups):
        fold_eps = external_episodes(frozenset(shows))
        leaks[f"(c) fold {f} held-show episodes"] = sum(show_key(ep["show"]) in set(shows) for ep in fold_eps)
    by_file = collections.Counter(ep["key"].split(":")[0] if ":" in ep.get("key", "") else "?" for ep in eps)
    print(f"leakcheck: {len(eps)} external episodes {dict(by_file)} · HOLD_TEST={E('HOLD_TEST', '0')} "
          f"HOLD_MULTIGENRE={E('HOLD_MULTIGENRE', '0')}")
    for k, v in sorted(leaks.items()):
        print(f"   {k:34} {v}")
    if any(leaks.values()):
        raise SystemExit("LEAK")
    print("   no leak")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "leakcheck":
        leakcheck(sys.argv[2])
        raise SystemExit(0)
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
    elif mode == "pretrain":
        pretrain(sys.argv[2])
    else:
        raise SystemExit(__doc__)
