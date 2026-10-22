#!/usr/bin/env python3
"""Pass 44: write one phone-labels file from a compact spec.

    write_label.py <results.json> <guid> <spec file or ->

LABEL_WHEN="pass 45, 22 Oct 2026" names the pass in the file (default Pass 44).

Spec lines: `LABEL a-b [sponsor words…] [|delivery] [#note]` (one region per
line; a gap between two lines is `LABEL gap a-b`). Labels: AD SELF NETWORK
INTRO OUTRO EITHER. Line numbers index that export's transcript.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    results, guid, spec = sys.argv[1], sys.argv[2], sys.argv[3]
    d = json.load(open(results))
    e = next(e for e in d["episodes"] if e["guid"] == guid)
    text = sys.stdin.read() if spec == "-" else open(spec).read()
    regions, n = [], 0
    for raw in text.splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("//"):
            continue
        note = ""
        if "#" in raw:
            raw, note = raw.split("#", 1)
        delivery = ""
        if "|" in raw:
            raw, delivery = raw.split("|", 1)
        parts = raw.split()
        label = parts[0]
        assert label in ("AD", "SELF", "NETWORK", "INTRO", "OUTRO", "EITHER"), label
        gap = parts[1] == "gap"
        a, b = map(int, parts[2 if gap else 1].split("-"))
        assert 0 <= a <= b < len(e["transcript"]), (a, b)
        sponsor = " ".join(parts[3 if gap else 2:])
        n += 1
        r = {"id": f"r{n}", "label": label, ("gap" if gap else "lines"): [a, b]}
        if sponsor: r["sponsor"] = sponsor
        if delivery.strip(): r["delivery"] = delivery.strip()
        if note.strip(): r["note"] = note.strip()
        regions.append(r)
    when = os.environ.get("LABEL_WHEN", "pass 44, 20 Oct 2026")
    out = {"show": e["show"], "episode": e["title"], "guid": guid,
           "source": f"{os.path.basename(results)} ({d.get('build')}, {when.split(', ', 1)[-1]}); line numbers index that export's transcript",
           "labelled_by": f"Claude-labelled ({when}) from the phone transcript around every engine's cuts and every selling word; not his decisions",
           "regions": regions}
    name = re.sub(r"[^A-Za-z0-9_.@-]+", "_", guid) + ".json"
    json.dump(out, open(os.path.join(HERE, "phone-labels", name), "w"), indent=1)
    print(name, len(regions), "regions")


if __name__ == "__main__":
    main()
