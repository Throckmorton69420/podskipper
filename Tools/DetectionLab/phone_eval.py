#!/usr/bin/env python3
"""Pass 43: score every engine's cuts in a Results export against the
Claude-labelled phone episodes in Tools/DetectionLab/phone-labels/.

    phone_eval.py <results export.json> [--build fe697b3] [--detail]
    phone_eval.py <results export.json> --cuts <cuts.json>   score extra cut sets

Labels are line ranges of that export's own transcript (the phone never
transcribes an episode twice, so the numbering is stable). Kinds:

  AD, SELF, NETWORK, INTRO, OUTRO   time the app should skip (his defaults
                                    skip all five; guests' plugs are SELF)
  EITHER                            cutting or keeping are both fine
  (anything unlabelled)             the show

Per engine: seconds of skippable time heard (not cut), seconds of show cut,
both per hour of audio; how many labelled regions were mostly missed; how
many cuts named the wrong kind; and the mean edge error of each labelled ad
or plug against the cut that covers most of it. Predictions are never
labels: the labels were read off the transcript around every engine's cuts
and every selling word, not taken from any engine.

--cuts reads {"<guid>": {"<name>": [[start, end, kind], ...]}} so a lab run
(a new prompt, a retrained reader) is scored the same way.
"""
import argparse, collections, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LABELS = os.path.join(HERE, "phone-labels")
SKIP = {"AD", "SELF", "NETWORK", "INTRO", "OUTRO"}
KIND = {"ad": "AD", "selfPromo": "SELF", "crossPromo": "NETWORK", "intro": "INTRO", "outro": "OUTRO",
        "credits": "OUTRO"}


def load_labels():
    out = {}
    for name in sorted(os.listdir(LABELS)):
        if name.endswith(".json"):
            d = json.load(open(os.path.join(LABELS, name)))
            out[d["guid"]] = d
    return out


def spans(label, lines):
    """(start, end, kind, id) for each region, in seconds."""
    out = []
    for r in label["regions"]:
        if "lines" in r:
            a, b = r["lines"]
            out.append((lines[a]["start"], lines[b]["end"], r["label"], r["id"]))
        elif "gap" in r:
            a, b = r["gap"]
            out.append((lines[a]["end"], lines[b]["start"], r["label"], r["id"]))
        else:
            out.append((r["start"], r["end"], r["label"], r["id"]))
    return out


def union(intervals):
    out = []
    for a, b in sorted(intervals):
        if b <= a:
            continue
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return out


def covered(a, b, ivs):
    return sum(max(0.0, min(b, y) - max(a, x)) for x, y in ivs)


def score(label_spans, cuts, audio_end):
    """cuts: [(start, end, kind)]."""
    cut_ivs = union([(c[0], c[1]) for c in cuts])
    skip_ivs = union([(s[0], s[1]) for s in label_spans if s[2] in SKIP])
    either_ivs = union([(s[0], s[1]) for s in label_spans if s[2] == "EITHER"])
    heard = sum(b - a - covered(a, b, cut_ivs) for a, b in skip_ivs)
    # Show = everything not labelled; time cut there is show cut.
    show_cut = 0.0
    for a, b in cut_ivs:
        inside = covered(a, b, union(skip_ivs + either_ivs))
        show_cut += (b - a) - inside
    missed, wrong_kind, edges = [], 0, []
    for s in label_spans:
        if s[2] not in SKIP:
            continue
        a, b = s[0], s[1]
        length = max(0.1, b - a)
        if covered(a, b, cut_ivs) / length < 0.5:
            missed.append(s[3])
            continue
        best = max(cuts, key=lambda c: max(0.0, min(b, c[1]) - max(a, c[0])))
        if KIND.get(best[2], best[2]) != s[2]:
            wrong_kind += 1
        if s[2] in ("AD", "SELF", "NETWORK"):
            edges.append((best[0] - a, best[1] - b))
    return {"heard": heard, "show_cut": show_cut, "missed": missed, "wrong_kind": wrong_kind,
            "edges": edges, "regions": sum(1 for s in label_spans if s[2] in SKIP), "audio": audio_end}


def engine_cuts(episode, build):
    """name → cuts, from the newest attempt of each method on this build."""
    out = {}
    for a in sorted(episode.get("attempts", []), key=lambda a: a["date"], reverse=True):
        if build and a.get("build") != build:
            continue
        m = a.get("method", "")
        if m == "PodSkipper reader":
            out.setdefault("Reader", [(c["start"], c["end"], c["kind"]) for c in a.get("readerCuts", [])])
            continue
        if m.startswith("PodSkipper reader") or m == "Apple Intelligence":
            continue
        out.setdefault(m + " (saved)", [(c["start"], c["end"], c["kind"]) for c in a.get("savedCuts", [])])
        out.setdefault(m + " (model)", [(c["start"], c["end"], c["kind"]) for c in a.get("proposedCuts", [])])
    return out


def main():
    p = argparse.ArgumentParser()
    p.add_argument("results")
    p.add_argument("--build", default="fe697b3")
    p.add_argument("--cuts")
    p.add_argument("--detail", action="store_true")
    args = p.parse_args()
    labels = load_labels()
    episodes = {e["guid"]: e for e in json.load(open(args.results))["episodes"]}
    extra = json.load(open(args.cuts)) if args.cuts else {}
    totals = collections.defaultdict(lambda: collections.Counter())
    edge_all = collections.defaultdict(list)
    missed_all = collections.defaultdict(list)
    for guid, label in labels.items():
        e = episodes.get(guid)
        if not e:
            continue
        lines = e["transcript"]
        ls = spans(label, lines)
        audio = lines[-1]["end"]
        sets = engine_cuts(e, args.build)
        for name, cuts in extra.get(guid, {}).items():
            sets[name] = [tuple(c) for c in cuts]
        for name, cuts in sets.items():
            s = score(ls, cuts, audio)
            t = totals[name]
            t["episodes"] += 1
            t["audio"] += audio
            t["heard"] += s["heard"]
            t["show_cut"] += s["show_cut"]
            t["regions"] += s["regions"]
            t["missed"] += len(s["missed"])
            t["wrong_kind"] += s["wrong_kind"]
            edge_all[name] += s["edges"]
            missed_all[name] += [f"{label['episode'][:24]}:{m}" for m in s["missed"]]
            if args.detail:
                print(f"{label['episode'][:40]:40} {name:45} heard {s['heard']:6.0f}s show cut {s['show_cut']:6.0f}s missed {s['missed']}")
    print(f"\n{'engine':52} {'eps':>3} {'heard s/h':>9} {'show s/h':>9} {'missed':>7} {'kind✗':>6} {'start±':>7} {'end±':>6}")
    for name, t in sorted(totals.items(), key=lambda kv: kv[1]["heard"] / max(1, kv[1]["audio"])):
        hours = t["audio"] / 3600
        edges = edge_all[name]
        ms = sum(abs(x[0]) for x in edges) / max(1, len(edges))
        me = sum(abs(x[1]) for x in edges) / max(1, len(edges))
        print(f"{name:52} {t['episodes']:3d} {t['heard'] / hours:9.1f} {t['show_cut'] / hours:9.1f} "
              f"{t['missed']:3d}/{t['regions']:<3d} {t['wrong_kind']:6d} {ms:7.1f} {me:6.1f}")
    if args.detail:
        for name, m in missed_all.items():
            print(f"\nmissed by {name}: {', '.join(m)}")


if __name__ == "__main__":
    main()
