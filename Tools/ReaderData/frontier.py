#!/usr/bin/env python3
"""Pass 57: compare readers at the same operating point, not wherever each
happened to land.

A reader's sentence answers go through the app's detector; a reader that
ranks sentences better can still cut more of the show if its answers sit on
a different scale from the one the detector was tuned to (Pass 53: every
better-ranked variant cut more show). So each reader's held-out answers are
read at several show biases — the show's logit moved by δ, which ships as one
number added to the head's `out.bias[0]` — and cut by the detector; the
result is a curve of ads heard against show cut per reader.

    frontier.py <out.json> name=<run dir or probs dir> [name=…] [--deltas -1,0,1]
                [--bin <lab-segments>] [--results <export>] [--only test|folds]

A δ for shipping is chosen without the test episodes (`pick`): the δ that
minimises heard + 2 × show cut over the show-held-out folds' answers.
Intervals are 95 % bootstrap over episodes (2,000 resamples, ratio of sums).
"""
import argparse, collections, itertools, json, os, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
os.environ.setdefault("READER_OUT", "p57")
import phone_eval  # noqa: E402
import reader_distill as rd  # noqa: E402

RESULTS = os.path.join(ROOT, "build", "phone-1031b", "results.json")


def shifted(rows, delta):
    if not delta:
        return rows
    out = []
    for r in rows:
        p = np.array(r[2:], dtype=np.float64)
        p[0] *= np.exp(delta)
        p /= p.sum()
        out.append(r[:2] + [float(x) for x in p])
    return out


_ids = itertools.count()


def detect(k, rows):
    """`reader_distill.detect`, safe from several threads at once."""
    path = os.path.join(rd.DATA, f"{k}.{os.getpid()}.{next(_ids)}.probs.json")
    json.dump(rows, open(path, "w"))
    env = dict(os.environ, LAB_TAGGER=":".join(rd.SHIPPED), LAB_TAGPROBS=path)
    r = subprocess.run([rd.BIN, os.path.join(rd.DATA, k + ".json"), "", "", ""], env=env, capture_output=True, text=True)
    os.remove(path)
    return parse_cuts(r.stdout)


def parse_cuts(stdout):
    cuts = []
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):([\d.]+)–(\d+):(\d+):([\d.]+)", stdout, re.M):
        kind, h1, m1, s1, h2, m2, s2 = m.groups()
        cuts.append((int(h1) * 3600 + int(m1) * 60 + float(s1), int(h2) * 3600 + int(m2) * 60 + float(s2), kind))
    return cuts


def load_probs(path):
    d = path if os.path.basename(path) == "probs" else os.path.join(path, "probs")
    return {n[:-5]: json.load(open(os.path.join(d, n))) for n in os.listdir(d) if n.endswith(".json")}


GAPS = False


def episode_scores(cuts_by_guid, episodes, labels):
    rows = {}
    for g, cuts in cuts_by_guid.items():
        e = episodes[g]
        ls = phone_eval.spans(labels[g], e["transcript"])
        if GAPS:
            ls = phone_eval.with_gaps(ls, e["transcript"], e.get("duration") or None)
        s = phone_eval.score(ls, [tuple(c) for c in cuts], e["transcript"][-1]["end"])
        edges = rd.block_edges(ls, cuts)
        rows[g] = {"audio": s["audio"], "heard": s["heard"], "show": s["show_cut"], "missed": len(s["missed"]),
                   "regions": s["regions"], "kind": s["wrong_kind"], "edges": edges}
    return rows


def totals(rows, keys=None):
    keys = list(rows) if keys is None else keys
    a = sum(rows[g]["audio"] for g in keys) / 3600
    return {"heard": sum(rows[g]["heard"] for g in keys) / a, "show": sum(rows[g]["show"] for g in keys) / a,
            "missed": sum(rows[g]["missed"] for g in keys), "regions": sum(rows[g]["regions"] for g in keys),
            "kind": sum(rows[g]["kind"] for g in keys),
            "edgeStart": float(np.median([abs(x[0]) for g in keys for x in rows[g]["edges"]] or [0])),
            "edgeEnd": float(np.median([abs(x[1]) for g in keys for x in rows[g]["edges"]] or [0]))}


def bootstrap(rows, base=None, n=2000, seed=57):
    """95 % intervals of heard/h, show/h (and their difference from `base`)."""
    keys = sorted(rows)
    rng = np.random.default_rng(seed)
    A = np.array([rows[g]["audio"] for g in keys]) / 3600
    H = np.array([rows[g]["heard"] for g in keys]); S = np.array([rows[g]["show"] for g in keys])
    if base is not None:
        H0 = np.array([base[g]["heard"] for g in keys]); S0 = np.array([base[g]["show"] for g in keys])
    out = collections.defaultdict(list)
    for _ in range(n):
        i = rng.integers(0, len(keys), len(keys))
        a = A[i].sum()
        out["heard"].append(H[i].sum() / a); out["show"].append(S[i].sum() / a)
        if base is not None:
            out["dheard"].append((H[i].sum() - H0[i].sum()) / a); out["dshow"].append((S[i].sum() - S0[i].sum()) / a)
    return {k: [float(np.percentile(v, 2.5)), float(np.percentile(v, 97.5))] for k, v in out.items()}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("out")
    p.add_argument("runs", nargs="+")
    p.add_argument("--deltas", default="-1.5,-1,-0.5,0,0.5,1,1.5,2")
    p.add_argument("--bin", default=os.path.join(ROOT, "build", "p56", "lab-segments"))
    p.add_argument("--results", default=RESULTS)
    p.add_argument("--base", help="run name the others are compared with (paired intervals)")
    p.add_argument("--gaps", action="store_true", help="wordless gaps inside breaks are EITHER (phone_eval.with_gaps)")
    a = p.parse_args()
    global GAPS
    GAPS = a.gaps
    rd.BIN = a.bin
    rd.prepare(a.results)
    labels = phone_eval.load_labels()
    data = json.load(open(a.results))
    episodes = {e["guid"]: e for e in data["episodes"]}
    bykey = {rd.key_of(e): e for e in data["episodes"]}
    deltas = [float(x) for x in a.deltas.split(",")]
    cache = json.load(open(a.out)) if os.path.exists(a.out) else {}
    jobs = []
    runs = {}
    for spec in a.runs:
        name, path = spec.split("=", 1)
        runs[name] = load_probs(path)
        for k, d in runs[name].items():
            e = bykey.get(k)
            if not e or e["guid"] not in labels:
                continue
            for delta in deltas:
                tag = f"{name}@{delta:g}"
                if e["guid"] in cache.get(tag, {}):
                    continue
                jobs.append((tag, e["guid"], k, d["rows"], delta))

    def run(job):
        tag, g, k, rows, delta = job
        return tag, g, detect(k, shifted(rows, delta))
    with ThreadPoolExecutor(8) as ex:
        for tag, g, cuts in ex.map(run, jobs):
            cache.setdefault(tag, {})[g] = cuts
    full = json.load(open(a.out)) if os.path.exists(a.out) else {}
    for t, c in cache.items():
        full.setdefault(t, {}).update(c)
    json.dump(full, open(a.out, "w"))
    # Only the runs asked for, on the episodes every one of them has (a run
    # still training has only its finished folds).
    names = set(runs)
    cache = {t: c for t, c in cache.items() if t.split("@")[0] in names}
    common = set.intersection(*[set(c) for c in cache.values()]) if cache else set()
    scores = {tag: episode_scores({g: c[g] for g in common}, episodes, labels) for tag, c in cache.items()}
    base0 = scores.get(f"{a.base}@0") if a.base else None
    print(f"{'reader @ δ':22} {'eps':>3} {'heard s/h':>17} {'show cut s/h':>17} {'missed':>8} {'kind✗':>5} "
          f"{'edges':>9} {'Δheard vs base':>17} {'Δshow vs base':>17}")
    for tag in sorted(scores, key=lambda t: (t.split("@")[0], float(t.split("@")[1]))):
        rows = scores[tag]
        t = totals(rows)
        common = base0 is not None and set(rows) == set(base0)
        ci = bootstrap(rows, base0 if common else None)
        d = (f"{ci['dheard'][0]:+6.1f}…{ci['dheard'][1]:+6.1f}  {ci['dshow'][0]:+6.1f}…{ci['dshow'][1]:+6.1f}"
             if common else "")
        print(f"{tag:22} {len(rows):3d} {t['heard']:5.1f} ({ci['heard'][0]:4.1f}–{ci['heard'][1]:4.1f}) "
              f"{t['show']:5.1f} ({ci['show'][0]:4.1f}–{ci['show'][1]:4.1f}) {t['missed']:3d}/{t['regions']:<3d} "
              f"{t['kind']:5d} {t['edgeStart']:4.1f}/{t['edgeEnd']:<4.1f} {d}")


if __name__ == "__main__":
    main()
