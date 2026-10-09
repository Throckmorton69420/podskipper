#!/usr/bin/env python3
"""Pass 34: one offline evaluation set from everything already collected.

    evalset.py build  <results export.json …> [--out DIR]
    evalset.py find-videos [--out DIR]
    evalset.py sponsorblock [--out DIR] [--map videos.csv] [--captions DIR] [--fetch-captions]
    evalset.py evaluate [--out DIR] [--tiers user,claude,sponsorblock] [--finder detected|final|reader]

Nothing here changes what the app skips. It gathers, per episode, the
transcript the phone made, what the app predicted (its final stretches and
the reader's own), and every *label* for that episode, each kept with where
it came from, in tiers that are never mixed up:

  user          his own decisions (confirmed, locked, edited, added, "not
                an ad") from the Results exports — the only ground truth
                that is his.
  claude        regions of the Claude-labelled lab fixtures
                (Tools/DetectionLab/regression/*.json), found by their words
                in this episode's transcript. Careful labels, but a model's.
  sponsorblock  SponsorBlock segments on the episode's YouTube upload,
                moved onto the podcast's clock by matching the video's
                captions to the transcript. Crowd labels: kept with their
                votes, and only where the two texts line up.

Predictions are never written as labels. Stitched-in (dynamic) ads differ
per download, so a fixture's inserted ads only count where their words are
found in this copy; a YouTube upload doesn't carry them at all.

`build` writes DIR/episodes/<key>.json and DIR/inventory.md. `sponsorblock`
reads DIR/videos.csv (guid,video_id — `build` writes it with every episode's
title so the IDs can be filled in; blank = no upload known), asks the public
SponsorBlock API once per video (cached in DIR/sponsorblock/) and, with
captions (DIR/captions/<video_id>.vtt or .json3, or --fetch-captions, which
asks `yt-dlp --skip-download` for the auto captions only), adds aligned
segments. `evaluate` scores the app per show against the chosen tiers and
splits the shows into development and held-out halves (fixed by name), so a
change tuned on one half is judged on the other. `detected` (default) is what
the app found before any edit; `final` includes his edits, so scoring it
against his own decisions is circular; `reader` is the reader alone.

Default DIR: build/evalset (generated, not committed).
"""
import argparse, collections, csv, difflib, hashlib, json, os, re, subprocess, sys, urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "regression"))
import score  # noqa: E402  (the fixture anchors are resolved exactly as the lab does)

KIND_LABEL = {"ad": "ADVERTISEMENT", "selfPromo": "SELF_PROMOTION", "crossPromo": "NETWORK_PROMOTION",
              "intro": "INTRO", "outro": "OUTRO", "credits": "CREDITS"}
SKIP = set(KIND_LABEL.values())
SB_LABEL = {"sponsor": "ADVERTISEMENT", "selfpromo": "SELF_PROMOTION", "intro": "INTRO", "outro": "OUTRO"}
# "interaction" (like/subscribe) is a plug the app treats as self-promotion;
# its edges are often loose, so it is kept separate and not scored by default.
SB_CATEGORIES = ["sponsor", "selfpromo", "interaction", "intro", "outro"]


def key_for(e):
    return re.sub(r"[^A-Za-z0-9]+", "_", e.get("guid") or e["title"])[-80:]


def norm_title(t):
    return " ".join(score.norm(t))


# MARK: build

def build(args):
    episodes = {}
    for path in args.exports:
        data = json.load(open(path))
        for e in data.get("episodes", []):
            k = key_for(e)
            rec = episodes.get(k)
            # The newest export of an episode holds its newest predictions.
            if rec is None or (data.get("exportedAt") or "") >= rec["exportedAt"]:
                labels = rec["labels"] if rec else {}
                rec = dict(key=k, guid=e.get("guid"), show=e["show"], title=e["title"], duration=e.get("duration"),
                           exportedAt=data.get("exportedAt") or "", build=data.get("build"),
                           transcript=[dict(start=l["start"], end=l["end"], text=l["text"]) for l in e.get("transcript") or []],
                           predictions=dict(
                               final=[dict(start=s["start"], end=s["end"], label=KIND_LABEL.get(s["kind"], s["kind"]),
                                           comedy=s.get("comedyBit", False), stage=s.get("stage", ""))
                                      for s in e.get("segments") or [] if s.get("verdict") != "notAnAd"],
                               detected=detected_cuts(e),
                               reader=[dict(start=s["start"], end=s["end"], label=KIND_LABEL.get(s["kind"], s["kind"]))
                                       for s in e.get("readerSegments") or []]),
                           finder=e.get("finder", ""), labels=labels)
                episodes[k] = rec
            add_user_labels(rec, e, data.get("build"))
    fixtures = load_fixtures()
    for rec in episodes.values():
        rec["labels"] = {k: v for k, v in rec["labels"].items() if v["tier"] != "claude"}
        rec["unresolved"] = []
        for name, fx in fixtures:
            if fixture_matches(fx, rec):
                rec.setdefault("unresolved", [])
                for lab in fixture_on_phone_clock(name, fx, rec["transcript"]):
                    if lab["start"] is None:
                        rec["unresolved"].append(f"{name}:{lab['id']}")
                    else:
                        rec["labels"][f"claude-{name}-{lab['id']}"] = lab
    os.makedirs(os.path.join(args.out, "episodes"), exist_ok=True)
    for rec in episodes.values():
        rec["labels"] = dict(sorted(rec["labels"].items(), key=lambda kv: kv[1]["start"]))
        json.dump(rec, open(os.path.join(args.out, "episodes", rec["key"] + ".json"), "w"), indent=1)
    write_video_template(args.out, episodes)
    write_inventory(args.out, episodes, fixtures)


def detected_cuts(e):
    """What the app found before anyone edited it — the view to score
    against his own decisions. The latest detection attempt's saved cuts;
    a stretch's own detected edges are not enough, because a merge or an
    absorbing edit keeps only the surviving stretch's (LoS 954: three found
    stretches, one locked stretch)."""
    attempts = sorted((a for a in e.get("attempts") or [] if a.get("savedCuts")), key=lambda a: a.get("date", ""))
    if attempts:
        return [dict(start=c["start"], end=c["end"], label=KIND_LABEL.get(c["kind"], c["kind"]))
                for c in attempts[-1]["savedCuts"]]
    return [dict(start=s["detectedStart"], end=s["detectedEnd"],
                 label=KIND_LABEL.get(s.get("detectedKind") or s["kind"], s["kind"]))
            for s in e.get("segments") or []
            if s.get("origin", "detected") == "detected" and s.get("detectedStart") is not None]


def add_user_labels(rec, e, build_id):
    """His decisions only. A stretch's own edge moving isn't one of them."""
    spans = []
    for c in e.get("corrections") or []:
        label = "NORMAL" if c["action"] in ("notAnAd", "delete", "remove") else KIND_LABEL.get(c["kind"], c["kind"])
        rec["labels"][f"user-{c['key']}"] = dict(start=c["start"], end=c["end"], label=label, tier="user",
                                                 provenance=f"his {c['action']} ({c['date']}, build {build_id})")
        spans.append((c["start"], c["end"]))
    for s in e.get("segments") or []:
        if not (s.get("verdict") in ("confirmed", "notAnAd") or s.get("locked")):
            continue
        if any(min(b, s["end"]) - max(a, s["start"]) > 0.5 * (s["end"] - s["start"]) for a, b in spans):
            continue
        what = "not an ad" if s.get("verdict") == "notAnAd" else ("locked" if s.get("locked") else "confirmed")
        label = "NORMAL" if s.get("verdict") == "notAnAd" else KIND_LABEL.get(s["kind"], s["kind"])
        rec["labels"][f"user-seg-{round(s['start'], 1)}"] = dict(start=s["start"], end=s["end"], label=label, tier="user",
                                                                 provenance=f"his verdict: {what} (build {build_id})")


def load_fixtures():
    out = []
    folder = os.path.join(HERE, "regression")
    for name in sorted(os.listdir(folder)):
        if name.endswith(".json"):
            fx = json.load(open(os.path.join(folder, name)))
            if isinstance(fx, dict) and "regions" in fx:
                out.append((name[:-5], fx))
    return out


def fixture_matches(fx, rec):
    a, b = norm_title(fx.get("episode", "")), norm_title(rec["title"])
    return bool(a) and fx.get("show", "")[:12].lower() in rec["show"].lower() + " " + rec["title"].lower() \
        and difflib.SequenceMatcher(None, a, b).ratio() > 0.8


def fixture_on_phone_clock(name, fx, lines):
    """A fixture was written against the lab's own transcript of its own
    download. Resolve it there, where its words are exact, then carry the
    times onto the phone's transcript by word alignment; an edge that falls
    where the two copies differ (a stitched ad) isn't carried. Without the
    lab transcript, resolve directly on the phone's words."""
    lab_path = os.path.join(HERE, "..", "..", "build", "lab", name + ".json")
    if not os.path.exists(lab_path):
        return resolve_fixture(fx, lines)
    mapping = align(json.load(open(lab_path)), lines)
    out = []
    for lab in resolve_fixture(fx, json.load(open(lab_path))):
        if lab["start"] is None or mapping is None:
            out.append(lab); continue
        start, end = mapping(lab["start"]), mapping(lab["end"])
        out.append(dict(lab, start=start, end=end) if start is not None and end is not None and end > start
                   else dict(lab, start=None, end=None))
    return out


def resolve_fixture(fx, lines):
    """The fixture's regions on this transcript's clock, found by their words.

    Anchors are matched exactly as score.py does; a region whose words aren't
    in this copy (an inserted ad that differs per download) is left out.
    """
    if not lines:
        return []
    import io, contextlib, tempfile
    with tempfile.TemporaryDirectory() as tmp:
        paths = [os.path.join(tmp, n) for n in ("t.json", "d.txt", "f.json", "dump.json")]
        json.dump(lines, open(paths[0], "w")); open(paths[1], "w").close(); json.dump(fx, open(paths[2], "w"))
        os.environ["SCORE_DUMP"] = paths[3]
        argv, sys.argv = sys.argv, ["score.py", *paths[:3]]
        printed = io.StringIO()
        try:
            with contextlib.redirect_stdout(printed):
                score.main()
        except SystemExit:
            pass
        finally:
            sys.argv = argv
            os.environ.pop("SCORE_DUMP", None)
        resolved = json.load(open(paths[3])) if os.path.exists(paths[3]) else []
    note = fx.get("labelled_by") or "Claude-labelled lab fixture"
    # Regions whose words this copy doesn't have (a stitched ad that differs
    # per download, or the phone's recognizer wording a line differently).
    missing = re.findall(r"\? (\S+): anchors not found", printed.getvalue())
    return [dict(id=m, start=None, end=None, label="UNRESOLVED", tier="claude", provenance=note[:80]) for m in missing] + [dict(id=r["id"], start=r["start"], end=r["end"], label=r["label"], tier="claude",
                 provenance=note[:80], delivery=r.get("delivery") or "", complete=bool(fx.get("complete")))
            for r in resolved]


def write_video_template(out, episodes):
    path = os.path.join(out, "videos.csv")
    known = {}
    if os.path.exists(path):
        for row in csv.DictReader(open(path)):
            known[row["guid"]] = row.get("video_id", "")
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["guid", "video_id", "show", "title"])
        for rec in sorted(episodes.values(), key=lambda r: (r["show"], r["title"])):
            w.writerow([rec["key"], known.get(rec["key"], ""), rec["show"], rec["title"]])


def write_inventory(out, episodes, fixtures):
    by_show = collections.defaultdict(list)
    for rec in episodes.values():
        by_show[rec["show"]].append(rec)
    lines = ["# Evaluation set inventory", "",
             "Labels by tier (seconds). Predictions are not labels.", "",
             "| Show | Episodes | Transcripts | user | claude | sponsorblock | Split |", "|---|---|---|---|---|---|---|"]
    totals = collections.Counter()
    for show in sorted(by_show):
        recs = by_show[show]
        secs = collections.Counter()
        for r in recs:
            for lab in r["labels"].values():
                secs[lab["tier"]] += lab["end"] - lab["start"]
        totals.update(secs)
        lines.append(f"| {show} | {len(recs)} | {sum(bool(r['transcript']) for r in recs)} | {secs['user']:.0f} | "
                     f"{secs['claude']:.0f} | {secs['sponsorblock']:.0f} | {split_of(show)} |")
    unresolved = [u for r in episodes.values() for u in r.get("unresolved", [])]
    matched = {n for n, fx in fixtures for r in episodes.values() if fixture_matches(fx, r)}
    lines += ["", f"Fixtures matched to an exported episode: {len(matched)} of {len(fixtures)} "
              f"({', '.join(sorted(matched)) or 'none'}). The others were labelled on lab downloads that "
              "aren't in a Results export; they still score the Mac lab (score.py).",
              f"Fixture regions whose words aren't in the phone's transcript (left out, so their time is unlabelled, "
              f"not program): {len(unresolved)} — {', '.join(unresolved) or 'none'}. Mostly stitched-in ads, which differ "
              "per download; a region of the recording itself here means its anchor needs the phone's wording.",
              f"Totals: user {totals['user']:.0f} s, claude {totals['claude']:.0f} s, sponsorblock {totals['sponsorblock']:.0f} s."]
    open(os.path.join(out, "inventory.md"), "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))


def split_of(show):
    """Development or held-out, fixed by the show's name (never by results)."""
    return "held-out" if int(hashlib.sha1(show.encode()).hexdigest(), 16) % 2 else "dev"


# MARK: Finding the YouTube uploads

def find_videos(args):
    """Fills blank video_ids in videos.csv from each show's YouTube channel.

    DIR/channels.csv (show,channel) — a channel ID (UC…) or an @handle — is
    written with every show the first time. Only the channel's public feed is
    read (its latest ~15 uploads), so this finds recent episodes; older ones
    can be filled in by hand. A match needs the titles to agree closely and
    is printed for checking; nothing is downloaded.
    """
    import html
    chan_path = os.path.join(args.out, "channels.csv")
    vid_path = os.path.join(args.out, "videos.csv")
    rows = list(csv.DictReader(open(vid_path)))
    if not os.path.exists(chan_path):
        with open(chan_path, "w", newline="") as f:
            w = csv.writer(f); w.writerow(["show", "channel"])
            for show in sorted({r["show"] for r in rows}):
                w.writerow([show, ""])
        print(f"Wrote {chan_path}: fill in each show's YouTube channel ID or @handle (blank = none), then run again.")
        return
    channels = {r["show"]: r["channel"].strip() for r in csv.DictReader(open(chan_path)) if r.get("channel", "").strip()}
    uploads = {}
    for show, channel in channels.items():
        if channel.startswith("@"):
            page = fetch_text("https://www.youtube.com/" + channel)
            m = re.search(r'"externalId":"(UC[A-Za-z0-9_-]{22})"', page or "")
            channel = m.group(1) if m else ""
        feed = fetch_text("https://www.youtube.com/feeds/videos.xml?channel_id=" + channel) if channel else ""
        entries = re.findall(r"<yt:videoId>([^<]+)</yt:videoId>\s*<yt:channelId>[^<]*</yt:channelId>\s*<title>([^<]*)</title>", feed or "")
        uploads[show] = [(vid, html.unescape(title)) for vid, title in entries if "#" not in title]
    found = 0
    for r in rows:
        if r.get("video_id") or r["show"] not in uploads:
            continue
        want = norm_title(r["title"])
        best = max(((difflib.SequenceMatcher(None, want, norm_title(t)).ratio(), vid, t) for vid, t in uploads[r["show"]]),
                   default=(0, "", ""))
        if best[0] >= 0.75:
            r["video_id"] = best[1]; found += 1
            print(f"{best[0]:.2f}  {r['title'][:60]}  →  {best[1]}  {best[2][:60]}")
    with open(vid_path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["guid", "video_id", "show", "title"]); w.writeheader(); w.writerows(rows)
    print(f"{found} uploads matched; check the lines above, then run `sponsorblock`.")


def fetch_text(url):
    """The system curl (macOS's own certificates; python.org builds lack them)."""
    done = subprocess.run(["curl", "-sS", "-L", "-m", "20", "-A", "Mozilla/5.0", "-w", "\n%{http_code}", url],
                          capture_output=True, text=True)
    body, _, code = done.stdout.rpartition("\n")
    if done.returncode != 0 or code not in ("200", "404"):
        print(f"  couldn't read {url}: {done.stderr.strip() or 'HTTP ' + code}")
        return None
    return body if code == "200" else ""


# MARK: SponsorBlock

def sponsorblock(args):
    rows = [r for r in csv.DictReader(open(args.map or os.path.join(args.out, "videos.csv"))) if r.get("video_id")]
    cache = os.path.join(args.out, "sponsorblock"); os.makedirs(cache, exist_ok=True)
    caps = args.captions or os.path.join(args.out, "captions"); os.makedirs(caps, exist_ok=True)
    report = []
    for row in rows:
        vid = row["video_id"].strip()
        path = os.path.join(args.out, "episodes", row["guid"] + ".json")
        if not os.path.exists(path):
            continue
        rec = json.load(open(path))
        segments = fetch_segments(vid, cache)
        cues = load_captions(vid, caps, args.fetch_captions)
        mapping = align(cue_lines(cues), rec["transcript"]) if cues else None
        rec["labels"] = {k: v for k, v in rec["labels"].items() if v["tier"] != "sponsorblock"}
        placed = 0
        for s in segments:
            label = SB_LABEL.get(s["category"])
            if not label or s.get("actionType") != "skip":
                continue
            a, b = s["segment"]
            start, end = (mapping(a), mapping(b)) if mapping else (None, None)
            if start is None or end is None or end <= start:
                continue
            placed += 1
            rec["labels"][f"sb-{s['UUID'][:12]}"] = dict(
                start=start, end=end, label=label, tier="sponsorblock", votes=s.get("votes", 0), locked=bool(s.get("locked")),
                provenance=f"SponsorBlock {s['category']} on {vid} {a:.1f}–{b:.1f}s, votes {s.get('votes', 0)}"
                           + (", locked" if s.get("locked") else ""))
        json.dump(rec, open(path, "w"), indent=1)
        report.append((rec["show"], rec["title"][:50], vid, len(segments), "yes" if cues else "no captions", placed))
    print("| Show | Episode | Video | SponsorBlock segments | Captions | Placed on the podcast |\n|---|---|---|---|---|---|")
    for r in report:
        print("| " + " | ".join(str(x) for x in r) + " |")
    if not report:
        print("No video IDs in videos.csv yet: fill in the video_id column (blank = no upload known).")


def fetch_segments(vid, cache):
    path = os.path.join(cache, vid + ".json")
    if os.path.exists(path):
        return json.load(open(path))
    query = urllib.parse.urlencode({"videoID": vid, "categories": json.dumps(SB_CATEGORIES)})
    body = fetch_text("https://sponsor.ajay.app/api/skipSegments?" + query)
    if body is None:
        return []              # not cached, so it is asked again next run
    segments = json.loads(body) if body else []   # 404 = nobody has submitted a segment
    json.dump(segments, open(path, "w"), indent=1)
    return segments


def load_captions(vid, folder, fetch):
    for ext in (".json3", ".en.json3", ".vtt", ".en.vtt"):
        path = os.path.join(folder, vid + ext)
        if os.path.exists(path):
            return parse_json3(path) if "json3" in ext else parse_vtt(path)
    if fetch:
        # Captions only — no audio or video is downloaded.
        subprocess.run(["yt-dlp", "--skip-download", "--write-auto-subs", "--sub-langs", "en", "--sub-format", "json3",
                        "-o", os.path.join(folder, vid), "https://www.youtube.com/watch?v=" + vid],
                       check=False, capture_output=True)
        path = os.path.join(folder, vid + ".en.json3")
        if os.path.exists(path):
            return parse_json3(path)
    return None


def parse_json3(path):
    cues = []
    for ev in json.load(open(path)).get("events", []):
        t0 = ev.get("tStartMs", 0) / 1000
        for seg in ev.get("segs") or []:
            text = seg.get("utf8", "").strip()
            if text:
                cues.append((t0 + seg.get("tOffsetMs", 0) / 1000, text))
    return cues


def parse_vtt(path):
    cues, t = [], None
    for line in open(path, encoding="utf-8"):
        m = re.match(r"(\d+):(\d+):(\d+)\.(\d+) -->", line) or re.match(r"(\d+):(\d+)\.(\d+) -->", line)
        if m:
            parts = [int(x) for x in m.groups()]
            t = (parts[0] * 3600 + parts[1] * 60 + parts[2] + parts[3] / 1000) if len(parts) == 4 else (parts[0] * 60 + parts[1] + parts[2] / 1000)
        elif t is not None and line.strip() and "-->" not in line:
            cues.append((t, re.sub(r"<[^>]+>", "", line.strip())))
    return cues


def cue_lines(cues):
    """Caption cues (time, text) as lines with an end: the next cue's start."""
    return [dict(start=t, end=(cues[i + 1][0] if i + 1 < len(cues) else t + 2), text=text) for i, (t, text) in enumerate(cues)]


def align(src, lines):
    """Another copy's clock (YouTube captions, the lab's download) → this
    transcript's clock, from runs of identical words.

    Word streams of the two transcripts are matched (difflib);
    only runs of at least 8 words anchor the clock, and a time is mapped only
    between two anchors less than 10 minutes apart whose offsets agree within
    3 s — otherwise it is left unplaced rather than guessed.
    """
    def stream(ls):
        out = []
        for l in ls:
            words = score.norm(l["text"])
            for i, w in enumerate(words):
                out.append((l["start"] + (l["end"] - l["start"]) * i / max(1, len(words)), w))
        return out
    vw, pw = stream(src), stream(lines)
    sm = difflib.SequenceMatcher(None, [w for _, w in vw], [w for _, w in pw], autojunk=False)
    anchors = []
    for block in sm.get_matching_blocks():
        if block.size >= 8:
            # Every 20 words along the run (a run can span the whole episode).
            for k in sorted({*range(4, block.size - 3, 20), block.size - 4}):
                anchors.append((vw[block.a + k][0], pw[block.b + k][0]))
    anchors.sort()
    if len(anchors) < 2:
        return None

    def mapping(t):
        before = [a for a in anchors if a[0] <= t]
        after = [a for a in anchors if a[0] >= t]
        if not before or not after:
            return None
        (v0, p0), (v1, p1) = before[-1], after[0]
        if v1 - v0 > 600 or abs((p1 - v1) - (p0 - v0)) > 3:
            return None        # a stitched ad or a cut in between: don't guess
        return p0 + (t - v0) if v1 == v0 else p0 + (t - v0) * (p1 - p0) / (v1 - v0)
    return mapping


# MARK: evaluate

def evaluate(args):
    tiers = set(args.tiers.split(","))
    rows = collections.defaultdict(lambda: collections.Counter())
    folder = os.path.join(args.out, "episodes")
    for name in sorted(os.listdir(folder)):
        rec = json.load(open(os.path.join(folder, name)))
        labels = [l for l in rec["labels"].values() if l["tier"] in tiers and l["label"] in SKIP | {"NORMAL"}]
        if not labels:
            continue
        cuts = [c for c in rec["predictions"][args.finder] if c["label"] in SKIP]
        labels = breaks(labels)
        r = rows[rec["show"]]
        r["episodes"] += 1
        r["unresolved"] += len(rec.get("unresolved", [])) if "claude" in tiers else 0
        for lab in labels:
            span = lab["end"] - lab["start"]
            covered = sum(max(0.0, min(lab["end"], c["end"]) - max(lab["start"], c["start"])) for c in cuts)
            covered = min(covered, span)
            if lab["label"] == "NORMAL":
                r["program_labelled_s"] += span; r["program_cut_s"] += covered
            else:
                r["skip_labelled_s"] += span; r["skip_heard_s"] += span - covered
                hits = [c for c in cuts if min(lab["end"], c["end"]) - max(lab["start"], c["start"]) > 0.5]
                if hits:
                    r["edges"] += 2
                    r["edge_err_s"] += abs(min(c["start"] for c in hits) - lab["start"]) + abs(max(c["end"] for c in hits) - lab["end"])
                else:
                    r["missed"] += 1
    print(f"Tiers: {', '.join(sorted(tiers))} · predictions: {args.finder}\n")
    print("| Show | Split | Episodes | Labelled skip s | Heard s | Labelled program s | Wrongly cut s | Missed | Mean edge error s |")
    print("|---|---|---|---|---|---|---|---|---|")
    for split in ("dev", "held-out"):
        for show in sorted(s for s in rows if split_of(s) == split):
            r = rows[show]
            edge = f"{r['edge_err_s'] / r['edges']:.1f}" if r["edges"] else "—"
            print(f"| {show} | {split} | {r['episodes']} | {r['skip_labelled_s']:.0f} | {r['skip_heard_s']:.0f} | "
                  f"{r['program_labelled_s']:.0f} | {r['program_cut_s']:.0f} | {r['missed']} | {edge} |")
    if not rows:
        print("No labels in these tiers yet.")
    elif any(r["unresolved"] for r in rows.values()):
        print("\nSome fixture regions weren't found in the phone's transcript (see inventory.md); cuts over them "
              "are neither credited nor charged.")


def breaks(labels):
    """Back-to-back skippable labels (≤ 3 s apart) as one break, so a cut
    covering a whole break isn't charged edge errors against each piece."""
    out = []
    for lab in sorted(labels, key=lambda l: l["start"]):
        if out and lab["label"] in SKIP and out[-1]["label"] in SKIP and lab["start"] - out[-1]["end"] <= 3:
            out[-1] = dict(out[-1], end=max(out[-1]["end"], lab["end"]))
        else:
            out.append(dict(lab))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build"); b.add_argument("exports", nargs="+")
    v = sub.add_parser("find-videos")
    s = sub.add_parser("sponsorblock"); s.add_argument("--map"); s.add_argument("--captions")
    s.add_argument("--fetch-captions", action="store_true")
    e = sub.add_parser("evaluate"); e.add_argument("--tiers", default="user,claude")
    e.add_argument("--finder", default="detected", choices=["detected", "final", "reader"])
    for p in (b, v, s, e):
        p.add_argument("--out", default=os.path.join(HERE, "..", "..", "build", "evalset"))
    args = ap.parse_args()
    {"build": build, "find-videos": find_videos, "sponsorblock": sponsorblock, "evaluate": evaluate}[args.cmd](args)


if __name__ == "__main__":
    main()
