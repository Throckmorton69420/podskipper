#!/usr/bin/env python3
"""Pass 65: SPoRC v1.1 + SponsorBlock → Reader training episodes.

Audited on 14 Nov 2026 against the real files, then rewritten, from a draft
written elsewhere (Gemini, same day). What the draft got wrong, measured:

  * `total_sp_labels` is SPoRC's count of *speaker* labels, not sponsor
    labels; `episode_catalog` has no `pod_title`/`primary_category` (they are
    in `podcast_catalog`).
  * SPoRC has no word timing: `turns/text` is speaker turns (start/end per
    turn, often a minute or more), `episodes/` an unsegmented transcript. The
    Reader reads sentences, so turns are cut into sentences here and timed by
    their share of the turn's characters.
  * SPoRC is May–June 2020 only (1,124,058 episodes); SponsorBlock's
    `videoInfo.csv` has no duration and no publish date for 8.6 M of its
    11.7 M videos, and `videoDuration` in `sponsorTimes.csv` is 0 on old rows,
    so the draft's `videoDuration >= 600` and title-substring join drop most
    of what exists and admit generic titles ("Full Episode").
  * Measured yield (14 Nov): 3,295,786 SponsorBlock videos with a usable
    sponsor segment; 10,293 whose title (or a title piece) names exactly one
    SPoRC episode, in 2,003 podcasts; of those, 109 are within 20 s of the
    same length, 311 within 60 s, 850 within 3 min. A YouTube cut of a
    different length has different ads or edits, so only alignment-verified
    episodes are kept (stage `pair`).
  * Hugging Face: the token comes from $HF_TOKEN or ~/.cache/huggingface/token
    through huggingface_hub and is never printed; the two search databases
    (48 GB) are never downloaded; `--matched` fetches only the turn parts the
    matched podcasts live in.
  * Training goes through the project's own two-stage recipe
    (Tools/DetectionLab/reader_distill.py: stage 1 on external episodes, then
    the shipped recipe on his labelled episodes) under a rule written first
    (build/p65/ship-rule-5.txt), not a 5×/2×/1× mix: his labelled episodes
    are the second stage, and the test and show-held-out episodes are only
    ever scored.
  * His 16 shows (and every show in his results exports) are never paired or
    sampled.

Run from the repository with the lab Python:

    PY=~/Developer/pk-ml/bin/python
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py check-env
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py download-sporc --catalogs
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py match
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py download-sporc --matched
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py pair
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py teacher-batch --episodes 2000 --name qwen38-27b --model qwen3.8-27b
       (run the batch file through Tools/ReaderData/kaggle_teacher.py on Kaggle or any OpenAI-compatible server)
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py teacher-import --name qwen38-27b --results <output.jsonl>
    $PY -I Tools/ReaderData/sporc_sb_distill_pipeline.py train-reader [--with-teacher qwen38-27b] [--run]

Licences: SponsorBlock's database is CC BY-NC-SA 4.0; SPoRC is research-use
only (gated, terms accepted by him). Used offline to train a personal app's
Reader; nothing from either is shipped except the trained weights.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from collections import defaultdict

# Plain HTTP GETs, one at a time (Xet's chunk fan-out is what drew HTTP 429s).
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "0")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
sys.path.insert(0, os.path.join(ROOT, "Scripts"))

SSD = "/Volumes/Samsung PSSD T9 Media/PodSkipper"
SPORC = os.path.join(SSD, "data", "sporc")
SB = os.path.join(SSD, "data", "sponsorblock-db")
OUT = os.path.join(SSD, "data", "reader-distill")
REPO_ID = "blitt/SPoRC"

SB_CATS = ("sponsor", "selfpromo", "interaction", "intro", "outro", "preview", "filler")
# A plain "I'll put a link in the description" is not an ad; these are.
STRONG = re.compile(r"brought to you by|sponsored by|promo code|use (the )?code|offer code|"
                    r"support for (this|the) (show|podcast|episode) comes from|\.com ?/|dot com slash|"
                    r"go to [a-z0-9-]+ ?(\.|dot) ?com|% off|percent off|free trial", re.I)


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


def norm(text):
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", (text or "").lower())).strip()


# ----------------------------------------------------------------- his shows

def his_shows():
    """Every show of his (the Reader's test and show-held-out episodes come
    from them): the Pass 58 list plus every show in his results exports."""
    import sponsorblock_select
    names = set()
    for d in sorted(os.listdir(os.path.join(ROOT, "build"))):
        path = os.path.join(ROOT, "build", d, "results.json")
        if d.startswith("phone-") and os.path.exists(path):
            try:
                names |= {norm(e.get("show", "")) for e in json.load(open(path))["episodes"]}
            except (ValueError, KeyError):
                pass
    names.discard("")
    return names, sponsorblock_select.HIS_SHOWS


def is_his(title, names, pattern):
    t = norm(title)
    return bool(t) and (t in names or bool(pattern.search(title or "")))


# ----------------------------------------------------------------- check-env

def check_env(args):
    if not os.path.isdir(os.path.dirname(SSD)):
        raise SystemExit(f"The drive isn't mounted ({os.path.dirname(SSD)}).")
    for m in ("huggingface_hub", "pyarrow", "pandas", "duckdb"):
        __import__(m)
    from huggingface_hub import HfApi, get_token
    if not get_token():
        raise SystemExit("No Hugging Face token: set $HF_TOKEN or save it to ~/.cache/huggingface/token.")
    info = HfApi().dataset_info(REPO_ID, files_metadata=True)
    files = {s.rfilename: s.size or 0 for s in info.siblings}
    db = sum(v for k, v in files.items() if k.endswith(".duckdb"))
    log(f"{REPO_ID}: token can read it — {len(files)} files, {sum(files.values()) / 1e9:.1f} GB "
        f"({db / 1e9:.1f} GB of it search databases, never fetched)")
    for name in ("sponsorTimes.csv", "videoInfo.csv"):
        path = os.path.join(SB, name)
        log(f"SponsorBlock {name}: " + (f"{os.path.getsize(path) / 1e9:.2f} GB" if os.path.exists(path) else "MISSING"))
    names, _ = his_shows()
    log(f"his shows guarded: {len(names)} from his exports + the Pass 58 list")


# ----------------------------------------------------------------- download

def parquet_ok(path):
    try:
        import pyarrow.parquet as pq
        return pq.ParquetFile(path).metadata.num_rows >= 0
    except Exception:  # noqa: BLE001 — a damaged or partial file
        return False


def fetch(names, sizes, min_interval=0.5, retries=10):
    """Paced, resumable downloads into SPORC; a file counts once its size
    matches the listing and (Parquet) its footer reads."""
    from huggingface_hub import hf_hub_download
    try:
        from huggingface_hub.errors import HfHubHTTPError
    except ImportError:  # older huggingface_hub
        from huggingface_hub.utils import HfHubHTTPError
    state_path = os.path.join(SPORC, "download_state.json")
    state = json.load(open(state_path)) if os.path.exists(state_path) else {}
    last, done = 0.0, 0
    total = sum(sizes.get(n, 0) for n in names)
    for i, name in enumerate(names, 1):
        local = os.path.join(SPORC, name)
        good = lambda: os.path.exists(local) and os.path.getsize(local) == sizes.get(name, os.path.getsize(local)) \
            and (not name.endswith(".parquet") or parquet_ok(local))
        if state.get(name) == sizes.get(name) and good():
            done += sizes.get(name, 0)
            continue
        for attempt in range(1, retries + 1):
            wait = min_interval - (time.monotonic() - last)
            if wait > 0:
                time.sleep(wait)
            last = time.monotonic()
            try:
                hf_hub_download(REPO_ID, name, repo_type="dataset", local_dir=SPORC)
                if not good():
                    os.remove(local)
                    raise RuntimeError("size or Parquet footer didn't check out")
                state[name] = sizes.get(name)
                json.dump(state, open(state_path + ".tmp", "w"), indent=0)
                os.replace(state_path + ".tmp", state_path)
                done += sizes.get(name, 0)
                log(f"[{i}/{len(names)}] {name} · {done / 1e9:.2f} of {total / 1e9:.2f} GB")
                break
            except HfHubHTTPError as error:
                code = getattr(getattr(error, "response", None), "status_code", None)
                if code in (401, 403):
                    raise SystemExit(f"HTTP {code}: accept the dataset's terms on its page and check the token.")
                after = getattr(getattr(error, "response", None), "headers", {}).get("Retry-After")
                pause = float(after) if after and str(after).isdigit() else min(300, 15 * 2 ** (attempt - 1))
                log(f"HTTP {code} on {name}; waiting {pause:.0f} s")
                time.sleep(pause)
            except Exception as error:  # noqa: BLE001 — network, retried
                pause = min(120, 5 * 2 ** (attempt - 1))
                log(f"{name}: {error}; waiting {pause:.0f} s")
                time.sleep(pause)
        else:
            raise SystemExit(f"gave up on {name} after {retries} tries")


def listing():
    from huggingface_hub import HfApi
    return {s.rfilename: s.size or 0 for s in HfApi().dataset_info(REPO_ID, files_metadata=True).siblings}


def parts_for(podcasts, trees=("turns_text",)):
    import duckdb
    ids = ",".join("'" + p.replace("'", "") + "'" for p in sorted(podcasts)) or "''"
    rows = duckdb.connect().execute(
        f"SELECT DISTINCT tree, part FROM read_parquet('{SPORC}/metadata/shard_map.parquet') "
        f"WHERE podcast_id IN ({ids}) AND tree IN ({','.join(repr(t) for t in trees)})").fetchall()
    folder = {"turns_text": "turns/text", "turns_metrics": "turns/metrics", "acoustics": "acoustics", "episodes": "episodes"}
    return sorted(f"{folder[t]}/{p}" for t, p in rows)


def download(args):
    sizes = listing()
    if args.catalogs:
        names = [n for n in sizes if n.endswith(("README.md", "manifest.json"))
                 or (n.startswith("metadata/") and n.endswith(".parquet"))]
    elif args.matched:
        import pandas as pd
        podcasts = set(pd.read_parquet(os.path.join(OUT, "matches.parquet")).podcast_id)
        names = parts_for(podcasts)
    elif args.podcasts:
        names = parts_for({l.strip() for l in open(args.podcasts) if l.strip()})
    elif args.all:
        names = [n for n in sizes if not n.endswith(".duckdb") and not n.startswith(".")
                 and not (args.skip_acoustics and n.startswith("acoustics/"))
                 and not (args.skip_episodes and n.startswith("episodes/"))]
    else:
        raise SystemExit("say what to fetch: --catalogs, --matched, --podcasts <file> or --all")
    log(f"{len(names)} files, {sum(sizes.get(n, 0) for n in names) / 1e9:.2f} GB → {SPORC}")
    fetch(sorted(names), sizes, args.min_interval)


# ----------------------------------------------------------------- match

def match(args):
    """SponsorBlock videos with a usable sponsor segment ↔ SPoRC episodes
    whose title is the video's title or one piece of it (split at | - : ( [),
    naming exactly one SPoRC episode, at most --max-duration-diff apart in
    length when SponsorBlock knows the video's length."""
    import duckdb
    os.makedirs(OUT, exist_ok=True)
    con = duckdb.connect()
    con.execute(f"SET temp_directory='{OUT}/duckdb_tmp'")
    con.execute("SET memory_limit='6GB'")
    n = lambda col: f"trim(regexp_replace(lower({col}), '[^a-z0-9]+', ' ', 'g'))"
    csv = lambda name: (f"read_csv('{SB}/{name}', header=true, all_varchar=true, ignore_errors=true, "
                        f"strict_mode=false)")
    cats = ",".join(repr(c) for c in SB_CATS)
    con.execute(f"""CREATE TABLE st AS SELECT videoID, category, actionType, TRY_CAST(startTime AS DOUBLE) s,
        TRY_CAST(endTime AS DOUBLE) e, TRY_CAST(votes AS INT) votes, TRY_CAST(locked AS INT) locked,
        TRY_CAST(videoDuration AS DOUBLE) dur, TRY_CAST(hidden AS INT) hidden, TRY_CAST(shadowHidden AS INT) sh,
        TRY_CAST(views AS BIGINT) views, UUID uuid
        FROM {csv('sponsorTimes.csv')} WHERE service = 'YouTube' AND category IN ({cats})""")
    con.execute("""CREATE TABLE v AS SELECT videoID, max(dur) sb_dur, max(e) last_end,
        count(*) FILTER (WHERE category = 'sponsor' AND actionType = 'skip' AND COALESCE(hidden, 0) = 0
                         AND COALESCE(sh, 0) = 0 AND (locked = 1 OR votes >= 0)) sponsors,
        count(*) FILTER (WHERE category = 'sponsor' AND actionType = 'full') whole
        FROM st GROUP BY videoID HAVING sponsors > 0 AND whole = 0""")
    con.execute(f"""CREATE TABLE vi AS SELECT videoID, channelID, title FROM {csv('videoInfo.csv')}
        WHERE videoID IN (SELECT videoID FROM v)""")
    con.execute(f"""CREATE TABLE keys AS SELECT DISTINCT videoID, {n('piece')} k FROM (
        SELECT videoID, unnest(list_append(regexp_split_to_array(title, '\\s[|\\-–—:]\\s|\\||\\(|\\)|\\[|\\]'), title)) piece
        FROM vi) WHERE length({n('piece')}) >= 14""")
    con.execute(f"""CREATE TABLE sp AS SELECT e.episode_id, e.podcast_id, p.pod_title, e.ep_title,
        p.primary_category, e.duration_seconds d, {n('e.ep_title')} k
        FROM read_parquet('{SPORC}/metadata/episode_catalog.parquet') e
        JOIN read_parquet('{SPORC}/metadata/podcast_catalog.parquet') p USING (podcast_id)
        WHERE length({n('e.ep_title')}) >= 14""")
    con.execute("""CREATE TABLE m AS SELECT DISTINCT keys.videoID, vi.title sb_title, vi.channelID, sp.*, v.sb_dur, v.last_end,
        v.sponsors FROM keys JOIN sp USING (k) JOIN v USING (videoID) JOIN vi USING (videoID)""")
    # Same length (when SponsorBlock knows it), then one video ↔ one episode:
    # a title naming several episodes ("Full Episode", a rerun) identifies
    # none, and an episode two uploads match is left out too.
    lim = float(args.max_duration_diff)
    con.execute(f"""CREATE TABLE m1 AS SELECT * FROM m WHERE (sb_dur > 0 AND abs(sb_dur - d) <= {lim})
        OR (COALESCE(sb_dur, 0) = 0 AND last_end <= d + 5)""")
    con.execute("""CREATE TABLE m2 AS SELECT * FROM m1 WHERE videoID IN (SELECT videoID FROM m1 GROUP BY 1 HAVING count(*) = 1)
        AND episode_id IN (SELECT episode_id FROM m1 GROUP BY 1 HAVING count(DISTINCT videoID) = 1)""")
    names, pattern = his_shows()
    rows = con.execute("SELECT * FROM m2").df()
    his = rows.apply(lambda r: is_his(r.pod_title, names, pattern) or is_his(r.sb_title, names, pattern), axis=1)
    kept = rows[~his]
    kept.to_parquet(os.path.join(OUT, "matches.parquet"))
    con.register("kept", kept)
    con.execute(f"COPY (SELECT * FROM st WHERE videoID IN (SELECT videoID FROM kept)) TO '{OUT}/match_segments.parquet'")
    log(f"usable SponsorBlock videos {con.execute('SELECT count(*) FROM v').fetchone()[0]:,}; "
        f"title matches {con.execute('SELECT count(*) FROM m').fetchone()[0]:,}; same length (within {lim:.0f} s, "
        f"or unknown) and one-to-one: {len(rows):,} ({int(his.sum())} of his shows dropped) → {len(kept):,} episodes "
        f"in {kept.podcast_id.nunique():,} podcasts")
    for a in (10, 20, 60, 180):
        log(f"  length within {a:>3} s: {int(((kept.sb_dur > 0) & ((kept.sb_dur - kept.d).abs() <= a)).sum())}")


# ----------------------------------------------------------------- turns → sentences

SPLIT = re.compile(r"(?<=[.?!])\s+(?=[\"'(]?[A-Z0-9])")


def turn_sentences(turns):
    """Sentences from SPoRC's speaker turns, each timed by its share of the
    turn's characters (SPoRC keeps no word times)."""
    out = []
    for t in turns:
        text = " ".join(str(t["turn_text"] or "").split())
        if not text:
            continue
        pieces = [p for p in SPLIT.split(text) if p.strip()]
        total = sum(len(p) for p in pieces) or 1
        start, span, acc = float(t["start_time"]), max(0.01, float(t["end_time"]) - float(t["start_time"])), 0
        for p in pieces:
            a = start + span * acc / total
            acc += len(p)
            out.append({"text": p, "start": round(a, 2), "end": round(start + span * acc / total, 2)})
    out.sort(key=lambda s: s["start"])
    return out


_part_cache = {}


def podcast_turns(podcast_id, smap):
    """One podcast's turns (its row group), or None when SPoRC has none or
    its part isn't downloaded."""
    import pyarrow.parquet as pq
    loc = smap.get(podcast_id)
    if not loc:
        return None
    path = os.path.join(SPORC, "turns", "text", loc[0])
    if not os.path.exists(path):
        return None
    if path not in _part_cache:
        _part_cache.clear()
        _part_cache[path] = pq.ParquetFile(path)
    return _part_cache[path].read_row_group(loc[1], columns=["episode_id", "turn_count", "turn_text", "start_time",
                                                              "end_time"]).to_pandas()


def shard_map():
    import pyarrow.parquet as pq
    t = pq.read_table(os.path.join(SPORC, "metadata", "shard_map.parquet")).to_pandas()
    t = t[t.tree == "turns_text"]
    return {r.podcast_id: (r.part, int(r.row_group)) for r in t.itertuples()}


# ----------------------------------------------------------------- pair

def consensus(rows, duration):
    """Pass 58's rules (sponsorblock_select): visible, not voted down (or
    locked), one per overlapping cluster of a category (the best voted), an
    intro in the first 5 min and an outro in the last 10."""
    segs = []
    for r in rows:
        if r["actionType"] != "skip" or r["hidden"] == 1 or r["sh"] == 1:
            continue
        if (r["votes"] or 0) < 0 and not r["locked"]:
            continue
        if r["e"] - r["s"] < 1:
            continue
        segs.append({"start": r["s"], "end": r["e"], "category": r["category"], "votes": r["votes"] or 0,
                     "locked": r["locked"] or 0, "views": r["views"] or 0, "uuid": r["uuid"]})
    segs.sort(key=lambda s: (s["locked"], s["votes"], s["views"]), reverse=True)
    kept = []
    for s in segs:
        if s["category"] == "intro" and s["start"] > 300:
            continue
        if s["category"] == "outro" and duration and s["end"] < duration - 600:
            continue
        if any(k["category"] == s["category"] and min(k["end"], s["end"]) - max(k["start"], s["start"])
               > 0.5 * min(k["end"] - k["start"], s["end"] - s["start"]) for k in kept):
            continue
        kept.append(s)
    return sorted(kept, key=lambda s: s["start"])


def align(sents, segs, window):
    """The clock shift (RSS audio vs the YouTube video) that puts every
    sponsor segment over the episode's own selling sentences and none of
    them just outside; None with the reason when the episode can't be
    trusted."""
    import numpy as np
    import sponsorblock_episodes as sbe
    starts = np.array([s["start"] for s in sents])
    ends = np.array([s["end"] for s in sents])
    sell = np.array([bool(sbe.SELLS.search(s["text"])) for s in sents])
    strong = np.array([bool(STRONG.search(s["text"])) for s in sents])
    ads = [g for g in segs if g["category"] == "sponsor"]
    if not ads:
        return None, "no sponsor segment"
    best = None
    for shift in np.arange(-window, window + 0.01, 0.5):
        score = -0.01 * abs(shift)
        for g in ads:
            a, b = g["start"] + shift, g["end"] + shift
            inside = (starts >= a - 1) & (ends <= b + 1)
            near = ((ends > a - 30) & (ends < a - 1)) | ((starts > b + 1) & (starts < b + 30))
            score += min(3, int(sell[inside].sum())) - 0.5 * min(3, int(strong[near].sum()))
            score -= 0.1 * min(5.0, float(np.abs(starts - a).min())) + 0.1 * min(5.0, float(np.abs(ends - b).min()))
        if best is None or score > best[0] + 1e-9:
            best = (score, float(shift))
    shift = best[1]
    for g in ads:
        a, b = g["start"] + shift, g["end"] + shift
        if not sell[(starts >= a - 1) & (ends <= b + 1)].any():
            return None, "a sponsor segment has no selling words under it"
    if ends.max() < max(g["end"] for g in segs) + shift - 10:
        return None, "the transcript stops before the last segment"
    # Ads SponsorBlock didn't mark, or ones inserted only in the feed: two or
    # more strong selling lines together, away from every segment.
    loose = [float(starts[i]) for i in np.flatnonzero(strong)
             if not any(g["start"] + shift - 20 <= starts[i] <= g["end"] + shift + 20 for g in segs)]
    clusters, run = 0, []
    for t in loose:
        if run and t - run[-1] > 60:
            clusters += len(run) >= 2
            run = []
        run.append(t)
    clusters += len(run) >= 2
    if clusters:
        return None, "selling lines outside every segment (an unmarked or feed-only ad)"
    return shift, None


def pair(args):
    import pandas as pd
    import sponsorblock_episodes as sbe
    matches = pd.read_parquet(os.path.join(OUT, "matches.parquet"))
    segrows = pd.read_parquet(os.path.join(OUT, "match_segments.parquet"))
    by_video = defaultdict(list)
    for r in segrows.to_dict("records"):
        by_video[r["videoID"]].append(r)
    smap = shard_map()
    episodes, details, why = [], [], defaultdict(int)
    for podcast_id, group in matches.groupby("podcast_id"):
        turns = podcast_turns(podcast_id, smap)
        if turns is None:
            why["no turns (not in SPoRC's turn data, or part not downloaded)"] += len(group)
            continue
        for m in group.itertuples():
            ep = turns[turns.episode_id == m.episode_id].sort_values("turn_count")
            sents = turn_sentences(ep.to_dict("records"))
            if len(sents) < 50:
                why["fewer than 50 sentences"] += 1
                continue
            if sbe.english_share(sents) < 0.3:
                why["not English"] += 1
                continue
            segs = consensus(by_video[m.videoID], m.sb_dur if m.sb_dur and m.sb_dur > 0 else m.d)
            if not any(g["category"] == "sponsor" for g in segs):
                why["no sponsor segment left after SponsorBlock's votes"] += 1
                continue
            diff = abs(m.sb_dur - m.d) if m.sb_dur and m.sb_dur > 0 else 0
            shift, problem = align(sents, segs, min(args.max_shift, max(8.0, diff + 8.0)))
            if problem:
                why[problem] += 1
                continue
            shifted = [dict(g, start=g["start"] + shift, end=g["end"] + shift) for g in segs]
            letters = sbe.label(sents, shifted)
            count = defaultdict(int)
            for l in letters:
                count[l or "-"] += 1
            if not any(l in ("A", "S") for l in letters):
                why["nothing labelled as an ad after alignment"] += 1
                continue
            why["kept"] += 1
            episodes.append({"key": f"external:sporc:{m.episode_id}", "guid": f"sporc-sb:{m.episode_id}",
                             "title": m.ep_title, "show": m.pod_title, "genre": m.primary_category or "",
                             "sents": sents, "labels": letters,
                             "source": f"SPoRC v1.1 episode {m.episode_id}; https://www.youtube.com/watch?v={m.videoID}",
                             "license": "SponsorBlock database dump, CC BY-NC-SA 4.0; SPoRC research-use terms"})
            details.append({"episode_id": m.episode_id, "videoID": m.videoID, "show": m.pod_title,
                            "title": m.ep_title, "category": m.primary_category, "sporc_duration": m.d,
                            "sb_duration": m.sb_dur, "shift": shift, "segments": shifted, "labels": dict(count)})
    json.dump(episodes, open(os.path.join(OUT, "sporc_sb_episodes.json"), "w"))
    with open(os.path.join(OUT, "sporc_sb_pairs.jsonl"), "w") as f:
        for d in details:
            f.write(json.dumps(d) + "\n")
    shows = {e["show"] for e in episodes}
    sentences = sum(sum(1 for l in e["labels"] if l) for e in episodes)
    log(f"kept {len(episodes)} episodes from {len(shows)} shows ({sentences:,} labelled sentences) → "
        f"{OUT}/sporc_sb_episodes.json")
    for k, v in sorted(why.items(), key=lambda kv: -kv[1]):
        log(f"  {v:5d}  {k}")


# ----------------------------------------------------------------- teacher

def teacher_batch(args):
    """Unlabelled SPoRC episodes (spread over categories, none of his shows,
    none already paired) → an OpenAI batch file in Scripts/distill_reader.py's
    format and prompt, plus the sentences each request refers to."""
    import duckdb
    import distill_reader as dr
    names, pattern = his_shows()
    paired = set()
    path = os.path.join(OUT, "sporc_sb_pairs.jsonl")
    if os.path.exists(path):
        paired = {json.loads(l)["episode_id"] for l in open(path)}
    per = max(1, args.episodes // 19)
    rows = duckdb.connect().execute(f"""
        WITH r AS (SELECT e.episode_id, e.podcast_id, p.pod_title, e.ep_title, p.primary_category, e.duration_seconds d,
            ROW_NUMBER() OVER (PARTITION BY p.primary_category ORDER BY hash(e.episode_id)) n,
            ROW_NUMBER() OVER (PARTITION BY e.podcast_id ORDER BY hash(e.episode_id)) per_show
          FROM read_parquet('{SPORC}/metadata/episode_catalog.parquet') e
          JOIN read_parquet('{SPORC}/metadata/podcast_catalog.parquet') p USING (podcast_id)
          WHERE e.duration_seconds BETWEEN 1200 AND 7200 AND COALESCE(p.primary_category, '') <> '')
        SELECT * FROM r WHERE per_show <= 2 AND n <= {per * 3}""").df()
    rows = rows[~rows.apply(lambda r: is_his(r.pod_title, names, pattern) or r.episode_id in paired, axis=1)]
    rows = rows.groupby("primary_category").head(per)
    with open(os.path.join(OUT, "teacher_podcasts.txt"), "w") as f:
        f.write("\n".join(sorted(set(rows.podcast_id))))
    if not args.no_download:
        sizes = listing()
        fetch(parts_for(set(rows.podcast_id)), sizes)
    smap = shard_map()
    folder = os.path.join(OUT, "teacher", args.name)
    os.makedirs(folder, exist_ok=True)
    requests, kept = 0, 0
    with open(os.path.join(folder, "batch-input.jsonl"), "w") as f, \
            open(os.path.join(folder, "episodes.jsonl"), "w") as g:
        for podcast_id, group in rows.groupby("podcast_id"):
            turns = podcast_turns(podcast_id, smap)
            if turns is None:
                continue
            for m in group.itertuples():
                sents = turn_sentences(turns[turns.episode_id == m.episode_id].sort_values("turn_count").to_dict("records"))
                if len(sents) < 50:
                    continue
                e = {"guid": f"sporc:{m.episode_id}", "show": m.pod_title, "title": m.ep_title}
                lines = [(s["text"], s["start"], s["end"]) for s in sents]
                g.write(json.dumps(dict(e, genre=m.primary_category, sents=sents)) + "\n")
                kept += 1
                for w in dr.windows(len(lines), args.window, args.overlap):
                    body = {"model": args.model, "temperature": 0, "max_tokens": args.max_tokens,
                            "response_format": {"type": "json_object"},
                            "messages": [{"role": "system", "content": dr.SYSTEM},
                                         {"role": "user", "content": dr.user_prompt(e, lines, w)}]}
                    f.write(json.dumps({"custom_id": f"{e['guid']}|{w[0]}|{w[1]}", "method": "POST",
                                        "url": "/v1/chat/completions", "body": body}) + "\n")
                    requests += 1
    log(f"{kept} episodes, {requests} requests → {folder}/batch-input.jsonl "
        f"(run it with Tools/ReaderData/kaggle_teacher.py)")


LETTER = {"PAID_AD": "A", "HOST_READ_AD": "A", "NETWORK_PROMO": "N", "SELF_PROMO": "S", "GUEST_PLUG": "S",
          "INTRO": "I", "OUTRO": "O", "CREDITS": "O", "MOCK_AD": "C", "RECURRING_SEGMENT": "C"}


def teacher_import(args):
    """The teacher's answers → Reader episodes. An entry is kept only at
    confidence ≥ --min-confidence; an ad or promo must have a selling line in
    it (a model ad over plain talk is how the show gets cut); sentences no
    kept entry covers are the show unless they sell (then left out); a
    window that didn't answer leaves its sentences out."""
    import distill_reader as dr
    import sponsorblock_episodes as sbe
    folder = os.path.join(OUT, "teacher", args.name)
    eps = {}
    for l in open(os.path.join(folder, "episodes.jsonl")):
        e = json.loads(l)
        eps[e["guid"]] = e
    answers = defaultdict(list)
    for row in open(args.results):
        row = json.loads(row)
        guid, a, b = row["custom_id"].rsplit("|", 2)
        body = (row.get("response") or {}).get("body") or {}
        text = (body.get("choices") or [{}])[0].get("message", {}).get("content")
        answers[guid].append(((int(a), int(b)), text))
    out, stats = [], defaultdict(int)
    for guid, got in answers.items():
        e = eps.get(guid)
        if not e:
            continue
        sents = e["sents"]
        lines = [(s["text"], s["start"], s["end"]) for s in sents]
        letters = ["C" if not sbe.SELLS.search(s["text"]) else None for s in sents]
        for w, text in got:
            parts = dr.parse(text)
            if parts is None:
                for i in range(w[0], w[1]):
                    letters[i] = None
                stats["unreadable windows"] += 1
        for f in dr.merge(sum((dr.found_entries(dr.parse(t), w, lines) for w, t in got), [])):
            letter = LETTER.get(f["label"])
            if letter is None:
                continue
            span = range(f["firstLine"], f["lastLine"] + 1)
            if f["confidence"] < args.min_confidence:
                for i in span:
                    letters[i] = None
                stats["entries below confidence"] += 1
                continue
            if letter in ("A", "S", "N") and not any(sbe.SELLS.search(sents[i]["text"]) for i in span):
                for i in span:
                    letters[i] = None
                stats["ads with no selling line (left out)"] += 1
                continue
            for i in span:
                letters[i] = letter
            stats[f"kept {f['label']}"] += 1
        out.append({"key": f"external:{guid}", "guid": guid, "title": e["title"], "show": e["show"],
                    "genre": e.get("genre", ""), "sents": sents, "labels": letters,
                    "source": "SPoRC v1.1 transcript; teacher " + args.name,
                    "license": "SPoRC research-use terms"})
    path = os.path.join(OUT, f"teacher_{args.name}_episodes.json")
    json.dump(out, open(path, "w"))
    log(f"{len(out)} episodes → {path}")
    for k, v in sorted(stats.items()):
        log(f"  {v:6d}  {k}")


# ----------------------------------------------------------------- train

def train_reader(args):
    """Rule 5 (build/p65/ship-rule-5.txt): stage 1 on Pass 58's SponsorBlock
    episodes plus the SPoRC pairs (plus a teacher's, when named), then the
    shipped recipe, then step A and step B as rule 4."""
    external = [os.path.expanduser("~/Developer/pk-data/sb58/episodes.json"), os.path.join(OUT, "sporc_sb_episodes.json")]
    if args.with_teacher:
        external.append(os.path.join(OUT, f"teacher_{args.with_teacher}_episodes.json"))
    for path in external:
        if not os.path.exists(path):
            raise SystemExit(f"missing {path}")
    script = os.path.join(ROOT, "Tools", "ReaderData", "reader_run.sh")
    cmd = ["zsh", script, args.suffix, ",".join(external)] + args.steps
    log(" ".join(repr(c) if " " in c else c for c in cmd))
    if args.run:
        subprocess.run(cmd, cwd=ROOT, check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check-env")
    d = sub.add_parser("download-sporc")
    d.add_argument("--catalogs", action="store_true")
    d.add_argument("--matched", action="store_true")
    d.add_argument("--podcasts", default="")
    d.add_argument("--all", action="store_true")
    d.add_argument("--skip-acoustics", action="store_true")
    d.add_argument("--skip-episodes", action="store_true")
    d.add_argument("--min-interval", type=float, default=0.5)
    m = sub.add_parser("match")
    m.add_argument("--max-duration-diff", type=float, default=180.0)
    p = sub.add_parser("pair")
    p.add_argument("--max-shift", type=float, default=200.0)
    t = sub.add_parser("teacher-batch")
    t.add_argument("--name", required=True)
    t.add_argument("--model", default="local")
    t.add_argument("--episodes", type=int, default=2000)
    t.add_argument("--window", type=int, default=400)
    t.add_argument("--overlap", type=int, default=20)
    t.add_argument("--max-tokens", type=int, default=2048)
    t.add_argument("--no-download", action="store_true")
    i = sub.add_parser("teacher-import")
    i.add_argument("--name", required=True)
    i.add_argument("--results", required=True)
    i.add_argument("--min-confidence", type=int, default=85)
    r = sub.add_parser("train-reader")
    r.add_argument("--with-teacher", default="")
    r.add_argument("--suffix", default="")
    r.add_argument("--run", action="store_true")
    r.add_argument("steps", nargs="*", default=["pre", "ext13", "ext17", "stepa"])
    args = ap.parse_args()
    {"check-env": check_env, "download-sporc": download, "match": match, "pair": pair,
     "teacher-batch": teacher_batch, "teacher-import": teacher_import, "train-reader": train_reader}[args.cmd](args)


if __name__ == "__main__":
    main()
