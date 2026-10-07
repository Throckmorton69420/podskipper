# PodSkipper — Handoff (Pass 32, 7 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) (178 base rows + the Pass 28–32 overlay at its top), then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) and the [Implementation Plan](../IMPLEMENTATION-PLAN.md). Project docs `claude/HANDOFF.md` and `claude/REQUEST-CATALOG.md` mirror these files.

## 1. Where the code is

- **`main` is canonical.** `codex/complete-project-recovery` was fast-forwarded into `main` at 77b904d (PR #22 shows merged 7 Oct). Pass 32 commit: see §6.
- Work in `~/Developer/podskipper` only. The `podskipper-recovery` worktree was removed after checking it was clean; its ignored build artefacts (including the 3.2 GB `model-runtime-probe`) were moved to `~/Developer/podskipper/build/recovery-archive/`. `~/Developer/pk-app` remains the second worktree for building `origin/main` while the lab runs.
- `stash@{0}` (catalogue transaction WIP) is untouched and is also on GitHub as tag `archive/backup-catalogue-stash-2026-10-02` (15a29af).
- Branches pruned: 18 remote branches fully contained in `main` deleted; 6 branches with unique commits archived as tags, then deleted — `archive/backup-catalogue-stash-2026-10-02` 15a29af, `archive/backup-ux4-dirty-2026-10-04` 0a0c43a, `archive/claude-funny-goldberg-m50ikc` 020324b, `archive/cloud-apple-parity-and-chart-fixes` 04d98dc, `archive/cloud-apple-parity-and-chart-fixes-v2` cb42f82, `archive/cloud-recovery-visual-model-memory` eb53913. Kept: `main`; `codex/complete-project-recovery` and `handoff/chatgpt-to-claude-2026-10-04` (base and head of open PR #23 — deleting the base would close it); the seven `feather-*` branches (separate updater work). Local `codex/complete-project-recovery` deleted (equal to main). Script: `~/Developer/pk-tools/branches-p32.sh`.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>` (ORIGIN becomes the token URL; output redacted).
- **Simulator:** the primary iPhone 16 Pro simulator (4DB432A8…) wedged this pass (test runner never connected; app installs hung). A fresh one, **PS-Unit** (F51033BC-3FEA-4D44-BF85-06F492C6933F, iPhone 16 Pro, iOS 27.0), works: `./Scripts/unit-test.sh F51033BC-3FEA-4D44-BF85-06F492C6933F` and `./Scripts/uitest.sh <Test> <tag> PS-Unit`. Also: a failing XCTest assertion makes the run crawl (in-process symbolication stalls), so a "hung" test is usually a failed assertion — sample the app to see the line.

## 2. What Pass 32 changed (code)

| Area | Files | Status |
|---|---|---|
| Speed & Audio chart: handles drawn in an overlay with 12 pt inset (no clipping); collapse, resize grabber, pin only with room; pinned tallest size from the measured header so enlarging never unpins | `Views/AudioControls.swift`, `Views/PlayerViews.swift` | see §4 |
| EQ: base gain stored to ±36 dB so every heard value in ±12 dB stays reachable with fixes on | `Models/SoundModel.swift` | Unit tested |
| Compare Models: one section per engine (four engine rows always shown), Basic/Hard + latest + history on each usable model row, auto-select after an asked-for download | `Views/ModelComparisonView.swift`, `Views/LocalModelView.swift`, `Services/LocalModel/ModelStore.swift`, `Services/CoreAIModelLibrary.swift` | see §4 |
| Progress/ETA: live-measured speed before any ETA, range for long answers, bar against expected time + ⅕ of worst case, never backwards, ≤97 % until done, no spinner/animation | `Services/LocalModel/WorkMeter.swift`, `LocalJudge.swift`, `ModelBench.swift`, `Services/CoreAIAdJudge.swift` | Unit tested |
| Core AI: waits for the catalog (fixes false "not downloaded" → reader), keeps the last good result when a read fails, per-episode crash guard, attempt provenance, portable GPU variant for chip-mismatched bundles, free-text fallback for hybrid models, prompt-prefix reuse off on iPhone | `Services/CoreAI*.swift`, `Services/ProcessingPipeline.swift`, `Services/ModelFinder.swift` | Logic unit tested; phone OPEN |
| Whole-stretch ("container") answers dropped for every engine | `Services/LocalModel/JudgePrompt.swift` | Unit tested |
| Reader's repeated-audio intros/outros kept beside model cuts | `Services/ModelCutCheck.swift` | Unit tested |
| What Was Skipped overlap editing (trim / absorb / locked wall / enclosing) with live hint | `Services/CorrectionLedger.swift`, `Views/SkipReportView.swift` | Unit tested |
| Diagnostics: "Send to the Mac" first, folding sections | `Views/DiagnosticsView.swift` | see §4 |
| Tests | `Tests/Pass32Tests.swift`, `Tests/Pass31Tests.swift` (meter expectation), `UITests/ScreenshotTests.swift` (`testSoundChartControls`, `testDiagnostics`) | see §4 |
| Lab tool: harvest his decisions from results exports | `Tools/DetectionLab/harvest_corrections.py` | 1 episode harvested (LoS, 410 s locked) |

## 3. Findings to keep

- **Reader instead of Core AI (phone, 77b904d):** detection began before the Core AI catalog finished loading, so the chosen model looked "not downloaded" and the reader ran. Now waited for (≤20 s).
- **Core AI Qwen3 4B episode crash:** inside Apple's runtime. Core AI episodes completed on 5 Oct, before Pass 30 added prompt-prefix reuse; reuse is now off on iOS (Mac lab: `COREAI_LAB_REUSE=1`). Unproven until the phone runs it.
- **convState errors:** Apple's GPU constrained decoder (pipelined strategy) doesn't support hybrid-state models (Nemotron 3 Nano is a hybrid model) → free generation primed with `{"parts":[`, stopped when the list closes.
- **Chip-specific Core AI bundles:** Gemma 4 E2B and MiniCPM5 ANE builds are AOT-compiled for h18p (iPhone 17 Pro). The app now loads the bundle's portable GPU variant when present and says so on the row.
- **Answer format (Mac lab, Gemma 4 E4B, xgrammar, phone conditions):** line-first recall 0.68 / false cuts 541 s; label-first 0.46 / 707 s; reason-first 0.72 / 550 s → label-first rejected, Gemma stays reason-first. Qwen3.5 4B (compact JSON, phone conditions): line-first recall 0.88 / false 41 s / missed 133 s; label-first 0.84 / 2 s / 180 s — fewer false cuts but more ads heard and a weaker Basic score, so no change: Qwen stays line-first. Whitespace (any vs compact) changes little for either model, so it does not explain the phone/Mac gap. Same conditions: Gemma 4 E2B recall 0.09–0.29 with 1,290–1,643 s of false cuts across the lab stretches and Ministral 3 3B 0.81–0.90 recall with 1,762–3,713 s false — both unusable for his shows whatever the answer format; Qwen3.5 4B stays the best MLX choice, Gemma 4 E4B second (`~/Developer/mlxlab/queue5.sh`, `r5.jsonl`).
- **Reader learning:** veto/confirm by sentence embedding (0.81), edge and bridge lessons, prompt examples, user-provenance fingerprints, known sponsors. Grades are measurement only. Retraining stays deferred (D07).
- **Engine reconciliation:** blind union rejected (adds every engine's false cuts); only exact-evidence reader cuts (repeated audio) join a model's result.
- **Item 12 decisions** are in the Spec (P21, P22).

## 4. Verification this pass

- **Unit tests:** 310 run, 0 failures, 1 skipped (PS-Unit simulator, `build/unit-test.log`).
- **Simulator build:** 0 warnings (`./Scripts/local-build.sh build`).
- **Simulator UI tests (PS-Unit, screenshots inspected):** `testSoundChartControls` passed (pinned short → tallest stays pinned, folds to one line, unpins and scrolls; `build/shots-p32b`); `testSoundSheetDetents` passed (a fix handle dragged to −11 dB is whole at the bottom of the plot; EQ drag, landscape; `build/shots-p32c`); `testDiagnostics` passed (Share first, six folds; `build/shots-p32c`); `testCoreAIModelDisclosure` passed (four engine sections with 72×44 Basic/Hard, Core AI/MLX lists open and close, Reader run shows its result; `build/shots-p32f`). On this fresh simulator the 77b904d baseline also failed the EQ-drag step once, so that step is flaky here, not a regression.
- Found while testing and fixed: enlarging the pinned chart silently unpinned it; the Background fold had no reachable identifier; Compare's list toggles reported no expanded/collapsed state to VoiceOver (now a plain button with a value).
- Noted, unchanged: the first launch downloads Qwen3.5 4B on Wi-Fi by design (it happened on the fresh simulator: 3 GB).
- Not tested anywhere but the phone: locked/background behaviour, the Core AI crash, portable-variant loading, Nemotron, MLX speed/heat, real ETA accuracy, real overlap drags.

## 5. Mac disk

Cleanup 1 recovered ≈33.0 GB (`~/Developer/pk-tools/cleanup.log`: old screenshot folders archived, duplicate lab copy, `pk-app/build` 13.6 GB, Core AI cache, Xcode DerivedData, unavailable simulators). Pass 32 step 2: four ruled-out MLX models removed from the Hugging Face cache (Llama 3.2 3B, LFM2.5 2.6B, MiniCPM5 1B, Qwen3.5 2B: 5.77 GB) and the recovery worktree's DeviceDerivedData (1.3 GB). Free space was ≈48 GB after cleanup 1 and ≈61 GB after step 2; ≈51 GB at the end of the pass after the two DerivedData folders were rebuilt for testing (regenerable). Kept on purpose: Qwen3.5 4B, Gemma 4 E4B/E2B, Ministral 3 3B (lab), `build/lab` fixtures, all source, stashes, archives, app data, signing and iCloud. Not reviewed (left alone): `~/Developer/pk272`, `pk-ml`, `pk-forensics`, `pk-research`, `pk-sym`, `pk-coreai`, `podskipper-archive`.

## 6. Delivery and next steps

- **Pass 32 app commit: `110406d61f051ea0b41e349ae51c752431c67840`** on `main`. CI run [37609093609](https://github.com/Throckmorton69420/podskipper/actions/runs/37609093609) completed successfully; artifact `PodSkipper-ipa`, 69,339,928 bytes. Install with Feather as before. A later documentation/scripts commit (Handoff, catalog, `watch-ci.sh` no longer reports "green" while a run is still going, `push.sh` attribution) changes no app code.
- Phone test list: see the Pass 32 report in the chat (and §2 above).

Next pass: his phone results on this build decide everything. Then (1) rerun the stopped Qwen/Ministral format lab with the Mac idle; (2) full fixture lab per show with current prompts; (3) Core AI recompile for A18 Pro (coreai-torch) only if the portable variants don't load or are too slow; (4) the base plan batches (processing observers, catalogue stash repair, quality fixtures, parity, data/publishing).
