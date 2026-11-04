#!/usr/bin/env python3
"""Pass 57: find every place in the labelled transcripts where the label
policy (LABEL-POLICY.md) could apply but the label says the show — by the
words alone, never by what a reader or model predicted, so fixing them can't
bend the labels toward any engine.

    label_audit.py list [category]   candidates per episode (outside any
                                     labelled skip or EITHER region)
    label_audit.py counts
"""
import collections, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import phone_eval  # noqa: E402

CATEGORIES = {
    "plug-round": re.compile(r"\b(do (some|the|our|a few|your) plugs|(any|some) plugs|plug (any|your|some|the|my|our) (dates|shows|tour|stuff|shit|things|special|book)|want to plug|what are you plugging|what('?re| are| do) you (got )?(to )?plug|anything (you want )?to plug|just plug|let'?s plug|where can (people|we|everyone|folks|they) (find|see|follow) you|how can people find you|where are you (going to be|gonna be|performing)|any dates coming up|dates coming up)\b", re.I),
    "credits": re.compile(r"\b(produced by|executive produc|edited by|mixed by|engineered by|theme music|music by|fact.?check|special thanks|our (senior )?producers?)\b", re.I),
    "network": re.compile(r"\b(podcast (family|network)|part of the \w+ (network|family)|a production of|presented by|from the makers of|listen to \w+ (on|wherever)|check out (my|our|the) (other )?(new )?(show|podcast)|new podcast)\b", re.I),
    "disclaimer": re.compile(r"\b(informational purposes|not (be )?(medical|legal|financial) advice|does not constitute|consult (your|a) (doctor|physician)|views expressed|opinions expressed|for entertainment purposes)\b", re.I),
    "own-plug": re.compile(r"\b(patreon|tickets|on tour|tour dates|merch|new special|\w+\.com\b|dot com|subscribe|rate and review|five.?star|follow (me|us)|youtube channel|premium (feed|episodes)|bonus episodes?)\b", re.I),
    "selling": re.compile(r"\b(promo code|use code|offer code|discount code|% off|percent off|brought to you by|sponsored by|is supported by|support for (this|the) (show|podcast)|free trial|terms apply|our sponsor|thanks to our|in partnership with)\b", re.I),
}


def episodes():
    man = corpus.load_manifest()
    labels = phone_eval.load_labels()
    cache = {}
    for g, m in sorted(man["episodes"].items(), key=lambda kv: (kv[1]["show"], kv[1]["title"])):
        if g not in labels:
            continue
        if m["source"] not in cache:
            cache.clear()
            cache[m["source"]] = json.load(open(os.path.join(ROOT, m["source"])))
        e = cache[m["source"]]["episodes"][m["index"]]
        yield m, e, labels[g]


def candidates(only=None):
    for m, e, label in episodes():
        lines = e["transcript"]
        covered = [None] * len(lines)
        for r in label["regions"]:
            if "lines" in r:
                for i in range(r["lines"][0], r["lines"][1] + 1):
                    covered[i] = r["label"]
        for i, l in enumerate(lines):
            if covered[i]:
                continue
            for cat, rx in CATEGORIES.items():
                if only and cat != only:
                    continue
                if rx.search(l["text"]):
                    yield m, e, label, i, cat


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "counts"
    if mode == "counts":
        c = collections.Counter((cat) for *_, cat in candidates())
        print(dict(c))
    elif mode == "list":
        only = sys.argv[2] if len(sys.argv) > 2 else None
        for m, e, label, i, cat in candidates(only):
            print(f"{cat:10} {m['guid'][:8]} {m['show'][:14]:14} {m['title'][:26]:26} {i:5d} {e['transcript'][i]['start']:7.0f} {e['transcript'][i]['text'][:120]}")
