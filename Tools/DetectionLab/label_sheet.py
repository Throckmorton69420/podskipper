#!/usr/bin/env python3
"""Pass 44: a labelling sheet for one exported episode — the transcript lines
worth reading to label where its ads and plugs are, numbered as the export's
own transcript (the numbering phone-labels/ uses).

    label_sheet.py <results.json> list               episodes, labelled or not
    label_sheet.py <results.json> <guid prefix> [pad] the sheet for one episode

A line is on the sheet when it falls within `pad` seconds (default 25) of any
engine's cut or a selling word, or in the first 2.5 minutes or the last 3.3.
Each block names every engine's marks as line ranges (q4 Qwen3.5 4B, q6 its Instruct 6-bit, c3
Core AI Qwen3 4B, mc MiniCPM5 2B, q2 Qwen3.5 2B, ai Apple Intelligence,
b2 Bonsai 2 4B, r the reader, ins audio stitched in at download, seg what is saved now) and the kind it said
(A ad, S own plug, N network, I intro, O outro). The marks only say where to
look: labels are read off the words, never copied from an engine.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LABELS = os.path.join(HERE, "phone-labels")
ENGINES = {"MLX · Qwen3.5 4B": "q4", "MLX · Qwen3.5 4B Instruct (6-bit)": "q6", "Core AI · Qwen3 4B": "c3",
           "Core AI · MiniCPM5 2B": "mc", "MLX · Qwen3.5 2B": "q2", "Apple Intelligence": "ai",
           "MLX · Bonsai 2 4B": "b2"}
KIND = {"ad": "A", "selfPromo": "S", "crossPromo": "N", "intro": "I", "outro": "O", "credits": "O"}
SELL = re.compile(r"promo code|use code|offer code|\.com|dot com|slash|sponsor|brought to you|support for|"
                  r"free trial|% off|percent off|terms apply|restrictions apply|patreon|merch|"
                  r"rate and review|wherever you get|app store|first order|free shipping|produced by|"
                  r"executive producer|you've been listening|you're listening to|tickets|on sale", re.I)


def labelled():
    out = set()
    for n in os.listdir(LABELS):
        if n.endswith(".json"):
            out.add(json.load(open(os.path.join(LABELS, n)))["guid"])
    return out


def marks(e):
    """(tag, start, end, kind letter) for each engine's newest cuts."""
    out, done = [], set()
    for a in sorted(e.get("attempts", []), key=lambda a: a["date"], reverse=True):
        m = a.get("method", "")
        if m == "PodSkipper reader" and "r" not in done:
            done.add("r")
            out += [("r", c["start"], c["end"], KIND.get(c["kind"], "?")) for c in a.get("readerCuts", [])]
            out += [("ins", c["start"], c["end"], "A") for c in a.get("readerCuts", []) if c.get("insertedAtDownload")]
        tag = ENGINES.get(m)
        if tag and tag not in done:
            done.add(tag)
            cuts = a.get("proposedCuts") or a.get("savedCuts") or []
            out += [(tag, c["start"], c["end"], KIND.get(c["kind"], "?")) for c in cuts]
    # What the episode has saved now (older episodes have no attempt log).
    out += [("seg", s["start"], s["end"], KIND.get(s["kind"], "?")) for s in e.get("segments", [])
            if s["end"] - s["start"] < 240]
    return out


def runs(ms, lines):
    """Each engine's marks as line ranges: "q4 A 1076–1106"."""
    out = []
    for tag in ("q4", "q6", "c3", "mc", "q2", "ai", "r", "ins", "seg"):
        for _, a, b, k in sorted(m for m in ms if m[0] == tag):
            first = next((i for i, l in enumerate(lines) if (l["start"] + l["end"]) / 2 >= a), None)
            last = next((i for i in range(len(lines) - 1, -1, -1) if (lines[i]["start"] + lines[i]["end"]) / 2 <= b), None)
            if first is not None and last is not None and last >= first:
                out.append((first, last, f"{tag} {k} {first}-{last}"))
    return out


def sheet(e, pad=25.0):
    lines = e["transcript"]
    end = lines[-1]["end"]
    ms = marks(e)
    keep = set()
    for i, l in enumerate(lines):
        t = (l["start"] + l["end"]) / 2
        if t < 150 or t > end - 200:
            keep.add(i)
        if any(a - pad <= t <= b + pad for _, a, b, _ in ms):
            keep.add(i)
        if SELL.search(l["text"]):
            for j in range(max(0, i - 30), min(len(lines), i + 30)):
                if abs(lines[j]["start"] - l["start"]) <= pad:
                    keep.add(j)
    rs = runs(ms, lines)
    out, block = [], []

    def flush():
        if block:
            a, b = block[0], block[-1]
            inside = [r[2] for r in rs if r[0] <= b and r[1] >= a]
            out.append(f"---- {a}-{b} ({lines[a]['start'] / 60:.1f}-{lines[b]['end'] / 60:.1f} min) " + "; ".join(inside))
            out.extend(f"{i} {lines[i]['text'].strip()}" for i in block)
            block.clear()
    for i in sorted(keep):
        if block and i != block[-1] + 1:
            flush()
        block.append(i)
    flush()
    return out, len(keep), len(lines)


def main():
    d = json.load(open(sys.argv[1]))
    done = labelled()
    if sys.argv[2] == "list":
        for e in d["episodes"]:
            if e.get("transcript"):
                print(("L " if e["guid"] in done else "  ") + e["guid"][:12], e["show"][:24], "|", e["title"][:50])
        return
    pad = float(sys.argv[3]) if len(sys.argv) > 3 else 25.0
    e = next(e for e in d["episodes"] if e["guid"].startswith(sys.argv[2]))
    out, n, total = sheet(e, pad)
    print(f"# {e['show']} | {e['title']} | guid {e['guid']} | {n} of {total} lines | "
          f"{e['transcript'][-1]['end'] / 60:.0f} min")
    print("\n".join(out))


if __name__ == "__main__":
    main()
