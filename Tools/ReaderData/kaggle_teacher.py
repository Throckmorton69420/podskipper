#!/usr/bin/env python3
"""Pass 65: run a teacher batch file through llama.cpp's server — on a free
Kaggle notebook (2 × T4, 32 GB) or any machine — and write OpenAI batch
output that `Scripts/distill_reader.py collect` and
`Tools/ReaderData/sporc_sb_distill_pipeline.py teacher-import` read.

Input: a batch file either of them wrote (`distill_reader.py annotate batch
--name N --model M` for his episodes; `sporc_sb_distill_pipeline.py
teacher-batch --name N` for SPoRC episodes). Every line is one window of one
episode: {"custom_id", "method", "url", "body": {chat completion request}}.

On Kaggle (Settings: Accelerator "GPU T4 x2", Internet on; the batch file
uploaded as a private Dataset):

    !python kaggle_teacher.py setup                     # llama.cpp b12283 with CUDA for the T4 (sm_75), ~10 min
    !python kaggle_teacher.py fetch --repo unsloth/Qwen3.8-27B-GGUF --pattern "*UD-Q4_K_XL*"
    !python kaggle_teacher.py serve --parallel 4 --ctx 16384 &
    !python kaggle_teacher.py run --input /kaggle/input/<dataset>/batch-input.jsonl \\
          --output /kaggle/working/batch-output.jsonl --hours 11.3

"Save & Run All (Commit)" runs it in the background for up to 12 h; the
output is resumable (finished windows are skipped), so the next session
carries on from the same output file uploaded back as a Dataset (--resume-from).
Download batch-output.jsonl, then on the Mac:

    distill_reader.py collect --name N --results batch-output.jsonl          (his episodes)
    sporc_sb_distill_pipeline.py teacher-import --name N --results batch-output.jsonl   (SPoRC)

Locally (any OpenAI-compatible server already running):

    kaggle_teacher.py run --server http://127.0.0.1:8080 --input … --output …

Thinking is switched off (the answer is a short JSON list; a reasoning model
would spend its budget first). Nothing here reads keys or sends anything
anywhere but the server named.

Pass 66 — the quick check (a go / no-go for a teacher model, NOT a tuning
set: never change a prompt to raise this number; his 11 test episodes stay a
test):

    kaggle_teacher.py quick --model <hf repo> --file <gguf file or pattern> \
        [--prompt-variant baseline|why-first] [--reasoning-budget N] [--name N]
        [--gguf <local file>] [--binary <llama-server>] [--server <url>]

builds the batch for his 11 test episodes only (distill_reader.py annotate
batch --order test11), starts llama-server on the model (fetched from Hugging
Face unless --gguf or --server is given), answers every window, collects
the answers as teacher records, puts them through the app's own check
(Tools/DetectionLab/check_sweep.py teacher:<name> test), and prints that
table (the Reader's row first) with prompt tokens per second and the hours
the 71-episode unlabelled pool would take at this speed. On Kaggle without
the repository: --stage run with --input <batch> answers only; build the
batch (--stage batch) and score (--stage score --results <output>) on the
Mac. Pass gate for a teacher: its checked score ≥ the Reader's.
"""
import argparse
import concurrent.futures as cf
import glob
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

WORK = "/kaggle/working" if os.path.isdir("/kaggle/working") else os.path.abspath("teacher-work")
TMP = "/kaggle/tmp" if os.path.isdir("/kaggle/tmp") else ("/tmp" if os.path.isdir("/tmp") else WORK)
LLAMA = os.path.join(TMP, "llama.cpp")


def sh(cmd, **kw):
    print("$", " ".join(cmd), flush=True)
    subprocess.run(cmd, check=True, **kw)


def setup(args):
    """llama.cpp at the tag PodSkipper ships (Scripts/build-llama.sh), built for
    CUDA on the T4 (compute capability 7.5)."""
    if not os.path.isdir(LLAMA):
        sh(["git", "clone", "--depth", "1", "--branch", args.tag, "https://github.com/ggml-org/llama.cpp", LLAMA])
    # Kaggle's CUDA 13 image: CMake's FindCUDAToolkit didn't find libcuda, so `CUDA::cuda_driver` was missing
    # (14 Nov). The build links against the toolkit's stub; the driver's own libcuda.so.1 is used at run time.
    # With no stub anywhere, llama.cpp is built without the driver link (no VMM pool; same answers).
    driver = next((p for p in ("/usr/local/cuda/lib64/stubs/libcuda.so",
                               "/usr/local/cuda/targets/x86_64-linux/lib/stubs/libcuda.so",
                               "/usr/lib/x86_64-linux-gnu/libcuda.so", "/usr/lib/x86_64-linux-gnu/libcuda.so.1",
                               "/usr/local/nvidia/lib64/libcuda.so.1") if os.path.exists(p)), None)
    extra = [f"-DCUDA_cuda_driver_LIBRARY={driver}"] if driver else ["-DGGML_CUDA_NO_VMM=ON"]
    print("libcuda for the build:", driver or "none found → GGML_CUDA_NO_VMM", flush=True)
    configure = ["cmake", "-S", LLAMA, "-B", os.path.join(LLAMA, "build"), "-DGGML_CUDA=ON",
                 f"-DCMAKE_CUDA_ARCHITECTURES={args.cuda_arch}", "-DLLAMA_CURL=OFF", "-DCMAKE_BUILD_TYPE=Release",
                 # Pass 67: a depth-1 clone has build number 1, so the web UI download asked for version "b1"
                 # (HTTP error, 17 Nov). The server runs with --no-webui: build with an empty UI table.
                 "-DLLAMA_USE_PREBUILT_UI=OFF", "-DLLAMA_BUILD_UI=OFF"]
    try:
        sh(configure + extra)
    except subprocess.CalledProcessError:
        if "-DGGML_CUDA_NO_VMM=ON" in extra:
            raise
        print("configure failed with the stub; trying again without the driver link", flush=True)
        shutil.rmtree(os.path.join(LLAMA, "build"), ignore_errors=True)
        sh(configure + ["-DGGML_CUDA_NO_VMM=ON"])
    sh(["cmake", "--build", os.path.join(LLAMA, "build"), "--target", "llama-server", "-j", str(os.cpu_count() or 4)])
    print("built", os.path.join(LLAMA, "build", "bin", "llama-server"))


def fetch(args):
    from huggingface_hub import snapshot_download
    path = snapshot_download(args.repo, allow_patterns=[args.pattern], local_dir=os.path.join(TMP, "model"))
    files = sorted(glob.glob(os.path.join(path, "**", "*.gguf"), recursive=True))
    print("\n".join(files))
    # A split model is opened from its first part.
    json.dump({"gguf": files[0]}, open(os.path.join(TMP, "model.json"), "w"))


def serve(args):
    gguf = args.gguf or json.load(open(os.path.join(TMP, "model.json")))["gguf"]
    binary = args.binary or os.path.join(LLAMA, "build", "bin", "llama-server")
    cmd = server_command(binary, gguf, args.port, args.parallel, args.ctx, args.split,
                         getattr(args, "reasoning_budget", 0))
    print("$", " ".join(cmd), flush=True)
    os.execv(binary, cmd)


def server_command(binary, gguf, port, parallel, ctx, split, reasoning_budget=0):
    cmd = [binary, "-m", gguf, "--host", "127.0.0.1", "--port", str(port), "-ngl", "999",
           "--parallel", str(parallel), "-c", str(ctx * parallel), "--jinja",
           "--reasoning-budget", str(reasoning_budget), "-fa", "on", "--no-webui"]
    if split:
        cmd += ["--split-mode", "layer", "--tensor-split", split]
    return cmd


def wait_for(server, seconds=1800):
    t0 = time.time()
    while time.time() - t0 < seconds:
        try:
            with urllib.request.urlopen(server.rstrip("/") + "/health", timeout=5) as r:
                if r.status == 200:
                    return
        except Exception:  # noqa: BLE001 — still loading
            pass
        time.sleep(5)
    raise SystemExit(f"{server} didn't come up in {seconds} s")


def too_long(row):
    """Pass 69: a window the server refused as longer than its context (terminal: kept, never retried)."""
    return ((row.get("response") or {}).get("status_code") == 400
            and (row.get("error") or {}).get("code") == "context_length_exceeded")


def run(args):
    server = args.server.rstrip("/")
    wait_for(server)
    done = set()
    for path in filter(None, [args.output, args.resume_from]):
        if os.path.exists(path):
            for line in open(path):
                try:
                    row = json.loads(line)
                    # Pass 69: a window over the server's context is recorded once as terminal and never retried.
                    if row.get("response", {}).get("status_code") == 200 or too_long(row):
                        done.add(row["custom_id"])
                except ValueError:
                    pass
    if args.resume_from and args.resume_from != args.output and os.path.exists(args.resume_from):
        with open(args.output, "a") as out:   # carry the earlier session's answers into this output
            for line in open(args.resume_from):
                out.write(line)
    todo = [json.loads(l) for l in open(args.input) if l.strip()]
    todo = [r for r in todo if r["custom_id"] not in done][: args.limit or None]
    print(f"{len(done)} windows already answered; {len(todo)} to go", flush=True)
    lock, out = threading.Lock(), open(args.output, "a")
    t0, stats = time.time(), {"n": 0, "prompt": 0, "completion": 0, "failed": 0, "too_long": 0}
    deadline = t0 + args.hours * 3600 if args.hours else None

    def one(row):
        if deadline and time.time() > deadline:
            return
        body = dict(row["body"])
        body["chat_template_kwargs"] = {"enable_thinking": bool(getattr(args, "thinking", False))}
        req = urllib.request.Request(server + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        result, error, too_big = None, None, None
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=args.timeout) as r:
                    result = json.load(r)
                break
            except urllib.error.HTTPError as e:
                try:
                    said = e.read().decode("utf-8", "replace")
                except Exception:  # noqa: BLE001 — no body
                    said = ""
                # Pass 69: llama-server answers 400 "exceeds the available context size" for a window longer than
                # --ctx; asking again can't change that (v4 of pat-q36 spent 0.6 h retrying four such windows).
                if e.code == 400 and ("context size" in said.lower() or "context length" in said.lower()):
                    too_big = said
                    break
                error = f"HTTP {e.code}: {said[:300]}"
                time.sleep(5 * (attempt + 1))
            except Exception as e:  # noqa: BLE001 — retried, then recorded
                error = str(e)
                time.sleep(5 * (attempt + 1))
        with lock:
            if too_big is not None:
                stats["too_long"] += 1
                out.write(json.dumps({"custom_id": row["custom_id"], "response": {"status_code": 400, "body": None},
                                      "error": {"code": "context_length_exceeded", "message": too_big[:300]}}) + "\n")
            elif result is None:
                stats["failed"] += 1
                out.write(json.dumps({"custom_id": row["custom_id"], "response": {"status_code": 500, "body": None},
                                      "error": {"message": error}}) + "\n")
            else:
                usage = result.get("usage") or {}
                stats["prompt"] += usage.get("prompt_tokens", 0)
                stats["completion"] += usage.get("completion_tokens", 0)
                out.write(json.dumps({"custom_id": row["custom_id"], "response": {"status_code": 200, "body": result},
                                      "error": None}) + "\n")
            out.flush()
            stats["n"] += 1
            if stats["n"] % args.report == 0 or stats["n"] == len(todo):
                wall = time.time() - t0
                left = (len(todo) - stats["n"]) * wall / stats["n"]
                print(f"{stats['n']}/{len(todo)} windows · {stats['prompt'] / wall:.0f} prompt tok/s · "
                      f"{stats['completion'] / wall:.1f} answer tok/s · {stats['failed']} failed · {stats['too_long']} too long · "
                      f"{left / 3600:.1f} h left", flush=True)

    with cf.ThreadPoolExecutor(args.parallel) as pool:
        list(pool.map(one, todo))
    out.close()
    stats["wall"] = time.time() - t0
    json.dump(stats, open(args.output + ".speed.json", "w"))   # Pass 67: kept with the answers (Kaggle output)
    print(f"wrote {args.output} ({stats['n']} windows this session, {stats['wall']:.0f} s)")
    return stats


REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
PY = sys.executable


def in_repo():
    return os.path.exists(os.path.join(REPO, "Scripts", "distill_reader.py"))


def pool_windows(window=400, overlap=20):
    """How many windows the 71-episode unlabelled pool is (the builder's own count)."""
    sys.path.insert(0, os.path.join(REPO, "Scripts"))
    import distill_reader as dr
    eps = dr.order(dr.manifest(), "pool")
    return sum(len(dr.windows(len(dr.lines_of(e)), window, overlap)) for e in eps), len(eps)


def quick(args):
    import re
    slug = re.sub(r"[^a-z0-9]+", "-", (os.path.basename(args.file) or args.model).lower()).strip("-")[:40]
    name = args.name or f"quick-{slug}-{args.prompt_variant}" + (f"-r{args.reasoning_budget}" if args.reasoning_budget else "")
    teachers = os.path.join(REPO, "build", "p57", "teachers")
    work = os.path.join(REPO, "build", "p66", "quick", name) if in_repo() else os.path.join(WORK, name)
    os.makedirs(work, exist_ok=True)
    batch = args.input or os.path.join(work, "batch-input.jsonl")
    output = args.results or os.path.join(work, "batch-output.jsonl")
    stages = ["batch", "run", "score"] if args.stage == "all" else [args.stage]
    if "batch" in stages and not args.input:
        if not in_repo():
            raise SystemExit("Building the batch needs the repository (his transcripts); pass --input on Kaggle.")
        if os.path.isdir(os.path.join(teachers, name)) and os.listdir(os.path.join(teachers, name)):
            # A record left from an earlier quick run would be skipped by the builder.
            raise SystemExit(f"{os.path.join(teachers, name)} already holds records; pass another --name")
        sh([PY, "-I", os.path.join(REPO, "Scripts", "distill_reader.py"), "annotate", "batch", "--name", name,
            "--model", args.served_name, "--order", "test11", "--prompt-variant", args.prompt_variant, "--out", batch])
    stats = None
    if "run" in stages:
        proc = None
        server = args.server
        if not server:
            gguf = args.gguf
            if not gguf:
                fetch(argparse.Namespace(repo=args.model, pattern=args.file))
                gguf = json.load(open(os.path.join(TMP, "model.json")))["gguf"]
            binary = args.binary or os.path.join(LLAMA, "build", "bin", "llama-server")
            cmd = server_command(binary, gguf, args.port, args.parallel, args.ctx, args.split, args.reasoning_budget)
            print("$", " ".join(cmd), flush=True)
            proc = subprocess.Popen(cmd, stdout=open(os.path.join(work, "server.log"), "w"), stderr=subprocess.STDOUT)
            server = f"http://127.0.0.1:{args.port}"
        try:
            stats = run(argparse.Namespace(server=server, input=batch, output=output, resume_from="",
                                           parallel=args.parallel, timeout=args.timeout, hours=0, limit=args.limit,
                                           report=10, thinking=args.reasoning_budget != 0))
        finally:
            if proc:
                proc.terminate()
                try:
                    proc.wait(30)
                except subprocess.TimeoutExpired:
                    proc.kill()
        json.dump(stats, open(os.path.join(work, "speed.json"), "w"))
    if "score" in stages:
        if not in_repo():
            raise SystemExit("Scoring needs the repository: copy batch-output.jsonl to the Mac and run --stage score.")
        sh([PY, "-I", os.path.join(REPO, "Scripts", "distill_reader.py"), "collect", "--name", name, "--results", output],
           stdout=subprocess.DEVNULL)
        table = subprocess.run([PY, "-I", os.path.join(REPO, "Tools", "DetectionLab", "check_sweep.py"),
                                f"teacher:{name}", "test", "--tag", f"quick-{name}"],
                               capture_output=True, text=True, cwd=REPO,
                               env=dict(os.environ, READER_OUT="p66",
                                        LAB_SEGMENTS=os.environ.get("LAB_SEGMENTS", os.path.join(REPO, "build", "p66", "lab-segments"))))
        report = [f"Quick check · {name} · {args.model} {args.file} · prompt {args.prompt_variant} · "
                  f"reasoning budget {args.reasoning_budget}", "(a go / no-go on his 11 test episodes; not a tuning set)", "",
                  table.stdout.strip() or table.stderr[-2000:]]
        speed = stats or (json.load(open(os.path.join(work, "speed.json"))) if os.path.exists(os.path.join(work, "speed.json")) else None)
        if speed and speed.get("n"):
            windows, episodes = pool_windows()
            per = speed["wall"] / speed["n"]
            report += ["", f"speed here: {speed['prompt'] / speed['wall']:.0f} prompt tok/s · "
                           f"{speed['completion'] / speed['wall']:.1f} answer tok/s · {per:.1f} s per window · {speed['failed']} failed",
                       f"the unlabelled pool ({episodes} episodes, {windows} windows) at this speed: {windows * per / 3600:.1f} h"]
        text = "\n".join(report)
        print(text)
        open(os.path.join(work, "result.txt"), "w").write(text + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("setup")
    s.add_argument("--tag", default="b12283")
    s.add_argument("--cuda-arch", default="75")
    f = sub.add_parser("fetch")
    f.add_argument("--repo", default="unsloth/Qwen3.8-27B-GGUF")
    f.add_argument("--pattern", default="*UD-Q4_K_XL*")
    v = sub.add_parser("serve")
    v.add_argument("--gguf", default="")
    v.add_argument("--binary", default="")
    v.add_argument("--port", type=int, default=8080)
    v.add_argument("--parallel", type=int, default=4)
    v.add_argument("--ctx", type=int, default=16384, help="context per parallel slot")
    v.add_argument("--split", default="1,1", help="tensor split across GPUs ('' for one GPU)")
    r = sub.add_parser("run")
    r.add_argument("--server", default="http://127.0.0.1:8080")
    r.add_argument("--input", required=True)
    r.add_argument("--output", required=True)
    r.add_argument("--resume-from", default="")
    r.add_argument("--parallel", type=int, default=4)
    r.add_argument("--timeout", type=int, default=900)
    r.add_argument("--hours", type=float, default=0, help="stop starting new windows after this long")
    r.add_argument("--limit", type=int, default=0)
    r.add_argument("--report", type=int, default=20)
    v.add_argument("--reasoning-budget", type=int, default=0)
    q = sub.add_parser("quick", help="the 11 test episodes as a go / no-go check of a teacher model")
    q.add_argument("--model", required=True, help="Hugging Face repo of the GGUF")
    q.add_argument("--file", required=True, help="the GGUF file name (or a pattern; a split model's first part)")
    q.add_argument("--prompt-variant", choices=["baseline", "why-first"], default="baseline")
    q.add_argument("--reasoning-budget", type=int, default=0, help="0: thinking off (default); -1: unlimited")
    q.add_argument("--name", default="")
    q.add_argument("--served-name", default="teacher", help="the model name written into the requests")
    q.add_argument("--stage", choices=["all", "batch", "run", "score"], default="all")
    q.add_argument("--input", default="", help="a batch built elsewhere (--stage run on Kaggle)")
    q.add_argument("--results", default="", help="the answers file (default beside the batch)")
    q.add_argument("--gguf", default="", help="a local GGUF instead of fetching")
    q.add_argument("--binary", default="")
    q.add_argument("--server", default="", help="an OpenAI-compatible server already running")
    q.add_argument("--port", type=int, default=8080)
    q.add_argument("--parallel", type=int, default=4)
    q.add_argument("--ctx", type=int, default=16384)
    q.add_argument("--split", default="1,1")
    q.add_argument("--timeout", type=int, default=900)
    q.add_argument("--limit", type=int, default=0, help="answer only the first n windows (smoke test)")
    args = ap.parse_args()
    {"setup": setup, "fetch": fetch, "serve": serve, "run": run, "quick": quick}[args.cmd](args)


if __name__ == "__main__":
    main()
