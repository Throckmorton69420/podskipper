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
                 f"-DCMAKE_CUDA_ARCHITECTURES={args.cuda_arch}", "-DLLAMA_CURL=OFF", "-DCMAKE_BUILD_TYPE=Release"]
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
    cmd = [binary, "-m", gguf, "--host", "127.0.0.1", "--port", str(args.port), "-ngl", "999",
           "--parallel", str(args.parallel), "-c", str(args.ctx * args.parallel), "--jinja",
           "--reasoning-budget", "0", "-fa", "on", "--no-webui"]
    if args.split:
        cmd += ["--split-mode", "layer", "--tensor-split", args.split]
    print("$", " ".join(cmd), flush=True)
    os.execv(binary, cmd)


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


def run(args):
    server = args.server.rstrip("/")
    wait_for(server)
    done = set()
    for path in filter(None, [args.output, args.resume_from]):
        if os.path.exists(path):
            for line in open(path):
                try:
                    row = json.loads(line)
                    if row.get("response", {}).get("status_code") == 200:
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
    t0, stats = time.time(), {"n": 0, "prompt": 0, "completion": 0, "failed": 0}
    deadline = t0 + args.hours * 3600 if args.hours else None

    def one(row):
        if deadline and time.time() > deadline:
            return
        body = dict(row["body"])
        body["chat_template_kwargs"] = {"enable_thinking": False}
        req = urllib.request.Request(server + "/v1/chat/completions", data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        result, error = None, None
        for attempt in range(3):
            try:
                with urllib.request.urlopen(req, timeout=args.timeout) as r:
                    result = json.load(r)
                break
            except Exception as e:  # noqa: BLE001 — retried, then recorded
                error = str(e)
                time.sleep(5 * (attempt + 1))
        with lock:
            if result is None:
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
                      f"{stats['completion'] / wall:.1f} answer tok/s · {stats['failed']} failed · "
                      f"{left / 3600:.1f} h left", flush=True)

    with cf.ThreadPoolExecutor(args.parallel) as pool:
        list(pool.map(one, todo))
    out.close()
    print(f"wrote {args.output} ({stats['n']} windows this session, {time.time() - t0:.0f} s)")


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
    args = ap.parse_args()
    {"setup": setup, "fetch": fetch, "serve": serve, "run": run}[args.cmd](args)


if __name__ == "__main__":
    main()
