#!/usr/bin/env python3
"""Pass 66: the cut check's rules compared on saved model answers — a teacher's
whole-episode reads (build/p57/teachers/<name>/) or every model's newest fresh
read on his phone (the exports' `proposedCuts`) — put through the app's own
check (lab-cutcheck: JudgePrompt's reading, ModelFinder.checkedCuts →
ModelCutCheck.verify with the Reader's show probabilities) once per mode, and
scored with the PodSkipper test. No model reads anything here.

    check_sweep.py teacher:<name>|phone [test|folds|all] [--probs <run dir>]
                   [--mode name[:ENV=V,ENV=V…]]… [--bin <lab-cutcheck>] [--tag <t>]

scope  test   his 11 test episodes; the Reader is the shipped pair (it never
              trained on them)
       folds  the other labelled episodes (60); pass --probs <run dir> with
              show-held-out Reader answers (build/p58/ext13, or an average
              made by build/p66/avgprobs.py) — the shipped pair trained on
              these episodes, so its own probabilities there prove nothing
       all    both, each read as above
mode   a name and lab-cutcheck's switches for it (LAB_VETO, LAB_SHOWSURE,
       LAB_EDGEVETO, LAB_EDGEPROVED, LAB_UNION…). Default: p64 (the check as
       Pass 64 shipped it), p66 (as it is now), noveto.

Prints, per mode: Everyday (shows weighted alike; for `phone`, the mean over
reads), show cut and skippable heard in s/h, breaks noticed; the Reader's own
cuts and the model alone are the first two rows. Cuts →
build/p66/sweep-<tag>.json ({mode: {item: cuts}}).
"""
import argparse, collections, json, os, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ROOT = os.path.dirname(ROOT)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "ReaderData"))
os.environ.setdefault("READER_OUT", "p66")
import corpus  # noqa: E402
import episode_eval  # noqa: E402
import frontier  # noqa: E402
import phone_eval  # noqa: E402
import podtest  # noqa: E402
import reader_consensus as rc  # noqa: E402
import teacher_annotate  # noqa: E402

rd = frontier.rd
SHIPPED = ":".join(rd.SHIPPED)
DEFAULT_MODES = ["p64:LAB_EDGEVETO=0", "p66", "noveto:LAB_VETO=0"]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("source")
    p.add_argument("scope", nargs="?", default="test", choices=["test", "folds", "all"])
    p.add_argument("--probs")
    p.add_argument("--mode", action="append")
    p.add_argument("--bin", default=os.path.join(ROOT, "build", "p66", "lab-cutcheck"))
    p.add_argument("--tag")
    p.add_argument("--shows", action="store_true", help="Everyday per show for each mode")
    a = p.parse_args()
    if not os.path.exists(a.bin):
        raise SystemExit(f"build {a.bin} first (the command is in LabCutCheck.swift's header)")
    modes = collections.OrderedDict()
    for spec in a.mode or DEFAULT_MODES:
        name, _, env = spec.partition(":")
        modes[name] = dict(kv.split("=", 1) for kv in env.split(",") if kv)
    man = corpus.load_manifest()["episodes"]
    labels = phone_eval.load_labels()
    wanted = {g for g, m in man.items() if g in labels and (a.scope == "all" or (a.scope == "test") == bool(m["testEpisode"]))}
    if a.scope != "test" and not a.probs:
        raise SystemExit("fold episodes need --probs <run dir> (show-held-out Reader answers)")
    rd.prepare(frontier.RESULTS)
    exported = {e["guid"]: e for e in json.load(open(frontier.RESULTS))["episodes"]}
    work = tempfile.mkdtemp(prefix="check-sweep-")

    # Items: (item id, guid, answers file).
    items = []
    if a.source.startswith("teacher:"):
        name = a.source[8:]
        for g in sorted(wanted):
            path = teacher_annotate.record_path(name, g)
            if os.path.exists(path) and g in exported:
                items.append((g, g, path))
    elif a.source == "phone":
        _, best, _ = episode_eval.load_attempts()
        for g in sorted(wanted):
            for engine, attempt in sorted(best.get(g, {}).items()):
                own = attempt.get("proposedCuts")
                if own is None or g not in exported:
                    continue
                path = os.path.join(work, f"{len(items)}.json")
                json.dump({"proposed": own}, open(path, "w"))
                items.append((f"{g}|{engine}", g, path))
    else:
        raise SystemExit("source: teacher:<name> or phone")
    if not items:
        raise SystemExit("nothing to check in that scope")

    def probs_file(g):
        if not a.probs or man[g]["testEpisode"]:
            return None
        d = a.probs if os.path.basename(a.probs) == "probs" else os.path.join(a.probs, "probs")
        f = os.path.join(d, rc.key_of(exported[g]) + ".json")
        if not os.path.exists(f):
            return None
        rows = os.path.join(work, os.path.basename(f))
        if not os.path.exists(rows):
            json.dump(json.load(open(f))["rows"], open(rows, "w"))
        return rows

    held = {g: probs_file(g) for _, g, _ in items}
    items = [it for it in items if man[it[1]]["testEpisode"] or held[it[1]]]

    def run(job):
        (item, g, answers), mode = job
        env = dict(os.environ, LAB_TAGGER=os.environ.get("LAB_TAGGER", SHIPPED), **modes[mode])
        if held[g]:
            env["LAB_TAGPROBS"] = held[g]
        r = subprocess.run([a.bin, os.path.join(rd.DATA, rd.key_of(exported[g]) + ".json"), answers],
                           env=env, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"lab-cutcheck failed on {item}: {r.stderr[-300:]}")
        return item, mode, json.loads(r.stdout.strip().splitlines()[-1])

    cuts = collections.defaultdict(dict)
    notes = collections.defaultdict(dict)
    with ThreadPoolExecutor(6) as ex:
        for item, mode, out in ex.map(run, [(it, m) for it in items for m in modes]):
            rows = lambda key: [[c[0], c[1], c[2]] for c in out[key]]
            cuts[mode][item] = rows("checked")
            cuts["(reader)"][item], cuts["(alone)"][item] = rows("reader"), rows("proposed")
            notes[mode][item] = out["notes"]
    tag = a.tag or f"{a.source.replace(':', '-')}-{a.scope}"
    path = os.path.join(ROOT, "build", "p66", f"sweep-{tag}.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(cuts, open(path, "w"))
    json.dump(notes, open(path.replace(".json", "-notes.json"), "w"), indent=1)

    episodes = podtest.Episodes(man)
    guid_of = {it[0]: it[1] for it in items}
    packs = {g: podtest.pack_episode(labels[g], episodes(g)) for g in sorted(set(guid_of.values()))}
    show_of = {it[0]: man[it[1]]["show"] for it in items}
    engines = len({i.partition("|")[2] for i in guid_of})
    print(f"{a.source} · scope {a.scope} · {len(items)} reads of {len(packs)} episodes"
          f"{' · Reader answers held out (' + a.probs + ') on fold episodes' if a.probs else ''}")
    print("| mode | Everyday | show cut s/h | skippable heard s/h | breaks noticed | switches |")
    print("|---|---|---|---|---|---|")
    table = {}
    for mode in ["(reader)", "(alone)"] + list(modes):
        rows = {i: podtest.score_pack(packs[guid_of[i]], c) for i, c in cuts[mode].items()}
        if a.source == "phone":
            # Every read counts the same (an engine has the episodes it read).
            ev = 100 * (1 - sum(r["cost"] for r in rows.values()) / sum(r["base"] for r in rows.values()))
        else:
            ev = podtest.everyday(rows, podtest.show_weights(rows, show_of))
        h = sum(r["audio"] for r in rows.values()) / 3600
        table[mode] = rows
        print(f"| {mode} | **{ev:.1f}** | {sum(r['show'] for r in rows.values()) / h:.1f} | "
              f"{sum(r['heard'] for r in rows.values()) / h:.1f} | "
              f"{sum(r['noticed'] for r in rows.values())}/{sum(r['breaks'] for r in rows.values())} | "
              f"{' '.join(f'{k}={v}' for k, v in modes.get(mode, {}).items())} |")
    if a.shows:
        names = list(table)
        print("\nEveryday per show:")
        print("| show | reads | " + " | ".join(names) + " |")
        print("|---|---|" + "---|" * len(names))
        for sh in sorted(set(show_of.values())):
            ks = [i for i in guid_of if show_of[i] == sh]
            cells = []
            for n in names:
                base = sum(table[n][i]["base"] for i in ks)
                cells.append(f"{100 * (1 - sum(table[n][i]['cost'] for i in ks) / base):.0f}" if base else "—")
            print(f"| {sh[:34]} | {len(ks)} | " + " | ".join(cells) + " |")
    print(f"\ncuts → {os.path.relpath(path, ROOT)} · {engines if a.source == 'phone' else 1} engine(s)")


if __name__ == "__main__":
    main()
