#!/usr/bin/env python3
"""PodSkipper's own reader, full strength (pass 25): a small transformer that
labels every sentence of an episode (C A S N I O) from the sentence and the
sentences around it — the job Apple's on-device model did, without Apple's
model, so iOS's limit on that model (locked, on battery) no longer matters.

    tagger.py loso  [groups…]   leave-one-show-out: out-of-fold probabilities
                                for every lab fixture → build/tagger/<tag>/oof/
    tagger.py train <out.bin>   train on everything, write the app's weights
    tagger.py dump <weights.bin> <key>   probabilities from exported weights
                                (checks the Swift reader against Python)

Settings come from the environment (TAG, BACKBONE, EPOCHS, LR, PHONE_W, …).
Run with ~/Developer/pk-ml/bin/python (torch, transformers).
"""
import json, os, re, sys, glob, gzip, math, time, random, struct
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LAB = os.path.join(ROOT, "build", "lab")
KEYS = ["stav199", "stavb199", "mssp633", "mssp636", "los952", "los956", "los957", "ymh1", "bears1",
        "bears2", "badf1", "theo1", "wg1", "afs2", "ct262", "ct284", "chaos1"]
LABELS = "CASNIO"
GROUPS = {"stav": ["stav199", "stavb199"], "mssp": ["mssp633", "mssp636"], "los": ["los952", "los956", "los957"],
          "ymh": ["ymh1"], "bears": ["bears1", "bears2"], "badf": ["badf1"], "theo": ["theo1"], "wg": ["wg1"],
          "afs": ["afs2"], "ct": ["ct262", "ct284"], "chaos": ["chaos1"]}
# How each group's show is named in his phone's results.
SHOWWORDS = {"stav": "stavvy", "mssp": "matt and shane", "los": "legion of skanks", "ymh": "your mom",
             "bears": "2 bears", "badf": "bad friends", "theo": "this past weekend", "wg": "whiskey ginger",
             "afs": "adam friedland", "ct": "cumtown", "chaos": "chrissy chaos"}

E = os.environ.get
TAG = E("TAG", "t1")
BACKBONE = E("BACKBONE", "google/electra-small-discriminator")
EPOCHS = float(E("EPOCHS", "3"))
LR = float(E("LR", "1e-4"))
HEAD_LR = float(E("HEAD_LR", "1e-3"))
PHONE_W = float(E("PHONE_W", "0.4"))
MAXLEN = int(E("MAXLEN", "512"))
SENT_CAP = int(E("SENT_CAP", "96"))
BATCH = int(E("BATCH", "8"))
PROMO_W = float(E("PROMO_W", "2.0"))
SEED = int(E("SEED", "7"))
OUT = os.path.join(ROOT, "build", "tagger", TAG)

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

# ---------------------------------------------------------------- side features
# A few facts the words don't carry: where the sentence is in the episode, the
# pauses around it, its length and speed. The Swift reader computes the same.

NFEAT = 22

def bucket(v, edges):
    for i, e in enumerate(edges):
        if v < e: return i
    return len(edges)

def side_features(sents, duration):
    F = np.zeros((len(sents), NFEAT), dtype=np.float32)
    for i, s in enumerate(sents):
        n = len(s["text"].split())
        f = F[i]
        f[0] = 1.0 if s["start"] < 120 else 0.0
        f[1] = 1.0 if s["start"] < 600 else 0.0
        f[2] = 1.0 if s["end"] > duration - 180 else 0.0
        f[3] = 1.0 if s["end"] > duration - 600 else 0.0
        gb = s["start"] - sents[i - 1]["end"] if i > 0 else 9.0
        ga = sents[i + 1]["start"] - s["end"] if i + 1 < len(sents) else 9.0
        f[4 + bucket(gb, [0.2, 0.5, 1.0, 2.0])] = 1.0          # 4..8
        f[9 + bucket(ga, [0.2, 0.5, 1.0, 2.0])] = 1.0          # 9..13
        length = max(0.3, s["end"] - s["start"])
        f[14 + bucket(n / length, [1.5, 2.5, 3.2, 4.0])] = 1.0  # 14..18
        f[19] = min(1.0, n / 30.0)
        f[20] = s["start"] / max(1.0, duration)
        f[21] = 1.0
    return F

# ---------------------------------------------------------------- data

LAB_KINDS = {"ADVERTISEMENT": "A", "SELF_PROMOTION": "S", "NETWORK_PROMOTION": "N", "INTRO": "I",
             "OUTRO": "O", "CREDITS": "O", "EITHER": None, "NORMAL": "C"}
APP_KINDS = {"ad": "A", "selfPromo": "S", "crossPromo": "N", "intro": "I", "outro": "O", "credits": "O"}

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

def group_of(key):
    for g, ks in GROUPS.items():
        if key in ks: return g
    return None

def lab_episode(key):
    segs = json.load(open(os.path.join(LAB, key + ".json")))
    sents = sentences(segs)
    rpath = os.path.join(LAB, key + ".regions.json")
    regions = json.load(open(rpath)) if os.path.exists(rpath) else []
    tpath = os.path.join(LAB, key + ".title")
    title = open(tpath).read().strip() if os.path.exists(tpath) else key
    return {"key": key, "title": title, "show": group_of(key), "sents": sents,
            "labels": label_by(sents, regions, LAB_KINDS), "weight": 1.0, "gold": True}

def phone_files():
    paths = []
    for d in sorted(glob.glob(os.path.join(ROOT, "build", "phone-*")), reverse=True):
        paths += sorted(glob.glob(os.path.join(d, "results*.json")), reverse=True)
        paths += sorted(glob.glob(os.path.join(d, "results*.json.gz")), reverse=True)
    return paths

def extra_gold():
    """His phone's episodes labelled sentence by sentence (extra-gold.json):
    guid → [(first, last, label)], used instead of the detector's cuts."""
    path = os.path.join(ROOT, "Tools", "DetectionLab", "extra-gold.json")
    return {g["guid"]: g["regions"] for g in json.load(open(path))} if os.path.exists(path) else {}

def phone_episodes(min_version=17):
    seen, out = set(), []
    gold = extra_gold()
    for path in phone_files():
        data = json.load(gzip.open(path) if path.endswith(".gz") else open(path))
        for e in data["episodes"]:
            if e["guid"] in seen or not e.get("transcript"): continue
            if e["guid"] in gold:
                seen.add(e["guid"])
                sents = sentences(e["transcript"])
                labels = ["C"] * len(sents)
                for a, b, lab, *_ in gold[e["guid"]]:
                    for i in range(a, min(b, len(sents) - 1) + 1): labels[i] = lab
                out.append({"key": "gold:" + e["guid"], "title": e["title"], "show": e.get("show", ""),
                            "sents": sents, "labels": labels, "weight": 1.0, "gold": True})
                continue
            v = e.get("detectorVersion", 0) or 0
            # 20 is the quick-check stamp: those cuts aren't the full check's.
            if v < min_version or v == 20: continue
            seen.add(e["guid"])
            if "We Are Garbage" in e["title"]: continue
            sents = sentences(e["transcript"])
            if len(sents) < 20: continue
            regions = []
            for s in e["segments"]:
                kind = "C" if s.get("verdict") == "notAnAd" else APP_KINDS.get(s["kind"])
                if kind: regions.append({"start": s["start"], "end": s["end"], "label": kind})
            labels = []
            for s in sents:
                mid = (s["start"] + s["end"]) / 2
                labels.append(next((r["label"] for r in regions if r["start"] <= mid <= r["end"]), "C"))
            out.append({"key": "phone:" + e["guid"], "title": e["title"], "show": e.get("show", ""),
                        "sents": sents, "labels": labels, "weight": PHONE_W, "gold": False})
    return out

def same_show(ep, group):
    return SHOWWORDS[group] in (ep["show"] + " " + ep["title"]).lower()

# ---------------------------------------------------------------- windows

def encode_episode(ep, tok):
    """Token ids of every sentence (no specials), capped."""
    if "_ids" not in ep:
        ids = tok([s["text"] for s in ep["sents"]], add_special_tokens=False)["input_ids"]
        ep["_ids"] = [x[:SENT_CAP] if x else [tok.unk_token_id] for x in ids]
        dur = ep["sents"][-1]["end"] if ep["sents"] else 0
        ep["_side"] = side_features(ep["sents"], dur)
    return ep["_ids"]

def windows(sent_ids, room):
    """[first, last) sentence ranges, each at most `room` tokens, each
    starting about halfway through the one before."""
    n = len(sent_ids)
    out, s = [], 0
    while s < n:
        total, e = 0, s
        while e < n and total + len(sent_ids[e]) <= room:
            total += len(sent_ids[e]); e += 1
        if e == s: e = s + 1
        out.append((s, e))
        if e >= n: break
        half, acc, nxt = total / 2, 0, s
        while nxt < e and acc + len(sent_ids[nxt]) <= half:
            acc += len(sent_ids[nxt]); nxt += 1
        s = max(s + 1, nxt)
    return out

def centre_window(wins, sent_ids):
    """For every sentence, the window it sits most centrally in (by tokens)."""
    best = [(-1, -1.0)] * len(sent_ids)
    for w, (a, b) in enumerate(wins):
        lens = [len(sent_ids[i]) for i in range(a, b)]
        total = sum(lens); acc = 0
        for i, L in zip(range(a, b), lens):
            margin = min(acc + L / 2, total - acc - L / 2)
            if margin > best[i][1]: best[i] = (w, margin)
            acc += L
    return [w for w, _ in best]

def window_item(ep, a, b, cls, sep):
    ids, spans = [cls], []
    for i in range(a, b):
        spans.append((len(ids), len(ids) + len(ep["_ids"][i])))
        ids += ep["_ids"][i]
    ids.append(sep)
    labs = [(-100 if ep["labels"][i] is None else LABELS.index(ep["labels"][i])) for i in range(a, b)]
    wts = [ep["weight"] * (1.0 if ep["labels"][i] in ("C", None) else PROMO_W) for i in range(a, b)]
    return {"ids": ids, "spans": spans, "labels": labs, "weights": wts, "side": ep["_side"][a:b]}

# ---------------------------------------------------------------- model

def build_model(backbone):
    import torch, torch.nn as nn
    from transformers import AutoModel

    class Tagger(nn.Module):
        def __init__(self):
            super().__init__()
            self.enc = AutoModel.from_pretrained(backbone)
            H = self.enc.config.hidden_size
            self.mid = nn.Linear(H + NFEAT, 128)
            self.out = nn.Linear(128, len(LABELS))
            self.act = nn.GELU()

        def pooled(self, ids, mask, spans):
            h = self.enc(input_ids=ids, attention_mask=mask,
                         token_type_ids=torch.zeros_like(ids)).last_hidden_state
            cs = torch.cumsum(h, dim=1)
            cs = torch.cat([torch.zeros_like(cs[:, :1]), cs], dim=1)   # cs[:, t] = sum of h[:, :t]
            b, s, e = spans[:, 0], spans[:, 1], spans[:, 2]
            return (cs[b, e] - cs[b, s]) / (e - s).clamp(min=1).unsqueeze(1).to(h.dtype)

        def forward(self, ids, mask, spans, side, with_pooled=False):
            pooled = self.pooled(ids, mask, spans)
            z = torch.cat([pooled, side], dim=1)
            logits = self.out(self.act(self.mid(z)))
            return (logits, pooled) if with_pooled else logits
    return Tagger()

def collate(items, pad, device):
    import torch
    T = max(len(x["ids"]) for x in items)
    ids = torch.full((len(items), T), pad, dtype=torch.long)
    mask = torch.zeros((len(items), T), dtype=torch.long)
    spans, labs, wts, side = [], [], [], []
    for bi, x in enumerate(items):
        ids[bi, :len(x["ids"])] = torch.tensor(x["ids"])
        mask[bi, :len(x["ids"])] = 1
        for (s, e) in x["spans"]: spans.append((bi, s, e))
        labs += x["labels"]; wts += x["weights"]; side.append(x["side"])
    return (ids.to(device), mask.to(device), torch.tensor(spans, dtype=torch.long).to(device),
            torch.tensor(np.concatenate(side), dtype=torch.float32).to(device),
            torch.tensor(labs, dtype=torch.long).to(device), torch.tensor(wts, dtype=torch.float32).to(device))

def device():
    import torch
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")

def train_model(train_eps, tok, log=print):
    import torch
    torch.manual_seed(SEED); random.seed(SEED); np.random.seed(SEED)
    dev = device()
    model = build_model(BACKBONE).to(dev)
    cls, sep, pad = tok.cls_token_id, tok.sep_token_id, tok.pad_token_id
    items = []
    for ep in train_eps:
        sid = encode_episode(ep, tok)
        for a, b in windows(sid, MAXLEN - 2):
            it = window_item(ep, a, b, cls, sep)
            if any(l != -100 for l in it["labels"]): items.append(it)
    steps_per_epoch = math.ceil(len(items) / BATCH)
    total = int(steps_per_epoch * EPOCHS)
    enc_params = list(model.enc.parameters())
    head_params = list(model.mid.parameters()) + list(model.out.parameters())
    opt = torch.optim.AdamW([{"params": enc_params, "lr": LR}, {"params": head_params, "lr": HEAD_LR}],
                            weight_decay=0.01)
    warm = max(1, int(0.06 * total))
    sched = torch.optim.lr_scheduler.LambdaLR(opt, lambda s: min(1.0, (s + 1) / warm) * max(0.0, (total - s) / max(1, total - warm)))
    log("   training on %d windows, %d steps, %s on %s" % (len(items), total, BACKBONE, dev))
    model.train(); step = 0; t0 = time.time(); run = 0.0
    while step < total:
        random.shuffle(items)
        for i in range(0, len(items), BATCH):
            if step >= total: break
            ids, mask, spans, side, labs, wts = collate(items[i:i + BATCH], pad, dev)
            logits = model(ids, mask, spans, side)
            keep = labs != -100
            loss_all = torch.nn.functional.cross_entropy(logits[keep], labs[keep], reduction="none")
            loss = (loss_all * wts[keep]).sum() / wts[keep].sum().clamp(min=1e-6)
            opt.zero_grad(); loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            opt.step(); sched.step(); step += 1
            run = 0.98 * run + 0.02 * loss.item() if step > 1 else loss.item()
            if step % 200 == 0:
                log("   step %d/%d loss %.4f (%.0f s)" % (step, total, run, time.time() - t0))
    log("   trained in %.0f s" % (time.time() - t0))
    model.eval()
    return model

def predict(model, ep, tok, with_vectors=False):
    import torch
    dev = next(model.parameters()).device
    sid = encode_episode(ep, tok)
    wins = windows(sid, MAXLEN - 2)
    centre = centre_window(wins, sid)
    cls, sep, pad = tok.cls_token_id, tok.sep_token_id, tok.pad_token_id
    P = np.zeros((len(sid), len(LABELS)), dtype=np.float32)
    V = None
    with torch.no_grad():
        for i in range(0, len(wins), 16):
            chunk = wins[i:i + 16]
            items = [window_item(ep, a, b, cls, sep) for a, b in chunk]
            ids, mask, spans, side, _, _ = collate(items, pad, dev)
            logits, pooled = model(ids, mask, spans, side, with_pooled=True)
            probs = torch.softmax(logits, dim=1).float().cpu().numpy()
            pooled = pooled.float().cpu().numpy()
            if V is None: V = np.zeros((len(sid), pooled.shape[1]), dtype=np.float32)
            k = 0
            for w, (a, b) in enumerate(chunk):
                for si in range(a, b):
                    if centre[si] == i + w: P[si] = probs[k]; V[si] = pooled[k]
                    k += 1
    return (P, V) if with_vectors else P

# ---------------------------------------------------------------- export

def export(model, tok, path, log=print, extra=None):
    """The app's format (SentenceTagger.swift): "PSTG", version 1, the
    length of a JSON header (config, tensor names/shapes/offsets, where the
    vocabulary is), the header, then every tensor as float16 and the
    vocabulary one word-piece per line. `extra`: more tensors by name (the
    delivery reader's, from `style`)."""
    cfg = model.enc.config
    blob, tensors = bytearray(), []
    items = [(k[4:] if k.startswith("enc.") else k, v.detach().float().cpu().numpy()) for k, v in model.state_dict().items()]
    items += list((extra or {}).items())
    for name, v in items:
        if name.startswith("pooler.") or name.endswith("position_ids"): continue
        arr = np.asarray(v, dtype=np.float32).astype("<f2")
        tensors.append({"name": name, "shape": list(arr.shape), "offset": len(blob)})
        blob += arr.tobytes()
    vocab = [t for t, _ in sorted(tok.get_vocab().items(), key=lambda x: x[1])]
    vbytes = "\n".join(vocab).encode("utf-8")
    header = {"config": {"vocab_size": cfg.vocab_size, "hidden": cfg.hidden_size, "layers": cfg.num_hidden_layers,
                         "heads": cfg.num_attention_heads, "intermediate": cfg.intermediate_size,
                         "max_pos": cfg.max_position_embeddings,
                         "emb_size": getattr(cfg, "embedding_size", cfg.hidden_size) or cfg.hidden_size,
                         "ln_eps": cfg.layer_norm_eps, "nfeat": NFEAT, "mid": model.mid.out_features,
                         "sent_cap": SENT_CAP, "maxlen": MAXLEN, "cls_id": tok.cls_token_id,
                         "sep_id": tok.sep_token_id, "unk_id": tok.unk_token_id},
              "tensors": tensors, "vocab_offset": len(blob), "vocab_length": len(vbytes)}
    blob += vbytes
    hj = json.dumps(header).encode("utf-8")
    hj += b" " * ((-len(hj)) % 4)
    with open(path, "wb") as f:
        f.write(b"PSTG"); f.write(struct.pack("<II", 1, len(hj))); f.write(hj); f.write(bytes(blob))
    log("   wrote %s (%.1f MB)" % (path, os.path.getsize(path) / 1e6))

def half_rounded(model):
    """The model as the app runs it: every weight rounded to float16."""
    import torch
    with torch.no_grad():
        for p in model.parameters(): p.copy_(p.half().float())
    return model

# ---------------------------------------------------------------- scoring

def auc_ap(truth, score):
    from sklearn.metrics import roc_auc_score, average_precision_score
    if 0 < sum(truth) < len(truth):
        return roc_auc_score(truth, score), average_precision_score(truth, score)
    return float("nan"), float("nan")

def write_oof(key, ep, P):
    d = os.path.join(OUT, "oof"); os.makedirs(d, exist_ok=True)
    rows = [[round(s["start"], 3), round(s["end"], 3)] + [round(float(x), 6) for x in p] for s, p in zip(ep["sents"], P)]
    json.dump(rows, open(os.path.join(d, key + ".json"), "w"))

def sentence_report(key, ep, P, log):
    lab = ep["labels"]
    idx = [i for i, l in enumerate(lab) if l is not None]
    truth = [0 if lab[i] == "C" else 1 for i in idx]
    score = [1 - P[i, 0] for i in idx]
    auc, ap = auc_ap(truth, score)
    pred = P.argmax(axis=1)
    agree = np.mean([LABELS[pred[i]] == lab[i] for i in idx]) if idx else float("nan")
    log("   %-9s promo AUC %.3f AP %.3f  label agreement %.3f  (promo share %.2f)" % (
        key, auc, ap, agree, sum(truth) / max(1, len(truth))))
    return idx, truth, score

# ---------------------------------------------------------------- main

def main():
    from transformers import AutoTokenizer
    mode = sys.argv[1] if len(sys.argv) > 1 else "loso"
    os.makedirs(OUT, exist_ok=True)
    logf = open(os.path.join(OUT, "log.txt"), "a")
    def log(*a):
        s = " ".join(str(x) for x in a); print(s, flush=True); logf.write(s + "\n"); logf.flush()
    log("== %s %s tag=%s backbone=%s epochs=%s lr=%s phone_w=%s promo_w=%s maxlen=%d" % (
        time.strftime("%H:%M:%S"), mode, TAG, BACKBONE, EPOCHS, LR, PHONE_W, PROMO_W, MAXLEN))
    tok = AutoTokenizer.from_pretrained(BACKBONE)
    labs = {k: lab_episode(k) for k in KEYS if os.path.exists(os.path.join(LAB, k + ".json"))}
    phone = phone_episodes() if PHONE_W > 0 else []
    log("lab fixtures %d, phone episodes %d" % (len(labs), len(phone)))
    if mode == "loso":
        # A fold is one show or several joined by "+" (FIVE: five folds of
        # two or three shows each, about four hours of fixtures apiece).
        groups = sys.argv[2:] or list(GROUPS)
        if groups == ["FIVE"]:
            groups = ["stav+ymh+theo", "mssp+wg", "los", "bears+badf+afs", "ct+chaos"]
        # EPISODES: hold out episodes, not shows — a new episode of a show
        # the reader knows, which is what his phone meets. Each fold holds
        # out one or two episodes of different shows; the same episodes are
        # left out of his phone's results too (by title).
        if groups == ["EPISODES"]:
            groups = ["stav199,mssp633,los952,bears1,ct262", "stavb199,mssp636,los956,bears2,chaos1",
                      "los957,ct284,ymh1,badf1", "theo1,wg1,afs2"]
        norm = lambda t: re.sub(r"[^a-z0-9]", "", t.lower())[:30]
        T, S = [], []
        for g in groups:
            if "," in g:
                held = [k for k in g.split(",") if k in labs]
                titles = {norm(labs[k]["title"]) for k in held}
                train_eps = [e for k, e in labs.items() if k not in held] + \
                            [e for e in phone if norm(e["title"]) not in titles]
                g = g.replace(",", "+")
            else:
                parts = g.split("+")
                held = [k for p in parts for k in GROUPS[p] if k in labs]
                train_eps = [e for k, e in labs.items() if k not in held] + \
                            [e for e in phone if not any(same_show(e, p) for p in parts)]
            log("fold %s: hold out %s; train on %d episodes" % (g, held, len(train_eps)))
            model = train_model(train_eps, tok, log)
            fd = os.path.join(OUT, "folds"); os.makedirs(fd, exist_ok=True)
            export(model, tok, os.path.join(fd, g + ".bin"), log)
            for k in held:
                P = predict(model, labs[k], tok)
                write_oof(k, labs[k], P)
                _, t, s = sentence_report(k, labs[k], P, log)
                T += t; S += s
            del model
            import torch
            if torch.backends.mps.is_available(): torch.mps.empty_cache()
        auc, ap = auc_ap(T, S)
        log("POOLED promo AUC %.3f AP %.3f over %d sentences" % (auc, ap, len(T)))
        return
    if mode == "train":
        train_eps = list(labs.values()) + phone
        model = train_model(train_eps, tok, log)
        import torch
        torch.save(model.state_dict(), os.path.join(OUT, "model.pt"))
        if len(sys.argv) > 2: export(model, tok, sys.argv[2], log)
        return
    if mode == "style":
        # style <model.pt> <out.bin>: the delivery reader — host-read or
        # produced, played for laughs or not — as two logistic regressions
        # over an ad's mean sentence summary, fitted on the answers Apple's
        # model gave on his phone (every export) and the lab's delivery
        # labels; written into the app's weights with the reader.
        import torch
        from sklearn.linear_model import LogisticRegression
        from sklearn.metrics import roc_auc_score
        model = build_model(BACKBONE)
        model.load_state_dict(torch.load(sys.argv[2], map_location="cpu"))
        model = model.to(device()).eval()
        rows = []   # (vector, host, comedy or None, show)
        def add(ep, spans):
            if not spans: return
            _, V = predict(model, ep, tok, with_vectors=True)
            mids = np.array([(s["start"] + s["end"]) / 2 for s in ep["sents"]])
            for a, b, host, comedy in spans:
                idx = np.where((mids >= a) & (mids <= b))[0]
                if len(idx): rows.append((V[idx].mean(axis=0), host, comedy, ep["show"]))
        seen = set()
        for path in phone_files():
            data = json.load(gzip.open(path) if path.endswith(".gz") else open(path))
            for e in data["episodes"]:
                if e["guid"] in seen or not e.get("transcript"): continue
                spans = [(s["start"], s["end"], s.get("delivery") == "host",
                          bool(s.get("comedyBit")) if s.get("delivery") == "host" else None)
                         for s in e["segments"] if s["kind"] == "ad" and s.get("delivery") in ("host", "produced")
                         and s.get("verdict") != "notAnAd"]
                if not spans: continue
                seen.add(e["guid"])
                sents = sentences(e["transcript"])
                add({"key": e["guid"], "sents": sents, "labels": ["C"] * len(sents), "weight": 1.0,
                     "show": e.get("show", "")}, spans)
        for k, ep in labs.items():
            rp = os.path.join(LAB, k + ".regions.json")
            if not os.path.exists(rp): continue
            regions = json.load(open(rp))
            spans = [(r["start"], r["end"], r.get("delivery") == "host", None) for r in regions
                     if r["label"] == "ADVERTISEMENT" and r.get("delivery") in ("host", "produced")]
            add(ep, spans)
        X = np.stack([r[0] for r in rows]); host = np.array([r[1] for r in rows], dtype=int)
        shows = [r[3] for r in rows]
        log("delivery examples: %d (%d host-read), comedy answers %d (%d played for laughs)" % (
            len(rows), host.sum(), sum(r[2] is not None for r in rows), sum(bool(r[2]) for r in rows)))
        mu, sd = X.mean(axis=0), X.std(axis=0) + 1e-6
        Z = (X - mu) / sd
        C = float(E("STYLE_C", "0.05"))
        def cv(y, mask):
            # Leave one show out, pooled AUC.
            idx = np.where(mask)[0]; scores = np.zeros(len(idx))
            for show in sorted(set(shows[i] for i in idx)):
                te = [n for n, i in enumerate(idx) if shows[i] == show]
                tr = [n for n, i in enumerate(idx) if shows[i] != show]
                if len(set(y[idx[tr]])) < 2: scores[te] = y[idx[tr]].mean(); continue
                m = LogisticRegression(C=C, max_iter=2000).fit(Z[idx[tr]], y[idx[tr]])
                scores[te] = m.predict_proba(Z[idx[te]])[:, 1]
            return roc_auc_score(y[idx], scores), scores, idx
        auc_h, _, _ = cv(host, np.ones(len(rows), dtype=bool))
        cmask = np.array([r[2] is not None for r in rows])
        comedy = np.array([1 if r[2] else 0 for r in rows])
        auc_c, sc, idx = cv(comedy, cmask)
        yc = comedy[idx]
        for tau in (0.4, 0.5, 0.6, 0.7):
            pred = sc >= tau
            log("   comedy at %.1f: %d called funny, %d of them right; %d of %d funny found" % (
                tau, pred.sum(), (pred & (yc == 1)).sum(), (pred & (yc == 1)).sum(), yc.sum()))
        log("delivery reader, leave one show out: host-read AUC %.3f, played-for-laughs AUC %.3f" % (auc_h, auc_c))
        mh = LogisticRegression(C=C, max_iter=2000).fit(Z, host)
        mc = LogisticRegression(C=C, max_iter=2000).fit(Z[cmask], comedy[cmask])
        W = np.stack([mh.coef_[0] / sd, mc.coef_[0] / sd]).astype(np.float32)
        b = np.array([mh.intercept_[0] - (mh.coef_[0] * mu / sd).sum(),
                      mc.intercept_[0] - (mc.coef_[0] * mu / sd).sum()], dtype=np.float32)
        export(model.cpu(), tok, sys.argv[3], log, extra={"style.weight": W, "style.bias": b})
        return
    if mode == "dump":
        # dump <model.pt> <key> <out.json>: float16-rounded weights on the
        # CPU, as the app runs them, for comparing with LAB_TAGDUMP.
        import torch
        model = build_model(BACKBONE)
        model.load_state_dict(torch.load(sys.argv[2], map_location="cpu"))
        model = half_rounded(model).eval()
        ep = labs[sys.argv[3]]
        P = predict(model, ep, tok)
        rows = [[s["start"], s["end"]] + [float(x) for x in p] for s, p in zip(ep["sents"], P)]
        json.dump(rows, open(sys.argv[4], "w"))
        log("dumped %d sentences" % len(rows))
        return
    raise SystemExit("unknown mode " + mode)

if __name__ == "__main__":
    main()
