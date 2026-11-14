# Pass 64 — task checklist (his 13 Nov message, build 3cee01c exports)

Evidence: `PodSkipper-diagnostics-1794556625.json`, `PodSkipper-results-1794556641.json`, two Compare Models screenshots.
States: **open** · **built** (compiles, unit tests where noted) · **sim** (seen working in the iOS 27.2 simulator) · **phone** (only his iPhone can close it).

## 1. Stop cancels at once
- [x] **built + unit** PodSkipper Test: Stop shows Stopped within 0.5 s; a run token makes every late progress/status/result callback from the old read a no-op; Resume/Start while the old read unwinds waits for it (heavy-work lease kept until the engine has really returned)
- [x] **built + unit** Model test (Basic/Hard): same — UI ends at once, the old task's clean-up can't clobber a new test (run ID check)
- [x] **built (device build)** llama.cpp: abort callback set on the context, so a Stop ends `llama_decode` mid-batch (not after 256 tokens)
- [~] MLX: stops at its next generated token (as before); a prefill chunk can't be interrupted without changing mlx-swift-lm — the panel no longer waits for it
- [x] Core AI: generation cancelled on Stop; the UI never waits on the uninterruptible preparation (it keeps the slot)

## 2. Core AI disk and crashes
- [x] **built** Purge compiler scratch (MPSGraph / ODIE temp folders) at launch and after every Core AI load, failure or Stop
- [x] **built + unit** Refuse on-device preparation below 5 GB free (or the model's need, whichever is larger); offer the Mac-compiled import instead
- [x] **built + unit** Never call into CoreAIRuntime for a bundle known to crash uncompiled (Gemma 3 4B, Gemma 4 E2B, Qwen3.5 2B/4B static-shape) unless a compiled copy is installed; show Import Compiled Copy

## 3. Main thread on Compare Models
- [x] **built** `isDownloaded` for CPU and Core AI models answered from a cache refreshed off the main thread (the three 0x8BADF00D kills: SwiftUI body → `CPUModel.isDownloaded` → `attributesOfItem` blocked in the kernel)
- [x] **built** Live progress/token-rate updates coalesced (≤ 4 a second) for the test panels

## 4. Scores, token caps, prompts
- [x] **built + unit** Headline score = the model alone; "with PodSkipper's check" second; a model that finds nothing shows 0
- [x] **built + unit + lab** Hybrid check vetoes model-only cuts over conversational show talk with no ad signal
- [x] **built + unit** Core AI answer cap 170 → 512
- [x] **built + unit + lab** No whole-stretch span (grammar), halves on restated answers; Qwen3.5 2B CPU fixed (form allowed no spaces); LFM2.5 1.2B measured weak, its bad cut now vetoed. Small-model tier: the `guided` profile (measured for LFM3) gave Qwen3.5 2B 45 % alone vs 34 % but 90 % vs 93 % checked on Basic, and LFM2.5 1.2B nothing; and on Hard v5 6 % vs 8 % alone (96–97 % checked): not adopted, the per-family tiers stay as measured
- [x] **built + unit** Basic = clean core; Hard = adversarial, not overlapping Basic; duration-weighted overlap, strict show-cut penalty

## 5. Reader + distillation
- [x] **lab** Where Qwen3.5 4B Instruct (6-bit) beat the Reader on Hard and on the 11 test episodes (edges, kinds)
- [x] **lab** Reader kind split: Hard 97 → 98 (target met); 11 test episodes 91.8 (target 93 NOT met); held-out 77.3 unchanged in the lab (no claim without a held-out number)
- [x] **built (not run)** `Scripts/distill_reader.py`: transcripts → cloud (OpenAI-compatible) or local teacher → labels the Reader's trainer reads

## 6. SSD models
- [x] **built, dry run + one real check (not fully run)** Mac script (repo `Scripts/ssd_models.sh` + copy on the SSD): download every catalogued GGUF, MLX and Core AI model to `/Volumes/Samsung PSSD T9 Media/PodSkipper/Models/`, pre-compile Core AI where the Mac can
- [x] **built + unit** App: External Model Library (folder picker, security-scoped bookmark); GGUF and MLX read straight from the drive; Import (copy) any model with GB/GB and MB/s

## 7. Compare Models screen
- [x] **built + UI test** Stopped run: the switch list shows every downloaded model (new ones too); Resume · Run Newly Added Models · Keep Earlier Results · Start Over, full width one per row (a two-column grid truncated "Keep Earlier Results")
- [x] **built + unit** ETA from each queued model's measured speed and its remaining tokens; live prefill time during slow Core AI reads
- [x] **built + unit** Every download/import shows X.XX GB / Y.YY GB and MB/s
- [x] **built** Scores on This iPhone collapsible; Unsupported / Heavy on This Device collapsed per family; clearer score cards (model alone, with check, ads cut, show kept, tok/s)

## Gates
- [x] Simulator build + unit tests on iOS 27.2 (iPhone 16 Pro): 684 / 0 failures / 3 skipped; UI tests testPass62PodTestStopped, testPass60PodTestResults pass
- [x] Device build (`./Scripts/device-build.sh`, Core AI and llama.cpp files): succeeded
- [x] Catalog + handoff + finish plan + phone checklist updated

## Still open after Pass 64 (not closable on the Mac)
- Everything above on the phone: PHONE-CHECKLIST 21l–21r.
- Reader ≥ 93 on his 11 test episodes (lab 91.8): next step is a teacher read with `Scripts/distill_reader.py` (a cloud teacher needs his provider choice and key).
- Full SSD fill and Core AI compiles: run `"/Volumes/Samsung PSSD T9 Media/PodSkipper/ssd_models.sh"` (≈100 GB; ≈17 min and 12 GB of memory per compile).
- MLX prefill chunks still can't be interrupted mid-chunk (the panel no longer waits for them).

# Pass 65 — task checklist (his 14 Nov message: Gemini's continuation prompt, Parts 1 and 2)

## Part 1 — re-checked against the code (most of it was built in Pass 64)
- [x] **built** Main thread: besides Pass 64's model-presence caches, two more disk reads left SwiftUI bodies — Settings › Devices listed the app's plug-ins, read the widget's signature from its executable and the widget snapshot file on every redraw (now once, off the main thread), and Tidy Up / Settings / Backup sized the Episodes folder on the main thread (now one listing off it: `ProcessingPipeline.episodeFileSizes`, `measuredDownloads`)
- [x] **checked** Stop: llama.cpp abort callback (Pass 64); MLX — mlx-swift-lm already checks cancellation before every 256-token prefill chunk, and PodSkipper's shared-prefix read now checks before each chunk too (it checked after); the panel ends at once (run tokens, Pass 64)
- [x] **checked** Core AI SIGTRAP guard and scratch purge after cancel/failure (Pass 64, unit-tested)
- [x] **checked** Scores, veto, 512-token answers, grammar, Compare Models queue/ETA/folds (Pass 64)
- [x] **fixed** `testAccessibleModelsAndSound`: the UI tests launched the app with `UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge`, a value UIKit doesn't know (its raw value is `…AccessibilityXXXL`), so since Pass 31 the "largest text" tests ran at the default size and asserted large-text layouts that never appeared. With the real value the player and sound page pass; Compare Models' engine lists are reachable but dozens of screens down, so the test scrolls further (`reveal`, 80 steps)
- [x] **fixed (Mac)** `ssd_models.py`: Xcode 27.2's coreai-build 3605.6.3 segfaults in ANEHostCompiler when asked for the Neural Engine (Qwen3 0.6B, twice, his run and mine); static graphs now compile for the GPU (Pass 38 found the old "neural-engine" builds held only a GPU program anyway; 66 s, 2.5 GB), and a failed compile is reported at the end instead of stopping the run. Restarted in his terminal; `sync_models.sh` on the drive is the same script
- [x] **built** Models and Caches › External Drive (the import page was only under the model libraries and Compare Models)
- [x] **fixed (seen at the real largest text size)** three layouts the old test never showed: the sound chart's zone names ran into each other (now they wrap at accessibility sizes), the tone line was cut to two lines ("Tone unchanged: y…"), the player's four skip chips broke words ("Ski p Ad s"; now one a line), and a model row's Delete/Download button broke into letters (now as wide as its words)

## Part 2 — SPoRC + SponsorBlock + teacher (D05)
- [x] **done** Environment: lab Python (`~/Developer/pk-ml`) has huggingface_hub 1.33, pyarrow 26, pandas 3.1, duckdb 2.0; his token reads the gated `blitt/SPoRC` (556 files, 94 GB, 47.8 GB of it search databases, never fetched)
- [x] **audited and rewritten** `Tools/ReaderData/sporc_sb_distill_pipeline.py` against the real files (findings in its docstring: `total_sp_labels` counts speakers, not sponsors; SPoRC has turn times only, May–June 2020 only; SponsorBlock lacks duration/date for most videos; title-substring joins admit "Full Episode"); stages `check-env`, `download-sporc --catalogs|--matched|--podcasts|--all` (paced, resumable, size + Parquet footer checked), `match`, `pair`, `teacher-batch`, `teacher-import`, `train-reader`; his 16 shows and every show in his exports are never used
- [x] **run** catalogs (0.23 GB) + the 106 turn parts the matches live in (12.2 GB) on the drive; match: 3,275,195 usable SponsorBlock videos → 33,432 title matches → 614 one-to-one, same length (≤ 3 min) → **pair kept 38 episodes from 31 shows** (35,790 labelled sentences). Rejected: 292 with a sponsor segment over plain show talk (the YouTube upload's own read, or a mislabel), 166 with no speaker turns in SPoRC, 62 too short, 9 with selling lines outside every segment, 4 cut short
- [x] **not run, by the rule written first** (`build/p65/ship-rule-5.txt`: fewer than 40 kept episodes → no run): 38 episodes next to Pass 58's 457 can't move stage 1. D05 stays open
- [x] **measured** teacher before any teacher run: the local Qwen3.5 4B Instruct teacher scores **64.5** on his 11 test episodes (the shipped Reader **91.8**) — a teacher has to beat the Reader before its labels can help
- [x] **built + tested on this Mac** `Tools/ReaderData/kaggle_teacher.py` + `kaggle_teacher.ipynb` (llama.cpp b12283 with CUDA for 2 × T4, Qwen3.8 27B UD-Q4_K_XL, thinking off, resumable, 11.3 h stop) — smoke test through a Mac llama-server (b12283, Metal) with Qwen3.5 2B: answer written in OpenAI batch format, read back by `distill_reader.py collect`
- [x] **ready, not uploaded** the scoring batch for a big teacher: `build/p57/teachers/qwen38-27b/batch-input.jsonl` (his 71 labelled episodes, 363 windows, ~1.7 M prompt tokens ≈ one Kaggle session). Uploading his episodes' transcripts to Kaggle is his call
- [x] `Scripts/ssd_models.sh` + drive copies (`ssd_models.sh`, `sync_models.sh`); app import from the drive (Pass 64) now also under Models and Caches

## Gates (Pass 65)
- [x] Simulator build, no new warnings; unit 684 / 0 failures / 3 skipped (iOS 27.2, iPhone 16 Pro)
- [x] UI `testAccessibleModelsAndSound` passes at the real largest text size, screens checked by eye (`build/shots-p65acc4/named/`)
- [x] Device build succeeded
- [x] Catalog X65, handoff §1y, finish plan, phone check 21s

## Both routes (his answer "Both routes", 14 Nov) — rule `build/p65/ship-rule-6.txt` (+ amendment 1), written before any data
- [x] **running** Route 1, human labels: `Tools/ReaderData/sb_scale_run.sh` (detached; log `~/Developer/pk-data/sb65/run.log`, terminal tab "Reader data") — **1,776 new SponsorBlock podcast episodes from 544 channels** (Pass 58: 457 from ~155), fetch (yt-dlp + deno, paced, pauses 30 min when YouTube refuses) → app transcriber (122 s per 90-min episode) → labels → stage 1 on sb58 + sb65 → recipe → step A → step B → `REPORT.txt`. Resumable: run the same command again
- [x] **built; signed in (14 Nov 02:45, as throck, 30 GPU-h this week); blocked on phone verification** — the first session ran with no GPU and no internet although both were on in its saved settings (Kaggle's rule for unverified accounts); the job now stops with that message. Fixed on the way: a notebook can't share its dataset's name (409 Conflict); one copy at a time (a lock); a Kaggle error that isn't about quota stops the job instead of retrying every 6 h. Route 2, teacher: `Tools/ReaderData/kaggle_auto.py all` — private Kaggle Dataset + GPU T4 x2 script per session (≤ 12 h each, answers kept between sessions), scores Qwen3.8 27B (UD-Q4_K_XL, 17.7 GB) on his 71 labelled episodes; only if it scores ≥ the Reader's 91.8 does it read his 71 unlabelled episodes and train run B (same judged machinery as route 1)
- [x] **fixed** `distill_reader.py train` now holds out the 11 test episodes (HOLD_TEST=1); its `gate` documents that its show-held-out half doesn't measure a new pair (rule 6 uses `reader_run.sh` instead)

- [x] **running (14 Nov 05:16)** route 2 on Kaggle after his phone verification: version 4 sat 2 h in Kaggle's queue while a fresh push (v5) started at once → the job now pushes again after 30 min queued (≤ 3 times, then waits 6 h), names the stuck version for him to stop, and a stale run exits on its token. v5 had GPU + internet but CMake found no `CUDA::cuda_driver` in Kaggle's CUDA 13 image → setup links the toolkit's libcuda stub (falls back to GGML_CUDA_NO_VMM); v6 started after 1 min and passed the build step. `kaggle_auto.py status` / `stop` for checking by hand

- [x] **fixed** both jobs had died or would die with the terminal tab that started them (route 1 stopped 02:47 at 129 fetched / 8 transcribed); `Tools/ReaderData/detach.py` starts them in a session of their own — restarted 05:24, confirmed alive after their shell closed. Start commands: `detach.py ~/Developer/pk-data/sb65/run.log zsh Tools/ReaderData/sb_scale_run.sh` and `detach.py build/p65/kaggle/run.log ~/Developer/pk-ml/bin/python -I Tools/ReaderData/kaggle_auto.py all` (with the lab Python, from the repo)

## Still open after Pass 65
- D05 (unseen shows ~34 s/h heard): the SPoRC route yields 38 episodes; the remaining routes are (a) more of Pass 58's own SponsorBlock YouTube episodes (thousands qualify; needs yt-dlp/ffmpeg/deno back and ~1 min of transcription per episode) and (b) a teacher that scores above the Reader on his labelled episodes
- Phone checks 21l–21r (Pass 64) and the large-text layouts on the phone
