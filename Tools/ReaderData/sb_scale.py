#!/usr/bin/env python3
"""Pass 65 route 1 (build/p65/ship-rule-6.txt): many more SponsorBlock podcast
episodes for the Reader, labelled by people, transcribed by the app's own
transcriber. Run end to end by Tools/ReaderData/sb_scale_run.sh.

    sb_scale.py select <dir>            picks.json (Pass 53 format) from the dump on the drive
    sb_scale.py select2 <dir> [--per-channel 15] [--min-skips 200] [--min-minutes 30] [--unknown-length]
                        [--sample 40] [--dry]   Pass 66: podcast channels (sb_channels.py), from sb.duckdb
    sb_scale.py status <dir>            how far fetch / transcription / labelling got
    sb_scale.py judge-b <compare.py output> step B of rule 6 from compare.py's table (gaps EITHER)
    sb_scale.py report <dir>            the run's report (also written to <dir>/REPORT.txt)

Selection = Pass 58's per-video rules (sponsorblock_select.py) with two
changes written in rule 6 first: a channel needs one qualifying video (not
three) and gives at most 15, and nothing already in sb58 is picked again.
Picks are ordered round-robin over channels (every channel's best first), so
a run cut short still covers as many shows as it can.
"""
import json
import os
import re
import sys
import time
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))

DUMP = "/Volumes/Samsung PSSD T9 Media/PodSkipper/data/sponsorblock-db"
SB58 = os.path.expanduser("~/Developer/pk-data/sb58")
PER_CHANNEL = 15


def select(out):
    import duckdb
    import sponsorblock_select as s
    from sporc_sb_distill_pipeline import consensus
    os.makedirs(out, exist_ok=True)
    done = set(json.load(open(os.path.join(SB58, "picks.json"))))
    con = duckdb.connect()
    con.execute("SET memory_limit='6GB'")
    csv = lambda n: f"read_csv('{DUMP}/{n}', header=true, all_varchar=true, ignore_errors=true, strict_mode=false)"
    cats = ",".join(repr(c) for c in s.CATS)
    con.execute(f"""CREATE TABLE st AS SELECT videoID, category, actionType, TRY_CAST(startTime AS DOUBLE) s,
        TRY_CAST(endTime AS DOUBLE) e, TRY_CAST(votes AS INT) votes, TRY_CAST(locked AS INT) locked,
        TRY_CAST(videoDuration AS DOUBLE) dur, TRY_CAST(hidden AS INT) hidden, TRY_CAST(shadowHidden AS INT) sh,
        TRY_CAST(views AS BIGINT) views, UUID uuid
        FROM {csv('sponsorTimes.csv')} WHERE service = 'YouTube' AND category IN ({cats})""")
    # Pass 58's video-level rules: 30 min – 4 h, a locked or voted-up sponsor
    # segment, no whole-video sponsor mark, at least 200 skips.
    con.execute("""CREATE TABLE v AS SELECT videoID, max(dur) d, sum(views) views FROM st GROUP BY videoID
        HAVING max(dur) BETWEEN 1800 AND 14400 AND sum(views) >= 200
        AND count(*) FILTER (WHERE category = 'sponsor' AND actionType = 'full') = 0
        AND count(*) FILTER (WHERE category = 'sponsor' AND actionType = 'skip' AND COALESCE(hidden, 0) = 0
                             AND COALESCE(sh, 0) = 0 AND (locked = 1 OR votes >= 1)) > 0""")
    vi = con.execute(f"""SELECT i.videoID, i.channelID, i.title, TRY_CAST(i.published AS DOUBLE) published, v.d, v.views
        FROM {csv('videoInfo.csv')} i JOIN v USING (videoID) WHERE i.title IS NOT NULL""").df()
    ok = lambda t: isinstance(t, str) and not s.HIS_SHOWS.search(t) and not s.NOT_PODCAST.search(t) \
        and s.english(t) and bool(s.PODCASTY.search(t))
    vi = vi[vi.title.apply(ok) & ~vi.videoID.isin(done)]
    con.register("vi", vi)
    rows = defaultdict(list)
    for r in con.execute("SELECT * FROM st WHERE videoID IN (SELECT videoID FROM vi)").df().to_dict("records"):
        rows[r["videoID"]].append(r)
    by_channel = defaultdict(list)
    for r in vi.itertuples():
        segs = consensus(rows[r.videoID], r.d)
        # consensus() keeps votes >= 0; Pass 58 also needs one sponsor voted up or locked.
        if not any(g["category"] == "sponsor" and (g["votes"] >= 1 or g["locked"]) for g in segs):
            continue
        by_channel[r.channelID].append((int(r.views or 0), r.videoID, float(r.d), r.title, float(r.published or 0), segs))
    for ch in by_channel:
        by_channel[ch].sort(key=lambda x: -x[0])
        by_channel[ch] = by_channel[ch][:PER_CHANNEL]
    order = sorted(by_channel, key=lambda c: -sum(x[0] for x in by_channel[c]))
    picks = {}
    for rank in range(PER_CHANNEL):
        for ch in order:
            if rank < len(by_channel[ch]):
                views, vid, d, title, pub, segs = by_channel[ch][rank]
                picks[vid] = {"channel": ch, "genre": "", "title": title, "duration": d, "published": pub, "skips": views,
                              "segments": [{k: g[k] for k in ("start", "end", "category", "votes", "locked", "uuid")}
                                           for g in segs],
                              "source": f"https://www.youtube.com/watch?v={vid}",
                              "labels": "SponsorBlock database dump (sb.ltn.fi), CC BY-NC-SA 4.0",
                              "fetched": time.strftime("%Y-%m-%d")}
    json.dump(picks, open(os.path.join(out, "picks.json"), "w"), indent=1)
    hours = sum(min(p["duration"], 5400) for p in picks.values()) / 3600
    print(f"{len(picks)} picks from {len(by_channel)} channels (sb58 had {len(done)}); "
          f"{hours:.0f} h of audio to fetch (first 90 min each)")


def select2(out, per_channel=40, min_skips=25, min_minutes=20, unknown_length=True, sample=0, seed=66, dry=False):
    """Pass 66 (OPUS-5.5-PLAN §5.4; `select` is unchanged): episodes of the podcast channels
    sb_channels.py found (build/p66/corpus-select/channels.json), from build/p66/corpus-select/sb.duckdb.
    Per video: Pass 58's rules except the title rule (a verified sponsor skip, no whole-video mark,
    >= min_skips, min_minutes – 4 h), not his shows, not already in sb58 / sb65 — and, because a
    podcast channel can also post other videos (third hand check, 85 % of channels), the title must
    carry the channel's show marker (a name recurring in its podcast titles), be podcast-like, or say
    "podcast". At most per_channel a channel, round-robin over genres (SPoRC's, where the show
    matched) and then channels, every channel's most-skipped first."""
    import collections
    import random
    import re as _re
    import sb_channels as sc
    import sponsorblock_select as s
    from sporc_sb_distill_pipeline import consensus
    chans = json.load(open(os.path.join(sc.OUT, "channels.json")))
    done = sc.done_ids()
    c = sc.con()
    sc.per_video(c)
    # v8 per-video rules (his 16 Nov correction): a verified sponsor skip, >= min_skips, min_minutes – 5 h, or
    # length unknown with a segment ending >= 10 min in (unknown_length); English channel, not talk-free titles.
    c.execute("CREATE TEMP TABLE IF NOT EXISTS ve AS SELECT videoID, max(e) max_e FROM st GROUP BY videoID")
    length = f"(d BETWEEN {min_minutes * 60} AND 18000" + (" OR ((d IS NULL OR d = 0) AND max_e >= 600))" if unknown_length else ")")
    rows = c.execute(f"""SELECT i.videoID, i.channelID, i.title, TRY_CAST(i.published AS DOUBLE), v.d, v.views
        FROM v JOIN ve USING (videoID) JOIN info i USING (videoID)
        WHERE good > 0 AND full_marks = 0 AND views >= {min_skips} AND {length} AND i.title IS NOT NULL""").fetchall()
    rows = [r for r in rows if r[1] in chans and r[0] not in done and not s.HIS_SHOWS.search(r[2])
            and not s.NOT_PODCAST.search(r[2]) and not sc.NOT_TALK.search(r[2]) and not sc.FOREIGN.search(r[2])]
    by = collections.defaultdict(list)
    for r in rows:
        by[r[1]].append(r)
    kept, markers = collections.defaultdict(list), {}
    for ch, vids in by.items():
        # The channel's show markers: its recurring title part and its SPoRC show's name.
        markers[ch] = [m for m in (chans[ch].get("marker"), sc.norm(chans[ch]["sporc"] or "")) if m]
        for r in vids:
            parts = [_re.sub(r"\s*\d+$", "", p) for p in sc.show_part(r[2])]
            if sc.LITERAL.search(r[2]) or sc.EPNUM.search(r[2]) or s.PODCASTY.search(r[2]) or sc.SHOW_NUMBER.search(r[2]) \
                    or any(m in parts or m in sc.norm(r[2]) for m in markers[ch]):
                kept[ch].append(r)
    for ch in kept:
        kept[ch].sort(key=lambda r: -(r[5] or 0))
        kept[ch] = kept[ch][:per_channel]
    total = sum(len(v) for v in kept.values())
    print(f"select2: {len(rows):,} candidate videos on {len(by)} podcast channels; with a show marker / podcast-like "
          f"title: {sum(len(v) for v in kept.values()):,} on {len(kept)} channels (≤ {per_channel} each)")
    if sample:
        chosen = sorted(kept)
        random.Random(seed).shuffle(chosen)
        for i, ch in enumerate(chosen[:sample], 1):
            g = chans[ch].get("genre") or "?"
            print(f"{i:2}. {ch} · {len(kept[ch])} picked of {len(by[ch])} · genre {g} · marker {markers[ch]}")
            for r in kept[ch][:3]:
                print("      ", r[2][:110])
    if dry:
        return
    genre = {ch: (chans[ch].get("genre") or "unknown") for ch in kept}
    by_genre = collections.defaultdict(list)
    for ch in sorted(kept, key=lambda ch: -sum(r[5] or 0 for r in kept[ch])):
        by_genre[genre[ch]].append(ch)
    order = []
    rank = 0
    while len(order) < total:
        for g in sorted(by_genre):
            for ch in by_genre[g]:
                if rank < len(kept[ch]):
                    order.append(kept[ch][rank])
        rank += 1
    seg_rows = collections.defaultdict(list)
    ids = [r[0] for r in order]
    c.register("ids", __import__("pandas").DataFrame({"videoID": ids}))
    for r in c.execute("SELECT st.* FROM st JOIN ids USING (videoID)").df().to_dict("records"):
        seg_rows[r["videoID"]].append(r)
    picks = {}
    for vid, ch, title, pub, d, views in order:
        segs = consensus(seg_rows[vid], d or 0)
        if not any(g["category"] == "sponsor" and (g["votes"] >= 1 or g["locked"]) for g in segs):
            continue
        picks[vid] = {"channel": ch, "genre": genre[ch], "title": title, "duration": d, "published": pub or 0,
                      "skips": int(views or 0),
                      "segments": [{k: g[k] for k in ("start", "end", "category", "votes", "locked", "uuid")} for g in segs],
                      "source": f"https://www.youtube.com/watch?v={vid}",
                      "labels": "SponsorBlock database dump (sb.ltn.fi), CC BY-NC-SA 4.0",
                      "fetched": time.strftime("%Y-%m-%d")}
    os.makedirs(out, exist_ok=True)
    json.dump(picks, open(os.path.join(out, "picks.json"), "w"), indent=1)
    hours = sum(min(p["duration"] or 5400, 5400) for p in picks.values()) / 3600
    g = collections.Counter(p["genre"] for p in picks.values())
    print(f"{len(picks):,} picks from {len({p['channel'] for p in picks.values()})} channels → {out}/picks.json; "
          f"{hours:.0f} h of audio to fetch (first 90 min each); genres: " + ", ".join(f"{k} {n}" for k, n in g.most_common()))


def status(d):
    picks = json.load(open(os.path.join(d, "picks.json")))
    audio = [f for f in os.listdir(os.path.join(d, "audio")) if f.endswith(".m4a") and ".tmp" not in f]
    tx = [f for f in os.listdir(os.path.join(d, "tx")) if f.endswith(".json")]
    failed = 0
    logs = os.path.join(d, "logs")
    for f in os.listdir(logs) if os.path.isdir(logs) else []:
        if f.startswith("fetch") and f.endswith(".log"):
            failed += sum(1 for l in open(os.path.join(logs, f)) if l.startswith("FAILED"))
    eps = os.path.join(d, "episodes.json")
    n = len(json.load(open(eps))) if os.path.exists(eps) else 0
    return {"picks": len(picks), "fetched": len(audio), "failed": failed, "transcribed": len(tx), "labelled": n}


ROW = re.compile(r"^\| (\S+) \| (\d+) \| [\d.]+ \| ([\d.]+) \([^)]*\) \| ([\d.]+) \(")


def judge_b(log):
    """Rule 6 step B from compare.py's first table (run with --gaps: gaps EITHER)."""
    first = {}
    for line in open(log):
        m = ROW.match(line)
        if m and m.group(1) not in first:
            first[m.group(1)] = (float(m.group(3)), float(m.group(4)))
    if "shipped" not in first or len(first) < 2:
        print("step B: table not found — FAILS (reported)")
        return False
    new = next(k for k in first if k != "shipped")
    (h0, s0), (h1, s1) = first["shipped"], first[new]
    ok = (h1 + 2 * s1 < h0 + 2 * s0) and (s1 <= s0 + 0.5) and (h1 <= h0 + 3)
    print(f"step B: shipped heard {h0} show cut {s0} (score {h0 + 2 * s0:.1f}); {new} heard {h1} show cut {s1} "
          f"(score {h1 + 2 * s1:.1f}) → {'PASSES' if ok else 'FAILS'}")
    return ok


def report(d):
    st = status(d)
    p65 = os.path.join(ROOT, "build", "p65")
    lines = [f"Pass 65 route 1 report — {time.strftime('%Y-%m-%d %H:%M')}",
             f"picks {st['picks']} · fetched {st['fetched']} · fetch failures {st['failed']} · transcribed "
             f"{st['transcribed']} · labelled episodes {st['labelled']}"]
    for name in ("matchedsb.txt", "stepb-sb.txt"):
        path = os.path.join(p65, name)
        if os.path.exists(path):
            lines += ["", f"== {name}"] + open(path).read().strip().splitlines()
    text = "\n".join(lines) + "\n"
    open(os.path.join(d, "REPORT.txt"), "w").write(text)
    open(os.path.join(p65, "route1-report.txt"), "w").write(text)
    print(text)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "select":
        select(sys.argv[2])
    elif cmd == "select2":
        import argparse
        ap = argparse.ArgumentParser(prog="sb_scale.py select2")
        ap.add_argument("out")
        ap.add_argument("--per-channel", type=int, default=15)
        ap.add_argument("--min-skips", type=int, default=200)
        ap.add_argument("--min-minutes", type=int, default=30)
        ap.add_argument("--unknown-length", action="store_true")
        ap.add_argument("--sample", type=int, default=0)
        ap.add_argument("--seed", type=int, default=66)
        ap.add_argument("--dry", action="store_true")
        a = ap.parse_args(sys.argv[2:])
        select2(a.out, a.per_channel, a.min_skips, a.min_minutes, a.unknown_length, a.sample, a.seed, a.dry)
    elif cmd == "status":
        print(json.dumps(status(sys.argv[2])))
    elif cmd == "judge-b":
        sys.exit(0 if judge_b(sys.argv[2]) else 1)
    elif cmd == "report":
        report(sys.argv[2])
    else:
        raise SystemExit(__doc__)
