#!/usr/bin/env python3
"""Pass 43: the app's MLX read of his labelled episodes on this Mac, with a
choice of instructions and of what the model is shown, scored by phone_eval.

    phone_judge.py <results.json> <model dir> <out dir> <variant[:focus]> [guid …]

variant: `app` (the shipped lean prompt) or a LabPrompts variant (v2, v2r).
focus:   `app` (ModelFinder.focusRanges as shipped) or `wide` (Pass 43: the
         opening and closing minutes the show itself spans, and the plug
         words a round of plugs is made of).

Writes <out>/<variant:focus>.cuts.json ({guid: {name: cuts}}) for
`phone_eval.py <results> --cuts`.
"""
import json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import phone_eval  # noqa: E402

# Pass 45: LAB_BIN=Tools/CoreAILab/.build/release/coreai-lab reads with the
# app's Core AI path (the bundle's own engine and context) instead of MLX.
LAB = os.environ.get("LAB_BIN") or os.path.join(ROOT, "build", "mlxlab-dd", "Build", "Products", "Release", "mlx-lab")
ENGINE = "coreai" if "coreai" in LAB else "mlx"

STRONG = ["promo code", "use code", "use the code", "offer code", "discount code", "code at checkout",
          "% off", "percent off", "brought to you by", "sponsored by", "is supported by", "support for this",
          "free trial", "terms apply", "our sponsor", "thanks to our"]
PLUG_ROUND = re.compile(r"\b(do (some|the|our|a few|your) plugs|(any|some) plugs|what are you plugging|what('?re| are| do) you (got )?(to )?plug|anything (you want )?to plug|plug (your|some|the|my|our) (dates|shows|tour|stuff|shit|things)|just plug|let'?s plug|where can (people|we|everyone|folks) find you)\b", re.I)
# Pass 43: the words a plug is made of (wide focus only).
PLUG_WORDS = re.compile(r"\b(tickets?|on tour|tour dates|come see|go see|check out|\w+\.com|dot com|subscribe|patreon|merch|new special|streaming now|my website|follow (me|us|him|her))\b", re.I)


def strong(text):
    t = text.lower()
    return any(w in t for w in STRONG) or re.search(r"\bcode [a-z]{3,}", t) is not None


def focus_ranges(lines, reader_cuts, duration, wide=False):
    end = max(duration, lines[-1]["end"])

    def span(a, b, pad):
        return (max(0, min(a, b) - pad), max(a, b) + pad)
    head, tail = (300, 420) if wide else (180, 180)
    spans = [span(0, 0, head), span(end, end, tail)]
    spans += [span(c["start"], c["end"], 90) for c in reader_cuts]
    spans += [span(c["start"], c["end"], 30) for c in reader_cuts if c.get("insertedAtDownload")]
    for l in lines:
        if strong(l["text"]):
            spans.append((max(0, l["start"] - 60), l["end"] + 60))
        if PLUG_ROUND.search(l["text"]):
            spans.append((max(0, l["start"] - 30), l["end"] + 300))
        if wide and PLUG_WORDS.search(l["text"]):
            spans.append((max(0, l["start"] - 45), l["end"] + 45))
    if wide:
        # The show's own end: post-rolls the reader found push the file's end
        # past it, so the closing minutes are read before the last of them too.
        tail_ads = [c for c in reader_cuts if c["start"] > end - 600]
        if tail_ads:
            first = min(c["start"] for c in tail_ads)
            spans.append((max(0, first - 300), first))
    return sorted(spans)


def main():
    results, model, out, spec = sys.argv[1:5]
    only = set(sys.argv[5:])
    variant, _, focus = spec.partition(":")
    focus = focus or "app"
    d = json.load(open(results))
    labels = phone_eval.load_labels()
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, spec.replace(":", "-") + ".cuts.json")
    done = json.load(open(path)) if os.path.exists(path) else {}
    for idx, e in enumerate(d["episodes"]):
        if e["guid"] not in labels or (only and e["guid"] not in only) or e["guid"] in done:
            continue
        reader = []
        for a in sorted(e.get("attempts", []), key=lambda a: a["date"], reverse=True):
            if a.get("readerCuts"):
                reader = a["readerCuts"]
                break
        spans = focus_ranges(e["transcript"], reader, e.get("duration") or 0, wide=focus == "wide")
        tmp = os.path.join(out, "part.json")
        env = dict(os.environ, LAB_ONLY=",".join(f"{a:.2f}-{b:.2f}" for a, b in spans), LAB_VARIANT=variant,
                   LAB_OUT=tmp)
        r = subprocess.run([LAB, model, results, str(idx), "judge"], env=env, capture_output=True, text=True)
        if r.returncode != 0:
            print(e["title"][:40], "failed:", r.stderr[-400:])
            continue
        print(e["title"][:40], "·", r.stdout.strip().splitlines()[-1])
        cuts = json.load(open(tmp))
        done[e["guid"]] = {f"{ENGINE} {spec}": [[float(c[0]), float(c[1]), c[2]] for c in cuts]}
        json.dump(done, open(path, "w"))
    print("wrote", path)


if __name__ == "__main__":
    main()
