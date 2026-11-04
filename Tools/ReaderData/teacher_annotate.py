#!/usr/bin/env python3
"""Pass 57: teacher reads — a language model reads whole episodes of the
corpus (corpus.py manifest), independently of the Reader (no focus ranges:
every line is read), and each read is kept with who read it and how.

    teacher_annotate.py run <teacher> [order]
        order: test (default: test episodes, then unlabelled — the pool
        teachers label — then the other labelled episodes)
    teacher_annotate.py score <teacher>      against the labels, per kind

Teachers (exact variants; the MLX path is the app's, through Tools/MLXLab):
  q35-4b      MLX Qwen3.5 4B 4-bit (mlx-community), the app's `listener` profile
  q35-4b-ins  MLX Qwen3.5 4B Instruct 6-bit (ALTICDEV), `listenerEdges`

Each read → build/p57/teachers/<teacher>/<guid>.json: the model's parts
(lines, label, sponsor, funny, confidence, its reason), every part's raw
answer, timing, and the teacher's identity (model folder, the SHA-256 of its
config and weights index, variant, budget, answer cap, the lab binary's
source revision). A teacher's read is evidence, never a label by itself.
"""
import collections, hashlib, json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))
import corpus  # noqa: E402
import phone_eval  # noqa: E402

HUB = os.path.expanduser("~/.cache/huggingface/hub")
TEACHERS = {
    "q35-4b": {"model": "models--mlx-community--Qwen3.5-4B-MLX-4bit", "variant": "p-listener"},
    "q35-4b-ins": {"model": "models--ALTICDEV--Qwen3.5-4B-Instruct-MLX-Q6", "variant": "p-listenerEdges"},
}
LAB = os.path.join(ROOT, "build", "mlxlab-dd", "Build", "Products", "Release", "mlx-lab")
OUT = os.path.join(ROOT, "build", "p57", "teachers")


def record_path(name, guid):
    """Where one teacher's read of one episode is kept (guids can hold
    "/" and ":", e.g. SoundCloud's "tag:soundcloud,2010:tracks/…")."""
    return os.path.join(OUT, name, re.sub(r"[^A-Za-z0-9._-]", "_", guid) + ".json")


def model_dir(name):
    snaps = os.path.join(HUB, TEACHERS[name]["model"], "snapshots")
    return os.path.join(snaps, sorted(os.listdir(snaps))[0])


def identity(name):
    d = model_dir(name)
    h = hashlib.sha256()
    for f in ("config.json", "model.safetensors.index.json", "tokenizer_config.json", "chat_template.jinja"):
        p = os.path.join(d, f)
        if os.path.exists(p):
            h.update(open(p, "rb").read())
    rev = subprocess.run(["git", "-C", ROOT, "log", "-1", "--format=%h", "--", "Tools/MLXLab", "Services/LocalModel"],
                         capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", ROOT, "status", "--porcelain", "--", "Tools/MLXLab", "Services/LocalModel"],
                           capture_output=True, text=True).stdout.strip()
    return {"teacher": name, "modelDir": d, "snapshot": os.path.basename(d), "files": h.hexdigest()[:16],
            "variant": TEACHERS[name]["variant"], "budget": int(os.environ.get("LAB_BUDGET", "4000")),
            "labSource": rev + ("+local" if dirty else ""), "engine": "mlx"}


def order(manifest, how):
    eps = list(manifest["episodes"].values())
    if how == "test":
        key = lambda m: (0 if m["testEpisode"] else 2 if m["labelled"] else 1, m["guid"])
    else:
        key = lambda m: m["guid"]
    # PER_SHOW=n: at most n unlabelled episodes of any one show (CumTown alone
    # has 25), so the teacher's time goes to more shows, not more of one.
    cap = int(os.environ.get("PER_SHOW", "0")) or None
    out, per = [], collections.Counter()
    for m in sorted(eps, key=key):
        if m["copyOf"]:
            continue
        if cap and not m["labelled"]:
            per[m["showKey"]] += 1
            if per[m["showKey"]] > cap:
                continue
        out.append(m)
    return out


def run(name, how="test"):
    manifest = corpus.load_manifest()
    ident = identity(name)
    out = os.path.join(OUT, name)
    os.makedirs(out, exist_ok=True)
    json.dump(ident, open(os.path.join(out, "teacher.json"), "w"), indent=1)
    for m in order(manifest, how):
        path = record_path(name, m["guid"])
        if os.path.exists(path):
            continue
        tmp, detail = os.path.join(out, "part.json"), os.path.join(out, "detail.json")
        env = dict(os.environ, LAB_ONLY="", LAB_VARIANT=ident["variant"], LAB_OUT=tmp, LAB_DETAIL=detail)
        t0 = time.time()
        r = subprocess.run([LAB, model_dir(name), os.path.join(ROOT, m["source"]), str(m["index"]), "judge"],
                           env=env, capture_output=True, text=True)
        if r.returncode != 0:
            print(m["title"][:40], "failed:", r.stderr[-300:], flush=True)
            continue
        record = json.load(open(detail))
        record.update({"guid": m["guid"], "title": m["title"], "show": m["show"], "source": m["source"],
                       "index": m["index"], "transcriptHash": m["transcriptHash"], "teacher": ident,
                       "date": time.strftime("%Y-%m-%dT%H:%M:%S"), "wall": round(time.time() - t0, 1)})
        json.dump(record, open(path, "w"))
        print(f"{time.strftime('%H:%M:%S')} {m['title'][:36]:36} {m['hours']:.2f} h · {record['parts']} parts · "
              f"{len(record['found'])} found · {record['wall']:.0f} s", flush=True)


KIND = {"PAID_AD": "ad", "HOST_READ_AD": "ad", "NETWORK_PROMO": "crossPromo", "SELF_PROMO": "selfPromo",
        "GUEST_PLUG": "selfPromo", "INTRO": "intro", "OUTRO": "outro", "CREDITS": "outro"}


def cuts(record):
    return [[f["start"], f["end"], KIND[f["label"]]] for f in record["found"] if f["label"] in KIND]


def score(name):
    manifest = corpus.load_manifest()
    labels = phone_eval.load_labels()
    out = os.path.join(OUT, name)
    sets = collections.defaultdict(dict)
    for g, m in manifest["episodes"].items():
        p = record_path(name, g)
        if g in labels and os.path.exists(p):
            sets[g][name] = cuts(json.load(open(p)))
    path = os.path.join(out, "cuts.json")
    json.dump(sets, open(path, "w"))
    print(len(sets), "labelled episodes read →", path)


if __name__ == "__main__":
    if sys.argv[1] == "run":
        run(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "test")
    elif sys.argv[1] == "score":
        score(sys.argv[2])
    else:
        raise SystemExit(__doc__)
