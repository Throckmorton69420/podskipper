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
