#!/usr/bin/env python3
"""Pass 65 route 2 (build/p65/ship-rule-6.txt), unattended: a large teacher on
Kaggle's free GPUs, scored before it labels anything, then trained in only if
it beats the Reader. Runs on the Mac in the background for as long as it
takes (Kaggle gives about 30 GPU-hours a week; it waits for the quota to come
back); no Claude needed.

One-time setup by him (I never see the credential):
    ~/Developer/pk-ml/bin/kaggle auth login        (browser sign-in; or save a token to ~/.kaggle/access_token)
    Kaggle account → phone verified (Kaggle needs it for GPU and internet in notebooks)

Then:
    ~/Developer/pk-ml/bin/python -I Tools/ReaderData/kaggle_auto.py all --name qwen38-27b

Steps of `all` (each also its own command):
  run       his 71 labelled episodes (build/p57/teachers/<name>/batch-input.jsonl) through the teacher:
            upload a private Dataset (runner + batch + answers so far), push a private GPU T4 x2 script
            that builds llama.cpp b12283, fetches the GGUF and answers windows for up to --hours, download its
            answers, repeat until every window is answered
  qualify   collect + score: its cuts on the 11 test episodes through the PodSkipper test against the
            shipped Reader's score (build/p64/score-kinds1-test.txt, 91.8) — rule 6: below the Reader → stop
  pool      if it qualified: the same over his unlabelled episodes (distill_reader.py annotate batch --order pool)
  train     rule 6 run B: Tools/ReaderData/reader_run.sh tb with TEACHER=<name> (silver labels), steps A and B

Everything it uploads goes to private Kaggle Datasets/Notebooks on his account: the batch files hold his
episodes' transcripts (public podcasts from his library). Nothing is made public.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PY = os.path.expanduser("~/Developer/pk-ml/bin/python")
KAGGLE = os.path.expanduser("~/Developer/pk-ml/bin/kaggle")
TEACHERS = os.path.join(ROOT, "build", "p57", "teachers")
WORK = os.path.join(ROOT, "build", "p65", "kaggle")


def log(*a):
    line = time.strftime("%d %b %H:%M:%S ") + " ".join(str(x) for x in a)
    print(line, flush=True)
    os.makedirs(WORK, exist_ok=True)
    open(os.path.join(WORK, "kaggle_auto.log"), "a").write(line + "\n")


def kaggle(*args, check=True):
    r = subprocess.run([KAGGLE, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"kaggle {' '.join(args)}: {(r.stderr or r.stdout).strip()[-400:]}")
    return (r.stdout or "") + (r.stderr or "")


def username():
    out = kaggle("config", "view", check=False)
    m = re.search(r"username:\s*(\S+)", out)
    if not m:
        raise SystemExit("Not signed in to Kaggle: run  ~/Developer/pk-ml/bin/kaggle auth login  first.")
    return m.group(1)


def check(args):
    user = username()
    log("signed in to Kaggle as", user)
    log(kaggle("quota", check=False).strip()[-600:])


def answered(path):
    done = set()
    if os.path.exists(path):
        for line in open(path):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if (row.get("response") or {}).get("status_code") == 200:
                done.add(row["custom_id"])
    return done


def merge_answers(into, new):
    """Keeps one answer per window (the first good one)."""
    rows, seen = [], set()
    for path in (into, new):
        if not os.path.exists(path):
            continue
        for line in open(path):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if (row.get("response") or {}).get("status_code") == 200 and row["custom_id"] not in seen:
                seen.add(row["custom_id"])
                rows.append(line if line.endswith("\n") else line + "\n")
    with open(into + ".tmp", "w") as f:
        f.writelines(rows)
    os.replace(into + ".tmp", into)
    return len(seen)


KERNEL = r'''
import glob, json, os, subprocess, sys, time
d = os.path.dirname(glob.glob("/kaggle/input/**/kaggle_teacher.py", recursive=True)[0])
job = json.load(open(os.path.join(d, "job.json")))
t = [sys.executable, os.path.join(d, "kaggle_teacher.py")]
print(open("/proc/driver/nvidia/gpus/" + os.listdir("/proc/driver/nvidia/gpus")[0] + "/information").read()
      if os.path.isdir("/proc/driver/nvidia/gpus") else "no GPU visible", flush=True)
subprocess.run(t + ["setup"], check=True)
subprocess.run(t + ["fetch", "--repo", job["repo"], "--pattern", job["pattern"]], check=True)
server = subprocess.Popen(t + ["serve", "--parallel", str(job["parallel"]), "--ctx", str(job["ctx"])],
                          stdout=open("/kaggle/working/server.log", "w"), stderr=subprocess.STDOUT)
earlier = os.path.join(d, "batch-output.jsonl")
subprocess.run(t + ["run", "--input", os.path.join(d, "batch-input.jsonl"), "--output", "/kaggle/working/batch-output.jsonl",
                    "--resume-from", earlier if os.path.exists(earlier) else "", "--parallel", str(job["parallel"]),
                    "--hours", str(job["hours"])], check=False)
server.terminate()
'''


def one_session(args, user, batch, answers, tag):
    """Upload, push, wait, download. Returns the number of windows answered so far."""
    slug = f"podskipper-teacher-{args.name}-{tag}"[:50].rstrip("-")
    # A notebook can't share its dataset's name (Kaggle answers 409 Conflict; found 14 Nov).
    kernel = f"podskipper-run-{args.name}-{tag}"[:50].rstrip("-")
    data = os.path.join(WORK, slug, "data")
    code = os.path.join(WORK, slug, "code")
    shutil.rmtree(os.path.join(WORK, slug), ignore_errors=True)
    os.makedirs(data)
    os.makedirs(code)
    shutil.copy2(os.path.join(HERE, "kaggle_teacher.py"), data)
    shutil.copy2(batch, os.path.join(data, "batch-input.jsonl"))
    if os.path.exists(answers):
        shutil.copy2(answers, os.path.join(data, "batch-output.jsonl"))
    json.dump({"repo": args.repo, "pattern": args.pattern, "parallel": args.parallel, "ctx": args.ctx,
               "hours": args.hours}, open(os.path.join(data, "job.json"), "w"))
    json.dump({"title": slug, "id": f"{user}/{slug}", "licenses": [{"name": "unknown"}]},
              open(os.path.join(data, "dataset-metadata.json"), "w"))
    exists = "ready" in kaggle("datasets", "status", f"{user}/{slug}", check=False).lower()
    if exists:
        kaggle("datasets", "version", "-p", data, "-m", time.strftime("answers to %d %b %H:%M"))
    else:
        kaggle("datasets", "create", "-p", data)          # private unless --public is given
    for _ in range(60):                                    # the new version must be ready before the notebook starts
        if "ready" in kaggle("datasets", "status", f"{user}/{slug}", check=False).lower():
            break
        time.sleep(20)
    open(os.path.join(code, "teacher_session.py"), "w").write(KERNEL)
    json.dump({"id": f"{user}/{kernel}", "title": kernel, "code_file": "teacher_session.py", "language": "python",
               "kernel_type": "script", "is_private": "true", "enable_gpu": "true", "enable_tpu": "false",
               "enable_internet": "true", "machine_shape": "NvidiaTeslaT4", "dataset_sources": [f"{user}/{slug}"],
               "competition_sources": [], "kernel_sources": [], "model_sources": []},
              open(os.path.join(code, "kernel-metadata.json"), "w"), indent=1)
    log("pushing", f"{user}/{kernel}", "(GPU T4 x2)")
    log(kaggle("kernels", "push", "-p", code, "--accelerator", "NvidiaTeslaT4").strip()[-300:])
    started = time.time()
    while True:
        time.sleep(300)
        status = kaggle("kernels", "status", f"{user}/{kernel}", check=False)
        state = (re.search(r'status "([^"]+)"', status) or re.search(r"(\w+)$", status.strip()) or [None, status])[1]
        if any(k in state.lower() for k in ("complete", "error", "cancel")):
            log("session", state, f"after {(time.time() - started) / 3600:.1f} h")
            break
        if time.time() - started > 13 * 3600:
            log("session still not finished after 13 h; collecting what it wrote")
            break
    out = os.path.join(WORK, slug, "output")
    shutil.rmtree(out, ignore_errors=True)
    kaggle("kernels", "output", f"{user}/{kernel}", "-p", out, check=False)
    # Kaggle runs a notebook on CPU with no internet when the account isn't phone-verified, even with the GPU
    # and internet switched on in its settings (14 Nov: "no GPU visible", "Could not resolve host: github.com").
    runlog = "".join(open(os.path.join(out, f)).read() for f in os.listdir(out) if f.endswith(".log")) \
        if os.path.isdir(out) else ""
    if "no GPU visible" in runlog or "Could not resolve host" in runlog:
        log("Kaggle ran the session without a GPU or internet")
        raise SystemExit("Kaggle gave the notebook no GPU and no internet: verify your phone number on Kaggle "
                         "(kaggle.com → Settings → Phone verification), then run the same command again.")
    got = os.path.join(out, "batch-output.jsonl")
    n = merge_answers(answers, got) if os.path.exists(got) else len(answered(answers))
    if os.path.exists(os.path.join(out, "server.log")):
        shutil.copy2(os.path.join(out, "server.log"), os.path.join(WORK, f"{slug}-server.log"))
    return n


def run_batch(args, batch, tag):
    """Sessions until every window of `batch` is answered (waiting out the weekly quota)."""
    user = username()
    answers = os.path.join(os.path.dirname(batch), "batch-output.jsonl")
    total = sum(1 for l in open(batch) if l.strip())
    tries_without_progress = 0
    while True:
        done = len(answered(answers))
        log(f"{tag}: {done} of {total} windows answered")
        if done >= total:
            return answers
        try:
            n = one_session(args, user, batch, answers, tag)
        except RuntimeError as error:
            text = str(error)
            # Out of quota or busy: wait. Anything else is a mistake to fix, not to retry every 6 h.
            if not re.search(r"quota|429|503|rate|limit|busy|unavailable|timed? ?out", text, re.I):
                log("Kaggle refused:", text)
                raise SystemExit("stopped: fix the cause above, then run the same command again (it resumes)")
            log("Kaggle refused:", text, "— trying again in 6 h")
            time.sleep(6 * 3600)
            continue
        if n <= done:
            tries_without_progress += 1
            wait = 6 if tries_without_progress < 3 else 24
            log(f"no new answers this session; waiting {wait} h (out of quota, or the session failed: see "
                f"build/p65/kaggle/*-server.log)")
            time.sleep(wait * 3600)
        else:
            tries_without_progress = 0


def collect(name, answers):
    subprocess.run([PY, "-I", os.path.join(ROOT, "Scripts", "distill_reader.py"), "collect", "--name", name,
                    "--results", answers], check=True)


def reader_score():
    first = open(os.path.join(ROOT, "build", "p64", "score-kinds1-test.txt")).readline()
    return float(re.search(r"\*\*([0-9.]+)\*\*", first).group(1))


def qualify(args):
    folder = os.path.join(TEACHERS, args.name)
    answers = os.path.join(folder, "batch-output.jsonl")
    collect(args.name, answers)
    subprocess.run([PY, "-I", os.path.join(ROOT, "Scripts", "distill_reader.py"), "score", "--name", args.name], check=True)
    out = subprocess.run([PY, "-I", os.path.join(HERE, "podtest.py"), "test",
                          f"{args.name}={os.path.join(folder, 'cuts.json')}:{args.name}"],
                         capture_output=True, text=True, cwd=ROOT).stdout
    rows = [l for l in out.splitlines() if l.startswith(f"| {args.name} |")]
    if not rows:
        raise SystemExit("the PodSkipper test printed no score for the teacher:\n" + out[-800:])
    score = float(re.search(r"\*\*([0-9.]+)\*\*", rows[0]).group(1))
    reader = reader_score()
    ok = score >= reader
    verdict = (f"{args.name}: PodSkipper test on the 11 test episodes {score} vs the shipped Reader {reader} → "
               f"{'QUALIFIES' if ok else 'does not qualify (rule 6: it labels nothing)'}")
    open(os.path.join(folder, "qualify.txt"), "w").write(verdict + "\n" + out)
    log(verdict)
    return ok


def pool_batch(args):
    folder = os.path.join(TEACHERS, args.name)
    pool = os.path.join(folder, "pool")
    os.makedirs(pool, exist_ok=True)
    subprocess.run([PY, "-I", os.path.join(ROOT, "Scripts", "distill_reader.py"), "annotate", "batch", "--name",
                    args.name, "--model", args.model, "--order", "pool"], check=True)
    # annotate batch writes batch-input.jsonl beside the scoring one; keep the two apart.
    shutil.move(os.path.join(folder, "batch-input.jsonl"), os.path.join(pool, "batch-input.jsonl"))
    return os.path.join(pool, "batch-input.jsonl")


def train(args):
    """Rule 6 run B (amendment 1)."""
    p65 = os.path.join(ROOT, "build", "p65")
    a_passed = os.path.exists(os.path.join(p65, "matchedsb.txt")) and "PASSES" in open(os.path.join(p65, "matchedsb.txt")).read()
    env = dict(os.environ, TEACHER=args.name,
               PRE=os.path.join(p65, "pre13sb.pt") if a_passed else os.path.join(ROOT, "build", "p58", "pre13.pt"),
               TWIN13="build/p65/sx13sb" if a_passed else "build/p58/ext13",
               TWIN17="build/p65/sx17sb" if a_passed else "build/p58/ext17")
    log("run B from", "route 1's stage 1" if a_passed else "Pass 58's stage 1", "with the teacher's silver labels")
    script = os.path.join(HERE, "reader_run.sh")
    subprocess.run(["zsh", script, "tb", "-", "sx13", "sx17", "stepa"], cwd=ROOT, env=env, check=True)
    if "PASSES" in open(os.path.join(p65, "matchedtb.txt")).read():
        subprocess.run(["zsh", script, "tb", "-", "stepb"], cwd=ROOT, env=env, check=True)
    else:
        log("run B step A did not pass; step B not run (rule 6)")


def single_copy():
    """One copy at a time: two would push the same notebook and trip over each other."""
    lock = os.path.join(WORK, "run.lock")
    os.makedirs(WORK, exist_ok=True)
    if os.path.exists(lock):
        try:
            pid = int(open(lock).read().strip() or 0)
            os.kill(pid, 0)
            raise SystemExit(f"already running (process {pid}); see build/p65/kaggle/kaggle_auto.log")
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    open(lock, "w").write(str(os.getpid()))


def run_all(args):
    scoring = os.path.join(TEACHERS, args.name, "batch-input.jsonl")
    if not os.path.exists(scoring):
        raise SystemExit(f"no scoring batch at {scoring}: distill_reader.py annotate batch --name {args.name} "
                         f"--model {args.model} --order test")
    run_batch(args, scoring, "score")
    if not qualify(args):
        return
    pool = os.path.join(TEACHERS, args.name, "pool", "batch-input.jsonl")
    if not os.path.exists(pool):
        pool = pool_batch(args)
    collect(args.name, run_batch(args, pool, "pool"))
    train(args)
    log("route 2 finished; reports in build/p65/ (matchedtb.txt, stepb-tb.txt)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "run", "qualify", "pool", "train", "all"])
    ap.add_argument("--name", default="qwen38-27b")
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--repo", default="unsloth/Qwen3.8-27B-GGUF")
    ap.add_argument("--pattern", default="*UD-Q4_K_XL*")
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--ctx", type=int, default=16384)
    ap.add_argument("--hours", type=float, default=10.0, help="answering time per session; setup (~30 min) comes on top, and Kaggle saves nothing from a run past 12 h")
    args = ap.parse_args()
    if args.cmd in ("run", "pool", "all", "train"):
        single_copy()
    if args.cmd == "check":
        check(args)
    elif args.cmd == "run":
        run_batch(args, os.path.join(TEACHERS, args.name, "batch-input.jsonl"), "score")
    elif args.cmd == "qualify":
        qualify(args)
    elif args.cmd == "pool":
        collect(args.name, run_batch(args, pool_batch(args), "pool"))
    elif args.cmd == "train":
        train(args)
    else:
        run_all(args)


if __name__ == "__main__":
    main()
