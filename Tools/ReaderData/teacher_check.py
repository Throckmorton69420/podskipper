#!/usr/bin/env python3
"""Pass 65: a teacher's saved whole-episode answers put through the app's own
cut check — JudgePrompt's reading, LocalJudge.merge, ModelFinder.checkedCuts →
ModelCutCheck, with the Reader's show probabilities so Pass 64's
vetoConversation runs as it does in ProcessingPipeline — and scored with the
PodSkipper test. No new model reads: the answers are the teacher's records
(build/p57/teachers/<teacher>/<guid>.json, e.g. the 27B's Kaggle answers).

    teacher_check.py <teacher> [test|all]

Cuts per episode → build/p65/teacher-check-<teacher>.json ({guid: {name: cuts}}):
  alone        the teacher's cuts as the app reads them, before the check
  checked      after the check with the veto (the app: show >= 0.9)
  checked-85   the veto at show >= 0.85 (LAB_SHOWSURE)
  noveto       after the check without the veto (LAB_VETO=0)
  reader       the Reader's own cuts (the shipped pair, LAB_TAGGER)
then the PodSkipper test of each (build/p65/teacher-check-<teacher>-<scope>.txt).
The check sees the transcript only (no audio evidence or silences), as
test_cuts.py's Reader runs do.
"""
import json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import frontier  # noqa: E402
import teacher_annotate  # noqa: E402

rd = frontier.rd
BIN = os.path.join(ROOT, "build", "p65", "lab-cutcheck")
SHIPPED = ":".join(os.path.join(ROOT, "Resources", "Detection", f) for f in ("TaggerWeights.bin", "TaggerWeights-2.bin"))
MODES = {"checked": {}, "checked-85": {"LAB_SHOWSURE": "0.85"}, "noveto": {"LAB_VETO": "0"}}


def check(transcript, record, extra):
    env = dict(os.environ, LAB_TAGGER=os.environ.get("LAB_TAGGER", SHIPPED), **extra)
    r = subprocess.run([BIN, transcript, record], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"lab-cutcheck failed on {record}: {r.stderr[-400:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def main():
    if len(sys.argv) < 2 or not os.path.exists(BIN):
        raise SystemExit(__doc__ + f"\n(build {BIN} as LabCutCheck.swift's header says)")
    name, scope = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "test")
    man = corpus.load_manifest()["episodes"]
    labels = frontier.phone_eval.load_labels()
    guids = sorted(g for g, m in man.items() if g in labels and (scope == "all" or m["testEpisode"])
                   and os.path.exists(teacher_annotate.record_path(name, g)))
    keys = {e["guid"]: rd.key_of(e) for e in json.load(open(frontier.RESULTS))["episodes"]}
    jobs = [(g, mode) for g in guids for mode in MODES]

    def run(job):
        g, mode = job
        out = check(os.path.join(rd.DATA, keys[g] + ".json"), teacher_annotate.record_path(name, g), MODES[mode])
        return g, mode, out

    cuts, notes = {}, {}
    with ThreadPoolExecutor(4) as ex:
        for g, mode, out in ex.map(run, jobs):
            rows = lambda key: [[c[0], c[1], c[2]] for c in out[key]]
            cuts.setdefault(g, {})[mode] = rows("checked")
            cuts[g]["alone"], cuts[g]["reader"] = rows("proposed"), rows("reader")
            notes.setdefault(g, {})[mode] = out["notes"]
    path = os.path.join(ROOT, "build", "p65", f"teacher-check-{name}.json")
    old = json.load(open(path)) if os.path.exists(path) else {}
    old.update(cuts)
    json.dump(old, open(path, "w"))
    json.dump(notes, open(path.replace(".json", "-notes.json"), "w"), indent=1)
    specs = [f"{name}-{k}={path}:{k}" for k in ("reader", "alone", "noveto", "checked", "checked-85")]
    text = subprocess.run([sys.executable, "-I", os.path.join(HERE, "podtest.py"), "test" if scope == "test" else "folds",
                           *specs], capture_output=True, text=True, cwd=ROOT).stdout
    report = os.path.join(ROOT, "build", "p65", f"teacher-check-{name}-{scope}.txt")
    open(report, "w").write(text)
    print(f"{len(guids)} episodes → {path}\n{text}")


if __name__ == "__main__":
    main()
