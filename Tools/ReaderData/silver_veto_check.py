#!/usr/bin/env python3
"""Pass 65: would Pass 64's conversation veto make a teacher's silver labels
(silver.py) more accurate? Measured on the labelled episodes the teacher read,
treating each as if it were unlabelled and comparing its silver sentences with
the human labels — no training, no new teacher reads.

    silver_veto_check.py <teacher> [probs dir]      default build/p65/sx13sb/probs

The Reader's show probability per sentence comes from show-held-out fold
models (the probs dir: every episode scored by a model that never saw its
show), so the filter isn't judged with a Reader that trained on the episode.
The filter mirrors ModelCutCheck.vetoConversation: a silver ad/plug sentence
is dropped where the Reader's show probability is >= the threshold and the
sentence has no selling / plug word — silver.veto, which silver.py applies
when SILVER_PROBS is set.
"""
import collections, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import phone_eval  # noqa: E402
import silver  # noqa: E402
import tagger  # noqa: E402
import teacher_annotate  # noqa: E402


def gold(e, label):
    """C / promo / None (EITHER) per sentence, as reader_distill.labelled_sentences."""
    spans = phone_eval.spans(label, e["transcript"])
    out = []
    for s in tagger.sentences(e["transcript"]):
        m = (s["start"] + s["end"]) / 2
        hit = next((sp for sp in spans if sp[0] <= m <= sp[1]), None)
        out.append("C" if hit is None else None if hit[2] == "EITHER" else "P")
    return out


def main():
    teacher = sys.argv[1]
    probs_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "build", "p65", "sx13sb", "probs")
    man = corpus.load_manifest()["episodes"]
    labels = phone_eval.load_labels()
    sources = {}
    stats = collections.defaultdict(collections.Counter)
    shows = collections.defaultdict(collections.Counter)
    for g, m in sorted(man.items()):
        if g not in labels or m["copyOf"] or not os.path.exists(teacher_annotate.record_path(teacher, g)):
            continue
        key = __import__("re").sub(r"[^A-Za-z0-9]", "_", g)
        pf = os.path.join(probs_dir, key + ".json")
        if not os.path.exists(pf):
            continue
        if m["source"] not in sources:
            sources[m["source"]] = json.load(open(os.path.join(ROOT, m["source"])))["episodes"]
        e = sources[m["source"]][m["index"]]
        r = silver.sentences_for(e, teacher, 0.6, show={})   # unfiltered; the filters are applied below
        if r is None:
            continue
        sents, letters, weights = r
        truth = gold(e, labels[g])
        rows = silver.show_probs(g, probs_dir)
        stats["all"]["episodes"] += 1
        for i, (s, l, w) in enumerate(zip(sents, letters, weights)):
            if not l or l == "C" or truth[i] is None:
                continue
            show = rows.get(round(s["start"], 2))
            if show is None:
                stats["all"]["no prob"] += 1
                continue
            for name, sure in (("silver as is", 2.0), ("veto show>=0.9", 0.9), ("veto show>=0.85", 0.85)):
                one = [l], [w]
                if silver.veto([s], *one, {round(s["start"], 2): show}, sure):   # silver.py's own filter
                    stats[name]["dropped " + ("show (right)" if truth[i] == "C" else "ad (wrong)")] += 1
                    continue
                stats[name]["kept ad, really " + ("show" if truth[i] == "C" else "ad")] += 1
                stats[name]["weighted wrong" if truth[i] == "C" else "weighted right"] += w
                if truth[i] == "C":
                    shows[name][m["show"][:28]] += 1
    print(f"{teacher}: {stats['all']['episodes']} labelled episodes, silver ad/plug sentences vs the human labels "
          f"(EITHER left out; Reader show from {os.path.relpath(probs_dir, ROOT)})")
    for name in ("silver as is", "veto show>=0.9", "veto show>=0.85"):
        c = stats[name]
        right, wrong = c["kept ad, really ad"], c["kept ad, really show"]
        prec = right / (right + wrong) if right + wrong else 0
        wprec = c["weighted right"] / (c["weighted right"] + c["weighted wrong"] or 1)
        print(f"  {name:16} kept {right + wrong:5}: {right:5} ads, {wrong:4} show → precision {prec:.3f} "
              f"(weighted {wprec:.3f}); dropped {c['dropped show (right)']} show, {c['dropped ad (wrong)']} ads")
        print("     show sentences still labelled ad, by show:", dict(shows[name].most_common(6)))


if __name__ == "__main__":
    main()
