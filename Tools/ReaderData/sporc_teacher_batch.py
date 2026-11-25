#!/usr/bin/env python3
"""Pass 67 route 2: a multi-genre SPoRC batch for the teacher pair, and its agreed, vetoed answers as weak labels.

    sporc_teacher_batch.py build <out dir> [--n 500]
        n built SPoRC episodes (sporc66/episodes.json, which has four-Reader soft targets), round-robin over
        SPoRC's genres, one a show, sha256 order, <= 90 min → <out dir>/batch-input.jsonl (the why-first prompt,
        Scripts/distill_reader.py's windows and request) + episodes.json (guid, show, title, genre, sents)
    sporc_teacher_batch.py patterns <out dir> [--windows 2100] [--skip <episodes.json>,…]
        Pass 69 (his 23 Nov go-ahead): SPoRC episodes (all of sporc66/episodes*.json) that contain one of the three
        patterns every SponsorBlock/SPoRC-distilled Reader pair gets wrong (build/p68/v3-diagnosis.md) — a produced
        trailer-style ad ("now streaming on …", "in theaters"), a "coming up…" teaser just before a break, or a host's
        own lead-in line just before an offer — round-robin over the three patterns (sha256 order, <= 2 per show,
        <= 90 min, none already in --skip, the multi-genre benchmarks or a test show) until --windows windows;
        same files as build, plus each episode's "pattern" and hit sentence indices
    sporc_teacher_batch.py labels <out dir> <answers A.jsonl> <answers B.jsonl> <weak.json> [--show-veto 0.85]
                                  [--teaser-show] [--spare-hits 12] [--spare-patterns trailer,teaser]
        each window's answer parsed as distill_reader.py collect does; a sentence is labelled only where both
        teachers put it in a part of the same group (ad: PAID_AD/HOST_READ_AD → A, NETWORK_PROMO → N; plug:
        SELF_PROMO/GUEST_PLUG → S; INTRO → I; OUTRO/CREDITS → O; A's letter when both are in a group) and the four
        shipped Readers' p_show < --show-veto (Pass 65: the veto lifts a teacher's ad precision 0.746 → 0.970)
        → {guid: [[sentence index, letter], …]} for reader_distill.py WEAK=
        --teaser-show (Pass 69): a teaser hit that neither teacher put in a part, followed within 150 s by an agreed
        ad, is labelled show ("C") from the hit to the ad's first line (<= 60 s) — the one place a show label is
        given, since agreement on "not skippable" elsewhere would also catch ads both teachers missed
        --spare-hits N (Pass 69): an agreed ad within N sentences of the episode's pattern hit is kept whatever the
        Readers' p_show (build/p69/veto-audit.md: vetoed agreed ads there are ~75 % real — produced trailers the
        Readers call show — against ~50 % elsewhere); the veto still applies everywhere else. --spare-patterns
        (default trailer,teaser): at hand-off hits the vetoed ads were mostly show talk (2 of 6, one 11-minute span)

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


TRAILER = re.compile(r"\b(now streaming|streaming now|stream(?:ing)? (?:it |them )?(?:now |only )?on (?:paramount|peacock|hulu|"
                     r"netflix|max|disney|apple tv|prime video)|only on (?:paramount|peacock|hulu|netflix|max|disney|apple tv|"
                     r"prime video)|(?:only |now |exclusively )in theaters|in theaters (?:now|everywhere|this)|rated (?:r|pg-13|pg)\b|"
                     r"new season (?:is )?(?:streaming|now|available)|season premieres?|premieres (?:this|on|friday|saturday|sunday|monday|tuesday|wednesday|thursday)|"
                     r"tickets (?:are )?on sale now|from the (?:director|creators?|producers?) of)", re.I)
TEASER = re.compile(r"\b(coming up (?:after|next|later|right after)|coming up,|after the break|when we come back|stick around|"
                    r"still to come|later (?:on )?in (?:the|this) (?:show|episode)|right after this)\b", re.I)
LEADIN = re.compile(r"\b(you guys know (?:me|that)|you know me|speaking of which|which (?:brings|reminds) me|that reminds me|"
                    r"let me tell you about|i(?:'ve| have) been using|i(?:'m| am) obsessed with|i love my|real quick,? (?:guys|folks|y'all))\b", re.I)
OFFER = re.compile(r"(promo code|use (?:the )?code|code [A-Z0-9]{3,}|\.com/|dot com slash|percent off|% off|free trial|"
                   r"first (?:month|box|order) free|this episode is (?:brought to you|sponsored|presented)|"
                   r"(?:brought to you|sponsored|presented) by)", re.I)


def pattern_hits(sents):
    """{pattern: [sentence index, …]} for one episode."""
    offer = [i for i, s in enumerate(sents) if OFFER.search(s["text"])]
    out = collections.defaultdict(list)
    for i, s in enumerate(sents):
        t = s["text"]
        if TRAILER.search(t):
            out["trailer"].append(i)
        near = [j for j in offer if j > i and sents[j]["start"] - s["end"] <= 150]
        if TEASER.search(t) and near:
            out["teaser"].append(i)
        if LEADIN.search(t) and any(sents[j]["start"] - s["end"] <= 60 for j in near):
            out["handoff"].append(i)
    return out


WARN_BYTES = 65000   # Pass 69: the four pattern windows llama-server refused (16,541–17,386 tokens > --ctx 16384)


def write_batch(out, picked, max_bytes=0):
    """max_bytes > 0 leaves out windows whose request is longer (logged); 0 only warns."""
    os.makedirs(out, exist_ok=True)
    n = 0
    with open(os.path.join(out, "batch-input.jsonl"), "w") as f:
        for e in picked:
            lines = [(s["text"], s["start"], s["end"]) for s in e["sents"]]
            for w in dr.windows(len(lines), 400, 20):
                body = dr.request_body("teacher", 2048, dr.user_prompt(e, lines, w), "why-first")
                cid = f"{e['guid']}|{w[0]}|{w[1]}"
                line = json.dumps({"custom_id": cid, "method": "POST", "url": "/v1/chat/completions", "body": body})
                if max_bytes and len(line.encode()) > max_bytes:
                    print(f"   left out {cid}: {len(line.encode())} bytes > --max-window-bytes {max_bytes}", flush=True)
                    continue
                if len(line.encode()) > WARN_BYTES:
                    print(f"   warning: {cid} is {len(line.encode())} bytes (> {WARN_BYTES}); it may exceed the "
                          f"teacher's 16,384-token context", flush=True)
                f.write(line + "\n")
                n += 1
    keys = ("guid", "show", "title", "genre", "sents", "pattern", "hits")
    json.dump([{k: e[k] for k in keys if k in e} for e in picked], open(os.path.join(out, "episodes.json"), "w"))
    return n


def patterns(a):
    sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
    os.environ["HOLD_TEST"] = "1"
    import reader_distill as rd
    held_channels, held_guids = rd.multigenre_held()
    test_guids, test_titles, test_shows = rd.test_held()
    skip = set()
    for path in filter(None, a.skip.split(",")):
        skip |= {e["guid"] for e in json.load(open(path))}
    files = sorted(f for f in os.listdir(D) if re.fullmatch(r"episodes(-\d+)?\.json", f))
    cands = collections.defaultdict(list)
    counts = collections.Counter()
    for name in files:
        for e in json.load(open(os.path.join(D, name))):
            if not e["sents"] or e["sents"][-1]["end"] > 5400:
                continue
            if e["guid"] in skip:
                counts["already labelled"] += 1
                continue
            if (e["guid"] in held_guids or e["show"] in held_channels or e["guid"] in test_guids
                    or rd.norm(e["title"]) in test_titles or rd.show_key(e["show"]) in test_shows):
                counts["held out"] += 1
                continue
            hits = pattern_hits(e["sents"])
            for p, idx in hits.items():
                counts[p] += 1
                cands[p].append((h(e["guid"]), e["guid"], e["show"], e["genre"], idx))
        print(f"   {name}: {dict(counts)}", flush=True)
    # round-robin over the patterns; every episode has >= 1 window, so a.windows episodes are always enough
    order = {p: sorted(v) for p, v in cands.items()}
    per_show, chosen, k = collections.Counter(), {}, collections.Counter()
    pats = sorted(order)
    while len(chosen) < a.windows and any(k[p] < len(order[p]) for p in pats):
        for p in pats:
            while k[p] < len(order[p]):
                _, guid, show, genre, idx = order[p][k[p]]
                k[p] += 1
                if guid in chosen or per_show[show] >= 2:
                    continue
                chosen[guid] = (p, idx)
                per_show[show] += 1
                break
    eps, picked = {}, []
    for name in files:  # second pass keeps only the chosen episodes' sentences in memory
        for e in json.load(open(os.path.join(D, name))):
            if e["guid"] in chosen and e["guid"] not in eps:
                p, idx = chosen[e["guid"]]
                eps[e["guid"]] = dict({k2: e[k2] for k2 in ("guid", "show", "title", "genre", "sents")}, pattern=p, hits=idx)
    # exact window budget, in the round-robin order the episodes were chosen
    total = 0
    for guid in chosen:
        e = eps[guid]
        w = len(dr.windows(len(e["sents"]), 400, 20))
        if total + w > a.windows:
            break
        picked.append(e)
        total += w
    n = write_batch(a.out, picked, a.max_window_bytes)
    pc = collections.Counter(e["pattern"] for e in picked)
    g = collections.Counter(e["genre"] for e in picked)
    print(f"candidates: {dict(counts)}")
    print(f"{len(picked)} episodes ({len(set(e['show'] for e in picked))} shows), {n} windows → {a.out}/batch-input.jsonl")
    print("patterns:", dict(pc))
    print("genres:", ", ".join(f"{k2} {v}" for k2, v in g.most_common()))


def answers(path, eps):
    """({guid: [(first, last, label), …]} with episode line numbers, {guids with >= 1 answered window}).
    Pass 69: an episode a teacher answered with no parts is answered (it found nothing), not missing."""
    out, seen = collections.defaultdict(list), set()
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
        seen.add(guid)
        text = row["response"]["body"]["choices"][0]["message"].get("content") or ""
        lines = [(s["text"], s["start"], s["end"]) for s in eps[guid]["sents"]]
        for p in dr.found_entries(dr.parse(text), (int(a), int(b)), lines):
            out[guid].append((p["firstLine"], p["lastLine"], p["label"]))
    return out, seen


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
    (A, seen_a), (B, seen_b) = answers(a.a, eps), answers(a.b, eps)
    out, counts = {}, collections.Counter()
    per = collections.defaultdict(collections.Counter)   # Pass 69: per pattern
    for guid, e in eps.items():
        pc = per[e.get("pattern") or "-"]
        pc["episodes"] += 1
        both = guid in seen_a and guid in seen_b
        if not both:
            counts["not answered by both"] += 1
        else:
            pc["answered by both"] += 1
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
                ad = ga[i][0] == "ad"
                pc["agreed ad"] += ad
                if probs is not None and probs[i] is not None and probs[i][0] >= a.show_veto:
                    if ad and a.spare_hits and e.get("pattern") in a.spare_patterns.split(",") and any(abs(i - h) <= a.spare_hits for h in e.get("hits", [])):
                        counts["spared ad at the pattern hit"] += 1
                        pc["spared ad"] += 1
                        rows.append([i, ga[i][1]])
                        counts[ga[i][1]] += 1
                        continue
                    counts["vetoed (Reader sure it is the show)"] += 1
                    pc["vetoed ad" if ad else "vetoed other"] += 1
                    continue
                rows.append([i, ga[i][1]])
                counts[ga[i][1]] += 1
                pc["kept ad" if ad else "kept other"] += 1
            elif ga[i] or gb[i]:
                counts["one teacher only (left out)"] += 1
        if a.teaser_show and e.get("pattern") == "teaser" and both:
            labelled = {r[0] for r in rows}
            given = set()
            for i in e.get("hits", []):
                if ga[i] or gb[i]:
                    continue
                ad = next((j for j in range(i + 1, n) if j in labelled and ga[j] and ga[j][0] == "ad"
                           and e["sents"][j]["start"] - e["sents"][i]["end"] <= 150), None)
                if ad is None or any(ga[j] or gb[j] for j in range(i, ad)):
                    continue
                for j in range(i, ad):
                    if e["sents"][ad]["start"] - e["sents"][j]["start"] <= 60 and j not in given:
                        given.add(j)
                        rows.append([j, "C"])
                        counts["C (teaser before an agreed ad)"] += 1
                        pc["C"] += 1
        if rows:
            out[guid] = rows
    json.dump(out, open(a.weak, "w"))
    print(f"{len(out)} of {len(eps)} episodes with agreed labels; {dict(counts)} → {a.weak}")
    cols = ["episodes", "answered by both", "agreed ad", "vetoed ad", "spared ad", "kept ad", "vetoed other",
            "kept other", "C"]
    print(f"\nper pattern (sentences; --show-veto {a.show_veto}, --spare-hits {a.spare_hits} for {a.spare_patterns}):")
    print("| pattern | " + " | ".join(cols) + " | ad vetoed % |")
    print("|---" * (len(cols) + 2) + "|")
    for p in sorted(per):
        c = per[p]
        pct = 100 * c["vetoed ad"] / c["agreed ad"] if c["agreed ad"] else 0.0
        print(f"| {p} | " + " | ".join(str(c[k]) for k in cols) + f" | {pct:.1f} |")


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
    l.add_argument("--teaser-show", action="store_true")
    l.add_argument("--spare-hits", type=int, default=0,
                   help="Pass 69: no veto for an agreed ad within this many sentences of the episode's pattern hit")
    l.add_argument("--spare-patterns", default="trailer,teaser",
                   help="patterns --spare-hits applies to (hand-off hits: vetoed ads there were mostly show talk)")
    q = sub.add_parser("patterns")
    q.add_argument("out")
    q.add_argument("--windows", type=int, default=2100)
    q.add_argument("--skip", default="")
    q.add_argument("--max-window-bytes", type=int, default=0,
                   help="leave out windows whose request is longer than this (0: warn over 65,000 bytes only)")
    args = ap.parse_args()
    {"build": build, "labels": labels, "patterns": patterns}[args.cmd](args)


if __name__ == "__main__":
    main()
