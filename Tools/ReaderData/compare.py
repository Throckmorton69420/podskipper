#!/usr/bin/env python3
"""Pass 57: the Reader comparison — every engine's cuts on the same labelled
episodes, per kind and per show, with 95 % bootstrap intervals over episodes.

    compare.py <scope> name=<cuts.json>[:<key in it>] …  [--labels HEAD|<rev>]

scope: `test` (the manifest's test episodes: no reader in the comparison
trained on them), `folds` (every labelled episode; use only show-held-out
answers), or a comma list of guid prefixes. A cut set covers the episodes it
has; rows say how many. `--labels <git rev>` scores against the labels of
that revision (default: the files as they are now, label policy 2).

Kinds heard: ads (AD), plugs (SELF), promos (NETWORK), intros, outros —
seconds per hour of the episodes' audio. "show cut" is time cut outside
every labelled region and EITHER. Kind ✗: breaks mostly cut but named a
different kind. Edges: median start/end error of each break a skip covers.
"""
import argparse, collections, json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import frontier  # noqa: E402
import phone_eval  # noqa: E402

KINDS = ["AD", "SELF", "NETWORK", "INTRO", "OUTRO"]


def labels_at(rev):
    if not rev:
        return phone_eval.load_labels()
    out = {}
    names = subprocess.run(["git", "-C", ROOT, "ls-tree", "--name-only", rev, "Tools/DetectionLab/phone-labels/"],
                           capture_output=True, text=True).stdout.split()
    for n in names:
        d = json.loads(subprocess.run(["git", "-C", ROOT, "show", f"{rev}:{n}"], capture_output=True, text=True).stdout)
        out[d["guid"]] = d
    return out


def per_kind(ls, cuts):
    ivs = phone_eval.union([(c[0], c[1]) for c in cuts])
    out = {}
    for k in KINDS:
        spans = phone_eval.union([(a, b) for a, b, kk, _ in ls if kk == k])
        out[k] = sum(b - a - phone_eval.covered(a, b, ivs) for a, b in spans)
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("scope")
    p.add_argument("sets", nargs="+")
    p.add_argument("--labels", default="")
    p.add_argument("--shows", action="store_true", help="per-show rows too")
    p.add_argument("--gaps", action="store_true",
                   help="label policy 2 rule 9: wordless gaps inside a break are EITHER (phone_eval.with_gaps)")
    a = p.parse_args()
    man = corpus.load_manifest()["episodes"]
    labels = labels_at(a.labels)
    if a.scope == "test":
        scope = {g for g, m in man.items() if m["testEpisode"] and g in labels}
    elif a.scope == "folds":
        scope = {g for g in labels if g in man}
    else:
        scope = {g for g in labels if any(g.startswith(x) for x in a.scope.split(","))}
    cache = {}

    def episode(g):
        m = man[g]
        if m["source"] not in cache:
            cache.clear()
            cache[m["source"]] = json.load(open(os.path.join(ROOT, m["source"])))
        return cache[m["source"]]["episodes"][m["index"]]
    sets = {}
    for spec in a.sets:
        name, path = spec.split("=", 1)
        path, _, key = path.partition(":")
        d = json.load(open(path))
        if key and key in d and isinstance(d[key], dict) and not any(isinstance(v, dict) for v in d[key].values()):
            sets[name] = {g: d[key][g] for g in d[key] if g in scope}          # frontier cache: {tag: {guid: cuts}}
        else:
            sets[name] = {g: (v[key] if key else next(iter(v.values()))) for g, v in d.items()
                          if g in scope and (not key or key in v)}
    rows = {}
    for name, cuts in sets.items():
        r = {}
        for g in sorted(cuts):
            e = episode(g)
            ls = phone_eval.spans(labels[g], e["transcript"])
            if a.gaps:
                ls = phone_eval.with_gaps(ls, e["transcript"], e.get("duration") or None)
            s = phone_eval.score(ls, [tuple(c) for c in cuts[g]], e["transcript"][-1]["end"])
            r[g] = {"audio": s["audio"], "heard": s["heard"], "show": s["show_cut"], "missed": len(s["missed"]),
                    "regions": s["regions"], "kind": s["wrong_kind"],
                    "edges": frontier.rd.block_edges(ls, cuts[g]), "byKind": per_kind(ls, cuts[g]),
                    "show_name": man[g]["show"]}
        rows[name] = r
    print(f"scope {a.scope}: {len(scope)} labelled episodes · labels {a.labels or 'policy 2 (working tree)'}"
          f"{' · wordless gaps inside breaks are EITHER' if a.gaps else ''}")
    hdr = f"| engine | eps | h | heard s/h (95 %) | show cut s/h (95 %) | " + " | ".join(k.lower() for k in KINDS) + " | missed | kind ✗ | edges s |"
    print(hdr); print("|" + "---|" * (hdr.count("|") - 1))
    for name, r in rows.items():
        if not r:
            continue
        t = frontier.totals(r); ci = frontier.bootstrap(r)
        h = sum(x["audio"] for x in r.values()) / 3600
        kinds = " | ".join(f"{sum(x['byKind'][k] for x in r.values()) / h:.1f}" for k in KINDS)
        print(f"| {name} | {len(r)} | {h:.1f} | {t['heard']:.1f} ({ci['heard'][0]:.1f}–{ci['heard'][1]:.1f}) | "
              f"{t['show']:.1f} ({ci['show'][0]:.1f}–{ci['show'][1]:.1f}) | {kinds} | {t['missed']}/{t['regions']} | "
              f"{t['kind']} | {t['edgeStart']:.1f} / {t['edgeEnd']:.1f} |")
    names = list(rows)
    if len(names) > 1:
        base = names[0]
        print(f"\nPaired differences against {base} (same episodes, 95 %):")
        for name in names[1:]:
            common = sorted(set(rows[name]) & set(rows[base]))
            if not common:
                continue
            ci = frontier.bootstrap({g: rows[name][g] for g in common}, {g: rows[base][g] for g in common})
            t1 = frontier.totals(rows[name], common); t0 = frontier.totals(rows[base], common)
            print(f"  {name}: {len(common)} eps · heard {t1['heard'] - t0['heard']:+.1f} ({ci['dheard'][0]:+.1f}…{ci['dheard'][1]:+.1f}) · "
                  f"show cut {t1['show'] - t0['show']:+.1f} ({ci['dshow'][0]:+.1f}…{ci['dshow'][1]:+.1f})")
    if a.shows:
        print("\nPer show (heard / show cut s/h):")
        shows = sorted({x["show_name"] for r in rows.values() for x in r.values()})
        print("| show | " + " | ".join(names) + " |"); print("|" + "---|" * (len(names) + 1))
        for sh in shows:
            cells = []
            for name in names:
                ks = [g for g, x in rows[name].items() if x["show_name"] == sh]
                if not ks:
                    cells.append("—"); continue
                t = frontier.totals(rows[name], ks)
                cells.append(f"{t['heard']:.0f} / {t['show']:.0f} ({len(ks)})")
            print(f"| {sh[:34]} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
