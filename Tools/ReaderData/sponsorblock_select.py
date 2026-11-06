#!/usr/bin/env python3
"""Pass 58: pick podcast episodes for the Reader from SponsorBlock's public
database dump instead of 18 hand-named channels (Pass 53).

    sponsorblock_select.py <dump dir> <out dir> [episodes] [per-channel]

<dump dir> holds sponsorTimes.csv and videoInfo.csv from the SponsorBlock
mirror (https://sb.ltn.fi/database/; the database is CC BY-NC-SA 4.0,
https://wiki.sponsor.ajay.app/w/Database_and_API_License). Used offline,
non-commercially, with attribution, to train a personal app's Reader.
Writes <out dir>/picks.json in Pass 53's format, so fetch/transcribe/label
(`sponsorblock_episodes.py`) work unchanged.

What gets in:
  * a YouTube video 30 min – 4 h long whose own title reads like an English
    podcast episode (podcast, Ep. N, #N, SnEn), from a channel with at least
    3 such long videos;
  * at least one sponsor segment that is locked or voted up, nothing marking
    the whole video as sponsored, and enough SponsorBlock skips (`views`)
    that its users watched it — the closest the dump has to "everything
    skippable was marked";
  * none of the 16 shows in his library (they stay the Reader's held-out
    shows), no gaming streams, compilations, clips or music;
  * per segment: not hidden, not shadow-hidden, votes ≥ 0 (or locked);
    overlapping submissions of one category keep the best voted; an intro
    must start in the first 5 min, an outro must end in the last 10 min
    (both are misused as chapter marks mid-video).
Channels are spread: at most <per-channel> episodes each, most-skipped first.
"""
import csv, json, os, re, sys, time, random
from collections import defaultdict

csv.field_size_limit(10**8)
CATS = {"sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "filler"}
HIS_SHOWS = re.compile(
    r"2 bears|bert kreischer|tom segura|99% ?invisible|bad friends|bobby lee|andrew santino|chapo|chrissy chaos|"
    r"distefano|cum ?town|legion of skanks|matt and shane|secret podcast|stavvy|adam friedland|peter attia|"
    r"the drive|this american life|this past weekend|theo von|we might be drunk|whiskey ginger|your mom'?s house|"
    r"ymh|christina p", re.I)
NOT_PODCAST = re.compile(
    r"\bstream\b|\bvod\b|livestream|gameplay|let'?s play|minecraft|fortnite|speedrun|walkthrough|playthrough|"
    r"full game|compilation|highlights|best of|\bclip\b|clips|asmr|\bmusic\b|\bmix\b|\balbum\b|audiobook|"
    r"\bsermon\b|\bmass\b|lecture \d|\bmovie\b|full movie|\bshorts\b|reaction to|reacts? to|tier list|ranking every", re.I)
# Pass 58 run 2: the episode's own title must read like a podcast episode
# (run 1 took a channel's majority and let in gaming and video essays).
PODCASTY = re.compile(r"podcast|\bpod\b|\bep(isode)?\b\.?\s*#?\s?\d+|#\s?\d{2,}\b|\bS\d+\s?E\d+\b", re.I)
STOP = re.compile(r"\b(the|a|and|of|to|in|on|is|my|how|why|what|with|we|you|i|it|this|for)\b", re.I)


def english(title):
    letters = [c for c in title if c.isalpha()]
    return bool(letters) and sum(c.isascii() for c in letters) / len(letters) > 0.95 and bool(STOP.search(title))


def main():
    dump, out = sys.argv[1], sys.argv[2]
    want = int(sys.argv[3]) if len(sys.argv) > 3 else 400
    per = int(sys.argv[4]) if len(sys.argv) > 4 else 3
    os.makedirs(out, exist_ok=True)
    t0 = time.time()
    info = {}
    with open(os.path.join(dump, "videoInfo.csv"), newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            title = row.get("title") or ""
            if not title or HIS_SHOWS.search(title) or NOT_PODCAST.search(title) or not english(title):
                continue
            try: pub = float(row.get("published") or 0)
            except ValueError: pub = 0
            info[row["videoID"]] = (row.get("channelID") or "", title, pub)
    print(f"videoInfo: {len(info)} English non-excluded titles ({time.time() - t0:.0f} s)", flush=True)

    segs, dur, full, views = defaultdict(list), {}, set(), defaultdict(int)
    with open(os.path.join(dump, "sponsorTimes.csv"), newline="", encoding="utf-8", errors="replace") as fh:
        for row in csv.DictReader(fh):
            vid = row["videoID"]
            if vid not in info or row.get("service") != "YouTube": continue
            cat = row.get("category")
            if row.get("actionType") == "full":
                if cat == "sponsor": full.add(vid)
                continue
            if cat not in CATS or row.get("actionType") != "skip": continue
            if row.get("hidden") == "1" or row.get("shadowHidden") == "1": continue
            try:
                votes, locked = int(row["votes"]), int(row["locked"])
                a, b = float(row["startTime"]), float(row["endTime"])
                d, v = float(row.get("videoDuration") or 0), int(row.get("views") or 0)
            except ValueError:
                continue
            if votes < 0 and not locked: continue
            if b - a < 1: continue
            if d > 0: dur[vid] = max(dur.get(vid, 0), d)
            views[vid] += v
            segs[vid].append({"start": a, "end": b, "category": cat, "votes": votes, "locked": locked,
                              "views": v, "uuid": row.get("UUID")})
    print(f"sponsorTimes: {len(segs)} candidate videos ({time.time() - t0:.0f} s)", flush=True)

    cand = defaultdict(list)
    for vid, ss in segs.items():
        d = dur.get(vid, 0)
        if vid in full or not (1800 <= d <= 14400): continue
        # One segment per overlapping cluster of a category: the best voted.
        ss.sort(key=lambda s: (s["locked"], s["votes"], s["views"]), reverse=True)
        kept = []
        for s in ss:
            if s["category"] == "intro" and s["start"] > 300: continue
            if s["category"] == "outro" and s["end"] < d - 600: continue
            if any(k["category"] == s["category"] and min(k["end"], s["end"]) - max(k["start"], s["start"])
                   > 0.5 * min(k["end"] - k["start"], s["end"] - s["start"]) for k in kept): continue
            kept.append(s)
        if not any(s["category"] == "sponsor" and (s["votes"] >= 1 or s["locked"]) for s in kept): continue
        if views[vid] < 200: continue
        ch, title, pub = info[vid]
        if not PODCASTY.search(title): continue
        cand[ch].append((views[vid], vid, d, title, pub, sorted(kept, key=lambda s: s["start"])))
    # A channel counts when it has ≥ 3 long videos and reads like a podcast.
    chans = {ch: vs for ch, vs in cand.items() if len(vs) >= 3}
    print(f"{len(cand)} channels with long segmented videos; {len(chans)} podcast-like", flush=True)

    rng = random.Random(58)
    order = sorted(chans, key=lambda c: -sum(v[0] for v in chans[c]))
    picks = {}
    for ch in order:
        vs = sorted(chans[ch], key=lambda v: -v[0])[:per * 3]
        rng.shuffle(vs)
        for views_, vid, d, title, pub, kept in vs[:per]:
            picks[vid] = {"channel": ch, "genre": "", "title": title, "duration": d, "published": pub,
                          "skips": views_,
                          "segments": [{k: s[k] for k in ("start", "end", "category", "votes", "locked", "uuid")}
                                       for s in kept],
                          "source": f"https://www.youtube.com/watch?v={vid}",
                          "labels": "SponsorBlock database dump (sb.ltn.fi), CC BY-NC-SA 4.0",
                          "fetched": time.strftime("%Y-%m-%d")}
        if len(picks) >= want: break
    json.dump(picks, open(os.path.join(out, "picks.json"), "w"), indent=1)
    hrs = sum(p["duration"] for p in picks.values()) / 3600
    by = defaultdict(int)
    for p in picks.values():
        for s in p["segments"]: by[s["category"]] += 1
    print(f"{len(picks)} picks from {len({p['channel'] for p in picks.values()})} channels, {hrs:.0f} h; segments {dict(by)}")


if __name__ == "__main__":
    main()
