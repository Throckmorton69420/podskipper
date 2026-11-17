#!/usr/bin/env python3
"""Pass 66 (OPUS-5.5-PLAN §5): where SponsorBlock's podcast episodes are lost,
and podcast channels found by channel instead of by one title.

Reads build/p66/corpus-select/sb.duckdb (tables `st`, 20,003,418 segment rows,
and `info`, 11,681,194 video rows; never the 8 GB CSV dump) and SPoRC's show
catalog (podcast_catalog.parquet: pod_title, primary_category).

    sb_channels.py funnel                 videos and channels after each rule of sb_scale.py select
    sb_channels.py channels [--min N]     podcast channels: (a) >= N videos whose own title passes
                                          PODCASTY, (b) a video-title show name equal to a SPoRC show
                                          → build/p66/corpus-select/channels.json
    sb_channels.py sample [--n 40] [--seed 66]   random channels that (a)/(b) add over `select`,
                                          with sample titles, for reading by hand

Per-video rules (Pass 58, sb_scale.py select): a sponsor skip segment locked or
voted up and not hidden; no whole-video sponsor mark; >= 200 skips over the
video's segments; 30 min – 4 h where the length is known; a title; not one of
his shows; not a stream / clip / music title; an English title. `select` then
needs PODCASTY in the title; `select2` (sb_scale.py) needs a podcast channel instead.
"""
import argparse
import collections
import json
import os
import random
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
DB = os.path.join(ROOT, "build", "p66", "corpus-select", "sb.duckdb")
OUT = os.path.join(ROOT, "build", "p66", "corpus-select")
SPORC = "/Volumes/Samsung PSSD T9 Media/PodSkipper/data/sporc/metadata/podcast_catalog.parquet"
DONE = [os.path.expanduser("~/Developer/pk-data/sb58/picks.json"), os.path.expanduser("~/Developer/pk-data/sb65/picks.json")]

# A show name that names nothing in particular (title prefixes like "Episode 12" or "LIVE").
GENERIC = {"the podcast", "podcast", "the show", "live", "episode", "full episode", "interview", "news", "update",
           "q a", "qa", "ama", "the", "a", "ep", "part", "bonus", "trailer", "highlights", "special", "the interview",
           "the daily", "today", "this week", "weekly", "the morning show", "morning show", "the talk", "talk",
           "conversation", "the conversation", "stories", "story time", "storytime", "after hours", "the breakdown",
           "breakdown", "recap", "review", "the review", "reaction", "unfiltered", "uncut", "unplugged", "rewind",
           "real talk", "deep dive", "the deep dive", "office hours", "open mic", "game day", "free agent", "overtime",
           "the end", "the beginning", "introduction", "intro", "outro", "explained", "reacts", "behind the scenes"}


def con():
    import duckdb
    c = duckdb.connect(DB, read_only=True)
    c.execute("SET threads=4")
    c.execute("SET memory_limit='5GB'")
    return c


def rules():
    import sponsorblock_select as s
    return s


def done_ids():
    out = set()
    for p in DONE:
        if os.path.exists(p):
            out |= set(json.load(open(p)))
    return out


def per_video(c):
    """Videos that pass the per-video rules before the title rules, with their info row."""
    c.execute("""CREATE TEMP TABLE v AS SELECT videoID, max(dur) d, sum(views) views,
        count(*) FILTER (WHERE category = 'sponsor' AND actionType = 'full') full_marks,
        count(*) FILTER (WHERE category = 'sponsor' AND actionType = 'skip' AND COALESCE(hidden, 0) = 0
                         AND COALESCE(sh, 0) = 0 AND (locked = 1 OR votes >= 1)) good
        FROM st GROUP BY videoID""")


def funnel(args):
    s = rules()
    c = con()
    per_video(c)
    steps = []

    def count(label, where, join=False):
        sql = (f"SELECT count(*), count(DISTINCT i.channelID) FROM v JOIN info i USING (videoID) WHERE {where}" if join
               else f"SELECT count(*), NULL FROM v WHERE {where}")
        n, ch = c.execute(sql).fetchone()
        steps.append((label, n, ch))
        print(f"{label:58} {n:>11,} videos" + (f" {ch:>9,} channels" if ch is not None else ""), flush=True)

    count("every video with a segment in the 7 categories", "TRUE")
    count("+ a sponsor skip, locked or voted up, not hidden", "good > 0")
    count("+ no whole-video sponsor mark", "good > 0 AND full_marks = 0")
    count("+ >= 200 skips over its segments", "good > 0 AND full_marks = 0 AND views >= 200")
    base = "good > 0 AND full_marks = 0 AND views >= 200 AND d BETWEEN 1800 AND 14400"
    count("+ 30 min – 4 h (length known)", base)
    count("+ an info row with a title", base + " AND i.title IS NOT NULL", join=True)
    rows = c.execute(f"SELECT i.videoID, i.channelID, i.title FROM v JOIN info i USING (videoID) WHERE {base} AND i.title IS NOT NULL").fetchall()
    done = done_ids()
    stages = [("+ not one of his shows", lambda t: not s.HIS_SHOWS.search(t)),
              ("+ not a stream / clip / music title", lambda t: not s.NOT_PODCAST.search(t)),
              ("+ an English title", s.english),
              ("+ PODCASTY title (the rule `select` adds)", lambda t: bool(s.PODCASTY.search(t)))]
    kept = rows
    for label, ok in stages:
        kept = [r for r in kept if ok(r[2])]
        steps.append((label, len(kept), len({r[1] for r in kept})))
        print(f"{label:58} {len(kept):>11,} videos {len({r[1] for r in kept}):>9,} channels", flush=True)
    fresh = [r for r in kept if r[0] not in done]
    steps.append(("+ not already in sb58 / sb65", len(fresh), len({r[1] for r in fresh})))
    print(f"{'+ not already in sb58 / sb65':58} {len(fresh):>11,} videos {len({r[1] for r in fresh}):>9,} channels")
    by = collections.Counter(r[1] for r in fresh)
    capped = sum(min(15, n) for n in by.values())
    steps.append(("+ at most 15 per channel", capped, len(by)))
    print(f"{'+ at most 15 per channel':58} {capped:>11,} videos {len(by):>9,} channels")
    # What the title rule throws away: videos that pass everything else.
    before = [r for r in rows if not s.HIS_SHOWS.search(r[2]) and not s.NOT_PODCAST.search(r[2]) and s.english(r[2])]
    print(f"\nthe title rule keeps {len(kept):,} of {len(before):,} videos ({100 * len(kept) / max(1, len(before)):.1f} %) "
          f"and {len({r[1] for r in kept}):,} of {len({r[1] for r in before}):,} channels")
    json.dump({"steps": steps}, open(os.path.join(OUT, "funnel.json"), "w"), indent=1)


# Not talk: what the first hand check found among "podcast-like" channels (16 Nov, sample40-check.txt).
NOT_TALK = re.compile(r"hermitcraft|minecraft|runescape|\bosrs\b|guess the elo|stockfish|\bchess\b|let'?s play|"
                      r"\bplaythrough\b|\bbuild(ing)?\b.*\bpt\.?\s*\d|declutter|\breaction\b|\breacts?\b|"
                      r"full documentary|\bdocumentary\b|\bretrospective\b|\bwalkthrough\b|\bspeedrun", re.I)
ERROR_TITLE = re.compile(r"sign in to confirm|innertube|^'?videodetails'?$|^\s*$", re.I)


def norm(t):
    t = t.lower().replace("&", " and ")
    t = re.sub(r"\bthe\b", " ", t)
    return re.sub(r"[^a-z0-9]+", " ", t).strip()


SPLIT = re.compile(r"\s+(?:[-–—|:]|//|\bep\b\.?|\bepisode\b|#)\s*|\s*[|]\s*|\s*\(\s*", re.I)


def show_part(title):
    """The show's name in a video title: the part before a separator, or after the last one
    ("Huberman Lab | Dr. X: Sleep" → "huberman lab"; "Sleep with Dr. X | Huberman Lab Podcast" → both sides)."""
    parts = [p for p in SPLIT.split(title) if p and p.strip()]
    out = []
    for p in (parts[0], parts[-1]) if len(parts) > 1 else ():
        n = norm(re.sub(r"\bpodcast\b|\bpod\b|\bshow\b|\bofficial\b|\bfull\b|\bepisode\b", " ", p, flags=re.I))
        if n:
            out.append(n)
    return out


def latin(t):
    letters = [ch for ch in t if ch.isalpha()]
    return bool(letters) and sum(ch.isascii() for ch in letters) / len(letters) > 0.95


def specific(name):
    words = name.split()
    return name not in GENERIC and (len(words) >= 2 or len(name) >= 8) and not re.fullmatch(r"[0-9 ]+", name)


# v4 (his 16 Nov correction): a channel is a podcast by any of three signs, none needing the word "podcast":
#   literal  "podcast" / "pod" in a title;
#   sporc    a SPoRC show's name (two words or more) on >= 3 of its videos and >= 30 % of them;
#   episodic numbered episodes (#123, Ep. 45, Episode 45, S2E4) on >= 40 % of its titles AND guests or a
#            recurring show name (w/, ft., feat., " x ", "with <Name>", the same title part) on >= 25 % AND a
#            median length >= 35 min (vlogs, game and build series are shorter or carry no guests).
# Channels where >= 20 % of titles are gaming / let's play / walkthrough / stream / music / reaction / tutorial /
# highlights / unboxing are dropped. English is judged per channel.
EPNUM = re.compile(r"#\s?\d{1,4}\b|\bep(isode)?\.?\s*#?\s?\d{1,4}\b|\bS\d{1,2}\s?E\d{1,3}\b|\|\s*\d{1,4}\s*$|\bno\.\s?\d{1,4}\b", re.I)
GUEST = re.compile(r"\bw/|\bft\.?\s|\bfeat\.?\s|\s[x×]\s|\bwith\s+(?:dr\.?\s|[A-Z][a-z]+\s+[A-Z])|\binterview", re.I)
LITERAL = re.compile(r"\bpodcasts?\b", re.I)
# Real English function words (not "a" / "o" / "e", which Portuguese and Spanish titles share).
ENGLISH = re.compile(r"\b(the|and|of|to|is|my|how|why|what|with|we|you|it|this|for|about|your|are|was|our|from|that|"
                     r"his|her|they|their|who|when|did|does|can|will|just|not|have|has|be)\b", re.I)
# Other languages: accented letters, or their own function words (16 Nov hand check v5: Spanish, Italian, Polish,
# French titles carried "The" or "to" too).
FOREIGN = re.compile(r"[ñáéíóúàèìòùâêîôûãõçäöüßżźćńłśąęőűœ¿¡]|\b(que|los|las|del|el|una|con|por|para|como|não|uma|"
                     r"il|della|degli|sono|che|und|der|die|das|ist|mit|nicht|ein|eine|nie|jak|się|czy|jest|les|des|"
                     r"est|avec|pour|dans|une|qui|het|een|och|att|och|på|og)\b", re.I)
SHOW_NUMBER = re.compile(r"[|\-–—]\s*[A-Za-z][\w' &.]{2,40}\s#?(?!(?:19|20)\d\d\b)\d{2,4}\s*$")
NOT_TALK = re.compile(NOT_TALK.pattern + r"|\bgameplay\b|\blet'?s play\b|\bstream(ed|ing)?\b|\bvod\b|\bmusic video\b|"
                      r"\bofficial video\b|\blyrics?\b|\btutorial\b|\bhow to (make|build|install|fix)\b|\bhighlights\b|"
                      r"\bunboxing\b|\bsurvival\b|\bmodded\b|\bhardcore\b|\bcampaign\b.*\bpart\b|\bpart \d+\b.*\bgame\b|"
                      r"\bfull match\b|\bcompilation\b|\btier list\b|\btrailer\b|\bdecl?utter\b|\brenovation\b|\bvlog\b|"
                      r"\bdeck\b|\bduel\b|\broblox\b|\bfnaf\b|\bnuzlocke\b|\bcommander\b|\b4k\b|\bmotivation(al)?\b|"
                      r"\btravel\b|\bi tried\b|\bexplained\b|\bunsleeping city\b|\bdimension 20\b|\bcritical role\b|\bgta\b|"
                      r"\bs?gdq\d*|\btasbot\b|\bspeed ?run|\bschlatt\b|\bwants to guess\b|\bcooking\b|\brecipe\b|"
                      r"\btry(ing)? .* (food|snacks)\b|\bcops\b|\bbodycam\b|\bcppcon\b|\bconference\b|\bkill count\b|\bvideo essay\b|"
                      r"\breview:|\bdriven:|\bhide and seek\b", re.I)
GENRE_WORDS = [("true crime", r"murder|killer|cold case|missing|disappear|true crime|serial|homicide|crime"),
               ("news & politics", r"trump|biden|election|politic|congress|news|senate|democrat|republican|war\b|ukraine|israel"),
               ("business", r"business|money|invest|market|startup|founder|ceo|finance|stock|crypto|bitcoin|entrepreneur"),
               ("science", r"science|physic|space|universe|brain|biology|evolution|climate|neuro|research"),
               ("history", r"history|historical|ancient|empire|medieval|world war|civil war"),
               ("technology", r"\bai\b|tech|apple|google|software|iphone|computer|programming"),
               ("sports", r"nfl|nba|mlb|nhl|football|soccer|f1\b|formula 1|ufc|boxing|basketball|baseball|golf|draft"),
               ("health", r"health|fitness|nutrition|diet|sleep|workout|longevity|doctor|medical"),
               ("comedy", r"comedy|comedian|stand-?up|funny|roast|laugh")]


def guess_genre(titles):
    text = " ".join(titles).lower()
    scores = [(len(re.findall(p, text)), g) for g, p in GENRE_WORDS]
    best = max(scores)
    return best[1] if best[0] >= 3 else "society & culture"


def base_rows(c, s):
    """Per-video rules (v4): a verified sponsor skip, no whole-video mark, >= 25 skips, 20 min - 5 h, or
    length unknown with a segment ending >= 10 min in; a title; not his shows; not stream / clip / music."""
    c.execute("CREATE TEMP TABLE IF NOT EXISTS ve AS SELECT videoID, max(e) max_e FROM st GROUP BY videoID")
    rows = c.execute("""SELECT i.videoID, i.channelID, i.title, v.d, v.views FROM v JOIN ve USING (videoID) JOIN info i USING (videoID)
        WHERE good > 0 AND full_marks = 0 AND views >= 25 AND i.title IS NOT NULL
          AND ((d BETWEEN 1200 AND 18000) OR ((d IS NULL OR d = 0) AND max_e >= 600))""").fetchall()
    return [r for r in rows if r[1] and r[1] != "null" and not ERROR_TITLE.search(r[2]) and not s.HIS_SHOWS.search(r[2])
            and not s.NOT_PODCAST.search(r[2]) and latin(r[2])]


def sporc_shows():
    import duckdb
    out = {}
    for title, genre, eps in duckdb.connect().execute(
            f"SELECT pod_title, primary_category, episode_count FROM '{SPORC}' WHERE language LIKE 'en%'").fetchall():
        if not title:
            continue
        n = norm(re.sub(r"\bpodcast\b|\bpod\b|\bshow\b|\bofficial\b", " ", title, flags=re.I))
        # v8: two real words ("D&D" and "Q&A" normalise to "d d", "q a").
        if n and specific(n) and sum(len(w) >= 3 for w in n.split()) >= 2 and (n not in out or (eps or 0) > out[n][2]):
            out[n] = (title, genre or "", eps or 0)
    return out


def channels(args):
    s = rules()
    c = con()
    per_video(c)
    rows = base_rows(c, s)
    shows = sporc_shows()
    by_channel = collections.defaultdict(list)
    for r in rows:
        by_channel[r[1]].append(r)
    out, dropped = {}, collections.Counter()
    for ch, vids in by_channel.items():
        titles = [r[2] for r in vids]
        n = len(vids)
        if sum(bool(NOT_TALK.search(t)) for t in titles) * 10 >= n:   # v7: a tenth of its titles
            dropped["not talk"] += 1
            continue
        literal = sum(bool(LITERAL.search(t)) for t in titles)
        epnum = sum(bool(EPNUM.search(t) or s.PODCASTY.search(t) or SHOW_NUMBER.search(t)) for t in titles)
        guests = sum(bool(GUEST.search(t)) for t in titles)
        parts = collections.Counter(re.sub(r"\s*\d+$", "", p) for t in titles for p in set(show_part(t)) if specific(p))
        marker, marker_n = parts.most_common(1)[0] if parts else ("", 0)
        names = collections.Counter(p for t in titles for p in set(show_part(t)) if p in shows)
        match = None
        if names:
            name, hits = names.most_common(1)[0]
            if hits >= 3 and hits * 10 >= 3 * n:
                match = name
        known = [r[3] for r in vids if r[3]]
        median = sorted(known)[len(known) // 2] if known else 0
        why = []
        if literal * 4 >= n:
            why.append(f"literal {literal}")
        if match:
            why.append("sporc")
        if epnum * 10 >= 4 * n and epnum >= 3 and (guests * 4 >= n or marker_n * 2 >= n) and (median >= 2100 or not known):
            why.append(f"episodic {epnum}")
        if not why:
            continue
        english = sum(bool(ENGLISH.search(t)) for t in titles)
        foreign = sum(bool(FOREIGN.search(t)) for t in titles)
        if foreign * 100 >= 15 * n or (not match and english * 10 < 3 * n):
            dropped["not English"] += 1
            continue
        out[ch] = {"videos": n, "podcasty": epnum, "literal": literal, "guests": guests, "why": why,
                   "marker": marker if marker_n * 2 >= n else "", "sporc": shows[match][0] if match else None,
                   "genre": shows[match][1] if match else guess_genre(titles), "median": median,
                   "titles": [r[2] for r in sorted(vids, key=lambda r: -(r[4] or 0))[:5]]}
    json.dump(out, open(os.path.join(OUT, "channels.json"), "w"), indent=1)
    kinds = collections.Counter(w.split()[0] for v in out.values() for w in v["why"])
    print(f"channels with a qualifying video: {len(by_channel):,} ({len(rows):,} videos); podcast channels: {len(out):,} "
          f"({', '.join(f'{k} {n}' for k, n in kinds.most_common())}); dropped: {dict(dropped)}")
    print(f"videos on podcast channels: {sum(v['videos'] for v in out.values()):,}; capped at 40: "
          f"{sum(min(40, v['videos']) for v in out.values()):,}")
    g = collections.Counter(v["genre"] for v in out.values())
    print("genres:", ", ".join(f"{k} {n}" for k, n in g.most_common()))


def sample(args):
    """Random podcast channels with their top titles, for reading by hand."""
    out = json.load(open(os.path.join(OUT, "channels.json")))
    chans = sorted(out)
    random.Random(args.seed).shuffle(chans)
    for i, ch in enumerate(chans[: args.n], 1):
        v = out[ch]
        print(f"{i:2}. {ch} · {v['videos']} videos · {', '.join(v['why'])} · {v['genre']}" + (f" · SPoRC: {v['sporc']}" if v["sporc"] else ""))
        for t in v["titles"][:3]:
            print("      ", t[:110])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("funnel")
    c = sub.add_parser("channels")
    c.add_argument("--min", type=int, default=3)
    sm = sub.add_parser("sample")
    sm.add_argument("--n", type=int, default=40)
    sm.add_argument("--seed", type=int, default=66)
    args = ap.parse_args()
    {"funnel": funnel, "channels": channels, "sample": sample}[args.cmd](args)


if __name__ == "__main__":
    main()
