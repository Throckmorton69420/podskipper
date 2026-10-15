"""Kev-0.8B as a zero-generation ad classifier on his three hand-labelled episodes.

Each ~20 s chunk of the transcript is asked about with its surroundings as context; chunks
whose cut-worthy probability passes a threshold become cuts. Scored like Pass 39's replay:
ad seconds heard (labelled cut-worthy time left uncut) and show seconds cut (cut time outside
the labelled and neutral ranges). MLX Qwen3.5 4B 6-bit's own cuts from the same export are
scored the same way for comparison.

usage (Pass 40 lab, his three hand-labelled episodes from build/phone-1015):
  git clone --branch kev-1.0 https://github.com/jaredpalmer/kev && cd kev && uv sync --frozen --no-dev
  uv pip install --python .venv/bin/python "mlx-lm>=0.31.3,<0.32"
  .venv/bin/python <repo>/Tools/DetectionLab/kev_eval.py build/phone-1015/PodSkipper-results-1792032802.json out.json
The MLX backend runs on the Mac GPU (~0.1 s a question); its probabilities matched the author's CPU fp32 path
within 0.003 on the smoke questions. Result (15 Oct 2026): see claude/evidence/2026-10-15-pass40.md section 6a.
"""
import json, sys, time

from kev.api import SystemOneRequest, to_record
from kev.checkpoint import Checkpoint, LoadOptions
from kev.model import admit

TRUTH = {
    "Two Mark Normands, One Sam Morril, no cups": ([(2155, 2375.5), (4879, 5048)],
                                                    [(2150, 2155), (2421, 2452), (4858, 4879), (5098, 5148)]),
    "#202 - Grace Kuhlenschmidt": ([(0, 44.5), (1665, 1786.5), (3894, 3912), (3946, 4110), (5805, 5864), (7651, 7737.7)],
                                   [(44.5, 59), (3940, 3946), (4110, 4112), (7635, 7651)]),
    "#690 - Josh Brolin": ([(0, 14.5), (15, 53), (1768, 1945.5), (3534, 3700), (5895, 5927)], [(53, 54), (5890, 5895)]),
}
CHUNK, BEFORE, AFTER = 20.0, 60.0, 40.0
QUESTIONS = {
    "ad": {"type": "noul", "instructions": "Is the passage an advertisement or a sponsor read (including one the host reads, or a promo code)?"},
    "plug": {"type": "noul", "instructions": "Is the passage a plug: promoting the show itself, another show, live tour dates, merch, a Patreon, or a guest's project?"},
}


def joined(ranges):
    out = []
    for a, b in sorted(ranges):
        if out and a <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], b))
        else:
            out.append((a, b))
    return out


def inter(a, b):
    return max(0.0, min(a[1], b[1]) - max(a[0], b[0]))


def score(cuts, truth):
    cut, neutral = truth
    u = joined(cuts)
    total = sum(b - a for a, b in cut)
    covered = sum(inter(r, c) for r in u for c in cut)
    neu = sum(inter(r, n) for r in u for n in neutral)
    length = sum(b - a for a, b in u)
    return {"heard": round(total - covered, 1), "showCut": round(length - covered - neu, 1), "cutSeconds": round(length, 1)}


def text(lines, a, b):
    return " ".join(l["text"].strip() for l in lines if l["end"] > a and l["start"] < b)


def chunks(lines):
    out, cur = [], []
    for i, l in enumerate(lines):
        cur.append(i)
        if lines[cur[-1]]["end"] - lines[cur[0]]["start"] >= CHUNK:
            out.append((lines[cur[0]]["start"], lines[cur[-1]]["end"])); cur = []
    if cur:
        out.append((lines[cur[0]]["start"], lines[cur[-1]]["end"]))
    return out


def main():
    results, out_path = sys.argv[1], sys.argv[2]
    data = json.load(open(results))
    ck = Checkpoint("jaredpalmer/kev-0.8b@v1.0")
    tok, model = ck.load("mps", LoadOptions(backend="mlx"))
    report = {"model": "jaredpalmer/kev-0.8b@v1.0 (MLX backend, Mac)", "chunk_s": CHUNK, "context_s": [BEFORE, AFTER],
              "questions": QUESTIONS, "episodes": {}}
    for ep in data["episodes"]:
        if ep["title"] not in TRUTH:
            continue
        lines = ep["transcript"]
        rows, tokens, t0 = [], 0, time.time()
        for (a, b) in chunks(lines):
            state = {"podcast": ep["show"], "episode": ep["title"],
                     "before the passage": text(lines, a - BEFORE, a), "passage": text(lines, a, b),
                     "after the passage": text(lines, b, b + AFTER)}
            rec, meta = to_record(SystemOneRequest.model_validate({"state": state, "questions": QUESTIONS}))
            enc = admit(model, tok, rec)
            tokens += len(enc["ids"])
            p = model.probs(enc)
            pa, pp = float(p[0][1]), float(p[1][1])
            rows.append({"start": a, "end": b, "ad": round(pa, 4), "plug": round(pp, 4)})
        secs = time.time() - t0
        truth = TRUTH[ep["title"]]
        kev = {}
        for th in (0.3, 0.4, 0.5, 0.6, 0.7):
            cuts = [(r["start"], r["end"]) for r in rows if max(r["ad"], r["plug"]) >= th]
            ads = [(r["start"], r["end"]) for r in rows if r["ad"] >= th]
            kev[str(th)] = {"ad or plug": score(cuts, truth), "ad only": score(ads, truth)}
        mlx = {}
        for att in ep["attempts"]:
            if not att["method"].startswith("MLX"):
                continue
            mlx[att["date"]] = {"model's own cuts": score([(c["start"], c["end"]) for c in att.get("proposedCuts", [])], truth),
                                "saved (after cut check)": score([(c["start"], c["end"]) for c in att.get("savedCuts", [])], truth)}
        report["episodes"][ep["title"]] = {"chunks": len(rows), "prompt_tokens": tokens, "seconds": round(secs, 1),
                                          "kev": kev, "mlx": mlx, "rows": rows}
        print(ep["title"], len(rows), "chunks", tokens, "tokens", round(secs, 1), "s", flush=True)
        for th, s in kev.items():
            print("   kev", th, s)
        for d, s in mlx.items():
            print("   mlx", d, s)
    json.dump(report, open(out_path, "w"), indent=1)


if __name__ == "__main__":
    main()
