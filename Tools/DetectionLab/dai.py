#!/usr/bin/env python3
"""Cheap evidence for the lab (pass 17): no language model involved.

    dai.py map <key>           inserted-ad map against the host's ad-free copy
    dai.py probe <key>         the same map by range requests only (what the app would do)
    dai.py prints <key>...     repeated-ad fingerprints across the given episodes
    dai.py pubtx <key>         the publisher's own transcript, if the feed has one

Works in build/lab. <key>.mp3 is the copy a podcast app got (fetched by
`lab.sh fetch` with a Podcasts user agent from this Mac, i.e. Shashank's home
connection). Results go to <key>.dai.json / <key>.prints.json / <key>.pubtx.json.
"""
import hashlib, json, os, re, subprocess, sys, time, urllib.request, difflib
import xml.etree.ElementTree as ET

import ssl
CTX = ssl.create_default_context(cafile="/etc/ssl/cert.pem")   # python.org builds ship no CA list
UA = "Podcasts/1740.2 CFNetwork/3826.500.62.2.1 Darwin/24.0.0"
BR = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
SR = [44100, 48000, 32000]

def frames(b):
    """(byte offset, length, payload hash) of every MPEG-1 Layer III frame."""
    i = 10 + ((b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9]) if b[:3] == b"ID3" else 0
    out, rate = [], 44100
    while i + 4 <= len(b):
        h0, h1, h2 = b[i], b[i + 1], b[i + 2]
        if h0 == 0xFF and h1 & 0xE0 == 0xE0 and (h1 >> 3) & 3 == 3 and (h1 >> 1) & 3 == 1 \
                and 0 < (h2 >> 4) & 15 < 15 and (h2 >> 2) & 3 < 3:
            rate = SR[(h2 >> 2) & 3]
            n = 144 * BR[(h2 >> 4) & 15] * 1000 // rate + ((h2 >> 1) & 1)
            out.append((i, n, hashlib.md5(b[i + 4:i + n]).digest()[:8]))
            i += n
        else:
            i += 1
    return out, 1152 / rate

def get(url, rng=None, method="GET", tries=3, limit=None):
    """(final URL, body, headers) through curl: Python's own HTTP stack took
    ~30 s per request to these hosts from this Mac (curl: under 1 s)."""
    import tempfile
    n = limit if limit is not None else (rng[1] - rng[0] + 1 if rng else None)
    with tempfile.NamedTemporaryFile() as hdr, tempfile.NamedTemporaryFile() as body:
        cmd = ["curl", "-sL", "--retry", str(tries), "--max-time", "300", "-A", UA,
               "-D", hdr.name, "-o", body.name, "-w", "%{url_effective}"]
        if rng: cmd += ["-r", f"{rng[0]}-{rng[1]}"]
        if n and not rng: cmd += ["-r", f"0-{n - 1}"]
        final = subprocess.run(cmd + [url], capture_output=True, text=True, check=True).stdout
        data = open(body.name, "rb").read()
        if n: data = data[:n]
        headers = {}
        for line in open(hdr.name, errors="replace").read().splitlines():
            if ":" in line:
                k, v = line.split(":", 1); headers[k.strip().title()] = v.strip()
        class H(dict):
            def get(self, k, d=None): return dict.get(self, k.title(), d)
        return final, data, H(headers)

def final_url(url):
    """Follow the redirect chain with a one-byte request (no download counted)."""
    u, _, _ = get(url, (0, 0))
    return u

# Spreaker mirrors of Megaphone/Simplecast shows (found through the iTunes
# Search API; research §2 H1). The app would find these the same way.
MIRRORS = {"feeds.megaphone.fm/GLT1158789509": "https://www.spreaker.com/show/7368533/episodes/feed",
           "feeds.simplecast.com/dHoohVNH": "https://www.spreaker.com/show/7368567/episodes/feed"}

def norm_title(t):
    return re.sub(r"[^a-z0-9]", "", (t or "").lower())

def candidates(key):
    """Every URL that might serve this episode without inserted ads."""
    feed = open(key + ".feed").read().strip() if os.path.exists(key + ".feed") else ""
    title = open(key + ".title").read()
    enclosure = open(key + ".url").read().strip()
    out = []
    # Following the enclosure asks the ad server for a stitch (slow, and it
    # counts); only Art19 needs it.
    fin = final_url(enclosure) if "art19" in enclosure else enclosure
    # Simplecast: the stitcher's own path with the analytics prefixes
    # (podtrac, pdrl.fm, arttrk, claritas…) and the query removed. Asking for
    # it redirects to the stored, ad-free file. Following the full enclosure
    # instead gets a freshly stitched copy (checked from home, 23 Sep).
    m = re.search(r"stitcher\.simplecastaudio\.com/[^?]+", enclosure)
    if m:
        out.append(("simplecast-noquery", "https://" + m.group(0)))
    for k, mirror in MIRRORS.items():
        if k in feed:
            root = ET.fromstring(get(mirror)[1])
            for it in root.iter("item"):
                if norm_title(it.findtext("title")) == norm_title(title):
                    out.append(("spreaker-mirror", it.find("enclosure").get("url")))
    m = re.search(r"rss\.art19\.com/episodes/[^?]+", enclosure)
    if m:
        out.append(("art19-direct", "https://" + m.group(0)))
    if "art19" in fin:
        out.append(("art19-plain", fin.split("?")[0]))
    return out, fin

def size_of(url):
    u, _, h = get(url, (0, 0))
    total = (h.get("Content-Range") or "/0").split("/")[-1]
    return u, int(total) if total.isdigit() else 0

def local_index(key):
    b = open(key + ".mp3", "rb").read()
    fr, dur = frames(b)
    return b, fr, dur

def spans_from_diff(lf, rf, dur):
    """Inserted runs of local frames (seconds in the local copy) by full diff."""
    a = [h for _, _, h in rf]; b = [h for _, _, h in lf]
    sm = difflib.SequenceMatcher(None, a, b, autojunk=False)
    out = []
    for op, i1, i2, j1, j2 in sm.get_opcodes():
        if op in ("insert", "replace") and (j2 - j1) - (i2 - i1) > 40:   # > ~1 s added
            out.append({"start": round(j1 * dur, 3), "end": round(j2 * dur, 3),
                        "clean_at": round(i1 * dur, 3), "seconds": round((j2 - j1) * dur, 2)})
        elif op == "delete" and i2 - i1 > 40:
            out.append({"removed_from_reference": round(i1 * dur, 3), "seconds": round((i2 - i1) * dur, 2)})
    return out, sm.ratio()

def cmd_map(key):
    t0 = time.time()
    cands, fin = candidates(key)
    b, lf, dur = local_index(key)
    best = None
    for name, url in cands:
        try:
            u, size = size_of(url)
        except Exception as e:
            print(f"  {name}: {e}"); continue
        print(f"  {name}: {size:,} bytes  ({u[:90]})")
        if size and (best is None or size < best[2]): best = (name, u, size)
    result = {"key": key, "local_bytes": len(b), "local_seconds": round(len(lf) * dur, 2),
              "local_host": fin.split('/')[2], "candidates": [c[0] for c in cands]}
    if best and best[2] < len(b) - 16000:        # at least ~1 s smaller: there is something to find
        name, u, size = best
        _, rb, _ = get(u)
        rf, _ = frames(rb)
        spans, ratio = spans_from_diff(lf, rf, dur)
        result.update(reference=name, reference_url=u, reference_bytes=len(rb),
                      reference_seconds=round(len(rf) * dur, 2), similarity=round(ratio, 4),
                      inserted=[s for s in spans if "start" in s],
                      other=[s for s in spans if "start" not in s])
    else:
        result.update(reference=None, inserted=[],
                      note="no copy smaller than the local one: nothing inserted, or no ad-free source")
    result["seconds_cpu_and_network"] = round(time.time() - t0, 1)
    json.dump(result, open(key + ".dai.json", "w"), indent=1)
    added = sum(s["seconds"] for s in result["inserted"])
    print(f"{key}: {len(result['inserted'])} inserted spans, {added:.1f} s; reference {result.get('reference')}")
    for s in result["inserted"]:
        print(f"   {clock(s['start'])}–{clock(s['end'])}  {s['seconds']:.2f} s  (clean timeline {clock(s['clean_at'])})")

def clock(s):
    s = float(s); return f"{int(s // 3600)}:{int(s % 3600 // 60):02d}:{s % 60:05.2f}"

WINDOW = 6144

def cmd_probe(key):
    """The map by small range requests against the reference: the app's method.

    delta(x) = local byte offset of the 3-frame run found at reference byte x,
    minus x. Inserts only ever add bytes, so delta never decreases; every
    interval whose ends differ holds at least one insert, and bisecting it down
    to ~2 frames finds each one.
    """
    d = json.load(open(key + ".dai.json"))
    if not d.get("reference_url"):
        print(f"{key}: no reference"); return
    url, rsize = d["reference_url"], d["reference_bytes"]
    b, lf, dur = local_index(key)
    fb = (lf[-1][0] + lf[-1][1] - lf[0][0]) / len(lf)             # mean frame bytes
    run, seen = {}, set()
    for i in range(len(lf) - 2):
        k = lf[i][2] + lf[i + 1][2] + lf[i + 2][2]
        if k in run: seen.add(k)
        run.setdefault(k, i)
    for k in seen: del run[k]           # silence repeats: a run must be unique to place it
    stats = {"requests": 0, "bytes": 0}
    cache = {}
    def delta(x):
        x = max(0, min(x, rsize - WINDOW))
        if x in cache: return cache[x]
        for attempt in range(4):
            lo = x + attempt * WINDOW
            _, chunk, _ = get(url, (lo, lo + WINDOW - 1))
            stats["requests"] += 1; stats["bytes"] += len(chunk)
            fr, _ = frames(chunk)
            fr = [f for f in fr if f[0] + f[1] <= len(chunk)]
            for k in range(len(fr) - 2):
                i = run.get(fr[k][2] + fr[k + 1][2] + fr[k + 2][2])
                if i is not None:
                    cache[x] = (lf[i][0] - (lo + fr[k][0]), i, lo + fr[k][0]); return cache[x]
        cache[x] = None; return None
    t0 = time.time()
    _, head, _ = get(url, (0, 9)); stats["requests"] += 1; stats["bytes"] += 10
    ref_audio = 10 + ((head[6] << 21) | (head[7] << 14) | (head[8] << 7) | head[9]) if head[:3] == b"ID3" else 0
    grid = [ref_audio + int((rsize - ref_audio) * k / 64) for k in range(65)]
    found = []
    def bisect(a, b_):
        da, db = delta(a), delta(b_)
        if da is None or db is None or da[0] == db[0]: return
        if db[2] - da[2] <= 2.5 * fb or b_ - a <= 2:
            found.append((da, db)); return
        m = (a + b_) // 2
        bisect(a, m); bisect(m, b_)
    for a, b_ in zip(grid, grid[1:]): bisect(a, b_)
    spans = []
    for da, db in found:
        # The insert is (db.delta - da.delta) bytes, somewhere in the <= 2-frame
        # clean gap between the two matched runs; place it at the gap's end.
        gap_ref = db[2] - da[2]
        ins = db[0] - da[0]
        s_i = min(range(len(lf)), key=lambda i: abs(lf[i][0] - (lf[da[1]][0] + gap_ref)))
        e_i = min(range(len(lf)), key=lambda i: abs(lf[i][0] - (lf[da[1]][0] + gap_ref + ins)))
        spans.append({"start": round(s_i * dur, 3), "end": round(e_i * dur, 3), "seconds": round((e_i - s_i) * dur, 2)})
    # Pre-roll: local frames before the first clean frame. Post-roll: whatever
    # length is left over once the clean audio and the mid-rolls are accounted for.
    d0 = delta(ref_audio)
    pre_frames = d0[1] - round((d0[2] - ref_audio) / fb) if d0 else 0
    ends = []
    if pre_frames > 40:
        ends.append({"start": 0.0, "end": round(pre_frames * dur, 3), "seconds": round(pre_frames * dur, 2), "how": "pre-roll"})
    ref_frames = (rsize - ref_audio) / fb
    post = len(lf) - ref_frames - pre_frames - sum(s["seconds"] for s in spans) / dur
    if post > 40:
        ends.append({"start": round((len(lf) - post) * dur, 3), "end": round(len(lf) * dur, 3),
                     "seconds": round(post * dur, 2), "how": "post-roll, by subtraction"})
    probe = {"requests": stats["requests"], "bytes": stats["bytes"], "seconds": round(time.time() - t0, 1),
             "inserted": sorted(ends + spans, key=lambda s: s["start"])}
    d["probe"] = probe
    json.dump(d, open(key + ".dai.json", "w"), indent=1)
    print(f"{key}: probe {stats['requests']} requests, {stats['bytes']:,} bytes, {probe['seconds']} s")
    for s in probe["inserted"]:
        print(f"   {clock(s['start'])}–{clock(s['end'])}")

# ---- repeated-ad fingerprints (research H2): landmark hashes, offset voting ----

def pcm8k(key):
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", key + ".mp3", "-ac", "1", "-ar", "8000",
                          "-f", "f32le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)

HOP = 256 / 8000          # 32 ms

def landmarks(x):
    """{hash: [frame, ...]} from spectral peaks, 5-peak fan-out."""
    import numpy as np
    from numpy.lib.stride_tricks import sliding_window_view as win
    n = (len(x) - 512) // 256
    idx = np.arange(512)[None, :] + 256 * np.arange(n)[:, None]
    spec = np.log1p(np.abs(np.fft.rfft(x[idx] * np.hanning(512), axis=1))[:, 1:257]).astype(np.float32)
    pad = np.pad(spec, ((7, 7), (7, 7)), constant_values=-1)
    local = win(win(pad, 15, axis=0).max(axis=-1), 15, axis=1).max(axis=-1)
    peaks = np.argwhere((spec == local) & (spec > spec.mean()))
    keep = [tuple(p) for p in peaks[np.argsort(peaks[:, 0], kind="stable")]]
    table = {}
    for a in range(len(keep)):
        t1, f1 = keep[a]
        for t2, f2 in keep[a + 1:a + 11]:
            dt = t2 - t1
            if 0 < dt < 64 and abs(int(f2) - int(f1)) < 64:
                table.setdefault((int(f1) << 16) | (int(f2) << 8) | int(dt), []).append(int(t1))
    return table

def cmd_prints(keys):
    """Cut every inserted span into 15 s pieces; look for each piece in every episode."""
    import numpy as np
    t0 = time.time()
    tables, secs, cpu = {}, {}, {}
    for k in keys:
        c0 = time.process_time(); w0 = time.time()
        x = pcm8k(k); secs[k] = len(x) / 8000
        tables[k] = landmarks(x)
        cpu[k] = (time.time() - w0, time.process_time() - c0)
        print(f"  {k}: {secs[k] / 3600:.2f} h, {time.time() - w0:.1f} s wall to decode + print", flush=True)
    pieces = []
    for k in keys:
        spans = json.load(open(k + ".dai.json")).get("inserted", []) if os.path.exists(k + ".dai.json") else []
        if os.path.exists(k + ".seeds.json"): spans += json.load(open(k + ".seeds.json"))
        for s in spans:
            t = s["start"]
            while t + 10 <= s["end"]:
                pieces.append((k, t, min(t + 15, s["end"]))); t += 15
    return tables, secs, cpu, pieces, t0

def match_pieces(keys):
    import bisect as bs
    tables, secs, cpu, pieces, t0 = cmd_prints(keys)
    pairs = {k: sorted((t, h) for h, ts in tables[k].items() for t in ts) for k in keys}
    times = {k: [p[0] for p in pairs[k]] for k in keys}
    own = {k: (json.load(open(k + ".dai.json")).get("inserted", []) if os.path.exists(k + ".dai.json") else [])
           for k in keys}
    hits = {k: [] for k in keys}
    s0 = time.time()
    for src, a, b in pieces:
        fa, fb_ = int(a / HOP), int(b / HOP)
        q = pairs[src][bs.bisect_left(times[src], fa):bs.bisect_left(times[src], fb_)]
        if len(q) < 50: continue
        for k in keys:
            votes = {}
            for tq, h in q:
                for te in tables[k].get(h, ()):
                    if k == src and fa - 5 <= te <= fb_ + 5: continue      # itself
                    votes[te - tq] = votes.get(te - tq, 0) + 1
            if not votes: continue
            off, v = max(votes.items(), key=lambda kv: kv[1])
            if v >= 30:
                hits[k].append({"at": round((fa + off) * HOP, 2), "to": round((fb_ + off) * HOP, 2),
                                "votes": v, "of": len(q), "from": f"{src}@{clock(a)}"})
    search = time.time() - s0
    report = {}
    for k in keys:
        regions = []
        for h in sorted(hits[k], key=lambda h: h["at"]):
            if regions and h["at"] <= regions[-1]["end"] + 2:
                regions[-1]["end"] = max(regions[-1]["end"], h["to"]); regions[-1]["pieces"].append(h["from"])
                regions[-1]["votes"] = max(regions[-1]["votes"], h["votes"])
            else:
                regions.append({"start": h["at"], "end": h["to"], "votes": h["votes"], "pieces": [h["from"]]})
        for r in regions:
            r["inside_own_inserted"] = any(s["start"] - 2 <= r["start"] and r["end"] <= s["end"] + 2 for s in own[k])
        report[k] = {"hours": round(secs[k] / 3600, 3), "decode_and_print_wall_s": round(cpu[k][0], 1),
                     "cpu_s": round(cpu[k][1], 1), "regions": regions}
        json.dump(report[k], open(k + ".prints.json", "w"), indent=1)
        new = [r for r in regions if not r["inside_own_inserted"]]
        print(f"{k}: {len(regions)} repeated-ad regions, {len(new)} outside its own inserted spans")
        for r in regions:
            print(f"   {clock(r['start'])}–{clock(r['end'])} votes {r['votes']:>4} {'(own insert)' if r['inside_own_inserted'] else 'NEW'}  from {', '.join(sorted(set(p.split('@')[0] for p in r['pieces'])))}")
    print(f"pieces {len(pieces)}, search {search:.1f} s total")

# ---- the publisher's own transcript (research H4 side finding) ----

def parse_cues(text):
    """SRT or VTT → [(start, end, text)]."""
    def ts(s):
        s = s.strip().replace(",", ".")
        parts = [float(p) for p in s.split(":")]
        return sum(p * 60 ** i for i, p in enumerate(reversed(parts)))
    cues = []
    for block in re.split(r"\n\s*\n", text.replace("\r", "")):
        lines = [l for l in block.strip().split("\n") if l.strip()]
        for i, l in enumerate(lines):
            if "-->" in l:
                a, b = l.split("-->")[:2]
                body = " ".join(lines[i + 1:])
                body = re.sub(r"<[^>]+>", "", body).strip()
                if body: cues.append((ts(a), ts(b.split()[0]), body))
                break
    return cues

def cmd_pubtx(key):
    feed = open(key + ".feed").read().strip()
    title = open(key + ".title").read()
    t0 = time.time()
    urls = []
    for k, mirror in list(MIRRORS.items()) + [("", feed)]:
        if k and k not in feed: continue
        root = ET.fromstring(get(mirror if k else feed)[1])
        for it in root.iter("item"):
            if norm_title(it.findtext("title")) == norm_title(title):
                for el in it:
                    if el.tag.endswith("}transcript"):
                        urls.append((el.get("type"), el.get("url")))
    print(f"{key}: transcripts offered: {urls}")
    pick = next((u for t, u in urls if t and ("srt" in t or "vtt" in t)), None)
    if not pick:
        print("  none with timings"); return
    _, body, _ = get(pick)
    cues = parse_cues(body.decode("utf-8", "replace"))
    fetch_s = time.time() - t0
    # Publisher times are on the ad-free timeline; shift them onto this copy.
    dai = json.load(open(key + ".dai.json")) if os.path.exists(key + ".dai.json") else {}
    shifts = sorted((s["clean_at"], s["seconds"]) for s in dai.get("inserted", []) if "clean_at" in s)
    # The publisher's file may carry its own pre-roll (Spreaker adds one), so
    # its clock can lead the ad-free timeline by a constant. Find it from
    # four-word runs both transcripts share.
    def norm_words(t): return re.sub(r"[^a-z0-9 ]", "", t.lower()).split()
    mine = json.load(open(key + ".json"))
    ins = sorted((s["start"], s["end"]) for s in dai.get("inserted", []))
    def clean_of(t):
        return t - sum(min(t, b) - a for a, b in ins if a < t)
    grams = {}
    for line in mine:
        w = norm_words(line["text"])
        for i in range(len(w) - 3):
            grams.setdefault(" ".join(w[i:i + 4]), []).append(line["start"])
    diffs = []
    for a, b, text in cues:
        w = norm_words(text)
        for i in range(len(w) - 3):
            hit = grams.get(" ".join(w[i:i + 4]))
            if hit and len(hit) == 1: diffs.append(a - clean_of(hit[0])); break
    diffs.sort()
    lead = diffs[len(diffs) // 2] if diffs else 0.0
    print(f"  publisher clock leads the ad-free timeline by {lead:.2f} s ({len(diffs)} shared phrases)")
    def local(t):
        t = t - lead
        return t + sum(sec for at, sec in shifts if at <= t + 0.01)
    lines = []
    for a, b, text in cues:
        la, lb = local(a), local(b)
        if lb <= 0: continue          # the publisher's own pre-roll
        toks = text.split()
        span, total = lb - la, sum(len(w) + 1 for w in toks) or 1
        words, c = [], la
        for w in toks:           # the publisher gives cue times only; spread words by length
            d = span * (len(w) + 1) / total
            words.append({"text": w, "start": round(c, 2), "end": round(c + d, 2)}); c += d
        lines.append({"text": " " + text, "start": round(la, 2), "end": round(lb, 2), "words": words})
    json.dump(lines, open(key + "-pub.json", "w"))
    for ext in ("title", "notes.txt"):
        if os.path.exists(f"{key}.{ext}"):
            open(f"{key}-pub.{ext}", "w").write(open(f"{key}.{ext}").read())
    cue_len = sorted(b - a for a, b, _ in cues)
    print(f"  {len(cues)} cues, median {cue_len[len(cue_len) // 2]:.1f} s, fetched in {fetch_s:.1f} s; "
          f"shifted by {len(shifts)} inserts → {key}-pub.json")

def cmd_cuts(key):
    """What the cheap evidence alone would cut, in the lab's detect format, so
    score.py can score it: inserted spans plus repeated-ad regions."""
    spans = []
    if os.path.exists(key + ".dai.json"):
        spans += [(s["start"], s["end"], "ad-free comparison") for s in json.load(open(key + ".dai.json")).get("inserted", [])]
    if os.path.exists(key + ".prints.json"):
        spans += [(r["start"], r["end"], "fingerprint") for r in json.load(open(key + ".prints.json"))["regions"]
                  if not r["inside_own_inserted"]]
    spans.sort()
    merged = []
    for a, b, why in spans:
        if merged and a <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b), merged[-1][2] + "+" + why)
        else:
            merged.append((a, b, why))
    with open(key + ".cheap.txt", "w") as f:
        f.write(f"cheap evidence only: {len(merged)} cuts\n")
        for a, b, why in merged:
            f.write(f"\n[ad] {clock(a)}–{clock(b)} ({why})\n")
    json.dump([{"start": a, "end": b, "why": why} for a, b, why in merged], open(key + ".cheap.json", "w"), indent=1)
    print(f"{key}: {len(merged)} cheap cuts → {key}.cheap.txt / .cheap.json")

if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "build", "lab"))
    {"map": lambda: [cmd_map(k) for k in args], "probe": lambda: [cmd_probe(k) for k in args],
     "prints": lambda: match_pieces(args), "pubtx": lambda: [cmd_pubtx(k) for k in args],
     "cuts": lambda: [cmd_cuts(k) for k in args]}[cmd]()
