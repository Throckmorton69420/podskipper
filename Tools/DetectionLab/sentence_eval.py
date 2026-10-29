#!/usr/bin/env python3
"""Pass 53: the readers' held-out sentence probabilities (`<tag>/probs` from
reader_distill folds/showfolds) against the labels, before the detector:
per class average precision, and skip-vs-show precision/recall at 0.5.

    sentence_eval.py <results.json> <run dir> [<run dir> …]
"""
import json, os, sys
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import phone_eval, reader_distill as rd, tagger  # noqa: E402


def ap(y, s):
    o = np.argsort(-s); y = y[o]; tp = np.cumsum(y); prec = tp / np.arange(1, len(y) + 1)
    return float((prec * y).sum() / max(1, y.sum()))


def main():
    results, runs = sys.argv[1], sys.argv[2:]
    labels = phone_eval.load_labels()
    eps = {rd.key_of(e): e for e in json.load(open(results))["episodes"]}
    common = None
    for r in runs:
        ks = {n[:-5] for n in os.listdir(os.path.join(r, "probs"))}
        common = ks if common is None else common & ks
    print(f"{'run':10} {'sents':>6} " + " ".join(f"AP {c}".rjust(7) for c in "ASNIO") + "  skip P   skip R")
    for r in runs:
        Y, P = [], []
        for k in sorted(common):
            e = eps[k]
            if e["guid"] not in labels: continue
            rows = json.load(open(os.path.join(r, "probs", k + ".json")))["rows"]
            _, letters = rd.labelled_sentences(e, labels[e["guid"]])
            for row, l in zip(rows, letters):
                if l is None: continue
                Y.append(tagger.LABELS.index(l)); P.append(row[2:])
        Y = np.array(Y); P = np.array(P)
        aps = [ap((Y == tagger.LABELS.index(c)).astype(float), P[:, tagger.LABELS.index(c)]) for c in "ASNIO"]
        skip_true = Y != 0; skip_pred = P[:, 0] < 0.5
        prec = (skip_true & skip_pred).sum() / max(1, skip_pred.sum()); rec = (skip_true & skip_pred).sum() / max(1, skip_true.sum())
        print(f"{os.path.basename(r):10} {len(Y):6d} " + " ".join(f"{a:7.3f}" for a in aps) + f"  {prec:6.3f}  {rec:6.3f}")


if __name__ == "__main__":
    main()
