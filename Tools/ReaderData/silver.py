#!/usr/bin/env python3
"""Pass 57: teacher-made training sentences for episodes no one labelled.

A teacher's read is evidence, not truth (its own reads miss many breaks), so
only what the evidence agrees on is kept, and everything uncertain is left
out of training (never labelled the show by default):

  promo   inside a teacher's part (a kind the app skips, confidence ≥ 70),
          except the first and last sentence of the part (edges are where
          teachers and the labels disagree most). Weight 1 when another
          family's read on his phone cut the same stretch as the same kind,
          or a selling / plug word is inside it; else TEACH_W (0.5).
  show    more than 45 s from every teacher part, every cut any engine made
          on his phone (his saved cuts, each model's own cuts, the Reader's),
          and every line with a selling or plug word. Weight AGREE_W.
  his     what he reviewed overrides both (REVIEW_W), as for any episode.

    silver.py stats <teacher>     how many sentences each rule keeps
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import label_audit  # noqa: E402
import tagger  # noqa: E402
import teacher_annotate  # noqa: E402

E = os.environ.get
TEACH_W = float(E("TEACH_W", "0.5"))
LETTER = {"ad": "A", "selfPromo": "S", "crossPromo": "N", "intro": "I", "outro": "O"}
WORDS = re.compile("|".join(label_audit.CATEGORIES[c].pattern for c in ("selling", "plug-round", "own-plug", "credits", "network")), re.I)


def teacher_parts(guid, teacher):
    p = teacher_annotate.record_path(teacher, guid)
    if not os.path.exists(p):
        return None
    rec = json.load(open(p))
    return [(f["start"], f["end"], teacher_annotate.KIND[f["label"]]) for f in rec["found"]
            if f["label"] in teacher_annotate.KIND and (f.get("confidence") or 0) >= 70]


def phone_cuts(e):
    """(start, end, kind, engine) of every cut any engine made on his phone."""
    out = [(s["start"], s["end"], s["kind"], "saved") for s in e.get("segments", [])]
    for a in e.get("attempts") or []:
        m = a.get("method", "")
        for key in ("proposedCuts", "readerCuts", "savedCuts"):
            for c in a.get(key) or []:
                out.append((c["start"], c["end"], c["kind"], m))
    return out


def sentences_for(e, teacher, agree_w):
    """(letters, weights) for one unlabelled episode, or None without a read."""
    parts = teacher_parts(e["guid"], teacher)
    if parts is None:
        return None
    sents = tagger.sentences(e["transcript"])
    mids = [(s["start"] + s["end"]) / 2 for s in sents]
    letters, weights = [None] * len(sents), [0.0] * len(sents)
    phone = phone_cuts(e)
    wordy = [s["start"] for s in sents if WORDS.search(s["text"])]
    for a, b, kind in parts:
        inside = [i for i, m in enumerate(mids) if a <= m <= b]
        if len(inside) < 3:
            continue
        family = "Qwen3.5"
        backed = any(k == kind and x < b and y > a and family not in m for x, y, k, m in phone
                     if not m.startswith("PodSkipper reader") and m != "saved") \
            or any(WORDS.search(sents[i]["text"]) for i in inside)
        for i in inside[1:-1]:
            letters[i] = LETTER[kind]
            weights[i] = 1.0 if backed else TEACH_W
    near = [(a - 45, b + 45) for a, b, _ in parts] + [(x - 45, y + 45) for x, y, _, _ in phone] + \
           [(t - 45, t + 45) for t in wordy]
    near.sort()
    for i, s in enumerate(sents):
        if letters[i] is None and not any(x <= s["end"] and y >= s["start"] for x, y in near):
            letters[i], weights[i] = "C", agree_w
    return sents, letters, weights


if __name__ == "__main__":
    if sys.argv[1] == "stats":
        import corpus, collections
        man = corpus.load_manifest()["episodes"]
        c = collections.Counter()
        for g, m in man.items():
            if m["labelled"] or m["copyOf"]:
                continue
            e = json.load(open(os.path.join(ROOT, m["source"])))["episodes"][m["index"]]
            r = sentences_for(e, sys.argv[2], 0.6)
            if r is None:
                continue
            sents, letters, weights = r
            c["episodes"] += 1; c["sentences"] += len(sents)
            for l, w in zip(letters, weights):
                if l:
                    c[l + (" backed" if w == 1.0 else "")] += 1
        print(dict(c))
