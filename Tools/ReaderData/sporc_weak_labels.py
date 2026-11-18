#!/usr/bin/env python3
"""Pass 67: high-precision weak labels on unlabelled external episodes (SPoRC), for stage 1 beside the four
Readers' soft targets — sharp labels on the sentences that say what they are.

An anchor is a sentence whose words name its kind AND that the four shipped Readers (their soft-target rows,
dump_soft.py) already lean towards that kind. The words alone are not enough (hosts say "sponsored by" about
other things; "produced by" opens many interviews); the Readers alone are what the soft targets already teach.

  ad (A)       a sponsor hand-off ("brought to you by", "sponsored by", "support for … comes from", "today's
               sponsor") or an offer ("use code", "promo code", "dot com slash", "free trial", "% off") with the
               four's p_ad >= AD_MIN (0.5)
  own plug (S) the same offer words with p_self >= 0.5 and p_self > p_ad (Patreon, merch, tour codes)
  outro (O)    a credit ("produced by", "theme music", "executive producer", "edited by", "mixed by", "our
               producer") in the last tenth or last five minutes, with p_show < 0.9 (the app's
               creditsAtTheEnd rule, SegmentDetector) and p_outro >= 0.2

    sporc_weak_labels.py label <episodes.json> <probs dir>[:<dir>…] <out.json>
    sporc_weak_labels.py check <episodes.json>[,…] <probs dir>[:<dir>…]
        precision of the ad/plug anchors against SponsorBlock's human labels (sponsor = A; the others count
        as not-sponsor) — run on sb58/sb65, where the four's probabilities are in-sample for finalsb, so this is
        an upper bound on the words' precision with a slightly optimistic gate.

Output: {guid: [[sentence index, letter], …]} as reader_distill.py WEAK= reads it.
"""
import collections, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "DetectionLab"))

HANDOFF = re.compile(r"\bbrought to you by\b|\bsponsored by\b|\bsupport for (this|the) (show|podcast|episode) "
                     r"(comes|is brought)|\btoday'?s sponsor\b|\bthis (episode|show|podcast) is sponsored\b|"
                     r"\bthanks to our sponsors?\b|\bour sponsors?\b.{0,20}\b(today|this week)\b", re.I)
OFFER = re.compile(r"\buse (the )?(promo |offer |discount )?code\b|\bpromo code\b|\boffer code\b|\bdiscount code\b|"
                   r"\bdot com slash\b|\.com/\w|\bfree trial\b|\b\d{1,2} ?(%|percent) off\b|\bfirst (month|order|box) "
                   r"(free|for)\b", re.I)
CREDIT = re.compile(r"\bproduced by\b|\btheme (music|song)\b|\bexecutive produc|\bedited by\b|\bmixed by\b|"
                    r"\bour producer\b|\bengineered by\b|\bmusic (is )?by\b|\bassociate producer\b", re.I)
AD_MIN = float(os.environ.get("AD_MIN", "0.5"))
# CASNIO: p_show, p_ad, p_self, p_cross, p_intro, p_outro (dump rows [start, end, …six])
SHOW, AD, SELF, CROSS, INTRO, OUTRO = range(6)


def soft_rows(guid, sents, dirs):
    name = re.sub(r"[^A-Za-z0-9]", "_", guid) + ".json"
    for d in dirs:
        path = os.path.join(d, name)
        if os.path.exists(path):
            rows = json.load(open(path))
            rows = rows["rows"] if isinstance(rows, dict) else rows
            by = {round(r[0], 2): r[2:8] for r in rows}
            return [by.get(round(s["start"], 2)) for s in sents]
    return None


def anchors(ep, probs):
    sents = ep["sents"]
    if not sents:
        return []
    end = sents[-1]["end"]
    tail = min(end * 0.9, end - 300)
    out = []
    for i, (s, p) in enumerate(zip(sents, probs)):
        if p is None:
            continue
        t = s["text"]
        if HANDOFF.search(t) or OFFER.search(t):
            if p[SELF] >= 0.5 and p[SELF] > p[AD] and not HANDOFF.search(t):
                out.append([i, "S"])
            elif p[AD] >= AD_MIN:
                out.append([i, "A"])
        elif CREDIT.search(t) and s["start"] >= tail and p[SHOW] < 0.9 and p[OUTRO] >= 0.2:
            out.append([i, "O"])
    return out


def label(path, dirs, out_path):
    eps = json.load(open(path))
    out, counts = {}, collections.Counter()
    for ep in eps:
        probs = soft_rows(ep["guid"], ep["sents"], dirs)
        if probs is None:
            counts["no soft targets"] += 1
            continue
        a = anchors(ep, probs)
        if a:
            out[ep["guid"]] = a
        counts["episodes"] += 1
        counts["episodes with an anchor"] += bool(a)
        for _, letter in a:
            counts[letter] += 1
    json.dump(out, open(out_path, "w"))
    print(os.path.basename(path), dict(counts), "→", out_path)


def check(paths, dirs):
    tp, n = collections.Counter(), collections.Counter()
    words_only = collections.Counter()
    for path in paths.split(","):
        for ep in json.load(open(path)):
            probs = soft_rows(ep["guid"], ep["sents"], dirs)
            if probs is None:
                continue
            for i, letter in anchors(ep, probs):
                gold = ep["labels"][i]
                if gold is None:
                    continue
                n[letter] += 1
                tp[letter] += (gold == "A") if letter == "A" else (gold in ("S", None) or gold != "C")
            for s, g in zip(ep["sents"], ep["labels"]):
                if g is not None and (HANDOFF.search(s["text"]) or OFFER.search(s["text"])):
                    words_only["n"] += 1
                    words_only["A"] += g == "A"
    for k in sorted(n):
        what = "sponsor (A)" if k == "A" else ("not the show" if k != "A" else "")
        print(f"{k}: {n[k]} anchors on labelled sentences, {tp[k] / n[k]:.3f} are {what}")
    if words_only["n"]:
        print(f"words alone (no Reader gate): {words_only['n']} sentences, {words_only['A'] / words_only['n']:.3f} sponsor")


if __name__ == "__main__":
    if sys.argv[1] == "label":
        label(sys.argv[2], sys.argv[3].split(":"), sys.argv[4])
    elif sys.argv[1] == "check":
        check(sys.argv[2], sys.argv[3].split(":"))
    else:
        raise SystemExit(__doc__)
