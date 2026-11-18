#!/usr/bin/env python3
"""Pass 67: a two-family agreement teacher — only the stretches two teachers both call skippable, of the same kind.

    teacher_agree.py <teacher A> <teacher B> <out name>

Reads build/p57/teachers/<A>/<guid>.json and <B>/<guid>.json (distill_reader.py collect records) and writes
build/p57/teachers/<out>/<guid>.json for every episode both read: each part of A that overlaps a part of B of the
same group becomes the overlap (later start, earlier end; lines likewise), labelled as A labelled it, confidence the
lower of the two. Groups: ad (PAID_AD, HOST_READ_AD, NETWORK_PROMO), plug (SELF_PROMO, GUEST_PLUG), INTRO,
outro (OUTRO, CREDITS). MOCK_AD and RECURRING_SEGMENT are never skipped and are dropped. The result is scored like
any teacher (check_sweep.py teacher:<out> test) and, for silver labels, read by silver.py like any teacher.
"""
import json, os, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TEACHERS = os.path.join(ROOT, "build", "p57", "teachers")
GROUP = {"PAID_AD": "ad", "HOST_READ_AD": "ad", "NETWORK_PROMO": "ad", "SELF_PROMO": "plug", "GUEST_PLUG": "plug",
         "INTRO": "intro", "OUTRO": "outro", "CREDITS": "outro"}


def main():
    a, b, out = sys.argv[1:4]
    da, db, do = (os.path.join(TEACHERS, x) for x in (a, b, out))
    os.makedirs(do, exist_ok=True)
    n = kept = parts_a = 0
    for name in sorted(os.listdir(da)):
        if not name.endswith(".json") or not os.path.exists(os.path.join(db, name)):
            continue
        ra, rb = json.load(open(os.path.join(da, name))), json.load(open(os.path.join(db, name)))
        if "found" not in ra or "found" not in rb:
            continue
        found = []
        for p in ra["found"]:
            g = GROUP.get(p["label"])
            if not g:
                continue
            parts_a += 1
            for q in rb["found"]:
                if GROUP.get(q["label"]) != g:
                    continue
                s, e = max(p["start"], q["start"]), min(p["end"], q["end"])
                if e - s < 1.0:
                    continue
                found.append(dict(p, start=s, end=e, firstLine=max(p["firstLine"], q["firstLine"]),
                                  lastLine=min(p["lastLine"], q["lastLine"]),
                                  confidence=min(p.get("confidence", 0), q.get("confidence", 0)),
                                  why=f"agreed: {p.get('why', '')} | {q.get('why', '')}"[:400]))
        found.sort(key=lambda x: x["start"])
        # The app's check (lab-cutcheck) reads the raw window answers and parses them as the phone does: the
        # agreed parts go back as one answer over the whole episode (line numbers are the episode's own).
        last = max([w["last"] for w in ra.get("answers") or []] + [q["lastLine"] for q in found] + [0])
        text = json.dumps({"parts": [{"first_line": q["firstLine"], "last_line": q["lastLine"], "label": q["label"],
                                      "sponsor": q.get("sponsor", ""), "funny": bool(q.get("funny")),
                                      "confidence": q.get("confidence", 0), "why": q.get("why", "")} for q in found]})
        rec = dict(ra, found=found, parts=len(found), answers=[{"first": 0, "last": last, "text": text}],
                   teacher=dict(ra.get("teacher") or {}, name=out, variant=f"agreement of {a} and {b}"))
        json.dump(rec, open(os.path.join(do, name), "w"), indent=1)
        n += 1
        kept += len(found)
    print(f"{out}: {n} episodes both read; {kept} agreed parts from {parts_a} skippable parts of {a}")


if __name__ == "__main__":
    main()
