#!/usr/bin/env python3
"""Pass 67: a multi-genre held-out benchmark from the human-labelled SponsorBlock episodes.

Why: his 11 test episodes (12.7 h, 7 mostly comedy shows) give the PodSkipper test a 95 % interval ~15 points
wide (one missed pre-roll moves a score by 5), and the 71 show-held-out episodes are 16 of his own shows. Neither
measures news, science, business, true crime … The 2,075 transcribed SponsorBlock episodes (sb58 + sb65) are
human-labelled for sponsor reads on hundreds of channels.

    multigenre_bench.py select                 → build/p67/multigenre-test.json (+ multigenre-episodes.json)
    multigenre_bench.py eval <name>=<w1.bin>[:<w2.bin>…] …  [--workers 2]
        each Reader set through the app's own Swift detector (lab-segments, LAB_TAGGER) on the 200 episodes;
        cuts cached in build/p67/mg-cuts/<name>.json (resumable)
    multigenre_bench.py score <name> … [--base <name>]   the table (and paired differences against --base)
    multigenre_bench.py select-clean           → build/p68/multigenre-clean.json (+ multigenre-clean-episodes.json)
    eval / score --bench clean                 the same on the clean benchmark (cuts in build/p68/mg-clean-cuts/)

Pass 68: the clean benchmark. build/p67/multigenre-test.json is in sb65, which finalsb (TaggerWeights-3/-4) and so
the shipped four trained on. select-clean takes the sb66 channels (route 1, fetched 18–20 Nov) that are in neither
sb58 nor sb65 (episodes or picks), not in multigenre-test.json, not one of his shows (his 16 shows by name, the
three SponsorBlock channels that carry them, any title naming one); per channel the eligible episodes (>= 1 sponsor
sentence, >= 15 min) sorted by key, then up to 3 drawn with one random.Random(68) over channels in sorted order.
Genre is sb66's own (channel keywords), "unknown" when missing. No Reader so far trained on any of it; soft targets
on other episodes still come from the four (second-order, as above).

Selection (deterministic, no randomness): channels that appear in sb65 but never in sb58 — so Pass 58's stage 1
(build/p58/pre13.pt, sb58 only) and Pass 58's pair never saw them — each given a genre from all its video titles
in the SponsorBlock dump (Tools/ReaderData/sb_channels.py's words plus education, arts, games, religion, film &
TV, music — an estimate from keywords); not his shows; talk channels only (no games, music, streams); channels
that pass the Pass 66 v8 podcast-channel rules first (tier "podcast"), then other talk channels (tier "talk");
round-robin over genres, channels in hashed order, at most 2 episodes a channel, until 200. Scores are reported
for all 200 and for the podcast tier alone (score --tier podcast).
HOLD_MULTIGENRE=1 (reader_distill.py) leaves every episode of these channels out of training and stage 1.

Not clean for every baseline: finalsb (TaggerWeights-3/-4) and its stage 1 pre13sb.pt trained on all of sb65,
these episodes included. Pass 58's pair is clean; a candidate is clean when its whole chain starts from
pre13.pt (or ELECTRA) with HOLD_MULTIGENRE=1. Soft targets on other episodes come from the four, which saw these
episodes: a second-order leak, noted wherever this benchmark is reported.

Labels: SponsorBlock "sponsor" sentences are the skippable time (A); show sentences (C) are the show; anything
else (self-promotion, intro, outro, previews, unlabelled) counts neither way. Score as the PodSkipper test's
Everyday score (podtest.py): cost = sponsor time heard beyond 2 s at each edge + 10 s per noticed break (> 5 s
heard) + 2 x show seconds cut + 10 s per show jump (a cut holding > 2 s of show); nothing cut = 0, perfect = 100;
every channel counts the same; 95 % intervals by resampling channels.
"""
import argparse, collections, hashlib, json, os, random, re, subprocess, sys, time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
DATA = os.path.expanduser("~/Developer/pk-data")
OUT = os.path.join(ROOT, "build", "p67")
BENCH = os.path.join(OUT, "multigenre-test.json")
EPISODES = os.path.join(OUT, "multigenre-episodes.json")
CUTS = os.path.join(OUT, "mg-cuts")
DB = os.path.join(ROOT, "build", "p66", "corpus-select", "sb.duckdb")
BIN = os.environ.get("LAB_SEGMENTS", os.path.join(ROOT, "build", "p66", "lab-segments"))
N = 200
CLEAN_OUT = os.path.join(ROOT, "build", "p68")
BENCHES = {"p67": (BENCH, EPISODES, CUTS),
           "clean": (os.path.join(CLEAN_OUT, "multigenre-clean.json"),
                     os.path.join(CLEAN_OUT, "multigenre-clean-episodes.json"),
                     os.path.join(CLEAN_OUT, "mg-clean-cuts"))}
# The SponsorBlock channels that carry his own shows (as reader_distill.HIS_CHANNELS).
HIS_CHANNELS = frozenset({"UCNGbPFX8UOm7qk6kvnHKr0w", "UC6ext5UAbrLT2e5y5BC6RTQ", "UCy6A9WMN43DrtBkID7nMXJw"})
CLEAN_PER_CHANNEL = 3
PER_CHANNEL = 2

EXTRA_GENRES = [
    ("education", r"\blearn|lesson|teach|student|school|college|university|exam|study|course|tutorial|lecture"),
    ("arts", r"\bart\b|artist|paint|design|writing|writer|novel|poetry|author|book|craft|photograph|architect"),
    ("games", r"gaming|video game|nintendo|playstation|xbox|\bgame\b|games|esports|minecraft|zelda|pokemon|d&d|dungeons"),
    ("religion & spirituality", r"church|bible|god\b|jesus|christian|faith|pray|gospel|islam|muslim|buddh|spiritual|theolog|sermon"),
    ("film & tv", r"movie|film|cinema|trailer|marvel|star wars|netflix|episode review|tv show|hbo|oscars|director"),
    ("music", r"music|album|song|band|guitar|rapper|hip hop|concert|producer|singer|vinyl"),
]


def h(x):
    return hashlib.sha256(x.encode()).hexdigest()


def load(path):
    return json.load(open(path))


def channel_facts(channels):
    """Per channel, from every title of it in the SponsorBlock dump: a genre, whether it passes the Pass 66 v8
    podcast-channel rules (sb_channels.py, hand-checked at 85 %), whether it is talk at all (not games, music,
    streams …) and whether any title names one of his shows."""
    import duckdb
    import sb_channels as sc
    rules = sc.rules()
    words = sc.GENRE_WORDS + EXTRA_GENRES
    c = duckdb.connect(DB, read_only=True)
    c.execute("CREATE TEMP TABLE want(ch VARCHAR)")
    c.executemany("INSERT INTO want VALUES (?)", [(ch,) for ch in channels])
    titles = collections.defaultdict(list)
    for ch, title in c.execute("SELECT channelID, title FROM info JOIN want ON info.channelID = want.ch "
                               "WHERE title IS NOT NULL").fetchall():
        titles[ch].append(title)
    out = {}
    for ch in channels:
        T = titles.get(ch, [])
        n = max(1, len(T))
        text = " ".join(T).lower()
        scores = sorted(((len(re.findall(p, text)), g) for g, p in words), reverse=True)
        literal = sum(bool(sc.LITERAL.search(t)) for t in T)
        epnum = sum(bool(sc.EPNUM.search(t) or rules.PODCASTY.search(t) or sc.SHOW_NUMBER.search(t)) for t in T)
        guests = sum(bool(sc.GUEST.search(t)) for t in T)
        parts = collections.Counter(re.sub(r"\s*\d+$", "", p) for t in T for p in set(sc.show_part(t)) if sc.specific(p))
        marker = parts.most_common(1)[0][1] if parts else 0
        english = sum(bool(sc.ENGLISH.search(t)) for t in T)
        foreign = sum(bool(sc.FOREIGN.search(t)) for t in T)
        out[ch] = {
            "genre": scores[0][1] if scores and scores[0][0] >= 3 else "society & culture",
            "talk": bool(T) and sum(bool(sc.NOT_TALK.search(t)) for t in T) * 10 < n,
            "english": foreign * 100 < 15 * n and english * 10 >= 3 * n,
            "podcast": literal * 4 >= n or (epnum * 10 >= 4 * n and epnum >= 3 and (guests * 4 >= n or marker * 2 >= n)),
            "his": any(rules.HIS_SHOWS.search(t) for t in T),
            "titles": len(T)}
    return out


def select(args):
    picks58 = load(os.path.join(DATA, "sb58", "picks.json"))
    eps65 = load(os.path.join(DATA, "sb65", "episodes.json"))
    eps58 = load(os.path.join(DATA, "sb58", "episodes.json"))
    seen58 = {p["channel"] for p in picks58.values()} | {e["show"].replace("YouTube @", "") for e in eps58}
    by_channel = collections.defaultdict(list)
    for e in eps65:
        ch = e["show"].replace("YouTube @", "")
        if ch in seen58:
            continue
        hours = (e["sents"][-1]["end"] - e["sents"][0]["start"]) / 3600 if e["sents"] else 0
        if not any(l == "A" for l in e["labels"]) or hours < 0.25:
            continue
        by_channel[ch].append(e)
    facts = channel_facts(sorted(by_channel))
    dropped = collections.Counter()
    tiers = {"podcast": collections.defaultdict(list), "talk": collections.defaultdict(list)}
    for ch in sorted(by_channel, key=h):
        f = facts[ch]
        if f["his"]:
            dropped["one of his shows"] += 1
        elif not f["talk"]:
            dropped["not talk (games, music, streams …)"] += 1
        elif not f["english"]:
            dropped["not English"] += 1
        else:
            tiers["podcast" if f["podcast"] else "talk"][f["genre"]].append(ch)
    # Podcast-rule channels first (round-robin over genres), then talk channels the rules don't call podcasts.
    chosen, channels = [], []
    for tier in ("podcast", "talk"):
        by_genre, turn = tiers[tier], 0
        while len(chosen) < N and any(len(v) > turn for v in by_genre.values()):
            for g in sorted(by_genre):
                if len(chosen) >= N or len(by_genre[g]) <= turn:
                    continue
                ch = by_genre[g][turn]
                eps = sorted(by_channel[ch], key=lambda e: h(e["guid"]))[:PER_CHANNEL][: N - len(chosen)]
                channels.append(ch)
                chosen += [(g, ch, tier, e) for e in eps]
            turn += 1
    hours = sum((e["sents"][-1]["end"] - e["sents"][0]["start"]) / 3600 for *_, e in chosen)
    ad = sum(s["end"] - s["start"] for *_, e in chosen for s, l in zip(e["sents"], e["labels"]) if l == "A")
    gcount = collections.Counter(g for g, *_ in chosen)
    tcount = collections.Counter(t for _, _, t, _ in chosen)
    bench = {
        "made": time.strftime("%Y-%m-%d %H:%M"),
        "rule": "sb65 channels never in sb58 (so Pass 58's stage 1 and pair never saw them); not his shows, talk, "
                "English; podcast-rule channels (sb_channels.py v8) first, then other talk channels; genre from "
                "the channel's titles (keywords — an estimate); round-robin over genres, channels in sha256 order, "
                "<= 2 episodes a channel (sha256 order), >= 1 sponsor sentence, >= 15 min",
        "episodes": [{"guid": e["guid"], "channel": ch, "genre": g, "tier": t, "title": e["title"],
                      "hours": round((e["sents"][-1]["end"] - e["sents"][0]["start"]) / 3600, 3)}
                     for g, ch, t, e in chosen],
        "channels": channels,
        "genres": dict(gcount.most_common()),
        "tiers": dict(tcount),
        "dropped_channels": dict(dropped),
        "hours": round(hours, 1),
        "sponsor_seconds": round(ad),
        "candidate_channels": len(by_channel),
    }
    os.makedirs(OUT, exist_ok=True)
    json.dump(bench, open(BENCH, "w"), indent=1)
    json.dump([e for *_, e in chosen], open(EPISODES, "w"))
    print(f"{len(chosen)} episodes, {len(channels)} channels (of {len(by_channel)} sb65-only channels with a sponsor; "
          f"dropped {dict(dropped)}), {hours:.1f} h, sponsor {ad / 3600:.1f} h ({ad / hours:.0f} s/h)")
    print("tiers:", dict(tcount), "· genres:", ", ".join(f"{g} {n}" for g, n in gcount.most_common()))
    print("wrote", BENCH, "and", EPISODES)


def show_key(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def channel(e):
    return e["show"].replace("YouTube @", "")


def select_clean(args):
    import sponsorblock_select as sbs
    sb66 = load(os.path.join(DATA, "sb66", "episodes.json"))
    olds = {}
    for name in ("sb58", "sb65"):
        eps = load(os.path.join(DATA, name, "episodes.json"))
        picks = load(os.path.join(DATA, name, "picks.json"))
        olds[name] = ({channel(e) for e in eps} | {p["channel"] for p in picks.values()},
                      {e["guid"] for e in eps} | {"sponsorblock:" + k for k in picks})
    mg = load(BENCH)
    olds["multigenre-test"] = (set(mg["channels"]), {e["guid"] for e in mg["episodes"]})
    manifest = load(os.path.join(ROOT, "build", "p57", "corpus", "manifest.json"))
    his_names = sorted({m.get("show", "") for m in manifest["episodes"].values()} - {""})
    his_keys = {show_key(n) for n in his_names}
    by_channel, dropped = collections.defaultdict(list), collections.Counter()
    for e in sb66:
        by_channel[channel(e)].append(e)
    chosen, rng = [], random.Random(68)
    for ch in sorted(by_channel):
        eps = by_channel[ch]
        if any(ch in chans for chans, _ in olds.values()):
            dropped["channel in sb58 / sb65 / multigenre-test"] += 1
            continue
        if ch in HIS_CHANNELS or show_key(eps[0]["show"]) in his_keys or any(sbs.HIS_SHOWS.search(e["title"]) for e in eps):
            dropped["one of his shows"] += 1
            continue
        ok = sorted((e for e in eps if any(l == "A" for l in e["labels"])
                     and e["sents"] and e["sents"][-1]["end"] - e["sents"][0]["start"] >= 900), key=lambda e: e["key"])
        if not ok:
            dropped["no episode with a sponsor sentence and >= 15 min"] += 1
            continue
        chosen += [(ch, e) for e in rng.sample(ok, min(CLEAN_PER_CHANNEL, len(ok)))]
    # The checks the benchmark promises, on what was chosen.
    keys = {e["guid"] for _, e in chosen}
    chans = {ch for ch, _ in chosen}
    checks = {}
    for name, (oc, og) in olds.items():
        checks[f"episodes also in {name}"] = len(keys & og)
        checks[f"channels also in {name}"] = len(chans & oc)
    checks["channels that carry his shows"] = len(chans & HIS_CHANNELS)
    checks["show names that are his shows"] = len({show_key(e["show"]) for _, e in chosen} & his_keys)
    checks["titles naming his shows"] = sum(bool(sbs.HIS_SHOWS.search(e["title"])) for _, e in chosen)
    assert all(v == 0 for v in checks.values()), checks
    hours = sum((e["sents"][-1]["end"] - e["sents"][0]["start"]) / 3600 for _, e in chosen)
    gcount = collections.Counter(e.get("genre") or "unknown" for _, e in chosen)
    bench = {
        "made": time.strftime("%Y-%m-%d %H:%M"),
        "rule": "sb66 channels in neither sb58 nor sb65 (episodes or picks) nor multigenre-test.json, not his shows; "
                ">= 1 sponsor sentence and >= 15 min; per channel sorted by key, up to 3 by random.Random(68)",
        "episodes": [{"guid": e["guid"], "channel": ch, "genre": e.get("genre") or "unknown", "tier": "sb66",
                      "title": e["title"], "hours": round((e["sents"][-1]["end"] - e["sents"][0]["start"]) / 3600, 3)}
                     for ch, e in chosen],
        "channels": sorted(chans),
        "genres": dict(gcount.most_common()),
        "checks": checks,
        "his_shows": his_names,
        "dropped_channels": dict(dropped),
        "hours": round(hours, 1),
    }
    bpath, epath, _ = BENCHES["clean"]
    os.makedirs(CLEAN_OUT, exist_ok=True)
    json.dump(bench, open(bpath, "w"), indent=1)
    json.dump([e for _, e in chosen], open(epath, "w"))
    print(f"{len(chosen)} episodes, {len(chans)} channels of {len(by_channel)} in sb66 (dropped {dict(dropped)}), "
          f"{hours:.1f} h · genres: " + ", ".join(f"{g} {n}" for g, n in gcount.most_common()))
    print("overlap checks (all 0):", checks)
    print("wrote", bpath, "and", epath)


def cuts_of(ep, weights, tmpdir):
    tr = os.path.join(tmpdir, h(ep["guid"])[:16] + ".json")
    json.dump([{"text": s["text"], "start": s["start"], "end": s["end"], "words": []} for s in ep["sents"]], open(tr, "w"))
    env = dict(os.environ, LAB_TAGGER=weights)
    r = subprocess.run([BIN, tr, "", "", ""], env=env, capture_output=True, text=True)
    os.remove(tr)
    out = []
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):([\d.]+)–(\d+):(\d+):([\d.]+)", r.stdout, re.M):
        kind, h1, m1, s1, h2, m2, s2 = m.groups()
        out.append([int(h1) * 3600 + int(m1) * 60 + float(s1), int(h2) * 3600 + int(m2) * 60 + float(s2), kind])
    return out if r.returncode == 0 else None


def evaluate(args):
    _, episodes_path, cuts_dir = BENCHES[args.bench]
    eps = load(episodes_path)
    os.makedirs(cuts_dir, exist_ok=True)
    tmp = os.path.join(OUT, ".mg-tmp")
    os.makedirs(tmp, exist_ok=True)
    for spec in args.specs:
        name, weights = spec.split("=", 1)
        weights = ":".join(os.path.abspath(w) for w in weights.split(":"))
        path = os.path.join(cuts_dir, name + ".json")
        have = load(path) if os.path.exists(path) else {}
        todo = [e for e in eps if e["guid"] not in have]
        t0 = time.time()
        with ThreadPoolExecutor(args.workers) as pool:
            for i, (e, c) in enumerate(zip(todo, pool.map(lambda e: cuts_of(e, weights, tmp), todo)), 1):
                if c is not None:
                    have[e["guid"]] = c
                if i % 20 == 0 or i == len(todo):
                    json.dump(have, open(path, "w"))
                    print(f"{name}: {i}/{len(todo)} ({time.time() - t0:.0f} s)", flush=True)
        json.dump(have, open(path, "w"))


def overlap(a, b, cuts):
    return sum(max(0.0, min(b, e) - max(a, s)) for s, e, _ in cuts)


ADS_ONLY = False


def episode_numbers(ep, cuts):
    """Everyday cost parts of one episode against its SponsorBlock labels. With --ads-only, the show cut and
    jumps count only cuts the engine calls an ad or another show's promo: two thirds of these episodes mark
    nothing but sponsors, so their plugs, intros and outros are unlabelled and sit in "show" (17 Nov: the four's
    self-promotion cuts were 13.2 of their 22.8 s/h of "show cut"). Sponsor time heard always counts every cut."""
    sents, labels = ep["sents"], ep["labels"]
    all_cuts = cuts
    if ADS_ONLY:
        cuts = [c for c in cuts if c[2] in ("ad", "crossPromo")]
    breaks, cur = [], None
    for s, l in zip(sents, labels):
        if l == "A":
            if cur and s["start"] - cur[1] <= 2.0:
                cur[1] = s["end"]
            else:
                cur = [s["start"], s["end"]]
                breaks.append(cur)
        elif l is not None:
            cur = None
    heard = noticed = 0.0
    null = 0.0
    for a, b in breaks:
        inner_a, inner_b = a + 2.0, b - 2.0
        uncut = (inner_b - inner_a) - overlap(inner_a, inner_b, all_cuts) if inner_b > inner_a else 0.0
        heard += max(0.0, uncut)
        noticed += uncut > 5.0
        null += (b - a) + 10.0
    show_cut = sum(overlap(s["start"], s["end"], cuts) for s, l in zip(sents, labels) if l == "C")
    jumps = 0
    for cs, ce, _ in cuts:
        c_in = sum(overlap(s["start"], s["end"], [(cs, ce, "")]) for s, l in zip(sents, labels) if l == "C"
                   and s["end"] > cs and s["start"] < ce)
        jumps += c_in > 2.0
    cost = heard + 10.0 * noticed + 2.0 * show_cut + 10.0 * jumps
    hours = (sents[-1]["end"] - sents[0]["start"]) / 3600
    return {"score": 100.0 * (1.0 - cost / null) if null else None, "heard": heard, "noticed": noticed,
            "breaks": len(breaks), "show_cut": show_cut, "jumps": jumps, "hours": hours}


def per_channel(bench, eps, cuts):
    rows = collections.defaultdict(list)
    for e in eps:
        if e["guid"] in cuts:
            rows[bench[e["guid"]]["channel"]].append(episode_numbers(e, cuts[e["guid"]]))
    return rows


def boot(values_by_channel, stat, n=2000, seed=67):
    keys = sorted(values_by_channel)
    rng = np.random.default_rng(seed)
    point = stat([values_by_channel[k] for k in keys])
    draws = []
    for _ in range(n):
        idx = rng.integers(0, len(keys), len(keys))
        draws.append(stat([values_by_channel[keys[i]] for i in idx]))
    return point, np.percentile(draws, 2.5), np.percentile(draws, 97.5)


def everyday(groups):
    return float(np.mean([np.mean([r["score"] for r in g]) for g in groups]))


def per_hour(field):
    return lambda groups: float(sum(r[field] for g in groups for r in g) / sum(r["hours"] for g in groups for r in g))


def score(args):
    global ADS_ONLY
    ADS_ONLY = args.ads_only
    bench_path, episodes_path, cuts_dir = BENCHES[args.bench]
    meta = load(bench_path)
    bench = {e["guid"]: e for e in meta["episodes"]}
    eps = load(episodes_path)
    names = args.names
    allcuts = {n: load(os.path.join(cuts_dir, n + ".json")) for n in names}
    common = set.intersection(*(set(c) for c in allcuts.values())) & set(bench)
    if args.tier:
        common = {g for g in common if bench[g]["tier"] == args.tier}
    eps = [e for e in eps if e["guid"] in common]
    hours = sum(bench[e["guid"]]["hours"] for e in eps)
    lines = [f"Multi-genre benchmark{' (clean, sb66)' if args.bench == 'clean' else ''} · {len(eps)} SponsorBlock episodes, {len({bench[e['guid']]['channel'] for e in eps})} "
             f"channels, {hours:.1f} h, {len(meta['genres'])} genres{' · tier ' + args.tier if args.tier else ''}{' · ad cuts only for show cut' if args.ads_only else ''} · paired (episodes every engine has)", "",
             "| engine | Everyday (95 %) | sponsor heard s/h | show cut s/h | breaks noticed | show jumps/h |",
             "|---|---|---|---|---|---|"]
    rows = {}
    for n in names:
        rows[n] = per_channel(bench, eps, allcuts[n])
        sc = boot(rows[n], everyday)
        hd = boot(rows[n], per_hour("heard"))
        sh = boot(rows[n], per_hour("show_cut"))
        noticed = sum(r["noticed"] for g in rows[n].values() for r in g)
        breaks = sum(r["breaks"] for g in rows[n].values() for r in g)
        jumps = per_hour("jumps")(list(rows[n].values()))
        lines.append(f"| {n} | **{sc[0]:.1f}** ({sc[1]:.1f}–{sc[2]:.1f}) | {hd[0]:.1f} ({hd[1]:.1f}–{hd[2]:.1f}) | "
                     f"{sh[0]:.1f} ({sh[1]:.1f}–{sh[2]:.1f}) | {noticed:.0f}/{breaks} | {jumps:.2f} |")
    if args.base and args.base in rows:
        lines += ["", f"Paired differences against {args.base} (95 %, channels resampled):"]
        for n in names:
            if n == args.base:
                continue
            keys = sorted(set(rows[n]) & set(rows[args.base]))
            pair = {k: (rows[n][k], rows[args.base][k]) for k in keys}
            def d(field_stat):
                return lambda groups: field_stat([g[0] for g in groups]) - field_stat([g[1] for g in groups])
            sc, hd, sh = boot(pair, d(everyday)), boot(pair, d(per_hour("heard"))), boot(pair, d(per_hour("show_cut")))
            lines.append(f"  {n}: Everyday {sc[0]:+.1f} ({sc[1]:+.1f}…{sc[2]:+.1f}) · heard {hd[0]:+.1f} "
                         f"({hd[1]:+.1f}…{hd[2]:+.1f}) s/h · show cut {sh[0]:+.1f} ({sh[1]:+.1f}…{sh[2]:+.1f}) s/h")
    if args.genres:
        lines += ["", "Everyday by genre (channels averaged):", "| genre | channels | " + " | ".join(names) + " |",
                  "|---|---|" + "---|" * len(names)]
        gch = collections.defaultdict(set)
        for e in eps:
            gch[bench[e["guid"]]["genre"]].add(bench[e["guid"]]["channel"])
        for g in sorted(gch):
            cells = [f"{everyday([rows[n][c] for c in gch[g] if c in rows[n]]):.1f}" for n in names]
            lines.append(f"| {g} | {len(gch[g])} | " + " | ".join(cells) + " |")
    text = "\n".join(lines)
    print(text)
    if args.out:
        open(args.out, "w").write(text + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("select")
    sub.add_parser("select-clean")
    e = sub.add_parser("eval")
    e.add_argument("--bench", default="p67", choices=sorted(BENCHES))
    e.add_argument("specs", nargs="+")
    e.add_argument("--workers", type=int, default=2)
    s = sub.add_parser("score")
    s.add_argument("names", nargs="+")
    s.add_argument("--bench", default="p67", choices=sorted(BENCHES))
    s.add_argument("--base", default="")
    s.add_argument("--genres", action="store_true")
    s.add_argument("--out", default="")
    s.add_argument("--tier", default="", choices=["", "podcast", "talk"])
    s.add_argument("--ads-only", action="store_true", help="show cut from ad / cross-promo cuts only")
    args = ap.parse_args()
    {"select": select, "select-clean": select_clean, "eval": evaluate, "score": score}[args.cmd](args)


if __name__ == "__main__":
    main()
