#!/usr/bin/env python3
"""Pass 63: real timing for Compare Models' made-up Basic and Hard samples.

Reads a results export (transcripts with word times) and the labels in
Tools/DetectionLab/phone-labels, and writes Services/LocalModel/BenchTimings.swift:
for each kind of speech (show talk, host-read ad, recorded spot, plug, another
show's promo, intro, credits) the pause before each line and its speaking rate
(words per second), taken line after line from real stretches of that kind, and
the pauses at the start and end of real breaks. Numbers only: no words, titles
or show names leave the export (the repository is public).

  python3 -I Tools/ReaderData/bench_timing.py <results.json> [out.swift]
"""
import glob, json, os, random, sys

KINDS = ["talk", "hostRead", "spot", "plug", "promo", "intro", "credits"]
PER_KIND = 96


def kind_of(region):
    label = region.get("label", "")
    if label == "AD":
        return "spot" if region.get("delivery") == "produced" else "hostRead"
    if label in ("SELF", "SELFPROMO", "GUESTPLUG", "PLUG"):
        return "plug"
    if label in ("NETWORK", "CROSSPROMO"):
        return "promo"
    if label == "INTRO":
        return "intro"
    if label in ("OUTRO", "CREDITS"):
        return "credits"
    return None


def rows(lines, first, last):
    out = []
    for i in range(first, last + 1):
        line = lines[i]
        n = len(line["text"].split())
        seconds = line["end"] - line["start"]
        if n < 2 or seconds <= 0.2:
            continue
        gap = line["start"] - lines[i - 1]["end"] if i > 0 else 0.0
        out.append((round(min(4.0, max(0.0, gap)), 2), round(min(5.0, max(1.6, n / seconds)), 2)))
    return out


def main():
    export = json.load(open(sys.argv[1]))
    out_path = sys.argv[2] if len(sys.argv) > 2 else "Services/LocalModel/BenchTimings.swift"
    episodes = {e["guid"]: e for e in export["episodes"] if e.get("transcript")}
    stretches = {k: [] for k in KINDS}
    edges_in, edges_out = [], []
    used = 0
    for path in sorted(glob.glob("Tools/DetectionLab/phone-labels/*.json")):
        label = json.load(open(path))
        episode = episodes.get(label.get("guid", ""))
        if not episode:
            continue
        lines = episode["transcript"]
        used += 1
        taken = set()
        for region in label.get("regions", []):
            kind = kind_of(region)
            a, b = region.get("lines", [0, -1])
            if kind is None or b >= len(lines) or a > b:
                continue
            taken.update(range(a, b + 1))
            got = rows(lines, a, b)
            if len(got) >= 3:
                stretches[kind].append(got)
            if a > 0:
                edges_in.append(round(min(4.0, max(0.0, lines[a]["start"] - lines[a - 1]["end"])), 2))
            if b + 1 < len(lines):
                edges_out.append(round(min(4.0, max(0.0, lines[b + 1]["start"] - lines[b]["end"])), 2))
        # Show talk: runs of at least 24 unlabelled lines, away from any break.
        run = []
        for i in range(len(lines)):
            if i in taken or any((i + d) in taken for d in (-3, -2, -1, 1, 2, 3)):
                if len(run) >= 24:
                    stretches["talk"].append(rows(lines, run[0], run[-1]))
                run = []
            else:
                run.append(i)
    rng = random.Random(63)
    tables = {}
    for kind in KINDS:
        pool = stretches[kind][:]
        rng.shuffle(pool)
        table = []
        for stretch in pool:
            start = rng.randrange(max(1, len(stretch) - 23)) if kind == "talk" else 0
            table += stretch[start:start + (24 if kind == "talk" else 16)]
            if len(table) >= PER_KIND:
                break
        tables[kind] = table[:PER_KIND]
    rng.shuffle(edges_in)
    rng.shuffle(edges_out)
    with open(out_path, "w") as f:
        f.write("import Foundation\n\n")
        f.write("/// Pass 63: real timing for the made-up Basic and Hard samples — written by\n")
        f.write("/// `Tools/ReaderData/bench_timing.py` from %d of his labelled episodes. For each\n" % used)
        f.write("/// kind of speech, the pause before a line and its speaking rate (words per\n")
        f.write("/// second), line after line as real stretches of that kind ran; and the pauses\n")
        f.write("/// where real breaks began and ended. Numbers only.\n")
        f.write("enum BenchTimings {\n")
        f.write("    struct Beat: Sendable { var gap: Double; var rate: Double }\n\n")
        for kind in KINDS:
            f.write("    static let %s: [Beat] = [\n" % kind)
            row = []
            for gap, rate in tables[kind]:
                row.append("Beat(gap: %s, rate: %s)" % (gap, rate))
                if len(row) == 4:
                    f.write("        " + ", ".join(row) + ",\n")
                    row = []
            if row:
                f.write("        " + ", ".join(row) + ",\n")
            f.write("    ]\n\n")
        f.write("    /// The pause before a real break's first line, and after its last.\n")
        f.write("    static let breakStarts: [Double] = %s\n" % json.dumps(edges_in[:48]))
        f.write("    static let breakEnds: [Double] = %s\n" % json.dumps(edges_out[:48]))
        f.write("}\n")
    for kind in KINDS:
        t = tables[kind]
        if t:
            print(kind, len(stretches[kind]), "stretches ->", len(t), "beats; mean gap %.2f rate %.2f" % (
                sum(g for g, _ in t) / len(t), sum(r for _, r in t) / len(t)))
    print("break starts mean %.2f, ends mean %.2f (%d, %d)" % (
        sum(edges_in) / max(1, len(edges_in)), sum(edges_out) / max(1, len(edges_out)), len(edges_in), len(edges_out)))


if __name__ == "__main__":
    main()
