#!/usr/bin/env python3
"""Pass 53: per-class scores of cut sets against the labels — what is heard
of each kind (ads, own plugs, network promos, intros, outros), how many of
each are mostly missed, and the show cut — so a Reader change can't trade
one class for another unseen.

    perclass.py <results.json> <cuts.json> [name …]
"""
import collections, json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import phone_eval  # noqa: E402

KINDS = ["AD", "SELF", "NETWORK", "INTRO", "OUTRO"]


def main():
    results, path, names = sys.argv[1], sys.argv[2], set(sys.argv[3:])
    labels = phone_eval.load_labels()
    eps = {e["guid"]: e for e in json.load(open(results))["episodes"]}
    cuts = json.load(open(path))
    common = None
    for g, sets in cuts.items():
        have = set(sets) & names if names else set(sets)
        common = have if common is None else common & have
    t = collections.defaultdict(collections.Counter)
    for g, sets in cuts.items():
        if g not in labels or g not in eps:
            continue
        lines = eps[g]["transcript"]; audio = lines[-1]["end"]
        ls = phone_eval.spans(labels[g], lines)
        for name in common:
            ivs = phone_eval.union([(c[0], c[1]) for c in sets[name]])
            r = phone_eval.score(ls, [tuple(c) for c in sets[name]], audio)
            c = t[name]; c["audio"] += audio; c["show"] += r["show_cut"]; c["eps"] += 1
            for a, b, kind, rid in ls:
                if kind not in KINDS: continue
                heard = (b - a) - phone_eval.covered(a, b, ivs)
                c["heard " + kind] += heard; c["n " + kind] += 1
                if heard / max(0.1, b - a) > 0.5: c["missed " + kind] += 1
    print(f"{'set':28} eps  show/h " + " ".join(f"{k:>14}" for k in KINDS) + "   (heard s/h · missed/n)")
    for name, c in sorted(t.items()):
        h = c["audio"] / 3600
        row = " ".join(f"{c['heard ' + k] / h:6.1f} {c['missed ' + k]:3d}/{c['n ' + k]:<3d}" for k in KINDS)
        print(f"{name[:28]:28} {c['eps']:3d} {c['show'] / h:7.1f} {row}")


if __name__ == "__main__":
    main()
