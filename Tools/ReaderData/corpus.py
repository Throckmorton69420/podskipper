#!/usr/bin/env python3
"""Pass 57: one manifest of every transcript the Reader can learn from or be
judged on, with where each came from, which copies are the same episode, and
which split it belongs to — so no training run can see a test episode, a
copy of one, or (for show-held-out folds) any episode of a held-out show.

    corpus.py build            → build/p57/corpus/manifest.json
    corpus.py check <tag dir>  checks a run's training log against the manifest

Sources, in order of trust:
  his        what he reviewed on his phone (locked / confirmed / added /
             "not an ad"), carried in every export
  labelled   Tools/DetectionLab/phone-labels/ (Claude-labelled from the
             transcript, label policy in Tools/ReaderData/LABEL-POLICY.md)
  lab        build/lab fixtures (Claude-labelled, pass 25)
  teacher    build/p57/teachers/… (model reads; never labels by themselves)
  external   ~/Developer/pk-data/sponsorblock/episodes.json (CC BY-NC-SA 4.0
             segment times on YouTube audio transcribed here; offline only)

Duplicates: the same guid in several exports is one episode (the newest
export with a transcript is used; line numbers in labels index that export,
and the phone never transcribes an episode twice). Different guids with the
same normalised title, or transcripts whose first 40 sentences match, are
one episode too (reruns, the same file in two feeds) and share a split.

Splits:
  test-episode  labelled episodes the shipped readers never trained on
                (labelled after pass 44 and absent from the exports they
                were trained from) — the like-for-like test against the
                shipped Reader
  fold-0/1/2    show groups for show-held-out folds (reader_distill.py
                show_groups: largest show first, balanced by episodes)
"""
import collections, glob, gzip, hashlib, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import phone_eval  # noqa: E402
import tagger  # noqa: E402

OUT = os.path.join(ROOT, "build", "p57", "corpus")
SHIPPED_TRAINED_THROUGH = 44
# The exports the shipped readers (Pass 44, 20 Oct) could have read
# agreement labels from: every export dated on or before 20 Oct.
SHIPPED_EXPORT_DIRS = ("phone-1014", "phone-1015", "phone-1015b", "phone-1016", "phone-1018", "phone-1019",
                       "phone-1020")


def norm(t):
    return re.sub(r"[^a-z0-9]", "", t.lower())[:30]


def show_key(name):
    return re.sub(r"[^a-z0-9]", "", (name or "").lower())


def export_files():
    paths = []
    for d in sorted(glob.glob(os.path.join(ROOT, "build", "phone-*")), reverse=True):
        paths += sorted(glob.glob(os.path.join(d, "*results*.json")), reverse=True)
    return paths


def load(path):
    return json.load(gzip.open(path) if path.endswith(".gz") else open(path))


def transcript_hash(lines):
    h = hashlib.sha256()
    for l in lines:
        h.update(f"{l['start']:.2f}|{l['text']}\n".encode())
    return h.hexdigest()[:16]


def head_print(lines):
    return hashlib.sha256(" ".join(norm(l["text"]) for l in lines[:40]).encode()).hexdigest()[:12]


def label_pass(label):
    m = re.search(r"pass (\d+)", label.get("labelled_by", ""))
    return int(m.group(1)) if m else 0


def build():
    labels = phone_eval.load_labels()
    episodes, seen_in = {}, collections.defaultdict(list)
    for path in export_files():
        data = load(path)
        rel = os.path.relpath(path, ROOT)
        for idx, e in enumerate(data["episodes"]):
            if not e.get("transcript"):
                continue
            seen_in[e["guid"]].append(rel)
            if e["guid"] in episodes:
                continue   # newest export first
            lines = e["transcript"]
            his = [s for s in e.get("segments", []) if tagger.reviewed(s)]
            episodes[e["guid"]] = {
                "guid": e["guid"], "show": e.get("show", ""), "showKey": show_key(e.get("show", "")),
                "title": e["title"], "source": rel, "index": idx, "build": data.get("build"),
                "lines": len(lines), "hours": round(lines[-1]["end"] / 3600, 3),
                "transcriptHash": transcript_hash(lines), "headPrint": head_print(lines),
                "his": len(his), "attempts": sorted({a.get("method", "") for a in e.get("attempts") or []
                                                     if not a.get("method", "").startswith("PodSkipper reader (")}),
            }
    # One episode, several guids: same title or same opening.
    groups, by_title, by_head = {}, {}, {}
    for g, m in sorted(episodes.items()):
        key = by_title.get(norm(m["title"])) or by_head.get(m["headPrint"]) or g
        groups[g] = key
        by_title.setdefault(norm(m["title"]), key)
        by_head.setdefault(m["headPrint"], key)
    for g, m in episodes.items():
        m["copyOf"] = groups[g] if groups[g] != g else None
        m["seenIn"] = seen_in[g]
        lab = labels.get(g)
        m["labelled"] = bool(lab)
        if lab:
            m["labelPass"] = label_pass(lab)
            m["labelledBy"] = lab.get("labelled_by", "")
            m["labelVersion"] = lab.get("policy", 1)
    # Show-held-out fold groups, exactly as reader_distill.show_groups.
    labelled = sorted(g for g in episodes if episodes[g]["labelled"])
    by = collections.defaultdict(list)
    for g in labelled:
        by[episodes[g]["showKey"]].append(g)
    folds = [[] for _ in range(3)]
    for show, gs in sorted(by.items(), key=lambda kv: (-len(kv[1]), kv[0])):
        min(folds, key=lambda x: sum(len(by[s]) for s in x)).append(show)
    fold_of = {s: f for f, shows in enumerate(folds) for s in shows}
    for g, m in episodes.items():
        m["fold"] = fold_of.get(m["showKey"])
        shipped_could_see = any(os.path.basename(os.path.dirname(p)) in SHIPPED_EXPORT_DIRS for p in m["seenIn"])
        m["shippedCouldSee"] = shipped_could_see
        m["testEpisode"] = bool(m["labelled"] and m["labelPass"] > SHIPPED_TRAINED_THROUGH and not shipped_could_see)
    # A copy shares its original's test membership.
    for g, m in episodes.items():
        if m["copyOf"] and episodes[m["copyOf"]].get("testEpisode"):
            m["testEpisode"] = True
    ext_path = os.path.expanduser("~/Developer/pk-data/sponsorblock/episodes.json")
    external = []
    if os.path.exists(ext_path):
        for ep in json.load(open(ext_path)):
            external.append({"guid": ep["guid"], "show": ep["show"], "title": ep["title"], "genre": ep.get("genre"),
                             "source": ep.get("source"), "license": ep.get("license"),
                             "sentences": len(ep["sents"]), "labelledSentences": sum(1 for l in ep["labels"] if l)})
    lab = []
    for k in tagger.KEYS:
        if os.path.exists(os.path.join(tagger.LAB, k + ".json")):
            ep = tagger.lab_episode(k)
            lab.append({"key": k, "title": ep["title"], "group": tagger.group_of(k),
                        "showWords": tagger.SHOWWORDS.get(tagger.group_of(k))})
    manifest = {"folds": folds, "episodes": episodes, "lab": lab, "external": external,
                "shippedTrainedThrough": SHIPPED_TRAINED_THROUGH}
    os.makedirs(OUT, exist_ok=True)
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"), indent=1)
    eps = list(episodes.values())
    print(f"{len(eps)} episodes ({sum(m['hours'] for m in eps):.1f} h) from {len(export_files())} exports; "
          f"{sum(1 for m in eps if m['labelled'])} labelled, {sum(1 for m in eps if m['testEpisode'])} test-episode, "
          f"{sum(1 for m in eps if m['copyOf'])} copies, {sum(m['his'] for m in eps)} of his reviews; "
          f"lab {len(lab)}, external {len(external)}")
    for f, shows in enumerate(folds):
        n = [m for m in eps if m["fold"] == f]
        print(f"fold {f}: {len(shows)} shows, {sum(1 for m in n if m['labelled'])} labelled + "
              f"{sum(1 for m in n if not m['labelled'])} unlabelled episodes")
    test = [m for m in eps if m["testEpisode"]]
    print("test-episode:", ", ".join(f"{m['title'][:28]} ({m['show'][:16]})" for m in test))
    print("labelled after pass 44 but in the shipped readers' exports:",
          sum(1 for m in eps if m["labelled"] and m["labelPass"] > SHIPPED_TRAINED_THROUGH and m["shippedCouldSee"]))


def load_manifest():
    return json.load(open(os.path.join(OUT, "manifest.json")))


if __name__ == "__main__":
    if sys.argv[1:2] == ["build"]:
        build()
    else:
        raise SystemExit(__doc__)
