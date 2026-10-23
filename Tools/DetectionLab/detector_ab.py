#!/usr/bin/env python3
"""Pass 46: the app's detector (two `lab-segments` builds) over every labelled
phone episode, scored against the labels — for a change to a detector stage.

    detector_ab.py <out dir> <name>=<lab-segments binary> [<name>=<binary> ...]

Each labelled episode is taken from the newest export in build/phone-*/ that
has it. The Reader's probabilities are Pass 44's held-out fold readers
(build/p45/heldout/<key>.rows.json: readers that never saw the episode) where
they exist, else the shipped readers (in-sample: fine for comparing two
detector builds, not for the Reader itself). LAB_PRODUCED is not used: his
exports carry no fingerprints. Writes <out>/cuts.json ({guid: {name: cuts}},
the `phone_eval.py --cuts` shape) and prints `reader_distill.summary`'s table
for both reader sources together, then the held-out episodes alone.

Run with ~/Developer/pk-ml/bin/python -I (numpy).
"""
import concurrent.futures, glob, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import phone_eval  # noqa: E402
import reader_distill as rd  # noqa: E402

SHIPPED = ":".join(rd.SHIPPED)
HELD = os.path.join(ROOT, "build", "p45", "heldout")


def exports():
    return sorted(glob.glob(os.path.join(ROOT, "build", "phone-*", "results.json")), reverse=True)


def episodes_by_guid(wanted):
    found = {}
    for path in exports():
        for e in json.load(open(path))["episodes"]:
            if e["guid"] in wanted and e["guid"] not in found and e.get("transcript"):
                found[e["guid"]] = e
    return found


def run(binary, transcript, rows):
    env = dict(os.environ, LAB_TAGGER=SHIPPED)
    if rows:
        env["LAB_TAGPROBS"] = rows
    r = subprocess.run([binary, transcript, "", "", ""], env=env, capture_output=True, text=True)
    cuts = []
    for m in re.finditer(r"^\[(\w+)\] (\d+):(\d+):([\d.]+)–(\d+):(\d+):([\d.]+)", r.stdout, re.M):
        kind, h1, m1, s1, h2, m2, s2 = m.groups()
        cuts.append([int(h1) * 3600 + int(m1) * 60 + float(s1), int(h2) * 3600 + int(m2) * 60 + float(s2), kind])
    return cuts


def main():
    out, builds = sys.argv[1], dict(a.split("=", 1) for a in sys.argv[2:])
    os.makedirs(out, exist_ok=True)
    labels = phone_eval.load_labels()
    eps = episodes_by_guid(set(labels))
    merged = os.path.join(out, "episodes.json")
    json.dump({"episodes": list(eps.values())}, open(merged, "w"))
    jobs = []
    for guid, e in eps.items():
        key = rd.key_of(e)
        transcript = os.path.join(out, key + ".json")
        json.dump([{"text": l["text"], "start": l["start"], "end": l["end"], "words": l.get("words") or []}
                   for l in e["transcript"]], open(transcript, "w"))
        rows = os.path.join(HELD, key + ".rows.json")
        for name, binary in builds.items():
            jobs.append((guid, name, binary, transcript, rows if os.path.exists(rows) else None))
    scored, held = {}, set()
    with concurrent.futures.ThreadPoolExecutor(max_workers=int(os.environ.get("PAR", "6"))) as pool:
        futures = {pool.submit(run, b, t, r): (g, n, r) for g, n, b, t, r in jobs}
        for f in concurrent.futures.as_completed(futures):
            g, n, r = futures[f]
            scored.setdefault(g, {})[n] = f.result()
            if r:
                held.add(g)
    json.dump(scored, open(os.path.join(out, "cuts.json"), "w"))
    print(f"{len(scored)} episodes ({len(held)} with held-out readers)")
    print(rd.summary(scored, merged))
    print("\nheld-out readers only:")
    print(rd.summary({g: s for g, s in scored.items() if g in held}, merged))


if __name__ == "__main__":
    main()
