#!/usr/bin/env python3
"""Pass 57: every engine's cuts on the labelled episodes, as compare.py reads
them ({guid: {name: cuts}}).

    test_cuts.py <out.json> [scope] [reader:<name>=<w1.bin>[:<w2.bin>…][@δ]] [teacher:<name>] [phone]

  reader:…   readers through the app's own Swift reader and detector
             (lab-segments with LAB_TAGGER), so what is scored is what the
             app computes; `@δ` moves the show's logit (frontier.py)
  teacher:…  a teacher's whole-episode reads (teacher_annotate.py)
  phone      each model's newest fresh read on his phone (its own cuts,
             before the cut check; reads that reused earlier parts are left
             out, as episode_eval.py does)
scope: test (default) or all.
"""
import json, os, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import episode_eval  # noqa: E402
import frontier  # noqa: E402
import teacher_annotate  # noqa: E402

rd = frontier.rd


def swift_cuts(k, weights, delta=0.0):
    """Cuts from given weights files, by the Swift reader itself; with a δ,
    the Swift reader's answers are dumped and re-cut at that bias."""
    env = dict(os.environ, LAB_TAGGER=":".join(weights))
    if not delta:
        r = frontier.subprocess.run([rd.BIN, os.path.join(rd.DATA, k + ".json"), "", "", ""], env=env,
                                    capture_output=True, text=True)
        return frontier.parse_cuts(r.stdout)
    dump = os.path.join(rd.DATA, f"{k}.{os.getpid()}.{next(frontier._ids)}.dump.json")
    frontier.subprocess.run([rd.BIN, os.path.join(rd.DATA, k + ".json"), "", "", ""],
                            env=dict(env, LAB_TAGDUMP=dump), capture_output=True, text=True)
    rows = json.load(open(dump)); os.remove(dump)
    return frontier.detect(k, frontier.shifted(rows, delta))


def main():
    out, args = sys.argv[1], sys.argv[2:]
    scope = "test"
    if args and args[0] in ("test", "all"):
        scope = args.pop(0)
    man = corpus.load_manifest()["episodes"]
    labels = frontier.phone_eval.load_labels()
    guids = sorted(g for g, m in man.items() if g in labels and (scope == "all" or m["testEpisode"]))
    rd.BIN = os.path.join(ROOT, "build", "p57", "lab-segments")
    rd.prepare(frontier.RESULTS)
    keys = {e["guid"]: rd.key_of(e) for e in json.load(open(frontier.RESULTS))["episodes"]}
    result = json.load(open(out)) if os.path.exists(out) else {}
    jobs = []
    for spec in args:
        if spec.startswith("reader:"):
            name, files = spec[7:].split("=", 1)
            files, _, delta = files.partition("@")
            weights = [os.path.abspath(w) for w in files.split(":")]
            for g in guids:
                if name not in result.get(g, {}):
                    jobs.append((g, name, weights, float(delta or 0)))
        elif spec.startswith("teacher:"):
            name = spec[8:]
            for g in guids:
                p = os.path.join(teacher_annotate.OUT, name, g + ".json")
                if os.path.exists(p):
                    result.setdefault(g, {})["teacher " + name] = teacher_annotate.cuts(json.load(open(p)))
        elif spec == "phone":
            _, best = episode_eval.load_attempts()[:2]
            for g in guids:
                for engine, a in best.get(g, {}).items():
                    own = a.get("proposedCuts") or (a.get("savedCuts") if engine == "Apple Intelligence" else None)
                    if own is None:
                        continue
                    result.setdefault(g, {})["phone " + engine] = [[c["start"], c["end"], c["kind"]] for c in own]

    def run(job):
        g, name, weights, delta = job
        return g, name, swift_cuts(keys[g], weights, delta)
    with ThreadPoolExecutor(8) as ex:
        for g, name, cuts in ex.map(run, jobs):
            result.setdefault(g, {})[name] = cuts
    json.dump(result, open(out, "w"))
    names = sorted({n for v in result.values() for n in v})
    for n in names:
        print(f"{n:40} {sum(1 for v in result.values() if n in v)} episodes")


if __name__ == "__main__":
    main()
