# PodSkipper — Handoff (Pass 37, 14 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) — the **Pass 37 overlay** (X37-01…09) at its top, then Pass 36 and older overlays and the base rows — and [Pass 37 evidence](evidence/2026-10-14-pass37.md) (Pass 36's is [here](evidence/2026-10-13-pass36-coreai-loading.md)). Then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) and [Implementation Plan](../IMPLEMENTATION-PLAN.md).

## 1. Where the code is

- **`main` is canonical** in `~/Developer/podskipper`. `~/Developer/pk-app` (77b904d, detached) untouched. `~/Developer/pk-sym` is **his own folder of old IPAs — not a worktree; leave it**.
- `stash@{0}` (catalogue transaction WIP) untouched; tag `archive/backup-catalogue-stash-2026-10-02`.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>`. `gh` not installed.
- **Simulator: the PS-Unit simulator no longer exists.** Use iPhone 16 Pro `4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`. Unit: `./Scripts/unit-test.sh 4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`; one class: `xcodebuild test-without-building … -only-testing:PodSkipperTests/<Class>` after `build-for-testing` (and `./Scripts/generate-project.sh --simulator` when files were added). UI: `./Scripts/uitest.sh <Test[,Test]> <tag> <simulator>`.
- Device compile: `./Scripts/device-build.sh` (unsigned Release iphoneos). Core AI code (`CoreAIPreparation`, `CoreAIAdJudge`, library) compiles **only** there.
- Symbolication: device symbols for iOS 27.0.1 are in `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 27.0.1 (24A446)/arm64e/Symbols` (`atos -arch arm64e -l <__TEXT vmaddr>`); app frames: rebuild the exact commit with `Scripts/device-build.sh` in a temporary worktree, `atos -arch arm64 -l 0x100000000`.
- **Compiled Core AI copy** for his iPhone 16 Pro: `build/coreai-aot/qwen3_4b_mixed_4bit_8bit_static.h17p.aimodelc` (2.5 GB, git-ignored; `sourceHash 882606B7…`). Now installed from a visible button under the Qwen3 4B row in Models and Caches; PodSkipper refuses it unless it was compiled from exactly the downloaded graph and for this chip. He has put an identical copy in his iCloud Drive → Downloads; the installer picks it in Files (package type accepted) and downloads it from iCloud with progress.

## 2. Pass 37 (on top of 4fdd2b7)

Batch A — Gemma 4 E2B with its word tables (+ h17p compiled copy at `build/coreai-aot/gemma/gemma4_e2b_qat_decode_int4lin_tbl.h17p.aimodelc`, 2.0 GB, git-ignored, sourceHash FC6830D0…), the two symbolicated iOS terminations (notes HTML import; iCloud push settings write), screen kept awake during model tests, Speed & Audio frequency zoom. Commit and IPA run in the delivery message. **Do not run Gemma inference in the Mac lab again**: on 14 Oct it hung this Mac into a hardware watchdog reset while reading the first part (loading with tables bound had succeeded). `build/gemma-lab/` holds the downloaded decoder + tables (4.4 GB, git-ignored).

Batch B — Apple Podcasts parity slice (Save Episode/Unsave/Saved, Mark as Played, Play Last, Mark All As Played, Start Your Library) and the plug-round cue for model reads (X37-10/11). Full unit suite: 374 run, 1 skipped, `PlaybackRequestTests.testCountdownPlaysOnlyTheMostRecentEpisode` failed under full-suite load and passed twice alone. UI: testEpisodePage, testPassSix, testPassNineteen, testSoundChartZoom, testSoundChartControls pass; `testPassThree` fails at its publishing-banner and Settings › Automatic Downloads steps (not re-run at 4fdd2b7 — check whether it predates Pass 37 before trusting it).

Lab: `Tools/CoreAILab` builds again (shim for `CoreAICompiledCopy`); `LAB_TABLES=<folder>` binds Gemma's tables.

## 2a. Pass 36 (on top of 4075f0e)

Batch A — Core AI loading/Stop, model-test records, model storage safety, export granularity: 48d62f4 (code) + the following commit (export footer wording, docs). The unsigned IPA is built by "Build unsigned IPA" on the push of that last commit (run listed in the delivery message). UI flows `testPass35StorageManagement` and `testDiagnostics` pass on the iPhone 16 Pro simulator (screens `build/shots-p36/named`); the Core AI rows can't appear in the simulator.

## 3. Findings to keep

**Batch B (his 13 Oct phone on 0aea7c6):** Qwen3 4B/0.6B now use the GPU build (X36-12) — the Neural Engine build's on-device compile is ~33 min for 0.6B on the Mac (4.5 min from a Mac-compiled copy; his phone hadn't finished the 4B copy in 16 min); Stop hands the slot to the still-running preparation and returns at once (X36-13); Compare reverted, running test kept in its section (X36-04). Don't recommend Mac-compiled copies for Neural Engine graphs again without a phone measurement.

Proven/measured: Qwen3 4B's latest "Loading 0 %" incidents are Core AI's on-phone preparation (ANE/Core AI compiler CPU and 4.3 GB disk-write reports; no crash report); `AIModel.specialize` ignores task cancellation and finishes (Mac); `AIModelCache.model(for:options:)` reads prepared state without work; prepared entries aren't attributable by file name (Mac); compiled `sourceHash` = source `main.hash`; Gemma 4 E2B needs a separate PLE tables bundle + h18p-only AOT (CoreAIKit source) — unsupported here; old recovery hid new failures behind old results; stops left no record; storage exports were silently truncated by log caps.

Hypotheses (unproven): the 36.8 GB "temporary files" removal on 12 Oct removed Qwen3 4B's prepared copy (no item list was kept then — there is now); the five "closed while loading" launches were forced quits (no crash or daily report yet); iOS accepts the h17p AOT copy; on-phone preparation of Qwen3 4B completes when left alone (it did once before 9 Oct 09:45).

## 4. Verification

See evidence §7 and the delivery message. Focused unit classes pass (Pass36 7, ModelBench 11, Pass35 13); device Release build passes. **No phone verification of anything in Pass 36.**

## 5. Next steps (Pass 37)

1. His phone on the Pass 37 IPA: Gemma 4 E2B — download (4.5 GB: decoder + tables), long-press it in Models and Caches → Install Compiled Copy… → the h17p copy (if he puts it in iCloud Drive), then one Basic test; without the copy, the first test compiles the portable decoder on the phone (publisher saw that fail on betas). Chart zoom by hand (pinch, two-finger slide, pill, double tap, knob drag + callout, pinch starting on a knob). A long model test with the screen left alone (should not lock). Notes pages and background/close while a Core AI test runs (the two terminations).
2. Parity: continue the string/structure audit destination by destination (player, Up Next, Search, New, show header, settings) — first slice done (X37-10).
3. Continuation, in plan order (unchanged, carried each pass): record-level Diagnostics/Results selection; record-level backup/restore; iCloud cross-device (needs his iPad); widgets/CarPlay against installed entitlements; Apple Podcasts parity pass; Batch 4 fixture replay with his Results corrections (X37-07); Batches 3, 5, 6.

## 5a. Next steps (Pass 36, kept)

1. His phone on the batch B IPA: download Qwen3 4B again (GPU build, 2.3 GB) and run Basic; delete the old "other version" Qwen3 4B (2.5 GB + 2.5 GB compiled copy inside). Then the rest of: his phone on the Pass 36 IPA — the short checklist in the delivery message (Qwen3 4B one test left to finish preparing; Stop during preparation; second test reuses it; Gemma row; delete one Core AI model and read the result; Temporary Files text; optional compiled-copy install).
2. Pass 35 continuation (X36-11), in plan order: record-level Diagnostics/Results selection; record-level backup/restore; iCloud cross-device (needs his iPad); widgets/CarPlay against installed entitlements; Apple Podcasts parity pass; then Batches 3–6.
3. If he wants in-app delivery of the compiled Qwen3 4B copy: decide where it may be hosted (publishing decision; Apache-2.0 permits redistribution with notice).
