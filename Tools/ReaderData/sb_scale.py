#!/usr/bin/env python3
"""Pass 65 route 1 (build/p65/ship-rule-6.txt): many more SponsorBlock podcast
episodes for the Reader, labelled by people, transcribed by the app's own
transcriber. Run end to end by Tools/ReaderData/sb_scale_run.sh.

    sb_scale.py select <dir>            picks.json (Pass 53 format) from the dump on the drive
    sb_scale.py status <dir>            how far fetch / transcription / labelling got
    sb_scale.py judge-b <test_cuts log> step B of rule 6 from test_cuts.py's table
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
    """Rule 6 step B from test_cuts.py's first table (gaps EITHER)."""
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
    elif cmd == "status":
        print(json.dumps(status(sys.argv[2])))
    elif cmd == "judge-b":
        sys.exit(0 if judge_b(sys.argv[2]) else 1)
    elif cmd == "report":
        report(sys.argv[2])
    else:
        raise SystemExit(__doc__)
