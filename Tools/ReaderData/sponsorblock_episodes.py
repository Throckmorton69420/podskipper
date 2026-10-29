#!/usr/bin/env python3
"""Pass 53: SponsorBlock picks → Reader training episodes.

    sponsorblock_episodes.py <pick dir>     writes <pick dir>/episodes.json

Each pick's audio was transcribed on the Mac by the app's own
TranscriptionService (`lab-transcribe`), so its sentences are the ones the
phone would make. Sentences are labelled from SponsorBlock's human-set
times (CC BY-NC-SA 4.0; provenance per episode in picks.json):

  sponsor → A   selfpromo, interaction → S   intro → I   outro → O
  preview, filler → left out (neither cut nor show for this Reader)

Sentences straddling a segment edge (less than ¾ on one side) are left out:
their label is the boundary itself. Unlabelled sentences are the show, but
only where nothing sells in them: SponsorBlock users mark what they skip,
not everything, so an unmarked "use code …" may be an ad nobody marked.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "DetectionLab"))
import tagger  # noqa: E402

KIND = {"sponsor": "A", "selfpromo": "S", "interaction": "S", "intro": "I", "outro": "O",
        "preview": None, "filler": None}
SELLS = re.compile(r"promo code|use code|offer code|\.com|dot com|slash|sponsor|brought to you|support for|"
                   r"free trial|% off|percent off|terms apply|patreon|merch|subscribe|link in|description|"
                   r"first order|free shipping|tickets|on sale|sign up|download the", re.I)


def label(sents, segments):
    out = []
    for s in sents:
        a, b = s["start"], s["end"]
        length = max(0.01, b - a)
        letter, best = "C", 0.0
        for g in segments:
            cover = max(0.0, min(b, g["end"]) - max(a, g["start"])) / length
            if cover > best:
                best, letter = cover, KIND.get(g["category"], None)
        if 0.25 < best < 0.75:
            out.append(None)
        elif best >= 0.75:
            out.append(letter)
        else:
            out.append(None if SELLS.search(s["text"]) else "C")
    return out


def main():
    root = sys.argv[1]
    picks = json.load(open(os.path.join(root, "picks.json")))
    eps, counts = [], {}
    for vid, p in picks.items():
        path = os.path.join(root, "tx", vid + ".json")
        if not os.path.exists(path):
            continue
        lines = json.load(open(path))
        sents = tagger.sentences(lines)
        if len(sents) < 50:
            continue
        letters = label(sents, p["segments"])
        for l in letters:
            counts[l or "-"] = counts.get(l or "-", 0) + 1
        eps.append({"key": f"external:{vid}", "guid": f"sponsorblock:{vid}", "title": p["title"],
                    "show": "YouTube @" + p["channel"], "genre": p["genre"], "sents": sents, "labels": letters,
                    "source": p["source"], "license": p["labels"]})
    json.dump(eps, open(os.path.join(root, "episodes.json"), "w"))
    print(len(eps), "episodes", counts)


if __name__ == "__main__":
    main()
