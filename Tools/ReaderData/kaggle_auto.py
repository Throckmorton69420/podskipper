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

Stuck in Kaggle's queue (Pass 73): by default (--restarts 0) nothing is pushed again — pushing again didn't unstick
Kaggle's Nov 2026 T4 x2 queue and spends the 2-session batch GPU cap. A run QUEUED for --queue-minutes (15) gets an
ALERT line in the log with the notebook's URL; the job keeps polling (every 5 min) and follows the batch run as soon
as it is RUNNING. Leave the notebook alone in the web UI: Edit/Internet toggles/Quick Save/Run each make a new version,
and the CLI reads only the latest, so a Quick Save (COMPLETE at once, no output) hid the real run on 27 Nov. A delete +
fresh push started in 1 min on 26 Nov but not on 27 Nov (nor a new notebook name): then it is Kaggle's capacity; wait.
--restarts N > 0 brings back the old re-push (each stuck version named in the log; a stuck run that starts later exits
on its token without using the GPU), then the same alert. Every push carries `-t` (--hours + 1 h, at most 42,000 s).

A second Kaggle account (Pass 73): --kaggle-home <dir> runs every `kaggle` call with HOME=<dir> (and no KAGGLE_*
credential variables), so the CLI reads <dir>/.kaggle/credentials.json — CLI 2.2.5's OAuth file is fixed at
~/.kaggle/credentials.json and ignores KAGGLE_CONFIG_DIR. Only those subprocesses see it: this process's HOME, the
batch/answer paths and the pk-ml tools are unchanged. Its lock and log get the directory's name
(build/p65/kaggle/run-<name>.lock, kaggle_auto-<name>.log), so one job per account can run at once.

By hand (Terminal app, any tab, or a `!` command in the chat — detach.py keeps the job alive after its shell closes):
    ~/Developer/pk-ml/bin/python -I Tools/ReaderData/kaggle_auto.py status   is it running, the Kaggle run, quota
    ~/Developer/pk-ml/bin/python -I Tools/ReaderData/kaggle_auto.py stop     stop the job (a Kaggle run carries on)
    kaggle.com → Your Work → podskipper-run-… → Versions → ⋯ → Stop        stop a stuck or unwanted Kaggle run
    cd ~/Developer/podskipper && ~/Developer/pk-ml/bin/python -I Tools/ReaderData/detach.py build/p65/kaggle/run.log \
        ~/Developer/pk-ml/bin/python -I Tools/ReaderData/kaggle_auto.py all      start again: answers so far are kept,
                                                                                  a run already on Kaggle is followed

Everything it uploads goes to private Kaggle Datasets/Notebooks on his account: the batch files hold his
episodes' transcripts (public podcasts from his library). Nothing is made public.
"""
import argparse
import atexit
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


KAGGLE_HOME = ""          # Pass 73: --kaggle-home; "" = this account (~/.kaggle)
CRED_VARS = ("KAGGLE_CONFIG_DIR", "KAGGLE_USERNAME", "KAGGLE_KEY", "KAGGLE_API_TOKEN", "XDG_CONFIG_HOME")


def account_tag():
    """'' for the default account, else the --kaggle-home directory's name without dots ('.kaggle-b' → 'kaggle-b')."""
    return re.sub(r"[^A-Za-z0-9_-]", "", os.path.basename(os.path.normpath(KAGGLE_HOME))) if KAGGLE_HOME else ""


def work_file(stem, ext):
    tag = account_tag()
    return os.path.join(WORK, f"{stem}-{tag}{ext}" if tag else f"{stem}{ext}")


def kaggle_env():
    """The environment of a `kaggle` subprocess. Only it gets the other HOME; os.environ is never changed."""
    if not KAGGLE_HOME:
        return None
    env = {k: v for k, v in os.environ.items() if k not in CRED_VARS}
    env["HOME"] = KAGGLE_HOME
    return env


def log(*a):
    line = time.strftime("%d %b %H:%M:%S ") + (f"[{account_tag()}] " if KAGGLE_HOME else "") + " ".join(str(x) for x in a)
    print(line, flush=True)
    os.makedirs(WORK, exist_ok=True)
    open(work_file("kaggle_auto", ".log"), "a").write(line + "\n")


def kaggle(*args, check=True):
    r = subprocess.run([KAGGLE, *args], capture_output=True, text=True, env=kaggle_env())
    if check and r.returncode != 0:
        raise RuntimeError(f"kaggle {' '.join(args)}: {(r.stderr or r.stdout).strip()[-400:]}")
    return (r.stdout or "") + (r.stderr or "")


def username():
    out = kaggle("config", "view", check=False)
    m = re.search(r"username:\s*(\S+)", out)
    if not m:
        raise SystemExit("Not signed in to Kaggle: run  " + (f'HOME="{KAGGLE_HOME}" ' if KAGGLE_HOME else "")
                         + "~/Developer/pk-ml/bin/kaggle auth login  first.")
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


def too_long(row):
    """Pass 69: llama-server refused the window as longer than its context (kaggle_teacher.py records it once)."""
    return ((row.get("response") or {}).get("status_code") == 400
            and (row.get("error") or {}).get("code") == "context_length_exceeded")


def terminal_skipped(path):
    """Windows recorded as too long for the server and never answered: done for the job, but not answers
    (collect / sporc_teacher_batch.py read status 200 only)."""
    skipped = set()
    if os.path.exists(path):
        for line in open(path):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if too_long(row):
                skipped.add(row["custom_id"])
    return skipped - answered(path)


def merge_answers(into, new):
    """Keeps one answer per window (the first good one), and a too-long record for a window with no answer."""
    rows, seen, terminal = [], set(), {}
    for path in (into, new):
        if not os.path.exists(path):
            continue
        for line in open(path):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            line = line if line.endswith("\n") else line + "\n"
            if (row.get("response") or {}).get("status_code") == 200 and row["custom_id"] not in seen:
                seen.add(row["custom_id"])
                rows.append(line)
            elif too_long(row):
                terminal.setdefault(row["custom_id"], line)
    rows += [line for cid, line in terminal.items() if cid not in seen]
    with open(into + ".tmp", "w") as f:
        f.writelines(rows)
    os.replace(into + ".tmp", into)
    return len(seen)


KERNEL = r'''
import glob, json, os, subprocess, sys, time
d = os.path.dirname(glob.glob("/kaggle/input/**/kaggle_teacher.py", recursive=True)[0])
job = json.load(open(os.path.join(d, "job.json")))
# A run that sat stuck in Kaggle's queue and was pushed again must not also spend GPU time when it finally
# starts: each push carries its time as a token; a dataset naming a later push means this run is stale. (A
# dataset naming an earlier push only means Kaggle hadn't finished the new version yet: carry on.)
if int(job.get("token", 0)) > @TOKEN@:
    print("superseded by a newer run; exiting without using the GPU", flush=True)
    sys.exit(0)
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


def push(args, user, slug, kernel, batch, answers):
    """A new dataset version (runner, batch, answers so far, a fresh token) and a new notebook version that
    carries the same token. Returns the version number Kaggle gave the push."""
    data = os.path.join(WORK, slug, "data")
    code = os.path.join(WORK, slug, "code")
    shutil.rmtree(data, ignore_errors=True)
    shutil.rmtree(code, ignore_errors=True)
    os.makedirs(data)
    os.makedirs(code)
    token = int(time.time())
    shutil.copy2(os.path.join(HERE, "kaggle_teacher.py"), data)
    shutil.copy2(batch, os.path.join(data, "batch-input.jsonl"))
    if os.path.exists(answers):
        shutil.copy2(answers, os.path.join(data, "batch-output.jsonl"))
    json.dump({"repo": args.repo, "pattern": args.pattern, "parallel": args.parallel, "ctx": args.ctx,
               "hours": args.hours, "token": token}, open(os.path.join(data, "job.json"), "w"))
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
    time.sleep(60)   # Kaggle can report the previous version "ready" for a moment after a new one is sent
    open(os.path.join(code, "teacher_session.py"), "w").write(KERNEL.replace("@TOKEN@", str(token)))
    json.dump({"id": f"{user}/{kernel}", "title": kernel, "code_file": "teacher_session.py", "language": "python",
               "kernel_type": "script", "is_private": "true", "enable_gpu": "true", "enable_tpu": "false",
               "enable_internet": "true", "machine_shape": "NvidiaTeslaT4", "dataset_sources": [f"{user}/{slug}"],
               "competition_sources": [], "kernel_sources": [], "model_sources": []},
              open(os.path.join(code, "kernel-metadata.json"), "w"), indent=1)
    timeout = push_timeout(args.hours)
    log("pushing", f"{user}/{kernel}", f"(GPU T4 x2, -t {timeout} s)")
    said = kaggle("kernels", "push", "-p", code, "--accelerator", "NvidiaTeslaT4", "-t", str(timeout)).strip()
    log(said[-300:])
    m = re.search(r"version (\d+)", said)
    if not m or re.search(r"push error|error:", said, re.I):
        # 24 Nov: "Kernel push error: Maximum batch GPU session count of 2 reached." came back as success and the
        # job then polled the previous (COMPLETE) version as if it were the new one.
        raise RuntimeError(f"kaggle kernels push refused: {said[-300:]}")
    return int(m.group(1))


def push_timeout(hours):
    """Pass 73: a hard ceiling on the Kaggle run — answering time + 1 h for setup, at most 42,000 s (11.7 h; Kaggle
    keeps nothing past 12 h)."""
    return min(42000, int((hours + 1.0) * 3600))


def notebook_url(user, kernel):
    return f"https://www.kaggle.com/code/{user}/{kernel}"


def queue_alert(user, kernel, version, waited):
    return (f"ALERT: version {version} of {kernel} has been QUEUED {waited:.0f} min ({notebook_url(user, kernel)}). "
            f"Nothing is pushed again; this job checks every 5 min and follows the run once it is RUNNING. Don't edit, "
            f"toggle Internet, Quick Save or Run it in the web UI: each makes a new version that hides this run from the "
            f"job (27 Nov). On 26 Nov a delete + fresh push started at once; on 27 Nov neither that nor a new name did.")


def parse_status(text):
    """Extract a real Kaggle kernel status string; returns '' on transient CLI/network errors so callers never
    mistake 'NameResolutionError' or 'ConnectionError' for KernelWorkerStatus.ERROR (Pass 69: 24 Nov DNS blip)."""
    m = re.search(r'status "([^"]+)"', text)
    if m:
        return m.group(1)
    s = text.strip()
    if re.fullmatch(r"(?:KernelWorkerStatus\.)?(?:queued|running|complete|error|cancel\w*)", s, re.I):
        return s
    return ""


def state_of(user, kernel, version=None):
    ref = f"{user}/{kernel}" + (f"/{version}" if version else "")
    status = kaggle("kernels", "status", ref, check=False)
    return parse_status(status)


def download_output(user, kernel, slug, answers):
    """Download latest Kaggle kernel output with retry on transient network errors and merge into `answers`.
    Returns (total_answered_count, download_succeeded)."""
    out = os.path.join(WORK, slug, "output")
    shutil.rmtree(out, ignore_errors=True)
    ok = False
    for attempt in range(3):
        try:
            kaggle("kernels", "output", f"{user}/{kernel}", "-p", out, check=True)
            ok = True
            break
        except RuntimeError as e:
            log(f"download attempt {attempt + 1}/3 for {kernel} failed: {e}")
            if attempt < 2:
                time.sleep(10 * (attempt + 1))
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
    return n, ok


def pull(args):
    """Pass 69: download and merge a finished Kaggle kernel's output without pushing any new version."""
    user = username()
    if args.input:
        batch = os.path.abspath(args.input)
        tag = "b"
    else:
        batch = os.path.join(TEACHERS, args.name, "batch-input.jsonl")
        tag = "score"
    answers = os.path.join(os.path.dirname(batch), "batch-output.jsonl")
    slug = f"podskipper-teacher-{args.name}-{tag}"[:50].rstrip("-")
    kernel = f"podskipper-run-{args.name}-{tag}"[:50].rstrip("-")
    state = state_of(user, kernel)
    log(f"pull {user}/{kernel}: status={state or 'UNKNOWN'}")
    if state and any(k in state.lower() for k in ("running", "queued")):
        raise SystemExit(f"{user}/{kernel} is still {state}; wait for it to finish before pulling")
    _, ok = download_output(user, kernel, slug, answers)
    if not ok:
        raise SystemExit(f"could not download output for {user}/{kernel} after 3 attempts")
    ids = {json.loads(l)["custom_id"] for l in open(batch) if l.strip()} if os.path.exists(batch) else None
    done = len(answered(answers) & ids) if ids is not None else len(answered(answers))
    skipped = len(terminal_skipped(answers) & ids) if ids is not None else len(terminal_skipped(answers))
    total = len(ids) if ids is not None else "?"
    log(f"{tag}: {done} of {total} windows answered" + (f" ({skipped} too long for the server, skipped)" if skipped else ""))


def one_session(args, user, batch, answers, tag):
    """Upload, push, wait, download. Returns the number of windows answered so far.

    Kaggle's queue can stick (14 Nov: version 4 queued for 2 h; version 5, pushed then, started at once), so a
    run queued for more than --queue-minutes is pushed again, at most --restarts times; the stuck one is named
    in the log for him to stop (the CLI can't cancel a run), and if it starts anyway it exits on its token."""
    slug = f"podskipper-teacher-{args.name}-{tag}"[:50].rstrip("-")
    # A notebook can't share its dataset's name (Kaggle answers 409 Conflict; found 14 Nov).
    kernel = f"podskipper-run-{args.name}-{tag}"[:50].rstrip("-")
    # Started again while a run of ours is already on Kaggle (a restart of the job, not of the run): follow
    # that run instead of pushing a second one beside it. If a prior run finished while polling was offline,
    # collect its answers first so we never discard completed GPU work by pushing a fresh version.
    raw_already = kaggle("kernels", "status", f"{user}/{kernel}", check=False)
    already = parse_status(raw_already).lower()
    # CLI 2.2.5 answers a notebook that doesn't exist yet with "Cannot access kernel … Permission 'kernels.get' was
    # denied" (Pass 73, first push on account B), not 404.
    if not already and not re.search(r"404|not found|cannot access kernel|kernels\.get' was denied", raw_already, re.I):
        raise RuntimeError(f"could not check {kernel} status (network unavailable): {raw_already.strip()[-200:]}")
    if "complete" in already:
        before = len(answered(answers))
        before_skip = len(terminal_skipped(answers))
        log(f"{kernel} is already COMPLETE on Kaggle; collecting its output before pushing")
        n, _ = download_output(user, kernel, slug, answers)
        if n > before or len(terminal_skipped(answers)) > before_skip:
            return n
    if "running" in already or "queued" in already:
        log(f"a run of {kernel} is already {already.split('.')[-1].rstrip(chr(34))} on Kaggle; following it")
        version = None
    else:
        version = push(args, user, slug, kernel, batch, answers)
    pushed, stuck, restarts, running_since, bad_polls = time.time(), [], 0, None, 0
    alerted = None
    log(f"notebook {notebook_url(user, kernel)}")
    while True:
        # 27 Nov: queued runs were polled every 60 s; one status call per 5 min is plenty for a queue that takes hours.
        time.sleep(300)
        state = state_of(user, kernel)
        if not state:
            bad_polls += 1
            log(f"poll of {kernel} returned no status ({bad_polls} consecutive; transient network error?) — continuing")
            if running_since and time.time() - running_since > 13 * 3600:
                log("session still not finished after 13 h; collecting what it wrote")
                break
            continue
        bad_polls = 0
        for old in stuck:
            if "running" in state_of(user, kernel, old).lower():
                log(f"WARNING: stuck version {old} has started after all; it exits on its token, "
                    f"but stop it on Kaggle to be sure (notebook {kernel}, version {old})")
        low = state.lower()
        if "queued" in low:
            waited = (time.time() - pushed) / 60
            if waited < args.queue_minutes:
                continue
            if restarts >= args.restarts:
                # Pass 73: no push; alert him (again every hour) and keep following this version.
                if alerted is None or time.time() - alerted >= 3600:
                    log(queue_alert(user, kernel, version, waited))
                    alerted = time.time()
                continue
            restarts += 1
            if version:
                stuck.append(version)
            log(f"version {version} queued {waited:.0f} min — pushing again ({restarts} of {args.restarts}); "
                f"stop version {version} on Kaggle if it is still listed (Your Work → {kernel} → Versions)")
            version = push(args, user, slug, kernel, batch, answers)
            pushed = time.time()
            continue
        if "running" in low and running_since is None:
            running_since = time.time()
            log(f"version {version} running after {(running_since - pushed) / 60:.0f} min in the queue"
                + (" (unstuck after the alert)" if alerted else "") + f" — {notebook_url(user, kernel)}")
        if any(k in low for k in ("complete", "error", "cancel")):
            log("session", state, f"after {(time.time() - (running_since or pushed)) / 3600:.1f} h of running")
            break
        if running_since and time.time() - running_since > 13 * 3600:
            log("session still not finished after 13 h; collecting what it wrote")
            break
    for old in stuck:
        if "running" in state_of(user, kernel, old).lower():
            log(f"WARNING: version {old} is running — stop it on Kaggle (it should exit on its own at once)")
    n, _ = download_output(user, kernel, slug, answers)
    return n


def run_batch(args, batch, tag, max_idle=None, fatal=False):
    """Sessions until every window of `batch` is answered (waiting out the weekly quota). Pass 67: with
    max_idle=n, gives up (returns the answers so far) after n sessions that added nothing; Pass 69: fatal=True
    (batch mode) exits 1 instead, so a caller script stops rather than going on with missing answers. Windows the
    server refused as too long count as done (not as answers)."""
    user = username()
    answers = os.path.join(os.path.dirname(batch), "batch-output.jsonl")
    ids = {json.loads(l)["custom_id"] for l in open(batch) if l.strip()}
    total = len(ids)
    tries_without_progress = 0
    while True:
        done = len(answered(answers) & ids)
        skipped = len(terminal_skipped(answers) & ids)
        log(f"{tag}: {done} of {total} windows answered" + (f" ({skipped} too long for the server, skipped)" if skipped else ""))
        if done + skipped >= total:
            return answers
        try:
            n = one_session(args, user, batch, answers, tag)
        except RuntimeError as error:
            text = str(error)
            # Out of quota, busy, or transient network blip: wait. Anything else is a mistake to fix, not to retry every 6 h.
            if not re.search(r"quota|429|503|rate|limit|busy|unavailable|timed? ?out|network|dns|resolve|connection|"
                             r"session count|maximum batch", text, re.I):
                log("Kaggle refused:", text)
                raise SystemExit("stopped: fix the cause above, then run the same command again (it resumes)")
            log("Kaggle refused:", text, "— trying again in 6 h")
            time.sleep(6 * 3600)
            continue
        n = len(answered(answers) & ids)
        newly_skipped = len(terminal_skipped(answers) & ids) - skipped
        if n <= done and newly_skipped <= 0:
            tries_without_progress += 1
            if max_idle is not None and tries_without_progress >= max_idle:
                log(f"{tag}: {tries_without_progress} session(s) added no answers; giving up on this batch "
                    f"(see build/p65/kaggle/*-server.log)")
                if fatal:
                    raise SystemExit(1)
                return answers
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


# Pass 67: the teacher quick check on Kaggle (his 17 Nov go-ahead: his 11 test transcripts may go to private
# Kaggle datasets). Each candidate: the 11-test-episode batch (why-first prompt with the five rules) built here,
# answered on a GPU T4 x2 session, then scored here through the app's own check (kaggle_teacher.py quick
# --stage score). A go / no-go per model, never a tuning set.
QUICK_DEFAULT = [
    "nemobolt|nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB-GGUF|NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB.gguf",
    "gemma31qat|google/gemma-4-31B-it-qat-q4_0-gguf|gemma-4-31B_q4_0-it.gguf",
    "qwen36a3b|unsloth/Qwen3.6-35B-A3B-GGUF|Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf",
]


def quick(args):
    results = []
    for spec in args.candidate or QUICK_DEFAULT:
        short, repo, gguf = spec.split("|")
        qname = f"quick-{short}-{args.variant}"
        work = os.path.join(ROOT, "build", "p66", "quick", qname)
        batch = os.path.join(work, "batch-input.jsonl")
        teacher = [PY, "-I", os.path.join(HERE, "kaggle_teacher.py"), "quick", "--name", qname, "--model", repo,
                   "--file", gguf, "--prompt-variant", args.variant]
        if not os.path.exists(batch):
            subprocess.run(teacher + ["--stage", "batch"], cwd=ROOT, check=True)
        a = argparse.Namespace(**dict(vars(args), name=f"q-{short}", repo=repo, pattern=gguf, hours=args.quick_hours))
        log(f"quick check {qname}: {repo} {gguf}")
        answers = run_batch(a, batch, "quick", max_idle=1)
        total = sum(1 for l in open(batch) if l.strip())
        got = len(answered(answers))
        slug = f"podskipper-teacher-q-{short}-quick"[:50].rstrip("-")
        speed = os.path.join(WORK, slug, "output", "batch-output.jsonl.speed.json")
        if os.path.exists(speed):
            shutil.copy2(speed, os.path.join(work, "speed.json"))
        if got == 0:
            results.append(f"## {qname}\n\nno answers (see build/p65/kaggle/{slug}-server.log)\n")
            log(f"quick check {qname}: no answers")
            continue
        subprocess.run(teacher + ["--stage", "score", "--results", answers], cwd=ROOT, check=False)
        text = open(os.path.join(work, "result.txt")).read() if os.path.exists(os.path.join(work, "result.txt")) else "(no result)"
        results.append(f"## {qname}\n\n{got} of {total} windows answered\n\n```\n{text}```\n")
        log(f"quick check {qname}: {got}/{total} windows scored")
        out = os.path.join(ROOT, "build", "p67", "teacher-quick-raw.md")
        os.makedirs(os.path.dirname(out), exist_ok=True)
        open(out, "w").write("# Teacher quick checks (11 test episodes, Kaggle GPU T4 x2)\n\n" + "\n".join(results))
    log("quick checks finished: build/p67/teacher-quick-raw.md")


def single_copy():
    """One copy at a time: two would push the same notebook and trip over each other."""
    lock = work_file("run", ".lock")
    os.makedirs(WORK, exist_ok=True)
    if os.path.exists(lock):
        try:
            pid = int(open(lock).read().strip() or 0)
            os.kill(pid, 0)
            raise SystemExit(f"already running (process {pid}); see {os.path.relpath(work_file('kaggle_auto', '.log'), ROOT)}")
        except (ValueError, ProcessLookupError, PermissionError):
            pass
    my_pid = str(os.getpid())
    open(lock, "w").write(my_pid)

    def _release():
        try:
            if os.path.exists(lock) and open(lock).read().strip() == my_pid:
                os.remove(lock)
        except OSError:
            pass
    atexit.register(_release)


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


def job_pid():
    lock = work_file("run", ".lock")
    try:
        pid = int(open(lock).read().strip() or 0)
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def status(args):
    """For him: is the job running, what it said last, where the Kaggle run is, how much quota is left."""
    pid = job_pid()
    print("job:", f"running (process {pid})" if pid else "not running")
    logf = work_file("kaggle_auto", ".log")
    if os.path.exists(logf):
        print(f"last lines of {os.path.relpath(logf, ROOT)}:")
        print("".join(open(logf).readlines()[-6:]), end="")
    user = username()
    for tag in ("score", "pool", "b"):
        kernel = f"podskipper-run-{args.name}-{tag}"[:50].rstrip("-")
        said = kaggle("kernels", "status", f"{user}/{kernel}", check=False).strip().splitlines()
        if said and "has status" in said[-1]:
            print(said[-1])
    for tag, batch in (("score", os.path.join(TEACHERS, args.name, "batch-input.jsonl")),
                       ("pool", os.path.join(TEACHERS, args.name, "pool", "batch-input.jsonl"))):
        if os.path.exists(batch):
            total = sum(1 for l in open(batch) if l.strip())
            print(f"{tag}: {len(answered(os.path.join(os.path.dirname(batch), 'batch-output.jsonl')))} of {total} windows answered")
    print(kaggle("quota", check=False).strip())


def stop(args):
    pid = job_pid()
    if not pid:
        print("the job isn't running")
        return
    os.kill(pid, 15)
    print(f"stopped the job (process {pid}). A run already on Kaggle carries on until it ends or you stop it there;")
    print("the answers it writes are collected the next time the job runs.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["check", "status", "stop", "pull", "run", "qualify", "pool", "train", "all", "quick", "batch"])
    ap.add_argument("--name", default="qwen38-27b")
    ap.add_argument("--model", default="qwen3.8-27b")
    ap.add_argument("--repo", default="unsloth/Qwen3.8-27B-GGUF")
    ap.add_argument("--pattern", default="*UD-Q4_K_XL*")
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--ctx", type=int, default=16384)
    ap.add_argument("--hours", type=float, default=10.0, help="answering time per session; setup (~30 min) comes on top, and Kaggle saves nothing from a run past 12 h")
    ap.add_argument("--queue-minutes", type=float, default=15,
                    help="a run QUEUED this long gets the web-UI kick alert (or, with --restarts > 0, is pushed again)")
    ap.add_argument("--restarts", type=int, default=0,
                    help="pushes again per session before the queue alert (Pass 73 default 0: never re-push)")
    ap.add_argument("--kaggle-home", default="",
                    help="run the kaggle CLI with HOME=<dir> (credentials in <dir>/.kaggle/credentials.json): a second account")
    ap.add_argument("--candidate", action="append", default=[],
                    help="quick: short|hf repo|gguf file (repeatable; default: Nemotron Bolt, gemma-4-31B QAT, Qwen3.6 35B)")
    ap.add_argument("--variant", default="why-first", choices=["baseline", "why-first"])
    ap.add_argument("--quick-hours", type=float, default=2.0)
    ap.add_argument("--input", default="", help="batch/pull: a batch file; answers are written beside it")
    ap.add_argument("--max-idle", type=int, default=2,
                    help="batch: give up (exit 1) after this many sessions that added no answers; 0: never")
    args = ap.parse_args()
    global KAGGLE_HOME
    if args.kaggle_home:
        KAGGLE_HOME = os.path.abspath(os.path.expanduser(args.kaggle_home))
        if not os.path.isfile(os.path.join(KAGGLE_HOME, ".kaggle", "credentials.json")):
            raise SystemExit(f"no {KAGGLE_HOME}/.kaggle/credentials.json — sign that account in with:\n"
                             f'  HOME="{KAGGLE_HOME}" ~/Developer/pk-ml/bin/kaggle auth login')
    if args.cmd in ("pull", "run", "pool", "all", "train", "quick", "batch"):
        single_copy()
    if args.cmd == "check":
        check(args)
    elif args.cmd == "status":
        status(args)
    elif args.cmd == "stop":
        stop(args)
    elif args.cmd == "pull":
        pull(args)
    elif args.cmd == "run":
        run_batch(args, os.path.join(TEACHERS, args.name, "batch-input.jsonl"), "score")
    elif args.cmd == "qualify":
        qualify(args)
    elif args.cmd == "pool":
        collect(args.name, run_batch(args, pool_batch(args), "pool"))
    elif args.cmd == "train":
        train(args)
    elif args.cmd == "quick":
        quick(args)
    elif args.cmd == "batch":
        # Pass 67: any batch file through --repo/--pattern, sessions until every window is answered (answers in
        # batch-output.jsonl beside it); collecting them is the caller's step.
        if not args.input:
            raise SystemExit("batch needs --input")
        run_batch(args, os.path.abspath(args.input), "b", max_idle=(args.max_idle or None), fatal=True)
    else:
        run_all(args)


if __name__ == "__main__":
    main()
