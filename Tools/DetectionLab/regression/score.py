#!/usr/bin/env python3
"""Scores the lab's detector output against a word-anchored regression file.

    score.py <transcript.json> <detect.txt> <fixture.json>

Each region's start and end are found by their words in *this* transcript, so
the same fixture works on any download of the episode, whatever ads were
stitched into it. Prints, per region, what the detector did there, and a pass
or fail against the tolerance; exits non-zero on any failure.
"""
import json, re, sys, difflib

SKIP_KINDS = {"ad": "ADVERTISEMENT", "selfPromo": "SELF_PROMOTION", "crossPromo": "NETWORK_PROMOTION",
              "intro": "INTRO", "outro": "OUTRO", "credits": "CREDITS"}
# What the app skips with its default switches (14 Sep: all five kinds; credits
# follow the outro switch). EITHER marks spans where cutting or keeping is fine
# (a funny read he keeps by default, a two-second name-drop).
SKIP_LABELS = {"ADVERTISEMENT", "SELF_PROMOTION", "NETWORK_PROMOTION", "INTRO", "OUTRO", "CREDITS"}

def norm(s):
    return re.sub(r"[^a-z0-9 ]", "", s.lower().replace("-", " ")).split()

def locate(lines, phrase, begin=0):
    """(line index, similarity) of the line where the phrase begins.

    A phrase can run across two or three recognizer lines, so lines are joined
    to find it, and the answer is then walked forward to the line that holds
    the phrase's first words.
    """
    words = norm(phrase)
    target = " ".join(words)
    head = " ".join(words[:3])
    best = (-1, 0.0)
    for i in range(begin, len(lines)):
        joined = " ".join(norm(" ".join(l["text"] for l in lines[i:i + 3])))
        if target in joined:
            window = range(i, min(i + 3, len(lines)))
            for j in window:
                if head in " ".join(norm(lines[j]["text"])):
                    return j, 1.0
            for j in window:
                if head in " ".join(norm(" ".join(l["text"] for l in lines[j:j + 2]))):
                    return j, 1.0
            return i, 1.0
        r = difflib.SequenceMatcher(None, target, joined[: len(target) + 40]).ratio()
        if r > best[1]:
            best = (i, r)
    return best

def last_line(lines, phrase, begin=0):
    """The line on which the phrase ends."""
    i, sim = locate(lines, phrase, begin)
    words = norm(phrase)
    tail = " ".join(words[-2:])
    for j in range(i, min(i + 3, len(lines))):
        if tail in " ".join(norm(lines[j]["text"])):
            return j, sim
    return i, sim

def is_filler(line):
    """'Yeah.' 'Uh-huh.' — a beat of the conversation, not the start of anything."""
    return line["end"] - line["start"] <= 1.2 and len(norm(line["text"])) <= 2

def clock(s):
    s = int(round(s)); return f"{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}"

def parse_detect(path):
    out = []
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):([\d.]+)–(\d+):(\d+):([\d.]+)", open(path).read(), re.M):
        k, h1, m1, s1, h2, m2, s2 = m.groups()
        out.append((SKIP_KINDS.get(k, k.upper()), int(h1) * 3600 + int(m1) * 60 + float(s1),
                    int(h2) * 3600 + int(m2) * 60 + float(s2)))
    return out

def parse_work(path):
    m = re.search(r"detection seconds: (\d+) segments: \d+ questions asked: (\d+) answered from cache: (\d+)", open(path).read())
    return tuple(int(g) for g in m.groups()) if m else None

def main():
    lines = json.load(open(sys.argv[1]))
    cuts = parse_detect(sys.argv[2])
    fx = json.load(open(sys.argv[3]))
    tol = fx.get("tolerance_seconds", 2.0)
    end_of_episode = lines[-1]["end"]
    failures = 0
    resolved = []
    dai_path = sys.argv[1].replace("-pub.json", ".json").replace(".json", ".dai.json")
    try:
        dai = json.load(open(dai_path)).get("inserted", [])
    except OSError:
        dai = []
    print(f"{fx['show']} — {fx['episode']}  ({len(cuts)} cuts)")
    cursor = 0
    for r in fx["regions"]:
        def where(key_at, key_after, key_before, edge):
            if key_at in r:
                if edge == "start":
                    i, sim = locate(lines, r[key_at], cursor); return lines[i]["start"], sim
                i, sim = last_line(lines, r[key_at], cursor); return lines[i]["end"], sim
            if key_after in r:
                i, sim = last_line(lines, r[key_after], cursor)
                if edge == "end":
                    return lines[i]["end"], sim
                j = i + 1
                while j < len(lines) and is_filler(lines[j]): j += 1
                return (lines[j]["start"] if j < len(lines) else lines[i]["end"]), sim
            if key_before in r:
                i, sim = locate(lines, r[key_before], cursor)
                if edge == "start":
                    return lines[i]["start"], sim
                return (lines[i - 1]["end"] if i > 0 else lines[i]["start"]), sim
            return None, 1.0
        # Wordless stretches (a theme's instrumental tail, credits music) have
        # no line of their own: "start_at_end_of" starts where a line ends,
        # "end_until" ends where a line starts, so a region can cover the gap.
        if "start_at_end_of" in r:
            i, s1 = last_line(lines, r["start_at_end_of"], cursor); start = lines[i]["end"]
        else:
            start, s1 = (0.0, 1.0) if r.get("start_at_episode_start") else where("start_at", "start_after", "start_before", "start")
        # Either-way regions don't move the search on for the regions after
        # them: they can overlap those, whose anchors may lie before their
        # start. Their own end is still looked for after their start.
        saved = cursor
        if start is not None:
            cursor = max(cursor, next((k for k, l in enumerate(lines) if l["start"] >= start - 0.01), cursor))
        if r.get("end_at_episode_end"):
            end, s2 = end_of_episode, 1.0
        elif "end_until" in r:
            i, s2 = locate(lines, r["end_until"], cursor); end = lines[i]["start"]
        else:
            end, s2 = where("end_at", "end_after", "end_before", "end")
        if r["label"] == "EITHER":
            cursor = saved
        if start is None or end is None or min(s1, s2) < 0.6 or end <= start:
            print(f"  ? {r['id']}: anchors not found in this copy (match {min(s1, s2):.2f})"); failures += 1; continue
        # An inserted ad's true edges are known to the frame when this copy
        # has an ad-free comparison (dai.py map); the anchors only say which one.
        if r.get("delivery") == "inserted" and dai:
            best = max(dai, key=lambda d: min(end + 5, d["end"]) - max(start - 5, d["start"]))
            if min(end + 5, best["end"]) - max(start - 5, best["start"]) > 0:
                start, end = best["start"], best["end"]
        label = r["label"]; ok_labels = {label, *r.get("alt_labels", [])}
        resolved.append({"id": r["id"], "label": label, "start": start, "end": end,
                         "group": r.get("group", r["id"]), "delivery": r.get("delivery")})
        if label == "EITHER":
            print(f"  ---- {r['id']:<16} {label:<17} {clock(start)}–{clock(end)}  (either is fine)"); continue
        # Touching isn't overlapping: the next cut starting where this one ends
        # says nothing about this region.
        overlapping = [c for c in cuts if c[1] < end - 0.5 and c[2] > start + 0.5]
        cut_seconds = sum(min(end, c[2]) - max(start, c[1]) for c in overlapping)
        span = end - start
        slack = r.get("boundary_slack", {})
        if label == "NORMAL":
            passed = cut_seconds <= tol
            verdict = f"{cut_seconds:.0f}s of {span:.0f}s wrongly cut" if cut_seconds > tol else "left alone"
        else:
            covering = [c for c in overlapping if c[0] in ok_labels]
            if not covering:
                wrong = ", ".join(sorted({c[0] for c in overlapping})) or "nothing"
                passed = False; verdict = f"missed (detector said: {wrong})"
            else:
                c0 = min(c[1] for c in covering); c1 = max(c[2] for c in covering)
                ds, de = c0 - start, c1 - end
                passed = (-tol - slack.get("start", 0)) <= ds <= tol and (-tol - slack.get("end", 0)) <= de <= tol + (slack.get("end", 0) if label == "ADVERTISEMENT" else 0)
                verdict = f"start {ds:+.0f}s, end {de:+.0f}s"
        failures += 0 if passed else 1
        print(f"  {'PASS' if passed else 'FAIL'} {r['id']:<16} {label:<17} {clock(start)}–{clock(end)}  {verdict}")
    print(f"{failures} failing")
    import os
    if os.environ.get("SCORE_DUMP"):
        # The regions resolved to times in this copy, for other lab tools.
        json.dump(resolved, open(os.environ["SCORE_DUMP"], "w"), indent=1)
    summary = {"fixture": sys.argv[3].split("/")[-1].replace(".json", ""), "failing": failures,
               "regions": len(resolved), "hours": round(end_of_episode / 3600, 3), "cuts": len(cuts)}
    work = parse_work(sys.argv[2])
    if work:
        secs, asked, cached = work
        fresh = cached <= 0.05 * max(1, asked + cached)     # a repeated question or two is still a fresh run
        summary.update(questions=asked + cached, detect_seconds=secs,
                       work_s_per_hour=round(secs / (end_of_episode / 3600), 1) if fresh else None)
        print(f"work: {secs} s, {asked + cached} questions" +
              (f" = {secs / (end_of_episode / 3600):.0f} s per hour of audio" if fresh else
               f" ({cached} from cache, so no timing)"))
    if fx.get("complete"):
        summary.update(metrics(resolved, cuts, end_of_episode))
    print("SUMMARY " + json.dumps(summary))
    sys.exit(1 if failures else 0)

def iou(a, b):
    inter = max(0.0, min(a[1], b[1]) - max(a[0], b[0]))
    return inter / (max(a[1], b[1]) - min(a[0], b[0]))

def match(truth, cuts):
    """One-to-one greedy matching at IoU >= 0.5 (research §6)."""
    pairs = sorted(((iou((t["start"], t["end"]), (c[1], c[2])), i, j) for i, t in enumerate(truth)
                    for j, c in enumerate(cuts)), reverse=True)
    used_t, used_c, out = set(), set(), []
    for v, i, j in pairs:
        if v < 0.5: break
        if i in used_t or j in used_c: continue
        used_t.add(i); used_c.add(j); out.append((truth[i], cuts[j]))
    return out

def metrics(resolved, cuts, total):
    """Per-cut precision/recall, edge errors, and seconds heard/skipped per hour.

    Only for fixtures marked "complete": every skippable span is labelled, so
    anything unlabelled is conversation.
    """
    truth = [r for r in resolved if r["label"] in SKIP_LABELS]
    either = [r for r in resolved if r["label"] == "EITHER"]
    # Back-to-back pieces of one break share a "group": score breaks too.
    groups = {}
    for r in truth:
        g = groups.setdefault(r["group"], dict(r)); g["start"] = min(g["start"], r["start"]); g["end"] = max(g["end"], r["end"])
    breaks = sorted(groups.values(), key=lambda g: g["start"])
    def only_either(c):
        return any(e["start"] - 2 <= c[1] and c[2] <= e["end"] + 2 for e in either)
    counted = [c for c in cuts if not only_either(c)]
    out = {}
    for name, T in (("ad", truth), ("break", breaks)):
        m = match(T, counted)
        out[f"{name}_precision"] = round(len(m) / len(counted), 3) if counted else None
        out[f"{name}_recall"] = round(len(m) / len(T), 3) if T else None
        out[f"{name}_matched"] = f"{len(m)}/{len(T)} ({len(counted)} cuts)"
        if name == "ad":
            errs = sorted(abs(e) for t, c in m for e in (c[1] - t["start"], c[2] - t["end"]))
            if errs:
                out["edge_median_s"] = round(errs[len(errs) // 2], 2)
                out["edge_p90_s"] = round(errs[min(len(errs) - 1, int(len(errs) * 0.9))], 2)
                out["edges_within_0_5s"] = round(sum(e <= 0.5 for e in errs) / len(errs), 2)
                out["edges_within_3s"] = round(sum(e <= 3 for e in errs) / len(errs), 2)
            missed = [t["id"] for t in T if not any(t is a for a, _ in m)]
            out["missed"] = missed
    # Is each cut on something skippable at all? A break of three ads
    # labelled as one region makes three correct cuts look like one match
    # and two misses above; this asks only whether the cut belongs there.
    allowed = truth + either
    def inside(c):
        covered = sum(max(0.0, min(c[2], r["end"]) - max(c[1], r["start"])) for r in allowed)
        return covered >= 0.8 * (c[2] - c[1])
    out["cuts_on_target"] = f"{sum(inside(c) for c in cuts)}/{len(cuts)}"
    # Time-weighted, on a 0.1 s grid.
    n = int(total * 10) + 1
    want = bytearray(n); fine = bytearray(n); cut = bytearray(n)
    for r in truth:
        for i in range(int(r["start"] * 10), min(n, int(r["end"] * 10))): want[i] = 1
    for r in either:
        for i in range(int(r["start"] * 10), min(n, int(r["end"] * 10))): fine[i] = 1
    for c in cuts:
        for i in range(int(c[1] * 10), min(n, int(c[2] * 10))): cut[i] = 1
    heard = sum(1 for i in range(n) if want[i] and not cut[i] and not fine[i]) / 10
    lost = sum(1 for i in range(n) if cut[i] and not want[i] and not fine[i]) / 10
    h = total / 3600
    out.update(ad_s_heard_per_h=round(heard / h, 1), content_s_skipped_per_h=round(lost / h, 1))
    print(f"per cut: ads {out['ad_matched']} P {out['ad_precision']} R {out['ad_recall']}; on target {out['cuts_on_target']}; "
          f"breaks {out['break_matched']} P {out['break_precision']} R {out['break_recall']}")
    if "edge_median_s" in out:
        print(f"edges: median {out['edge_median_s']} s, p90 {out['edge_p90_s']} s, "
              f"{int(out['edges_within_0_5s'] * 100)}% within 0.5 s, {int(out['edges_within_3s'] * 100)}% within 3 s")
    print(f"per hour: {out['ad_s_heard_per_h']} s of ads heard, {out['content_s_skipped_per_h']} s of show skipped"
          + (f"; missed: {', '.join(out['missed'])}" if out.get("missed") else ""))
    return out

if __name__ == "__main__":
    main()
