#!/usr/bin/env python3
"""Pass 54: how well each engine finds ads in his real episodes, measured so
that no number can be flattered by the Reader's training data, by another
engine's work or by a reused answer.

    episode_eval.py [--out build/p54/eval.json] [--reader-folds build/p53/base/cuts.json]

Reads every Results export in build/phone-1*/ (attempts de-duplicated by id)
and the labels in phone-labels/. Separately for each engine:

  own      the engine's own cuts (a model's parts before the app's cut check;
           Apple Intelligence's detector output)
  saved    what the app saved after fusing a model with the Reader
  Reader   the Reader as shipped (its cuts in the same attempt) — trained on
           the labels of passes ≤ 44, so on those episodes it is marked
           "seen in training" and left out of the comparison
  Reader (held-out show)
           Pass 53's show-held-out fold readers: a reader that never saw any
           episode of that show (transcript only, no audio evidence)
  no cuts  the baseline every number is read against

Per engine, only on the episodes that engine itself read with a fresh
answer (attempts that reused parts answered on an earlier run are left
out). Per class (ads, own and guests' plugs, other shows' promos, intros,
outros): seconds heard per hour and stretches mostly missed; the show cut
per hour (time a listener loses) and how many cuts lie wholly in the show;
named the wrong kind; and break edges (median seconds the skip starts late /
ends early or late). His own corrections are scored on their own: the only
human-reviewed truth (what he locked, confirmed, added or moved).

Models on his phone read in "focused" mode: only the stretches the shipped
Reader flagged, the opening and closing minutes and lines with selling
words. Their own cuts therefore aren't independent of the Reader; the
report says which mode each read used.
"""
import argparse, collections, glob, json, os, re, statistics, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import phone_eval  # noqa: E402

CLASSES = ["AD", "SELF", "NETWORK", "INTRO", "OUTRO"]
READER_TRAINED_THROUGH = 44   # the shipped readers (Pass 44) were trained on labels of passes ≤ 44


def label_pass(label):
    m = re.search(r"pass (\d+)", label.get("labelled_by", ""))
    return int(m.group(1)) if m else 0


def engine_name(method):
    return re.sub(r"\s*\(.*", "", method).strip()


def load_attempts():
    """guid → engine → newest fresh attempt; plus the episodes themselves."""
    episodes, attempts = {}, {}
    for path in sorted(glob.glob(os.path.join(ROOT, "build", "phone-1*", "*results*.json"))):
        try:
            d = json.load(open(path))
        except (OSError, ValueError):
            continue
        for e in d.get("episodes", []):
            episodes.setdefault(e["guid"], e)
            for a in e.get("attempts", []):
                attempts[a["id"]] = (e["guid"], a)
    best = collections.defaultdict(dict)
    skipped = collections.Counter()
    for guid, a in attempts.values():
        method = a.get("method", "")
        run = a.get("run") or {}
        if method.startswith("PodSkipper reader"):
            continue
        name = engine_name(method)
        reads = run.get("partReads") or []
        if any("answered before, kept" in r for r in reads):
            skipped[name + " (reused parts)"] += 1
            continue
        if run.get("deferred"):
            continue
        old = best[guid].get(name)
        if old is None or a["date"] > old["date"]:
            best[guid][name] = a
    return episodes, best, skipped


def breaks(label_spans):
    """Skippable regions joined into breaks where they touch or an EITHER joins them."""
    ivs = sorted((s[0], s[1], s[2]) for s in label_spans if s[2] in CLASSES + ["EITHER"])
    out = []
    for a, b, k in ivs:
        if out and a <= out[-1][1] + 2.0:
            out[-1][1] = max(out[-1][1], b)
            out[-1][2] |= k != "EITHER"
        else:
            out.append([a, b, k != "EITHER"])
    return [(a, b) for a, b, real in out if real]


def measure(label_spans, cuts, audio):
    cut_ivs = phone_eval.union([(c[0], c[1]) for c in cuts])
    skip_ivs = phone_eval.union([(s[0], s[1]) for s in label_spans if s[2] in CLASSES])
    either_ivs = phone_eval.union([(s[0], s[1]) for s in label_spans if s[2] == "EITHER"])
    allowed = phone_eval.union(skip_ivs + either_ivs)
    m = collections.Counter()
    m["audio"] = audio
    for a, b, kind, _ in label_spans:
        if kind not in CLASSES:
            continue
        length = max(0.1, b - a)
        heard = length - phone_eval.covered(a, b, cut_ivs)
        m["heard " + kind] += heard
        m["n " + kind] += 1
        if heard / length > 0.5:
            m["missed " + kind] += 1
            continue
        best = max(cuts, key=lambda c: max(0.0, min(b, c[1]) - max(a, c[0])))
        m["named"] += 1
        if phone_eval.KIND.get(best[2], best[2]) != kind:
            m["wrong kind"] += 1
    for a, b in cut_ivs:
        inside = phone_eval.covered(a, b, allowed)
        m["show cut"] += (b - a) - inside
        if inside / max(0.1, b - a) < 0.2:
            m["cuts in the show"] += 1
    edges = []
    for a, b in breaks(label_spans):
        over = [iv for iv in cut_ivs if iv[1] > a and iv[0] < b]
        if not over or phone_eval.covered(a, b, cut_ivs) / max(0.1, b - a) < 0.5:
            continue
        edges.append((min(iv[0] for iv in over) - a, max(iv[1] for iv in over) - b))
    return m, edges


def table(rows, title):
    print(f"\n### {title}\n")
    head = ["engine", "eps", "h", "heard s/h", "ads", "plugs", "promos", "intros", "outros",
            "show cut s/h", "cuts in show", "missed", "kind✗", "edge start/end s"]
    print("| " + " | ".join(head) + " |")
    print("|" + "---|" * len(head))
    for name, (m, edges, eps) in rows:
        h = m["audio"] / 3600 or 1
        heard = sum(m["heard " + k] for k in CLASSES)
        cls = [f"{m['heard ' + k] / h:.1f} ({m['missed ' + k]}/{m['n ' + k]})" for k in CLASSES]
        missed = sum(m["missed " + k] for k in CLASSES)
        n = sum(m["n " + k] for k in CLASSES)
        es = statistics.median(abs(e[0]) for e in edges) if edges else 0
        ee = statistics.median(abs(e[1]) for e in edges) if edges else 0
        print(f"| {name} | {eps} | {h:.1f} | {heard / h:.1f} | " + " | ".join(cls)
              + f" | {m['show cut'] / h:.1f} | {m['cuts in the show']} | {missed}/{n} | "
              + f"{m['wrong kind']}/{m['named']} | {es:.1f} / {ee:.1f} |")


def human(episodes, best, folds):
    """His corrections: every locked, confirmed, added or edited stretch should be cut."""
    print("\n### His own corrections (human-reviewed truth: what he locked, confirmed, added or moved)\n")
    print("| engine | episodes | his stretches | heard of them s | of total s | mostly missed |")
    print("|---|---|---|---|---|---|")
    totals = collections.defaultdict(collections.Counter)
    for guid, e in episodes.items():
        truth = [(float(c["key"].split("-")[0]), float(c["key"].split("-")[1]))
                 for c in e.get("corrections") or [] if c.get("action") in ("lock", "confirm", "add", "edit")
                 and "-" in c.get("key", "")]
        if not truth:
            continue
        sets = {}
        for name, a in best.get(guid, {}).items():
            sets[name + " own"] = a.get("proposedCuts") or a.get("savedCuts") or []
            sets[name + " saved"] = a.get("savedCuts") or []
            sets.setdefault("Reader (shipped)", a.get("readerCuts") or [])
        if guid in folds:
            sets["Reader (held-out show)"] = [{"start": c[0], "end": c[1]} for c in folds[guid]]
        sets["no cuts"] = []
        for name, cuts in sets.items():
            ivs = phone_eval.union([(c["start"], c["end"]) for c in cuts])
            t = totals[name]
            t["episodes"] += 1
            for a, b in truth:
                heard = (b - a) - phone_eval.covered(a, b, ivs)
                t["stretches"] += 1
                t["heard"] += heard
                t["total"] += b - a
                if heard / max(0.1, b - a) > 0.5:
                    t["missed"] += 1
    for name, t in sorted(totals.items(), key=lambda kv: kv[1]["heard"]):
        print(f"| {name} | {t['episodes']} | {t['stretches']} | {t['heard']:.0f} | {t['total']:.0f} | {t['missed']} |")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--out", default=os.path.join(ROOT, "build", "p54", "eval.json"))
    p.add_argument("--reader-folds", default=os.path.join(ROOT, "build", "p53", "base", "cuts.json"))
    args = p.parse_args()
    labels = phone_eval.load_labels()
    episodes, best, skipped = load_attempts()
    folds = {}
    if os.path.exists(args.reader_folds):
        for guid, sets in json.load(open(args.reader_folds)).items():
            folds[guid] = next(iter(sets.values()))
    engines = sorted({n for g in best for n in best[g] if g in labels})
    print(f"Labelled episodes: {len(labels)} ({sum(1 for l in labels.values() if label_pass(l) > READER_TRAINED_THROUGH)} unseen by the shipped Reader). "
          f"Attempts left out for reusing earlier answers: {dict(skipped)}")
    report = {}
    for engine in engines:
        guids = [g for g in labels if engine in best.get(g, {}) and g in episodes]
        modes = collections.Counter((best[g][engine].get("run") or {}).get("mode", "?") for g in guids)
        builds = collections.Counter(best[g][engine].get("build") for g in guids)
        rows = collections.OrderedDict()
        for key in ["own", "saved", "own, unseen episodes only", "saved, unseen episodes only",
                    "Reader (shipped, unseen episodes only)", "Reader (held-out show)", "no cuts"]:
            rows[key] = [collections.Counter(), [], 0]
        for g in guids:
            e, a, label = episodes[g], best[g][engine], labels[g]
            lines = e["transcript"]
            ls = phone_eval.spans(label, lines)
            audio = lines[-1]["end"]
            own = a.get("proposedCuts") or (a.get("savedCuts") if engine == "Apple Intelligence" else [])
            sets = {"own": own, "saved": a.get("savedCuts") or [], "no cuts": []}
            if label_pass(label) > READER_TRAINED_THROUGH:
                sets["Reader (shipped, unseen episodes only)"] = a.get("readerCuts") or []
                sets["own, unseen episodes only"] = own
                sets["saved, unseen episodes only"] = a.get("savedCuts") or []
            if g in folds:
                sets["Reader (held-out show)"] = [{"start": c[0], "end": c[1], "kind": c[2]} for c in folds[g]]
            for key, cuts in sets.items():
                m, edges = measure(ls, [(c["start"], c["end"], c["kind"]) for c in cuts], audio)
                rows[key][0].update(m)
                rows[key][1] += edges
                rows[key][2] += 1
        if engine == "Apple Intelligence":
            rows.pop("saved")
            rows.pop("saved, unseen episodes only")
        shown = [(k, (v[0], v[1], v[2])) for k, v in rows.items() if v[2]]
        table(shown, f"{engine} — {len(guids)} labelled episodes it read fresh · modes {dict(modes)} · builds {dict(builds)}")
        report[engine] = {k: {"episodes": v[2], **{x: y for x, y in v[0].items()}, "edges": v[1]} for k, v in rows.items()}
    human(episodes, best, folds)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    json.dump(report, open(args.out, "w"), indent=1)
    print(f"\nwrote {args.out}")


if __name__ == "__main__":
    main()
