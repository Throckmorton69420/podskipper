#!/usr/bin/env python3
"""Pass 59: the PodSkipper test — one fair way to compare every ad finder.

His 7 Nov objections to the old numbers: seconds-per-hour figures from
different episodes can't be compared (ad load runs from 0 to 361 s/h by
show); Basic/Hard are two made-up samples; and the score must weigh a missed
break against a slightly late cut sensibly.

What this does instead:

* **Paired.** Only episodes every compared engine has cuts for are scored,
  so every engine faces the same ads, plugs, intros and traps.
* **Everyday score** (0-100): how much of the interruption an engine removes,
  net of the damage it does, on whole episodes, every show counting the same.
  Cost of an episode = seconds of skippable audio still heard (beyond a 2 s
  allowance at each edge of every break) + 10 s for every break you'd notice
  (more than 5 s of it heard) + 2 x every second of the show cut + 10 s for
  every jump in the show (a show cut longer than 2 s). Cutting nothing costs
  every break's length + 10 s each: that's 0. Perfect is 100. An engine that
  cuts a lot of the show can go below 0.
* **Challenge score** (0-100): the same episodes cut into situations (host
  read, produced spot, back-to-back spots, short spot, long comic read,
  pre-roll, post-roll, plug round, the hosts' own plug, other shows' promos,
  intro, outro/credits, and traps: show talk with selling words in it). Each
  situation's pass rate counts the same however rare it is.

    podtest.py <scope> name=<cuts.json>[:<key>] ... [--gaps] [--shows]

scope: `test` (no shipped reader trained on them), `folds` (all labelled
episodes) or a comma list of guid prefixes. Cut files as compare.py reads
them ({guid: {key: [[start, end, kind], ...]}} or a frontier cache).
"""
import argparse, collections, json, os, re, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import phone_eval  # noqa: E402
from label_audit import CATEGORIES  # noqa: E402

SKIP = ("AD", "SELF", "NETWORK", "INTRO", "OUTRO")
EDGE = 2.0          # s at each edge of a break that may be left either way
NOTICED = 5.0       # s of a break heard before you notice it
NOTICE_COST = 10.0  # s added for a break you notice
SHOW_WEIGHT = 2.0   # a second of the show cut costs two of an ad heard
JUMP = 2.0          # a show cut longer than this is a jump you hear
JUMP_COST = 10.0    # s added per jump
SHOW_MARGIN = 1.0   # s of the show next to a break that may be cut either way

SITUATIONS = [
    ("host read", "an ad the hosts read themselves"),
    ("produced spot", "a recorded ad"),
    ("back to back", "one of several spots in a row"),
    ("short spot", "an ad under 20 s"),
    ("long read", "an ad over 2 min (riffs, jokes inside)"),
    ("pre-roll", "a break in the first minute"),
    ("post-roll", "a break in the last 2 min"),
    ("plug round", "plugs the host asks for (guest's dates, handles)"),
    ("own plug", "the show's own tour, Patreon, merch"),
    ("other show", "another show's promo or trailer"),
    ("intro", "the opening theme or ident"),
    ("outro", "the closing theme and credits"),
    ("selling words in the show", "show talk with ad words (keep it)"),
    ("plug words in the show", "talk about tours, tickets, merch (keep it)"),
]


def union(ivs):
    return phone_eval.union(ivs)


def covered(a, b, ivs):
    return phone_eval.covered(a, b, ivs)


def allowance(length):
    return min(EDGE, 0.15 * length)


def region_situations(r, spans, lines, audio_end, text):
    """Which challenge situations a labelled region is an instance of."""
    a, b, k = r[0], r[1], r[2]
    out = []
    if k == "AD":
        out.append("host read" if r[4] == "host" else "produced spot" if r[4] == "produced" else None)
        others = [s for s in spans if s is not r and s[2] in SKIP and (abs(s[0] - b) <= 3 or abs(a - s[1]) <= 3)]
        if others:
            out.append("back to back")
        if b - a < 20:
            out.append("short spot")
        if b - a > 120:
            out.append("long read")
    if k in ("AD", "SELF", "NETWORK"):
        if a < 60:
            out.append("pre-roll")
        if b > audio_end - 120:
            out.append("post-roll")
    if k == "SELF":
        out.append("plug round" if CATEGORIES["plug-round"].search(text) else "own plug")
    if k == "NETWORK":
        out.append("other show")
    if k == "INTRO":
        out.append("intro")
    if k == "OUTRO":
        out.append("outro")
    return [s for s in out if s]


def traps(lines, spans):
    """Show lines with selling or plug words, at least 30 s from any labelled
    region: talk to keep that a careless finder cuts."""
    near = union([(s[0] - 30, s[1] + 30) for s in spans])
    out = []
    for i, l in enumerate(lines):
        if covered(l["start"], l["end"], near) > 0:
            continue
        if CATEGORIES["selling"].search(l["text"]):
            out.append((l["start"], l["end"], "selling words in the show", i))
        elif CATEGORIES["own-plug"].search(l["text"]) or CATEGORIES["plug-round"].search(l["text"]):
            out.append((l["start"], l["end"], "plug words in the show", i))
    return out


def score_episode(label, ep, cuts, gaps=True):
    lines = ep["transcript"]
    audio_end = ep.get("duration") or lines[-1]["end"]
    raw = phone_eval.spans(label, lines)
    deliveries = {r["id"]: r.get("delivery", "") for r in label["regions"]}
    spans = [(a, b, k, i, deliveries.get(i, "")) for a, b, k, i in raw]
    if gaps:
        spans += [(a, b, k, i, "") for a, b, k, i in phone_eval.with_gaps(raw, lines, audio_end)[len(raw):]]
    cut_ivs = union([(c[0], c[1]) for c in cuts])
    skip = [s for s in spans if s[2] in SKIP]
    labelled = union([(s[0], s[1]) for s in spans if s[2] in SKIP or s[2] == "EITHER"])
    r = {"heard": 0.0, "noticed": 0, "show": 0.0, "jumps": 0, "base": 0.0, "breaks": len(skip), "caught": 0,
         "skippable": 0.0, "byKind": collections.Counter(), "kindN": collections.Counter(),
         "kindCaught": collections.Counter(), "sit": collections.Counter(), "sitN": collections.Counter()}
    for s in skip:
        a, b = s[0], s[1]
        length = b - a
        al = allowance(length)
        core = (a + al, b - al)
        heard = (core[1] - core[0]) - covered(core[0], core[1], cut_ivs) if core[1] > core[0] else 0.0
        noticed = heard > NOTICED
        r["heard"] += heard
        r["noticed"] += noticed
        r["base"] += max(0.0, core[1] - core[0]) + NOTICE_COST
        r["skippable"] += max(0.0, core[1] - core[0])
        r["caught"] += not noticed
        r["byKind"][s[2]] += heard
        r["kindN"][s[2]] += 1
        r["kindCaught"][s[2]] += not noticed
        text = " ".join(l["text"] for l in lines if l["start"] >= a - 0.01 and l["end"] <= b + 0.01)
        for sit in region_situations(s, spans, lines, audio_end, text):
            r["sitN"][sit] += 1
            r["sit"][sit] += not noticed
    # The show: everything unlabelled, less a margin next to each break.
    margin = union([(x - SHOW_MARGIN, y + SHOW_MARGIN) for x, y in labelled])
    for a, b in cut_ivs:
        pieces, start = [], a
        for x, y in margin:
            if y <= start or x >= b:
                continue
            if x > start:
                pieces.append((start, x))
            start = max(start, y)
        if start < b:
            pieces.append((start, b))
        for x, y in pieces:
            r["show"] += y - x
            r["jumps"] += (y - x) > JUMP
    for x, y, sit, _ in traps(lines, spans):
        r["sitN"][sit] += 1
        r["sit"][sit] += covered(x, y, cut_ivs) < 0.5 * (y - x)
    r["cost"] = r["heard"] + NOTICE_COST * r["noticed"] + SHOW_WEIGHT * r["show"] + JUMP_COST * r["jumps"]
    r["audio"] = audio_end
    return r


def everyday(rows, weights):
    cost = sum(weights[g] * x["cost"] for g, x in rows.items())
    base = sum(weights[g] * x["base"] for g, x in rows.items())
    return 100 * (1 - cost / base) if base else float("nan")


def challenge(rows):
    n, ok = collections.Counter(), collections.Counter()
    for x in rows.values():
        n.update(x["sitN"]); ok.update(x["sit"])
    rates = {s: ok[s] / n[s] for s, _ in SITUATIONS if n[s]}
    return 100 * float(np.mean(list(rates.values()))), rates, n


def show_weights(rows, show_of):
    per = collections.Counter(show_of[g] for g in rows)
    return {g: 1.0 / per[show_of[g]] for g in rows}


def bootstrap(rows_a, rows_b, show_of, n=2000, seed=7):
    """95 % interval of Everyday(a) - Everyday(b), resampling shows then
    episodes within them (paired: the same draw for both)."""
    rng = np.random.default_rng(seed)
    shows = sorted({show_of[g] for g in rows_a})
    by = {s: [g for g in rows_a if show_of[g] == s] for s in shows}
    d = []
    for _ in range(n):
        pick = []
        for s in rng.choice(shows, len(shows)):
            pick += list(rng.choice(by[s], len(by[s])))
        w = collections.Counter(pick)
        per = collections.Counter(show_of[g] for g in pick)
        ww = {g: c / per[show_of[g]] for g, c in w.items()}
        def ev(rows):
            cost = sum(ww[g] * rows[g]["cost"] for g in ww)
            base = sum(ww[g] * rows[g]["base"] for g in ww)
            return 100 * (1 - cost / base) if base else 0.0
        d.append(ev(rows_a) - (ev(rows_b) if rows_b else 0))
    return np.percentile(d, 2.5), np.percentile(d, 97.5)


def load_sets(specs, scope):
    sets = {}
    for spec in specs:
        name, path = spec.split("=", 1)
        path, _, key = path.partition(":")
        d = json.load(open(path))
        if key and key in d and isinstance(d[key], dict) and not any(isinstance(v, dict) for v in d[key].values()):
            sets[name] = {g: d[key][g] for g in d[key] if g in scope}
        else:
            sets[name] = {g: (v[key] if key else next(iter(v.values()))) for g, v in d.items()
                          if g in scope and isinstance(v, dict) and (not key or key in v)}
    return sets


def main():
    p = argparse.ArgumentParser()
    p.add_argument("scope")
    p.add_argument("sets", nargs="+")
    p.add_argument("--no-gaps", action="store_true")
    p.add_argument("--shows", action="store_true")
    p.add_argument("--unpaired", action="store_true", help="score each engine on all its own episodes (not comparable)")
    a = p.parse_args()
    man = corpus.load_manifest()["episodes"]
    labels = phone_eval.load_labels()
    if a.scope == "test":
        scope = {g for g, m in man.items() if m["testEpisode"] and g in labels}
    elif a.scope == "folds":
        scope = {g for g in labels if g in man}
    else:
        scope = {g for g in labels if g in man and any(g.startswith(x) for x in a.scope.split(","))}
    sets = load_sets(a.sets, scope)
    common = set.intersection(*(set(s) for s in sets.values())) if sets else set()
    cache = {}

    def episode(g):
        m = man[g]
        if m["source"] not in cache:
            cache.clear()
            cache[m["source"]] = json.load(open(os.path.join(ROOT, m["source"])))
        return cache[m["source"]]["episodes"][m["index"]]
    show_of = {g: man[g]["show"] for g in scope}
    rows = {}
    for name, cuts in sets.items():
        use = sorted(cuts) if a.unpaired else sorted(common)
        rows[name] = {g: score_episode(labels[g], episode(g), cuts[g], gaps=not a.no_gaps) for g in use}
    eps = len(common)
    shows = len({show_of[g] for g in common})
    print(f"PodSkipper test · scope {a.scope} · {'unpaired' if a.unpaired else f'paired on {eps} episodes, {shows} shows'}")
    print("| engine | Everyday (95 %) | Challenge | breaks noticed | skippable heard | show cut s/h | jumps/h |")
    print("|---|---|---|---|---|---|---|")
    first = None
    for name, r in rows.items():
        if not r:
            continue
        w = show_weights(r, show_of)
        ev = everyday(r, w)
        lo, hi = bootstrap(r, None, show_of)
        ch, rates, n = challenge(r)
        h = sum(x["audio"] for x in r.values()) / 3600
        noticed = sum(x["noticed"] for x in r.values()); breaks = sum(x["breaks"] for x in r.values())
        heard = sum(x["heard"] for x in r.values()); skippable = sum(x["skippable"] for x in r.values())
        print(f"| {name} | **{ev:.1f}** ({lo:.1f}–{hi:.1f}) | {ch:.0f} | {noticed}/{breaks} | {100 * heard / skippable:.0f} % | "
              f"{sum(x['show'] for x in r.values()) / h:.1f} | {sum(x['jumps'] for x in r.values()) / h:.1f} |")
        first = first or name
    names = [n for n in rows if rows[n]]
    print("\nChallenge, situation by situation (share handled; n = instances):")
    print("| situation | n | " + " | ".join(names) + " |")
    print("|---|---|" + "---|" * len(names))
    for s, what in SITUATIONS:
        ns = [challenge(rows[n])[2][s] for n in names]
        if not max(ns):
            continue
        cells = [f"{100 * challenge(rows[n])[1].get(s, float('nan')):.0f} %" for n in names]
        print(f"| {s} | {ns[0]} | " + " | ".join(cells) + " |")
    if not a.unpaired and len(names) > 1:
        print(f"\nPaired Everyday differences against {first} (95 %, shows resampled):")
        for n in names[1:]:
            d = everyday(rows[n], show_weights(rows[n], show_of)) - everyday(rows[first], show_weights(rows[first], show_of))
            lo, hi = bootstrap(rows[n], rows[first], show_of)
            print(f"  {n}: {d:+.1f} ({lo:+.1f}…{hi:+.1f})")
    if a.shows:
        print("\nEveryday per show:")
        print("| show | eps | " + " | ".join(names) + " |")
        print("|---|---|" + "---|" * len(names))
        for sh in sorted({show_of[g] for g in common}):
            ks = [g for g in common if show_of[g] == sh]
            cells = [f"{everyday({g: rows[n][g] for g in ks}, {g: 1 for g in ks}):.0f}" for n in names]
            print(f"| {sh[:34]} | {len(ks)} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
