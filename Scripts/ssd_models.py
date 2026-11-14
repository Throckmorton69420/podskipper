#!/usr/bin/env python3
"""Pass 64 (his 13 Nov request): fill an external drive with every model
PodSkipper's catalogs list, in the layout the app's External Drive screen
reads, and compile Core AI models on this Mac for his iPhone's chip so the
phone never runs Core AI's on-device compiler (which wrote 17 GB and left
105 MB free on his iPhone 16 Pro).

    Scripts/ssd_models.py [--root "/Volumes/Samsung PSSD T9 Media/PodSkipper/Models"]
                          [--only gguf,mlx,coreai] [--models <id>,<id>…]
                          [--compile needed|all|none] [--chip h17p] [--max-mb 5826] [--dry-run]

Layout (the iPhone's own, so the app finds each model where it would put it):

    Models/gguf/<file>.gguf                              CPU models (SHA-256 checked)
    Models/<org>/<name>/ + .download.json                MLX models at their pinned commit
    Models/coreai/<repo>/<revision>/<variant path>/      Core AI bundles; with --compile, the
                                                         graph compiled for --chip inside it
                                                         and metadata.json pointing at it

The catalogs are read from the app's sources (CPUReading.swift,
LocalModelSpec.swift) and CoreAIKit's catalog.json, so the drive holds
exactly the files and revisions the app pins. Downloads resume (curl -C -);
anything already complete is skipped. Compiling uses `xcrun coreai-build
compile … --platform iOS --preferred-compute neural-engine --architecture
<chip>` (Qwen3 4B took 17 minutes and 12 GB of memory on this Mac), one model
at a time; nothing is ever run (no Core AI inference on this Mac).

--compile needed (the default) compiles the models that closed PodSkipper
while being prepared on the phone (CoreAILoadGate.needsCompiledCopy) — Gemma
3 4B, Gemma 4 E2B, Qwen3.5 2B/4B, LFM2.5 2.6B, LFM3 1.7B — plus any model
whose iPhone build isn't made for --chip. A copy of this script lives on the
drive next to Models/ (ssd_models.sh runs it).
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE) if os.path.exists(os.path.join(os.path.dirname(HERE), "Services")) else \
    os.path.expanduser("~/Developer/podskipper")
DEFAULT_ROOT = "/Volumes/Samsung PSSD T9 Media/PodSkipper/Models"
CATALOG = "https://raw.githubusercontent.com/john-rocky/coreai-kit/main/catalog.json"
HF = "https://huggingface.co"
NEEDS_COMPILED = {"gemma-3-4b-it", "gemma-4-e2b", "qwen3.5-2b", "qwen3.5-4b", "lfm2.5-2.6b", "lfm3-1.7b"}
# LocalModelSpec.nemotron3_4B.configPatch: keys the app adds to config.json.
CONFIG_PATCH = {"mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit": {
    "moe_intermediate_size": 12544, "moe_shared_expert_intermediate_size": 12544,
    "n_routed_experts": 1, "num_experts_per_tok": 1}}


def source(path):
    return open(os.path.join(REPO, path), encoding="utf-8").read()


def cpu_catalog():
    text = source("Services/LocalModel/CPUReading.swift")
    out = []
    for m in re.finditer(r'CPUModel\(\s*id: "([^"]+)", name: "([^"]+)", repo: "([^"]+)",\s*revision: "([0-9a-f]+)", '
                         r'file: "([^"]+)",\s*bytes: ([0-9_]+), sha256: "([0-9a-f]+)"', text, re.S):
        out.append(dict(id=m[1], name=m[2], repo=m[3], revision=m[4], file=m[5], bytes=int(m[6].replace("_", "")), sha256=m[7]))
    return out


def mlx_catalog():
    """LocalModelSpec.all, in its order (the CPU models' plan-only specs aren't in it)."""
    text = source("Services/LocalModel/LocalModelSpec.swift")
    by_var = {}
    for m in re.finditer(r'static let (\w+)(?::\s*LocalModelSpec)?\s*=\s*(?:\{\s*var spec = )?'
                         r'(?:small\(|LocalModelSpec\(\s*id:)\s*"([^"]+)",\s*(?:name:\s*)?"([^"]+)",\s*'
                         r'(?:revision:\s*)?"([0-9a-f]{40})"', text):
        by_var[m[1]] = dict(id=m[2], name=m[3], revision=m[4])
    listed = re.search(r"static let all: \[LocalModelSpec\] = \[([^\]]+)\]", text)
    names = [n.strip() for n in listed[1].split(",")] if listed else list(by_var)
    return [by_var[n] for n in names if n in by_var]


def get_json(url):
    """Through curl (the system's certificates; python.org's Python has none)."""
    out = subprocess.run(["curl", "-sL", "--fail", "--retry", "5", "--retry-all-errors", "--retry-delay", "3",
                          "-A", "podskipper-ssd", url], capture_output=True, check=True)
    return json.loads(out.stdout)


failed = []


def curl(url, dest, size=None):
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if size and os.path.exists(dest) and os.path.getsize(dest) == size:
        return False
    part = dest + ".part"
    if size and size > 50_000_000:
        print(f"   {os.path.basename(dest)} ({size / 1e9:.2f} GB)", flush=True)
    quiet = ["--progress-bar"] if size and size > 50_000_000 else ["-sS"]
    subprocess.run(["curl", "-L", "--fail", "--retry", "5", "--retry-delay", "5", "-C", "-", *quiet, "-o", part, url], check=True)
    os.replace(part, dest)
    return True


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def do_gguf(root, models, wanted, dry):
    folder = os.path.join(root, "gguf")
    for m in models:
        if wanted and m["id"] not in wanted:
            continue
        dest = os.path.join(folder, m["file"])
        url = f"{HF}/{m['repo']}/resolve/{m['revision']}/{m['file']}"
        print(f"[gguf] {m['name']}: {m['bytes'] / 1e9:.2f} GB → {dest}")
        if dry:
            continue
        curl(url, dest, m["bytes"])
        if os.path.getsize(dest) != m["bytes"] or sha256(dest) != m["sha256"]:
            os.remove(dest)
            raise SystemExit(f"{m['name']}: size or SHA-256 doesn't match the app's pin; removed it")


def needed(path):
    """LocalModelSpec.isNeeded: top-level .safetensors, .json, .jinja, no vision settings."""
    return "/" not in path and path not in ("preprocessor_config.json", "processor_config.json",
                                           "video_preprocessor_config.json") \
        and (path.endswith(".safetensors") or path.endswith(".json") or path.endswith(".jinja"))


def do_mlx(root, specs, wanted, dry):
    for spec in specs:
        if wanted and spec["id"] not in wanted:
            continue
        try:
            listing = get_json(f"{HF}/api/models/{spec['id']}/revision/{spec['revision']}?blobs=true")
        except subprocess.CalledProcessError:
            print(f"[mlx] {spec['name']}: Hugging Face didn't list its files; skipped (run again later)")
            failed.append(spec["name"])
            continue
        files = [{"path": s["rfilename"], "size": s["size"]} for s in listing["siblings"]
                 if needed(s["rfilename"]) and s.get("size")]
        folder = os.path.join(root, spec["id"])
        total = sum(f["size"] for f in files)
        print(f"[mlx] {spec['name']}: {len(files)} files, {total / 1e9:.2f} GB → {folder}")
        if dry:
            continue
        for f in sorted(files, key=lambda f: -f["size"]):
            curl(f"{HF}/{spec['id']}/resolve/{spec['revision']}/{f['path']}", os.path.join(folder, f["path"]), f["size"])
        patch = CONFIG_PATCH.get(spec["id"])
        if patch:
            config = os.path.join(folder, "config.json")
            obj = json.load(open(config))
            obj.update({k: v for k, v in patch.items() if obj.get(k) is None})
            json.dump(obj, open(config, "w"), sort_keys=True)
        manifest = {"repo": spec["id"], "revision": spec["revision"],
                    "files": sorted(files, key=lambda f: -f["size"])}
        json.dump(manifest, open(os.path.join(folder, ".download.json"), "w"))


def ios_variant(model, chip):
    """The bundle the app loads on this chip (CoreAICompatibility, simplified):
    the iPhone build when it is made for this chip (or for no chip in
    particular), else the portable Mac build."""
    ios = (model.get("variants") or {}).get("ios")
    mac = (model.get("variants") or {}).get("macos")
    if ios:
        # The chip in the path ("ios-h18p/…"), else the catalog's list
        # (LFM3 1.7B: "ios", architectures ["h19p"]), as CoreAICompatibility.
        chips = re.findall(r"h\d+p", ios["path"]) or list(ios.get("architectures") or [])
        if not chips or chip in chips:
            return ios["path"], not chips
    return (mac["path"], True) if mac else (None, False)


def compile_bundle(bundle, chip, dry, name=""):
    meta_path = os.path.join(bundle, "metadata.json")
    if dry:
        print(f"   would compile its graph for {chip} on this Mac")
        return
    meta = json.load(open(meta_path))
    main = (meta.get("assets") or {}).get("main", "")
    if main.endswith(".aimodelc"):
        print(f"   already compiled: {main}")
        return
    asset = os.path.join(bundle, main)
    name = os.path.splitext(main)[0] + f".{chip}.aimodelc"
    out = os.path.join(bundle, name)
    print(f"   compiling {main} for {chip} → {name} (minutes; up to ~12 GB of memory)")
    if dry:
        return
    tmp = out + ".building"
    shutil.rmtree(tmp, ignore_errors=True)
    # Static-shape graphs: GPU. Pass 38 found the Pass 35 "neural-engine"
    # builds held only a GPU (MPSGraph) program anyway, and coreai-build
    # 3605.6.3 (Xcode 27.2) segfaults in ANEHostCompiler when asked for the
    # Neural Engine (14 Nov: Qwen3 0.6B, twice; the GPU build took 66 s).
    # Growing-cache graphs: GPU expecting frequent reshapes, as
    # CoreAIPreparation.options does on the phone.
    static = "static" in bundle.lower() or "static" in main.lower()
    compute = ["--preferred-compute", "gpu"] if static else ["--preferred-compute", "gpu", "--expect-frequent-reshapes"]
    try:
        subprocess.run(["xcrun", "coreai-build", "compile", asset, "--output", tmp, "--platform", "iOS",
                        "--architecture", chip] + compute, check=True)
    except subprocess.CalledProcessError as error:
        shutil.rmtree(tmp, ignore_errors=True)
        print(f"   compile failed ({error.returncode}); the download is kept, the iPhone prepares it itself")
        failed.append(f"{name or bundle} (compile)")
        return
    built = tmp if tmp.endswith(".aimodelc") and os.path.isdir(tmp) and os.path.exists(os.path.join(tmp, "metadata.json")) \
        else next((os.path.join(tmp, d) for d in os.listdir(tmp) if d.endswith(".aimodelc")), None)
    if not built:
        raise SystemExit(f"coreai-build made no .aimodelc in {tmp}")
    shutil.rmtree(out, ignore_errors=True)
    os.replace(built, out)
    shutil.rmtree(tmp, ignore_errors=True)
    # As CoreAICompiledCopy.install: keep the download's metadata, name the compiled graph.
    kept = os.path.join(bundle, "metadata.portable.json")
    if not os.path.exists(kept):
        shutil.copy2(meta_path, kept)
    meta = json.load(open(kept))
    meta.setdefault("assets", {})["main"] = name
    json.dump(meta, open(meta_path, "w"), indent=2, sort_keys=True)


# CoreAICompatibility.weightBudgetMB for his iPhone 16 Pro (7.47 GB, increased
# memory limit): 84 % of memory less 600 MB. Larger models are listed by the
# app as too large for this iPhone, so they aren't fetched unless asked for.
IPHONE_BUDGET_MB = 5826


def do_coreai(root, wanted, how, chip, dry, max_mb=IPHONE_BUDGET_MB):
    try:
        catalog = get_json(CATALOG)
    except Exception:  # noqa: BLE001 — the snapshot the app's audit used
        catalog = json.load(open(os.path.join(REPO, "build", "p63", "coreai-catalog.json")))
    for model in catalog["models"]:
        if model.get("kind") != "chat" or (wanted and model["id"] not in wanted):
            continue
        path, portable = ios_variant(model, chip)
        if not path:
            print(f"[coreai] {model['name']}: no build for iPhone; skipped")
            continue
        size_mb = next((v.get("sizeMB") or 0 for v in (model.get("variants") or {}).values() if v.get("path") == path), 0)
        if max_mb and size_mb > max_mb and not (wanted and model["id"] in wanted):
            print(f"[coreai] {model['name']}: {size_mb / 1000:.1f} GB, too large for this iPhone; skipped (--max-mb 0 fetches it)")
            continue
        bundle = os.path.join(root, "coreai", model["repo"], model["revision"], path)
        try:
            tree = get_json(f"{HF}/api/models/{model['repo']}/tree/{model['revision']}/{path}?recursive=true")
        except subprocess.CalledProcessError:
            print(f"[coreai] {model['name']}: Hugging Face didn't list its files; skipped (run again later)")
            failed.append(model["name"])
            continue
        files = [t for t in tree if t.get("type") == "file"]
        total = sum(t.get("size", 0) for t in files)
        print(f"[coreai] {model['name']}: {len(files)} files, {total / 1e9:.2f} GB → {bundle}")
        if not dry:
            for t in files:
                rel = t["path"][len(path) + 1:] if t["path"].startswith(path + "/") else t["path"]
                curl(f"{HF}/{model['repo']}/resolve/{model['revision']}/{t['path']}", os.path.join(bundle, rel), t.get("size"))
        if how == "all" or (how == "needed" and (model["id"] in NEEDS_COMPILED or portable)):
            if dry or os.path.exists(os.path.join(bundle, "metadata.json")):
                compile_bundle(bundle, chip, dry, model["name"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=DEFAULT_ROOT)
    ap.add_argument("--only", default="gguf,mlx,coreai")
    ap.add_argument("--models", default="", help="comma-separated ids (CPU id, MLX repo, Core AI catalog id)")
    ap.add_argument("--compile", choices=["needed", "all", "none"], default="needed")
    ap.add_argument("--chip", default="h17p", help="his iPhone 16 Pro is h17p")
    ap.add_argument("--max-mb", type=int, default=IPHONE_BUDGET_MB,
                    help="skip Core AI models larger than this (his iPhone 16 Pro's budget); 0 = no limit")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    root = args.root
    # The drive already has PodSkipper/models (lowercase) from Pass 58; on a
    # case-insensitive volume that is the same folder.
    lower = os.path.join(os.path.dirname(root), "models")
    if not os.path.exists(root) and os.path.exists(lower):
        root = lower
    if not os.path.isdir(os.path.dirname(root)):
        raise SystemExit(f"{os.path.dirname(root)} isn't there: plug the drive in.")
    os.makedirs(root, exist_ok=True)
    wanted = {m for m in args.models.split(",") if m}
    kinds = set(args.only.split(","))
    if "gguf" in kinds:
        do_gguf(root, cpu_catalog(), wanted, args.dry_run)
    if "mlx" in kinds:
        do_mlx(root, mlx_catalog(), wanted, args.dry_run)
    if "coreai" in kinds:
        do_coreai(root, wanted, args.compile, args.chip, args.dry_run, args.max_mb)
    if not args.dry_run:
        dest = os.path.join(os.path.dirname(root), "ssd_models.py")
        if os.path.abspath(dest) != os.path.abspath(__file__):
            shutil.copy2(__file__, dest)
    if failed:
        print("Not fetched this time (run the script again; finished files are skipped): " + ", ".join(failed))
    print("Done. On the iPhone: Settings › Ad Skipping › a model library › External Drive › Choose Folder → PodSkipper/Models.")


if __name__ == "__main__":
    main()
