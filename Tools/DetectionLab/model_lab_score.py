#!/usr/bin/env python3
"""Pass 44: score the per-model prompt lab (`phone_judge.py` runs under
build/p44/models/<model>/<variant>.cuts.json) against the labels, each
variant only on the episodes every variant of that model has finished, with
the model's own phone parts on the same episodes beside them.

    model_lab_score.py <results.json> [models dir]
"""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import phone_eval  # noqa: E402
import reader_distill  # noqa: E402

PHONE = {"q4": "MLX · Qwen3.5 4B (model)", "q6": "MLX · Qwen3.5 4B Instruct (6-bit) (model)",
         "c3": "Core AI · Qwen3 4B (model)", "mc": "Core AI · MiniCPM5 2B (model)"}


def main():
    results = sys.argv[1]
    root = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.dirname(HERE)), "build", "p44", "models")
    episodes = {e["guid"]: e for e in json.load(open(results))["episodes"]}
    for model in sorted(os.listdir(root)):
        folder = os.path.join(root, model)
        if not os.path.isdir(folder):
            continue
        runs = {f[:-10]: json.load(open(os.path.join(folder, f))) for f in sorted(os.listdir(folder)) if f.endswith(".cuts.json")}
        if not runs:
            continue
        common = set.intersection(*(set(r) for r in runs.values()))
        scored = {}
        for name, run in runs.items():
            for g in common:
                scored.setdefault(g, {})[name] = next(iter(run[g].values()))
        print(f"\n{model}: {len(common)} episodes")
        print(reader_distill.summary(scored, results))
        # The same variants on just the episodes this model read on his
        # phone, with its phone parts beside them.
        both = {}
        for g in common:
            phone = phone_eval.engine_cuts(episodes[g], "").get(PHONE.get(model, ""))
            if phone is not None:
                both[g] = dict(scored[g], **{"phone parts (his iPhone)": phone})
        if both:
            print(f"  on the {len(both)} it read on his phone:")
            print(reader_distill.summary(both, results))


if __name__ == "__main__":
    main()
