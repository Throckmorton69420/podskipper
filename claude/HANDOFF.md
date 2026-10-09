# PodSkipper — Handoff (Pass 33, 9 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) — the **Pass 33 overlay** at its top, then the Pass 28–32 overlay, then the 178 base rows — and [Pass 33 evidence](evidence/2026-10-09-pass33-phone-evidence.md). Then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) and [Implementation Plan](../IMPLEMENTATION-PLAN.md). You don't need the Pass 33 prompt; everything it asked is tracked as X33-01…13 and P23.

## 1. Where the code is

- **`main` is canonical.** Work in `~/Developer/podskipper` only. `~/Developer/pk-app` is a second worktree at 77b904d (detached) for building an older main while the lab runs.
- `stash@{0}` (catalogue transaction WIP, 252 tests / one cross-context regression) is untouched; also tag `archive/backup-catalogue-stash-2026-10-02` (15a29af). Do not pop it casually (Batch 3).
- Archive tags from Pass 32 are intact (`archive/*`, six). Branches: `main`, PR #23's two branches, the `feather-*` branches.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>` (ORIGIN → token URL, output redacted). `gh` is not installed.
- **Simulators.** PS-Unit (F51033BC-3FEA-4D44-BF85-06F492C6933F, iPhone 16 Pro, iOS 27.0): `./Scripts/unit-test.sh F51033BC-…` and `./Scripts/uitest.sh <Test[,Test]> <tag> PS-Unit`. The live simulator panel needs his "Let Claude use it" grant (not given this pass); headless tests work without it.
- **Symbolicating his crashes:** CI archives no dSYM. Build the exact commit in a temporary worktree with CI's flags (`xcodebuild … -configuration Release -sdk iphoneos … ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO`, same Xcode 27.0) into `build/DeviceDerivedData`, then `atos -o …/PodSkipper.app.dSYM/Contents/Resources/DWARF/PodSkipper -l 0x100000000 <0x100000000+offset>`. Only coherent call chains are trustworthy (UUIDs differ).
- MetricKit/report helpers used this pass: scratch scripts only (matrix and MetricKit stack printers); the matrix table is in the evidence file.

## 2. What Pass 33 changed (code)

| Area | Files | Evidence level |
|---|---|---|
| One owner for the library: full schema, opened once, shared by App Intents; failed open reports stage/store/sizes/protection/free space/full error chain, recovery screen with Details/Copy, auto-retry on unlock/foreground; recovery log in Diagnostics; launch time from window open | `Services/LibraryStore.swift` (new), `Views/Views.swift`, `Services/Intents.swift`, `Services/Diagnostics.swift` | Unit (disposable stores) · phone OPEN |
| Compare folds as their own rows (no in-row DisclosureGroups); crash-history line and confirm before testing a model that closed the app | `Views/ModelComparisonView.swift`, `Views/LocalModelView.swift` | Unit + UI (pixel/geometry test that fails on Pass 32) · phone OPEN |
| Honest test progress: work-only bar, cooling recorded as waiting, time left in work time, explicit run states, errors in the tapped row, tests pre-empt Prepare Ahead | `Services/LocalModel/ModelBench.swift`, `ThermalPacing.swift`, `LocalJudge.swift` (monitor), `Views/ModelComparisonView.swift` | Unit · phone OPEN |
| Core AI: precise crash stage (reading vs writing, tokens), per-model closure record, automatic work skips a model that closed the app twice in 14 days | `Services/CoreAIAdJudge.swift`, `ModelBench.swift`, `ProcessingPipeline.swift` | Device-compiled · phone OPEN |
| Model storage: Core AI delete removes all revisions/variants/staging of the repo; compiled cache cleared when no Core AI model is left; Settings → Storage → Models and Caches (measured; confirmed cleanups) | `Services/ModelStorage.swift` (new), `Services/CoreAIModelLibrary.swift`, `Views/ModelStorageView.swift` (new), `Views/SettingsViews.swift` | Unit · phone OPEN |
| MLX: forced completion + whitespace suppression in guided generation, loop stop in free retries, case-tolerant labels, bare-list answers, both attempts logged | `Services/LocalModel/LocalJudge.swift`, `ModelAnswerFailure.swift`, `JudgePrompt.swift` | Unit · phone OPEN |
| Audio: engine-format change restart; interruption/route reasons; playback trace in Diagnostics | `Services/AudioEngine.swift`, `StreamEngine.swift`, `PlayerEngine.swift`, `Services/PlaybackTrace.swift` (new) | Device-compiled · phone OPEN |
| Speed & Audio: All Shows / This Show, Starting Speed, Reset with confirm + Undo, per-show Smart Speed/Even Out actually applied | `Models/SoundProfile.swift` (new), `Models/SoundModel.swift`, `Views/PlayerViews.swift`, `Services/AudioEngine.swift`, `Services/PlayerEngine.swift` | Unit + UI · phone OPEN |
| Lab: harvest also takes his stretch verdicts/locks (pre-ledger) | `Tools/DetectionLab/harvest_corrections.py` | Run on his export: 2 episodes, 1,146 s |
| Tests | `Tests/Pass33StoreTests.swift`, `Tests/Pass33Tests.swift`, `UITests/ScreenshotTests.swift` (`testCompareFoldsStayPut`, `testAccessibleCompareFoldsStayPut`, `testSoundScopeAndReset`) | see §4 |

## 3. Findings to keep (proven vs not)

Proven: `3ba90ff` = Pass 32 app code. The smaller-schema open deletes bookmarks, listening history and stations. The 120 s "launch" was the recovery screen; the 62-minute one a background-started process. Core AI Qwen3 4B aborts inside Metal under the GPU delegate (same stack 5 Oct) — prefix reuse is not the cause. Most disk writes come from on-phone Core AI compilation; deleted models left other revisions/variants/staging and compiled copies. PodSkipper never uses the microphone. Pre-ledger LoS decisions reached on-device lessons but not the Mac harvest. "Started (automatic)" = Prepare Ahead on screen. Compare's jump = row cross-fade of an in-row fold (the new test reproduces it on Pass 32).

Hypotheses, not proven: the 04:27 store failure's cause (smaller-schema race, low free space, other); headset profile change → stopped engine → pause / silent playback; Gemma/MiniCPM loading closures = memory; what in the static-shape run Metal aborts on.

## 4. Verification this pass

- **Unit:** 332 run, 0 failures, 1 skipped (PS-Unit). New: 27 across `Pass33StoreTests` (5) and `Pass33Tests` (22).
- **UI (PS-Unit, screenshots inspected):** `testCompareFoldsStayPut` and `testAccessibleCompareFoldsStayPut` pass (and the former **fails on the Pass 32 views**: 7–13 % of the screen above the fold changes while it opens — `build/test-p32-folds.log`); `testCoreAIModelDisclosure` passes; `testSoundScopeAndReset` passes; `testSoundChartControls` and `testSoundSheetDetents` pass (phone-proven chart behaviour intact). Shots: `build/shots-p33-folds`, `build/shots-p33-sound2`, `build/shots-p33-sound`.
- **Device compile:** Release iphoneos of the Pass 33 tree succeeds (`./Scripts/device-build.sh`); remaining app warnings are pre-existing iOS 27 deprecations (AVAudioSession interruption API, `auAudioUnit`, AVAssetWriter in DemoVideo, `GenerationError`) and one pre-existing capture warning in `CoreAIModelLibrary.download`.
- **Not tested anywhere but the phone:** every Core AI/MLX run, heat, the store failure, audio routes/interruptions, storage numbers after deletes.

## 5. Mac disk

≈22 GB free at the end of the pass (`build/DeviceDerivedData` ≈ 1.4 GB, simulator DerivedData rebuilt). The temporary 3ba90ff worktree used for symbolication was removed. Nothing else deleted.

## 6. Delivery and next steps

- **Pass 33 app commit: `8bbe5dddbf413cf1b09218243b3613bddc83e843`** on `main`. CI run [37905713822](https://github.com/Throckmorton69420/podskipper/actions/runs/37905713822) succeeded; artifact `PodSkipper-ipa` (id 11604479652), 69,517,611 bytes; also published to the `latest` release by the workflow. Install with Feather as before. The following docs commit (catalog, handoff, evidence, plan, spec) changes no app code and is marked `[skip ci]`.
- `AGENTS.md` (an untracked Codex-style copy of CLAUDE.md, written 9 Oct 00:56 by another tool) was left untouched and uncommitted.
- Next pass: his phone results on this build. Then: if Qwen3 4B still aborts, the new in-flight stage says reading vs writing and at which token — compare with the static graph buckets (256…4,096 × 8/16/64) before considering an A18 Pro rebuild; replace the deprecated iOS 27 interruption API; MLX Granite-H runtime compatibility; then the base plan batches (catalogue stash repair, quality fixtures per show, parity, data/publishing).
