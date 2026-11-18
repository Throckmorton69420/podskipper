#!/usr/bin/env python3
"""Pass 67 route 2: a multi-genre SPoRC batch for the teacher pair, and its agreed, vetoed answers as weak labels.

    sporc_teacher_batch.py build <out dir> [--n 500]
        n built SPoRC episodes (sporc66/episodes.json, which has four-Reader soft targets), round-robin over
        SPoRC's genres, one a show, sha256 order, <= 90 min → <out dir>/batch-input.jsonl (the why-first prompt,
        Scripts/distill_reader.py's windows and request) + episodes.json (guid, show, title, genre, sents)
    sporc_teacher_batch.py labels <out dir> <answers A.jsonl> <answers B.jsonl> <weak.json> [--show-veto 0.85]
        each window's answer parsed as distill_reader.py collect does; a sentence is labelled only where both
        teachers put it in a part of the same group (ad: PAID_AD/HOST_READ_AD → A, NETWORK_PROMO → N; plug:
        SELF_PROMO/GUEST_PLUG → S; INTRO → I; OUTRO/CREDITS → O; A's letter when both are in a group) and the four
        shipped Readers' p_show < --show-veto (Pass 65: the veto lifts a teacher's ad precision 0.746 → 0.970)
        → {guid: [[sentence index, letter], …]} for reader_distill.py WEAK=

His episodes never appear here (SPoRC selection excludes his shows); this is not a test set.
"""
import argparse, collections, hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))
import distill_reader as dr  # noqa: E402

D = "/Volumes/Samsung PSSD T9 Media/PodSkipper/data/pk-data/sporc66"
SOFT = [os.path.join(ROOT, "build", "p66", "distill", "sporcprobs"), os.path.join(D, "probs")]
GROUP = {"PAID_AD": ("ad", "A"), "HOST_READ_AD": ("ad", "A"), "NETWORK_PROMO": ("ad", "N"),
         "SELF_PROMO": ("plug", "S"), "GUEST_PLUG": ("plug", "S"), "INTRO": ("intro", "I"),
         "OUTRO": ("outro", "O"), "CREDITS": ("outro", "O")}


def h(x):
    return hashlib.sha256(x.encode()).hexdigest()


def build(a):
    eps = json.load(open(os.path.join(D, "episodes.json")))
    by = collections.defaultdict(list)
    seen_show = set()
    for e in sorted(eps, key=lambda e: h(e["guid"])):
        if e["show"] in seen_show or not e["sents"] or e["sents"][-1]["end"] > 5400:
            continue
        seen_show.add(e["show"])
        by[e["genre"]].append(e)
    picked, k = [], 0
    while len(picked) < a.n and any(len(v) > k for v in by.values()):
        picked += [by[g][k] for g in sorted(by) if len(by[g]) > k]
        k += 1
    picked = picked[: a.n]
    os.makedirs(a.out, exist_ok=True)
    n = 0
    with open(os.path.join(a.out, "batch-input.jsonl"), "w") as f:
        for e in picked:
            lines = [(s["text"], s["start"], s["end"]) for s in e["sents"]]
            for w in dr.windows(len(lines), 400, 20):
                body = dr.request_body("teacher", 2048, dr.user_prompt(e, lines, w), "why-first")
                f.write(json.dumps({"custom_id": f"{e['guid']}|{w[0]}|{w[1]}", "method": "POST",
                                    "url": "/v1/chat/completions", "body": body}) + "\n")
                n += 1
    json.dump([{k: e[k] for k in ("guid", "show", "title", "genre", "sents")} for e in picked],
              open(os.path.join(a.out, "episodes.json"), "w"))
    g = collections.Counter(e["genre"] for e in picked)
    print(f"{len(picked)} episodes ({len(picked)} shows), {n} windows → {a.out}/batch-input.jsonl")
    print("genres:", ", ".join(f"{k} {v}" for k, v in g.most_common()))


def answers(path, eps):
    """{guid: [(first, last, label), …]} with episode line numbers."""
    out = collections.defaultdict(list)
    for line in open(path):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if (row.get("response") or {}).get("status_code") != 200:
            continue
        guid, a, b = row["custom_id"].rsplit("|", 2)
        if guid not in eps:
            continue
        text = row["response"]["body"]["choices"][0]["message"].get("content") or ""
        lines = [(s["text"], s["start"], s["end"]) for s in eps[guid]["sents"]]
        for p in dr.found_entries(dr.parse(text), (int(a), int(b)), lines):
            out[guid].append((p["firstLine"], p["lastLine"], p["label"]))
    return out


def soft_rows(guid, sents):
    name = re.sub(r"[^A-Za-z0-9]", "_", guid) + ".json"
    for d in SOFT:
        path = os.path.join(d, name)
        if os.path.exists(path):
            rows = json.load(open(path))["rows"]
            by = {round(r[0], 2): r[2:8] for r in rows}
            return [by.get(round(s["start"], 2)) for s in sents]
    return None


def labels(a):
    eps = {e["guid"]: e for e in json.load(open(os.path.join(a.dir, "episodes.json")))}
    A, B = answers(a.a, eps), answers(a.b, eps)
    out, counts = {}, collections.Counter()
    for guid, e in eps.items():
        if guid not in A or guid not in B and not B.get(guid) == []:
            counts["not answered by both"] += guid not in A or guid not in B
        n = len(e["sents"])
        ga, gb = [None] * n, [None] * n
        for first, last, label in A.get(guid, []):
            for i in range(first, min(last, n - 1) + 1):
                ga[i] = GROUP.get(label)
        for first, last, label in B.get(guid, []):
            for i in range(first, min(last, n - 1) + 1):
                gb[i] = GROUP.get(label)
        probs = soft_rows(guid, e["sents"])
        rows = []
        for i in range(n):
            if ga[i] and gb[i] and ga[i][0] == gb[i][0]:
                if probs is not None and probs[i] is not None and probs[i][0] >= a.show_veto:
                    counts["vetoed (Reader sure it is the show)"] += 1
                    continue
                rows.append([i, ga[i][1]])
                counts[ga[i][1]] += 1
            elif ga[i] or gb[i]:
                counts["one teacher only (left out)"] += 1
        if rows:
            out[guid] = rows
    json.dump(out, open(a.weak, "w"))
    print(f"{len(out)} of {len(eps)} episodes with agreed labels; {dict(counts)} → {a.weak}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("out")
    b.add_argument("--n", type=int, default=500)
    l = sub.add_parser("labels")
    l.add_argument("dir")
    l.add_argument("a")
    l.add_argument("b")
    l.add_argument("weak")
    l.add_argument("--show-veto", type=float, default=0.85)
    args = ap.parse_args()
    {"build": build, "labels": labels}[args.cmd](args)


if __name__ == "__main__":
    main()
