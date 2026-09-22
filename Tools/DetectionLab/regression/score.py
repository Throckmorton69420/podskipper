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
              "intro": "INTRO", "outro": "OUTRO"}

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
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):(\d+)–(\d+):(\d+):(\d+)", open(path).read(), re.M):
        k, h1, m1, s1, h2, m2, s2 = m.groups()
        out.append((SKIP_KINDS.get(k, k.upper()), int(h1) * 3600 + int(m1) * 60 + int(s1),
                    int(h2) * 3600 + int(m2) * 60 + int(s2)))
    return out

def main():
    lines = json.load(open(sys.argv[1]))
    cuts = parse_detect(sys.argv[2])
    fx = json.load(open(sys.argv[3]))
    tol = fx.get("tolerance_seconds", 2.0)
    end_of_episode = lines[-1]["end"]
    failures = 0
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
        start, s1 = where("start_at", "start_after", "start_before", "start")
        if start is not None:
            cursor = max(cursor, next((k for k, l in enumerate(lines) if l["start"] >= start - 0.01), cursor))
        if r.get("end_at_episode_end"):
            end, s2 = end_of_episode, 1.0
        else:
            end, s2 = where("end_at", "end_after", "end_before", "end")
        if start is None or end is None or min(s1, s2) < 0.6 or end <= start:
            print(f"  ? {r['id']}: anchors not found in this copy (match {min(s1, s2):.2f})"); failures += 1; continue
        label = r["label"]; ok_labels = {label, *r.get("alt_labels", [])}
        overlapping = [c for c in cuts if c[1] < end and c[2] > start]
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
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
