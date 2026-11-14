#!/usr/bin/env python3
"""Pass 64 (his 13 Nov request): distil a large teacher model into
PodSkipper's Reader, on this Mac.

The Reader is a small sentence tagger (Resources/Detection/TaggerWeights*.bin)
trained by Tools/DetectionLab/reader_distill.py. This script adds teachers to
that pipeline — a large cloud model through any OpenAI-compatible API
(DeepSeek-V3.2, Qwen3-235B-A22B, Qwen3.8-Max, …) or a local one (Qwen3.5 4B
Instruct 6-bit through the Mac labs) — and keeps the project's rules:

  * A teacher's read is evidence, never a label by itself. Its records go
    where the existing teacher reads go (build/p57/teachers/<name>/<guid>.json,
    the format of Tools/ReaderData/teacher_annotate.py), and
    Tools/ReaderData/silver.py keeps only what the evidence agrees on.
  * No test episode, copy of one, or held-out show is trained on
    (Tools/ReaderData/corpus.py's manifest decides; `annotate` reads only the
    unlabelled pool unless --order says otherwise, and training excludes the
    test split as before).
  * Nothing ships without a rule written first: `gate` judges a trained pair
    against the shipped one on his 11 test episodes and the 71 show-held-out
    episodes (build/p64/eval.sh), and `export` refuses unless the gate passed.

Steps

  1. annotate   the teacher reads whole episodes
       distill_reader.py annotate cloud --name deepseek-v32 \\
           --base-url https://api.deepseek.com/v1 --model deepseek-chat \\
           --api-key-env DEEPSEEK_API_KEY [--limit 20] [--order pool|test|all]
       distill_reader.py annotate batch --name qwen3-235b --base-url … --model … \\
           --api-key-env …            (writes an OpenAI Batch API file; --submit sends it)
       distill_reader.py collect --name qwen3-235b --results <batch output .jsonl>
       distill_reader.py annotate local-cpu --name q35-4b-ins-cpu \\
           --gguf "/Volumes/Samsung PSSD T9 Media/PodSkipper/Models/gguf/Qwen3.5-4B-Q6_K.gguf"
       distill_reader.py annotate local-mlx --name q35-4b-ins   (Tools/ReaderData/teacher_annotate.py)
  2. score      how the teacher does on the labelled episodes it read
       distill_reader.py score --name deepseek-v32
  3. train      the Reader from labels + agreement + this teacher's silver labels
       distill_reader.py train --name deepseek-v32 --tag d64a [--run]
  4. gate       the trained pair against the shipped Reader (rule below)
       distill_reader.py gate --tag d64a
  5. export     copy the weights into the app, only after the gate passed
       distill_reader.py export --tag d64a

The gate's rule (written before any result): on his 11 test episodes the new
pair's Everyday score must not fall below the shipped Reader's, and on the 71
show-held-out episodes it must rise by at least 0.5 points with no more than
0.5 s/h more of the show cut.

Keys are read from the environment variable named by --api-key-env, never
from a file in the repository, and never written to a record.
Transcripts sent to a cloud teacher are his episodes' words: --base-url is his
choice of provider; nothing is sent anywhere unless he runs `annotate cloud`.
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "Tools", "ReaderData"))
sys.path.insert(0, os.path.join(ROOT, "Tools", "DetectionLab"))

TEACHERS = os.path.join(ROOT, "build", "p57", "teachers")
LABELS = ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS",
          "MOCK_AD", "RECURRING_SEGMENT"]

# The teacher's instructions: the app's labels and answer form, with what a
# listener skips said plainly. A large model reads a whole stretch at once.
SYSTEM = """You label podcast transcripts for an ad skipper. Lines are numbered from 0.
Return every stretch a listener would want skipped, each as one entry:
- PAID_AD: a produced sponsor spot. HOST_READ_AD: a sponsor read by a host.
- NETWORK_PROMO: a promo for another show or network. SELF_PROMO: the show's own plug (Patreon, tour, merch, bonus episodes).
- GUEST_PLUG: a guest plugging their own work (special, tour, book) when asked to.
- INTRO / OUTRO / CREDITS: the produced opening, the sign-off and production credits.
- MOCK_AD: a joke ad or a bit in an ad's voice that is part of the show (do not skip; listed so it isn't cut).
- RECURRING_SEGMENT: a regular produced bit of the show itself (do not skip).
Rules: an entry runs from the first line of the stretch to its last; entries never overlap; back-to-back
breaks of different kinds are separate entries; ordinary conversation is never an entry, even when it
mentions brands, prices or tours; most of an episode is the show. Answer with JSON only:
{"parts":[{"first_line":0,"last_line":0,"label":"PAID_AD","sponsor":"","funny":false,"confidence":90,"why":"..."}]}"""


def manifest():
    import corpus
    return corpus.load_manifest()


def order(m, how):
    eps = list(m["episodes"].values())
    if how == "test":
        eps = [e for e in eps if e.get("split") == "test-episode" or e.get("labelled")]
    elif how == "pool":
        eps = [e for e in eps if not e.get("labelled") and not e.get("copyOf")]
    return sorted(eps, key=lambda e: e["hours"])


_exports = {}


def lines_of(e):
    """The transcript lines of one manifest episode (from its results export)."""
    path = os.path.join(ROOT, e["source"])
    if path not in _exports:
        _exports.clear()
        _exports[path] = json.load(open(path))
    ep = _exports[path]["episodes"][e["index"]]
    return [(l["text"], l["start"], l["end"]) for l in ep.get("transcript", [])]


def windows(n, size, overlap):
    out, start = [], 0
    while start < n:
        end = min(n, start + size)
        out.append((start, end))
        if end == n:
            break
        start = end - overlap
    return out


def user_prompt(e, lines, w):
    body = "\n".join(f"{i - w[0]} {lines[i][0]}" for i in range(w[0], w[1]))
    return (f"Show: {e['show']}\nEpisode: {e['title']}\nThis stretch is lines {w[0]}–{w[1] - 1} of {len(lines)} "
            f"(numbered here from 0).\n\n{body}")


def parse(text):
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        return None
    try:
        parts = json.loads(m.group(0)).get("parts")
    except json.JSONDecodeError:
        return None
    return parts if isinstance(parts, list) else None


def found_entries(parts, w, lines):
    out = []
    for p in parts or []:
        try:
            a, b = int(p["first_line"]) + w[0], int(p["last_line"]) + w[0]
        except (KeyError, TypeError, ValueError):
            continue
        label = str(p.get("label", "")).upper()
        if label not in LABELS or a > b or a < w[0] or b >= w[1]:
            continue
        out.append({"firstLine": a, "lastLine": b, "start": lines[a][1], "end": lines[b][2], "label": label,
                    "sponsor": str(p.get("sponsor", ""))[:60], "funny": bool(p.get("funny", False)),
                    "confidence": int(p.get("confidence", 80) or 80), "why": str(p.get("why", ""))[:160]})
    return out


def merge(found):
    found.sort(key=lambda f: (f["firstLine"], f["lastLine"]))
    out = []
    for f in found:
        if out and out[-1]["label"] == f["label"] and f["firstLine"] <= out[-1]["lastLine"]:
            out[-1]["lastLine"] = max(out[-1]["lastLine"], f["lastLine"])
            out[-1]["end"] = max(out[-1]["end"], f["end"])
            out[-1]["confidence"] = max(out[-1]["confidence"], f["confidence"])
        else:
            out.append(dict(f))
    return out


def record_path(name, guid):
    import teacher_annotate
    teacher_annotate.OUT = TEACHERS
    return teacher_annotate.record_path(name, guid)


def save(name, e, found, identity, answers, wall):
    path = record_path(name, e["guid"])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    record = {"variant": identity["variant"], "budget": identity.get("window"), "cap": identity.get("cap"),
              "parts": len(answers), "found": merge(found), "answers": answers, "guid": e["guid"],
              "title": e["title"], "show": e["show"], "source": e["source"], "index": e["index"],
              "transcriptHash": e["transcriptHash"], "teacher": identity,
              "date": time.strftime("%Y-%m-%dT%H:%M:%S"), "wall": round(wall, 1)}
    json.dump(record, open(path, "w"))
    return record


def identity_for(args, kind):
    ident = {"kind": kind, "name": args.name, "variant": f"distill-{kind}",
             "prompt": hashlib.sha256(SYSTEM.encode()).hexdigest()[:16], "window": args.window,
             "overlap": args.overlap, "cap": args.max_tokens,
             "source": subprocess.run(["git", "-C", ROOT, "log", "-1", "--format=%h"], capture_output=True,
                                      text=True).stdout.strip()}
    if kind in ("cloud", "batch"):
        ident.update(model=args.model, host=re.sub(r"^https?://", "", args.base_url).split("/")[0])
    if kind == "local-cpu":
        ident.update(model=os.path.basename(args.gguf))
    os.makedirs(os.path.join(TEACHERS, args.name), exist_ok=True)
    json.dump(ident, open(os.path.join(TEACHERS, args.name, "teacher.json"), "w"), indent=1)
    return ident


def chat(args, key, user):
    body = {"model": args.model, "temperature": 0, "max_tokens": args.max_tokens,
            "response_format": {"type": "json_object"},
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]}
    req = urllib.request.Request(args.base_url.rstrip("/") + "/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=args.timeout) as r:
                return json.load(r)["choices"][0]["message"]["content"]
        except Exception as error:  # noqa: BLE001 — retried, then reported
            if attempt == 3:
                raise
            print("  retrying after:", error, flush=True)
            time.sleep(5 * (attempt + 1))


def annotate_cloud(args):
    key = os.environ.get(args.api_key_env or "")
    if not key:
        raise SystemExit(f"Set the API key in ${args.api_key_env} first (it is never written anywhere).")
    ident = identity_for(args, "cloud")
    for e in order(manifest(), args.order)[: args.limit or None]:
        if os.path.exists(record_path(args.name, e["guid"])):
            continue
        lines, t0, found, answers = lines_of(e), time.time(), [], []
        for w in windows(len(lines), args.window, args.overlap):
            text = chat(args, key, user_prompt(e, lines, w))
            answers.append({"first": w[0], "last": w[1] - 1, "text": text})
            found += found_entries(parse(text), w, lines)
        record = save(args.name, e, found, ident, answers, time.time() - t0)
        print(f"{e['title'][:40]:40} {e['hours']:.2f} h · {len(record['found'])} found · {record['wall']:.0f} s", flush=True)


def annotate_batch(args):
    ident = identity_for(args, "batch")
    out = os.path.join(TEACHERS, args.name, "batch-input.jsonl")
    n = 0
    with open(out, "w") as f:
        for e in order(manifest(), args.order)[: args.limit or None]:
            if os.path.exists(record_path(args.name, e["guid"])):
                continue
            lines = lines_of(e)
            for w in windows(len(lines), args.window, args.overlap):
                body = {"model": args.model, "temperature": 0, "max_tokens": args.max_tokens,
                        "response_format": {"type": "json_object"},
                        "messages": [{"role": "system", "content": SYSTEM},
                                     {"role": "user", "content": user_prompt(e, lines, w)}]}
                f.write(json.dumps({"custom_id": f"{e['guid']}|{w[0]}|{w[1]}", "method": "POST",
                                    "url": "/v1/chat/completions", "body": body}) + "\n")
                n += 1
    print(f"{n} requests → {out}")
    if args.submit:
        key = os.environ.get(args.api_key_env or "")
        if not key:
            raise SystemExit(f"Set the API key in ${args.api_key_env} first.")
        base = args.base_url.rstrip("/")
        boundary = "pkdistill" + hashlib.sha256(out.encode()).hexdigest()[:12]
        data = open(out, "rb").read()
        form = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"purpose\"\r\n\r\nbatch\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"batch.jsonl\"\r\n"
                f"Content-Type: application/jsonl\r\n\r\n").encode() + data + f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(base + "/files", data=form, headers={
            "Authorization": "Bearer " + key, "Content-Type": f"multipart/form-data; boundary={boundary}"})
        file_id = json.load(urllib.request.urlopen(req, timeout=args.timeout))["id"]
        req = urllib.request.Request(base + "/batches", data=json.dumps({
            "input_file_id": file_id, "endpoint": "/v1/chat/completions", "completion_window": "24h"}).encode(),
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
        batch = json.load(urllib.request.urlopen(req, timeout=args.timeout))
        json.dump(batch, open(os.path.join(TEACHERS, args.name, "batch.json"), "w"), indent=1)
        print("submitted batch", batch.get("id"), "· collect its output file with `collect` when it finishes")
    json.dump(ident, open(os.path.join(TEACHERS, args.name, "teacher.json"), "w"), indent=1)


def collect(args):
    ident = json.load(open(os.path.join(TEACHERS, args.name, "teacher.json")))
    by_episode = {}
    for row in open(args.results):
        row = json.loads(row)
        guid, a, b = row["custom_id"].rsplit("|", 2)
        text = (((row.get("response") or {}).get("body") or {}).get("choices") or [{}])[0].get("message", {}).get("content")
        by_episode.setdefault(guid, []).append(((int(a), int(b)), text))
    eps = manifest()["episodes"]
    for guid, answers in by_episode.items():
        e = eps.get(guid)
        if not e:
            continue
        lines, found, kept = lines_of(e), [], []
        for w, text in sorted(answers):
            kept.append({"first": w[0], "last": w[1] - 1, "text": text})
            found += found_entries(parse(text), w, lines)
        record = save(args.name, e, found, ident, kept, 0)
        print(f"{e['title'][:40]:40} {len(record['found'])} found")


def annotate_local_cpu(args):
    ident = identity_for(args, "local-cpu")
    lab = os.path.join(ROOT, "Tools", "CPULab", ".build", "release", "cpu-lab")
    if not os.path.exists(lab):
        subprocess.run(["swift", "build", "-c", "release"], cwd=os.path.join(ROOT, "Tools", "CPULab"), check=True)
    for e in order(manifest(), args.order)[: args.limit or None]:
        if os.path.exists(record_path(args.name, e["guid"])):
            continue
        tmp = os.path.join(TEACHERS, args.name, "part.json")
        env = dict(os.environ, LAB_GGUF=args.gguf, LAB_THREADS=str(args.threads), LAB_PREFIX="1",
                   LAB_CAP=str(args.max_tokens), LAB_GRAMMAR="1", LAB_PROFILE="listenerEdges", LAB_OUT=tmp, LAB_ONLY="")
        t0 = time.time()
        r = subprocess.run([lab, os.path.join(ROOT, e["source"]), str(e["index"])], env=env, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(tmp):
            print(e["title"][:40], "failed:", r.stderr[-300:], flush=True)
            continue
        lines = lines_of(e)
        out = json.load(open(tmp))
        found = []
        for p in out.get("parts", []):
            found += found_entries(parse(p.get("text")), (p["first"], p["last"] + 1), lines)
        record = save(args.name, e, found, ident, out.get("parts", []), time.time() - t0)
        print(f"{e['title'][:40]:40} {len(record['found'])} found · {record['wall']:.0f} s", flush=True)


def annotate_local_mlx(args):
    import teacher_annotate
    teacher_annotate.run(args.name, args.order if args.order != "pool" else "test")


def score(args):
    import teacher_annotate
    teacher_annotate.OUT = TEACHERS
    teacher_annotate.score(args.name)
    tag = args.name
    print("Then: ~/Developer/pk-ml/bin/python -I Tools/ReaderData/podtest.py test "
          f"{tag}={os.path.join(TEACHERS, args.name, 'cuts.json')}:{tag}")


def train(args):
    py = os.path.expanduser("~/Developer/pk-ml/bin/python")
    results = args.results or os.path.join(ROOT, "build", "phone-1029", "results.json")
    # Pass 65: HOLD_TEST=1 — the 11 test episodes are what `gate` judges on, so
    # they must not be trained on (Pass 64 left this out).
    env = dict(os.environ, TEACHER=args.name, WARM="1", HOLD_TEST="1")
    cmd = [py, "-I", "-u", os.path.join(ROOT, "Tools", "DetectionLab", "reader_distill.py"), "train", results, args.tag]
    print("TEACHER=%s WARM=1 HOLD_TEST=1 %s" % (args.name, " ".join(cmd)))
    if args.run:
        subprocess.run(cmd, env=env, check=True)
        print(f"Trained → build/p44/{args.tag}/TaggerWeights{{,-2}}.bin; next: distill_reader.py gate --tag {args.tag}")
    else:
        print("(add --run to train: hours on this Mac; the SSD must be connected)")


def read_score(path):
    first = open(path).readline()
    m = re.search(r"\*\*([0-9.]+)\*\*.*?\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*$", first)
    if not m:
        m2 = re.search(r"\*\*([0-9.]+)\*\*", first)
        return (float(m2.group(1)), None) if m2 else (None, None)
    cols = [c.strip() for c in first.split("|") if c.strip()]
    return float(re.search(r"\*\*([0-9.]+)\*\*", first).group(1)), float(cols[-2])


def gate(args):
    """Pass 65: only the test-episode half of this is a measurement of the new
    pair — build/p64/eval.sh's show-held-out score reads Pass 58's stored
    fold answers (build/p58/ext13), so that half never moves. Rule 6 judges a
    teacher's pair with Tools/ReaderData/reader_run.sh (TEACHER=<name>,
    folds retrained) instead; see Tools/ReaderData/kaggle_auto.py."""
    weights = os.path.join(ROOT, "build", "p44", args.tag)
    if not os.path.exists(os.path.join(weights, "TaggerWeights.bin")):
        raise SystemExit(f"No trained pair in {weights}")
    shipped = os.path.join(ROOT, "Resources", "Detection")
    env = dict(os.environ)
    for name, folder in (("shipped", shipped), (args.tag, weights)):
        env["LAB_TAGGER"] = os.path.join(folder, "TaggerWeights.bin") + ":" + os.path.join(folder, "TaggerWeights-2.bin")
        subprocess.run([os.path.join(ROOT, "build", "p64", "eval.sh"), "gate-" + name,
                        "build/p64/lab-segments"], env=env, check=True)
    base_t = read_score(os.path.join(ROOT, "build", "p64", "score-gate-shipped-test.txt"))
    new_t = read_score(os.path.join(ROOT, "build", "p64", f"score-gate-{args.tag}-test.txt"))
    base_f = read_score(os.path.join(ROOT, "build", "p64", "score-gate-shipped-folds.txt"))
    new_f = read_score(os.path.join(ROOT, "build", "p64", f"score-gate-{args.tag}-folds.txt"))
    passed = (new_t[0] >= base_t[0] and new_f[0] >= base_f[0] + 0.5
              and (new_f[1] is None or base_f[1] is None or new_f[1] <= base_f[1] + 0.5))
    verdict = (f"test episodes {base_t[0]} → {new_t[0]}; show-held-out {base_f[0]} → {new_f[0]} "
               f"(show cut {base_f[1]} → {new_f[1]} s/h): {'PASSED' if passed else 'not passed'}")
    open(os.path.join(weights, "gate.txt"), "w").write(verdict + "\n")
    print(verdict)


def export(args):
    weights = os.path.join(ROOT, "build", "p44", args.tag)
    verdict = open(os.path.join(weights, "gate.txt")).read() if os.path.exists(os.path.join(weights, "gate.txt")) else ""
    if "PASSED" not in verdict:
        raise SystemExit("The gate hasn't passed for this pair (distill_reader.py gate --tag " + args.tag + ").")
    for name in ("TaggerWeights.bin", "TaggerWeights-2.bin"):
        shutil.copy2(os.path.join(weights, name), os.path.join(ROOT, "Resources", "Detection", name))
    print("Copied into Resources/Detection. Bump AdDetector.version, rebuild the anchor "
          "(ANCHOR_BIN=$PWD/build/p57/lab-segments tagger.py anchor …), then run the unit tests.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("annotate")
    a.add_argument("kind", choices=["cloud", "batch", "local-cpu", "local-mlx"])
    a.add_argument("--name", required=True)
    a.add_argument("--base-url", default="https://api.openai.com/v1")
    a.add_argument("--model", default="")
    a.add_argument("--api-key-env", default="")
    a.add_argument("--gguf", default="")
    a.add_argument("--threads", type=int, default=4)
    a.add_argument("--order", choices=["pool", "test", "all"], default="pool")
    a.add_argument("--limit", type=int, default=0)
    a.add_argument("--window", type=int, default=400, help="lines a large teacher reads at once")
    a.add_argument("--overlap", type=int, default=20)
    a.add_argument("--max-tokens", type=int, default=2048)
    a.add_argument("--timeout", type=int, default=300)
    a.add_argument("--submit", action="store_true")
    c = sub.add_parser("collect")
    c.add_argument("--name", required=True)
    c.add_argument("--results", required=True)
    s = sub.add_parser("score")
    s.add_argument("--name", required=True)
    t = sub.add_parser("train")
    t.add_argument("--name", required=True)
    t.add_argument("--tag", required=True)
    t.add_argument("--results", default="")
    t.add_argument("--run", action="store_true")
    g = sub.add_parser("gate")
    g.add_argument("--tag", required=True)
    x = sub.add_parser("export")
    x.add_argument("--tag", required=True)
    args = ap.parse_args()
    if args.cmd == "annotate":
        {"cloud": annotate_cloud, "batch": annotate_batch, "local-cpu": annotate_local_cpu,
         "local-mlx": annotate_local_mlx}[args.kind](args)
    else:
        {"collect": collect, "score": score, "train": train, "gate": gate, "export": export}[args.cmd](args)


if __name__ == "__main__":
    main()
