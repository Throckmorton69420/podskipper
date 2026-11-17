#!/usr/bin/env python3
"""Pass 66 (his 16 Nov correction, item 2b): thousands of real podcast transcripts for the Reader at zero download
cost — SPoRC's speaker-turn transcripts already on the drive (data/sporc/turns/text, 701,630 episodes).

SPoRC has no ad labels. These episodes train the Reader only through the four shipped Readers' probabilities
(reader_distill.py SOFT=, distillation), never as hard labels. Licence: SPoRC is research-use-only (README);
like SponsorBlock's CC BY-NC-SA, fine for his own builds, a question before anything is published.

    sporc_scale.py scan                 per-episode cue counts over every turn → <OUT>/scan.parquet (minutes)
    sporc_scale.py select [--n 12000]   English, 20 min – 4 h, >= 80 sentences, a sponsor or structure cue, not his
                                        shows, <= 3 per show, round-robin over genres → <OUT>/selection.json
    sporc_scale.py build [--n 2500]     the first n of the selection as Reader episodes → <OUT>/episodes.json
                                        (Pass 53 format: key, guid, title, show, genre, sents, labels all None)

Cues (per episode, counted on turns): sponsor hand-offs ("brought to you by", "sponsored by", "our sponsor",
"support for this podcast"), codes ("promo code", "use code", "offer code"), web offers ("dot com slash",
".com/", "go to … dot com"), credits ("produced by", "edited by", "theme music").
"""
import argparse
import collections
import json
import os
import random
import re
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
SSD = "/Volumes/Samsung PSSD T9 Media/PodSkipper"
SPORC = os.path.join(SSD, "data", "sporc")
OUT = os.path.join(SSD, "data", "pk-data", "sporc66")

CUES = {
    "handoff": r"brought to you by|sponsored by|our sponsor|support for (this|the) (podcast|show)|this episode is (brought|sponsored)|thanks to our sponsor",
    "code": r"promo code|use code|offer code|discount code|with code",
    "url": r"dot com slash|\.com/|go to [a-z0-9]+ ?dot com|at [a-z0-9]+ ?dot com",
    "credits": r"produced by|edited by|theme music|executive producer|our producer",
}
GENRES = {  # SPoRC primary_category → the strata his request names (others: "other")
    "true crime": "True Crime", "true": "True Crime", "crime": "True Crime", "news": "News", "commentary": "News", "government": "News", "politics": "News",
    "daily": "News", "comedy": "Comedy", "culture": "Society & Culture", "relationships": "Society & Culture",
    "personal": "Society & Culture", "documentary": "Society & Culture", "places": "Society & Culture",
    "business": "Business", "entrepreneurship": "Business", "investing": "Business", "careers": "Business",
    "marketing": "Business", "management": "Business", "science": "Science", "natural": "Science",
    "social": "Science", "life": "Science", "physics": "Science", "astronomy": "Science", "history": "History",
    "technology": "Technology", "sports": "Sports", "football": "Sports", "basketball": "Sports",
    "baseball": "Sports", "soccer": "Sports", "hockey": "Sports", "wrestling": "Sports", "fantasy": "Sports",
    "health": "Health & Fitness", "fitness": "Health & Fitness", "medicine": "Health & Fitness",
    "mental": "Health & Fitness", "nutrition": "Health & Fitness", "education": "Education", "arts": "Arts",
    "film": "TV & Film", "tv": "TV & Film", "entertainment": "TV & Film", "games": "Leisure", "leisure": "Leisure",
    "hobbies": "Leisure", "music": "Music", "family": "Kids & Family", "kids": "Kids & Family",
    "religion": "Religion", "christianity": "Religion", "spirituality": "Religion",
}


def con():
    import duckdb
    c = duckdb.connect()
    c.execute("SET threads=6")
    c.execute("SET memory_limit='8GB'")
    return c


def scan(args):
    os.makedirs(OUT, exist_ok=True)
    c = con()
    t0 = time.time()
    parts = os.path.join(SPORC, "turns", "text", "*.parquet")
    cue = ", ".join(f"count(*) FILTER (WHERE regexp_matches(lower(turn_text), '{p}')) AS {k}" for k, p in CUES.items())
    c.execute(f"""COPY (SELECT episode_id, any_value(podcast_id) podcast_id, count(*) turns,
            sum(length(regexp_extract_all(turn_text, '[.?!](\\s|$)'))) + count(*) sentences, max(end_time) last_end, {cue}
        FROM read_parquet('{parts}') GROUP BY episode_id) TO '{OUT}/scan.parquet' (FORMAT parquet)""")
    n = c.execute(f"SELECT count(*), sum(handoff > 0 OR code > 0 OR url > 0)::BIGINT FROM '{OUT}/scan.parquet'").fetchone()
    print(f"scanned {n[0]:,} episodes ({n[1]:,} with a sponsor cue) in {time.time() - t0:.0f} s → {OUT}/scan.parquet")


def select(args):
    import sporc_sb_distill_pipeline as pipe
    names, pattern = pipe.his_shows()
    c = con()
    meta = os.path.join(SPORC, "metadata")
    rows = c.execute(f"""SELECT s.episode_id, s.podcast_id, p.pod_title, e.ep_title, lower(coalesce(p.primary_category, '')) cat,
            e.duration_seconds d, s.sentences, s.handoff, s.code, s.url, s.credits
        FROM '{OUT}/scan.parquet' s JOIN read_parquet('{meta}/episode_catalog.parquet') e USING (episode_id)
        JOIN read_parquet('{meta}/podcast_catalog.parquet') p ON p.podcast_id = s.podcast_id
        WHERE lower(coalesce(e.language, p.language, '')) LIKE 'en%' AND e.duration_seconds BETWEEN 1200 AND 14400
          AND s.sentences >= 80 AND (s.handoff + s.code + s.url + s.credits) > 0""").fetchall()
    print(f"candidates (English, 20 min – 4 h, >= 80 sentences, a cue): {len(rows):,}")
    rows = [r for r in rows if not pipe.is_his(r[2], names, pattern)]
    print(f"not his shows: {len(rows):,}")
    # The strongest cues first within a show: a hand-off or a code, then a web offer, then credits only.
    strength = lambda r: (r[7] > 0) * 4 + (r[8] > 0) * 3 + (r[9] > 0) * 2 + (r[10] > 0)
    rng = random.Random(66)
    by_show = collections.defaultdict(list)
    for r in rows:
        by_show[r[1]].append(r)
    by_genre = collections.defaultdict(list)
    for show, eps in by_show.items():
        rng.shuffle(eps)
        eps.sort(key=lambda r: -strength(r))
        genre = GENRES.get(eps[0][4].split()[0] if eps[0][4] else "", "Other")
        by_genre[genre].append(eps[: args.per_show])
    for g in by_genre:
        rng.shuffle(by_genre[g])
    picked, rank = [], 0
    while len(picked) < args.n and any(by_genre.values()):
        for g in sorted(by_genre):
            for _ in range(2):   # two shows per genre per round
                if by_genre[g]:
                    eps = by_genre[g].pop()
                    picked.append((g, eps))
        rank += 1
    out = []
    for g, eps in picked:
        for r in eps:
            out.append({"episode_id": r[0], "podcast_id": r[1], "show": r[2], "title": r[3], "genre": g, "category": r[4],
                        "duration": r[5], "sentences": int(r[6]), "cues": {k: int(v) for k, v in zip(CUES, r[7:11])}})
            if len(out) >= args.n:
                break
        if len(out) >= args.n:
            break
    json.dump(out, open(os.path.join(OUT, "selection.json"), "w"), indent=0)
    gc = collections.Counter(e["genre"] for e in out)
    print(f"selected {len(out):,} episodes from {len({e['podcast_id'] for e in out}):,} shows → {OUT}/selection.json")
    print("genres:", ", ".join(f"{k} {v}" for k, v in gc.most_common()))
    print("with a hand-off or code:", sum(1 for e in out if e["cues"]["handoff"] or e["cues"]["code"]))


def build(args):
    import sporc_sb_distill_pipeline as pipe
    sel = json.load(open(os.path.join(OUT, "selection.json")))[: args.n]
    smap = pipe.shard_map()
    by_part = collections.defaultdict(list)
    for e in sel:
        loc = smap.get(e["podcast_id"])
        if loc:
            by_part[loc].append(e)
    out, skipped = [], collections.Counter()
    t0 = time.time()
    for (part, group), eps in sorted(by_part.items()):
        turns = pipe.podcast_turns(eps[0]["podcast_id"], smap)
        if turns is None:
            skipped["no turns"] += len(eps)
            continue
        for e in eps:
            ep = turns[turns.episode_id == e["episode_id"]].sort_values("turn_count")
            sents = pipe.turn_sentences(ep.to_dict("records"))
            if len(sents) < 80:
                skipped["fewer than 80 sentences"] += 1
                continue
            out.append({"key": "sporc:" + e["episode_id"], "guid": "sporc:" + e["episode_id"], "title": e["title"] or "",
                        "show": e["show"] or "", "genre": e["genre"], "sents": sents, "labels": [None] * len(sents),
                        "source": "SPoRC (speaker turns; sentences timed by character share)",
                        "license": "SPoRC, research use only"})
        if len(out) % 250 < len(eps):
            print(f"  {len(out):,} episodes ({time.time() - t0:.0f} s)", flush=True)
    json.dump(out, open(os.path.join(OUT, "episodes.json"), "w"))
    print(f"built {len(out):,} episodes ({sum(len(e['sents']) for e in out):,} sentences); skipped {dict(skipped)} → {OUT}/episodes.json")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    s = sub.add_parser("select")
    s.add_argument("--n", type=int, default=12000)
    s.add_argument("--per-show", type=int, default=3)
    b = sub.add_parser("build")
    b.add_argument("--n", type=int, default=2500)
    a = ap.parse_args()
    {"scan": scan, "select": select, "build": build}[a.cmd](a)


if __name__ == "__main__":
    main()
