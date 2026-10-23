# PodSkipper — Handoff (Pass 46, 23 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) — the **Pass 46 overlay** (X46-01…08) at its top, then Pass 45 and older overlays and the base rows — and [Pass 46 evidence](evidence/2026-10-23-pass46.md) (Pass 45's is [here](evidence/2026-10-22-pass45.md)). Then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) and [Implementation Plan](../IMPLEMENTATION-PLAN.md).

**What still applies from older sections below:** §1 (where the code is, simulator, scripts, symbolication, compiled Core AI copy) and the cleanup record in §1a. Superseded: §5's Gemma "install the compiled copy, then test" (Gemma is refused on his iPhone since Pass 39, X39-05); §5a's "download Qwen3 4B again" (done); Pass 41's checklist item 3 (drag) — replaced by the Pass 42 checklist. "Findings to keep" (§3) and the Gemma Mac-lab ban stay in force.

## 1g. Pass 46 (on top of db9993c)

Commits f3628c4 (A: detection safety, kinds, Reader learning provenance, Qwen3 4B prompt ceiling), 6eb218a (B: Apple Podcasts 27.2 RC player, Playing Next, season actions, reference), then docs. **Unsigned IPA: "Build unsigned IPA" on 6eb218a — success** (23 Oct; release asset not inspected). Exports: `build/phone-1023/` (git-ignored). Evidence level: lab, unit (full suite 482 / 1 skipped; the one failure was an expectation this pass changes on purpose, updated), sim (player, video, storage, library UI tests), device build — **no phone run**.

- **Fingerprint evidence:** `AdPrints.withoutSharedProgram` (in `detectionEvidence`); `SegmentDetector.withProduced` widening/position rules, `plausible` (kind length backstop), `plugs(sureShow:)`, `completeShortReads`. `AdDetector.version` 46.
- **Lab for a detector stage:** `Tools/DetectionLab/detector_ab.py <out> base=<lab-segments> new=<lab-segments>` (59 labelled episodes, held-out fold readers where present). Build binaries with `Tools/DetectionLab/lab.sh build-segments <ABSOLUTE output path> <source root>` (a relative output path fails to link: the script changes into `build/lab`). The shipped readers: `LAB_TAGGER=$PWD/Resources/Detection/TaggerWeights.bin:…TaggerWeights-2.bin`. Fingerprint fixtures: `LAB_PRODUCED=1` with `<key>.produced.json`; `build/lab/tal899*` is "Reaching Out" (downloaded this pass) with a self-copy `tal899dup`.
- **Kinds:** `ModelCutCheck.reconcileKinds` (`reconcilesKinds` is the replay's switch); replay `Pass46ReplayTests` → `build/p46/replay.json`.
- **Learner policy 46:** `OnDeviceReaderLearner.independent`, per-family votes, `claimed`, `Status.evidence/setAside/examplesReaders/rebuiltFor`, `rebuild` (from `ProcessingPipeline.rebuildReaderLearningIfNeeded`, called by `maintain`); the set-aside head is `Detection/UserTaggerHead-set-aside.bin`. `ModelBench.score(named:coreAI:)`.
- **Qwen3 4B:** `ModelPromptPlan.promptCeiling` / `qwen3PromptCeiling` (1,536) / `windowRoom`, used by `CoreAIAdJudge` and the Core AI lab (`LAB_NOCEILING=1` turns it off there). If closures continue at smaller parts on the phone, remove it.
- **Player:** `PlaybackSpeedButton`, `SpeedPanel`, `SleepTimerButton`, `VolumeRow`/`SystemVolumeSlider` (`MPVolumeView`, blank in the simulator), `PlayingNextView` (QueueViews). The grabber is `PlayerClose`; ⋯ is `PlayerMore` beside the title.
- **Reference:** `ApplePodcastsReference/ios27.2rc/DISTILLED/` (the RC; supersedes 27.2b2). Runtime layout from Apple's iOS 27 user guide (support.apple.com), cited in the evidence.
- **UI tests:** run player tests and `testPass35StorageManagement` on a fresh simulator boot; after the player tests the demo's loaded episode is "in use" and the storage test removes nothing.

**Phone checklist:** evidence §11.

## 1f. Pass 45 (on top of d0b9c70)

Commits e5fc9af (A: cut check, re-label at serious, Core AI per-part checkpoint, MiniCPM5 `compactTight`, status throttle, Core AI lab judge), 3df998e (B: Downloads & Storage scopes, search sources, show header, play-pill words), then docs (Qwen3 4B: measured on its real build, `compactListener` kept — no code change). His exports: `build/phone-1022/` (git-ignored). **Unsigned IPA: workflow run #329 on 3df998e — success** (22 Oct, 13 min; release asset not inspected). Evidence level: lab (replay + real Core AI builds on the Mac), unit (full suite 464 / 1 skipped; the one timing test that failed under lab load passes alone), sim (storage and Library UI tests), device build — **no phone run**.

- **Cut check replay.** `Pass45ReplayTests` (skips without `build/phone-1022/results.json`) writes `build/p45/replay.json`; score with `python3 -I Tools/DetectionLab/phone_eval.py build/phone-1022/results.json --build NONE --cuts build/p45/replay.json`. It also fuses any `build/p45/{mc,c3}/*.cuts.json` lab reads with the held-out Reader (`build/p45/heldout-reader.json`). Wrapper: `build/p45/replay.sh <tag>`.
- **Core AI on the Mac, for real.** `Tools/CoreAILab` (`swift build -c release`): `coreai-lab <bundle> <results.json> <episode index> judge` reads an exported episode as `CoreAIAdJudge` does. Drive with `LAB_BIN=$PWD/Tools/CoreAILab/.build/release/coreai-lab LAB_FAMILY=<catalog id> LAB_CONTEXT=2047 python3 -I Tools/DetectionLab/phone_judge.py <results> <bundle> <out> <variant> <guids…>`; variants `p-<profile>` or drafts in `Tools/CoreAILab/variants/`. Queue script pattern `build/p45/models.sh mc:<variant> c3:<variant>`. Bundles: `~/Developer/pk-coreai/minicpm5-2b/int8` (his phone's build, 2.5 GB, downloaded this pass) and `qwen3-4b/macos`. ~14 min (MiniCPM5) / ~15 min (Qwen3 4B) per 25 episodes. Never run MLX and Core AI labs together.
- **Labels:** 59 now (#691 added, `LABEL_WHEN="pass 45, 22 Oct 2026" write_label.py …`).
- **Storage page:** `StorageView.Kind.action` is the removal for the scope; `.all` → `Choice` dialog. `SelectionActionBar(showsCount:)`.

**Phone checklist:** evidence §9.

## 1e. Pass 44 (on top of ff854a0)

Commits 1d142a5 (A: retrained Reader), bb67cf1 (B: each tested model's instructions, Core AI memory guard), 48b18fe (C: one episode row, Activity during Find Ads), then the docs commit. His exports: `build/phone-1020/` (git-ignored). **Unsigned IPA: run 39442409553 on 48b18fe — success** (20 Oct 15:01 UTC; release asset not inspected this pass). Evidence level: lab, unit (full suite 454 / 0 failures / 1 skipped), simulator screens and UI tests, device build (Release, iphoneos, unsigned) — **no phone run**.

- **Reader (X44-01).** Labels: `Tools/DetectionLab/phone-labels/` (58 episodes; Claude-labelled from transcripts — never treat as his corrections). Sheets: `python3 -I Tools/DetectionLab/label_sheet.py <results> list|<guid prefix>`; write: `write_label.py <results> <guid> <spec|->`. Train/evaluate: `~/Developer/pk-ml/bin/python -I -u Tools/DetectionLab/reader_distill.py prepare|folds|train|sweep <results> <tag>` (outputs `build/p44/<tag>/`, ~12 min per reader on MPS; a fold run of 3 × 2 readers ≈ 75 min). Ship: `build/p44/ship-reader.sh` pattern (train → `tagger.py style` per reader → anchor). Detector sweep through `lab-segments` (`LAB_TAGPROBS`, `LAB_TAGBOOST`). Learned heads are tied to reader identity: a new reader sets his phone's head aside. **Pause the MLX lab (SIGSTOP) while training** — sharing the GPU made both 3× slower.
- **Models (X44-02).** Queue: `build/p44/models/run.sh` pattern (`phone_judge.py <results> <model dir> <out> <variant>` over `model-dev.json`; Core AI stand-ins with `LAB_BUDGET=1450 LAB_CAP=170`), score `~/Developer/pk-ml/bin/python -I Tools/DetectionLab/model_lab_score.py <results>`. ~22 min per model × variant. MiniCPM5's MLX copy answers empty — don't use it to judge Core AI MiniCPM5.
- **Core AI memory (X44-03).** `CoreAIMemory.short(since:available:warned:)`: `since` = when reading began, warnings count only below `warnedFloorMB` (1,200).
- **Rows (X44-04/05).** `EpisodeListRow` is the only episode row; add page specifics through `status`, `findAdsTitle`, `removal`. Selection rows are id `SelectableEpisode` everywhere. `ProcessingJobStore.records` is `@ObservationIgnored`; observers read `revision` (moves on every change except progress within a step). Lab: `TEST_RUNNER_LAB_ACTIVITY=1 TEST_RUNNER_LAB_DEMO=1 ./Scripts/uitest.sh ResponsivenessLabUITests/testActivityScrollHitches <tag>` — on the simulator it gives scroll durations only, no hitch ratio.

**Phone checklist:** evidence §8 (Reader on known episodes; Core AI Qwen3 4B on #960; Instruct 6-bit edges; rows and swipes everywhere; Activity scrolling during Find Ads; "… left").

## 1d. Pass 43 (on top of f34df0c)

Commits 9fbd4f8 (A: playback recovery, Core AI route and resume, agreement learning, batch Find Ads Again) and f639f16 (B: Qwen3.5 4B listener rules), then the docs commit. His exports: `build/phone-1019/` (git-ignored, with dumps `playback.txt`, `engines.txt`, `bg-events.txt`, `overview.txt`). **Unsigned IPA: run 39313279595 on f639f16 — success** (release `latest`, PodSkipper.ipa 72.8 MB, 19 Oct 19:59 UTC). Evidence level: unit (full suite 450 / 0 failures / 1 skipped), simulator demo screens (`build/p43-shots/`), device build (Release, iphoneos, unsigned) — **no phone run**.

- **Core AI route (X43-01).** `CoreAIEngineRoute.choose` sends every dynamic bundle to `.sequential` (cap 2,047); `fallback(engineHint:path:)` gives unhinted ones `.runtimeGrammar` at 1,024. Qwen3 4B therefore gets `Profile.compact` and shorter parts now (`Profile.forContext`) — unmeasured. `CoreAIMemory` stops a read between parts (warning since load, or < 300 MB). Not run: Qwen3 4B on the sequential engine anywhere (only the 0.6B GPU build on this Mac). If his phone shows the sequential engine can't open the 4B, it falls back to the decoder at 1,024 (Diagnostics › model shows which engine ran).
- **Resume (X43-02).** `CoreAIInFlight` note has `away` (set by `applicationDidEnterBackground`/`WillEnterForeground`) and free MB; `ModelBench.init` records closures only when not away. `CoreAICrashGuard` counts per episode (`triesAfterClosing = 1`); `CoreAIStability.policy = 43` resets old counts. `ProcessingPipeline.stillOwed(_:)` decides owed/waits-for-you/no; `detectAndSave` keeps an earlier result for now and owes the read; `headOfLine` skips jobs with a future `retryAfter`.
- **Detection (X43-03).** Lab: `Tools/MLXLab` (`mlx-lab <model> <results.json> <episode#> judge`, variants in `LabPrompts.swift`), driver `Tools/DetectionLab/phone_judge.py <results> <model dir> <out dir> <variant[:focus]>`, scorer `python3 -I Tools/DetectionLab/phone_eval.py <results> [--cuts file] [--detail]`. App: `Profile.listener` for Qwen3.5 > 2.5B (`ModelPromptPlan`). Next candidates: run v2r for Qwen3.5 4B Instruct 6-bit and the other families he uses before widening it; the Core AI compact rules for Qwen3 4B.
- **Reader (X43-04).** `OnDeviceReaderLearner.agreementLabels`, `shouldTrain`, `silverPolicy = 43`; teachers from `ProcessingPipeline.otherTeachers(FinderAttemptLog…)`. Lab: `~/Developer/pk-ml/bin/python -I -u Tools/DetectionLab/reader_consensus.py prepare|run …` (variants `consensus@0.395~0.5` etc.). Head-only learning measured near its limit; his corrections are the lever.
- **Playback (X43-05).** `AudioEngine` reopen (`reopenDelays`, `reopenGrace`, test hooks `failsReadsForTesting`/`failsReopensForTesting`), `Health.unreadable`, `PlayerEngine.interruptionWillEnd`. iOS 27 deprecates `InterruptionOptions`/`InterruptionType` (device build warnings) — migrate when the resumption-recommendation notifications can be checked on a phone.
- **UI (X43-06/07).** `EpisodeBatch.doneBefore`/`findAdsAgain`; `ProcessingPipeline.provenance`; `finderModelLabel`; Up Next selection in `QueueViews.swift`.

**Phone checklist:** evidence §8 (Leroy Jetson #960 with Core AI Qwen3 4B; lock mid-read; AirPods during Find Ads; Activity rows; Find Again on a selection; Reader learning without rollback runs).

## 1c. Pass 42 (on top of 3d77f86)

Commits 6986e50 (A: the player reads ahead itself and notices when sound runs out), fe697b3 (B: drag-to-choose scrolls), then the docs commit. His exports: `build/phone-1018/` (git-ignored). **Unsigned IPA: run 39180860607 on fe697b3 — success** (release `latest`, PodSkipper.ipa 72.8 MB, 19 Oct 00:38 UTC). **Xcode on this Mac is now 27.1** (27A9275, iOS SDK 27.1; updated outside the session at 18:58 on 18 Oct). Simulator runtime still iOS 27.0.

- **Sound (X42-01).** `AudioEngine` no longer uses one `scheduleSegment`; it reads one-second buffers on `feedQueue` and keeps 20 s ahead. `health()` → `PlayerEngine.restartSound` (≤ 3 in 2 min, then pause). The trace's engine state now carries "given to … (… ahead), slowest read …, ran dry …×"; entries carry `heat`/`work`. Test hook `holdsReadingForTesting` starves the reader. **Don't go back to `scheduleSegment`**: its read-ahead can't be observed, which is why the old watchdog couldn't see his silence.
- **Drag (X42-02).** `SelectionPan` (UIKit pan via `UIGestureRecognizerRepresentable`) + `CADisplayLink` in `SelectionDrag`. Edge = the scroll view's `adjustedContentInset` area. Constants: band 64 pt, rest 0.3 s (0.12 s broke a resting finger on the last row), 90–1,100 pt/s. Lab: `TEST_RUNNER_LAB_PAGE=Downloaded|show:<title> [TEST_RUNNER_LAB_HOLD=s] ./Scripts/uitest.sh ResponsivenessLabUITests/testDragSelectScrollsOn <tag>`; recordings with `xcrun simctl io <sim> recordVideo` while it runs, frames via ffmpeg.
- **Open finding:** scene-update watchdog during a Core AI read when backgrounded at serious (X42-03) — not yet symbolicated.
- **Phone checklist (Pass 42 IPA):**
  1. Play an episode, then run a heavy model test (Bonsai 27B, or Qwen3.5 4B / Nemotron at serious). Listen throughout. If sound stops: does it come back by itself within a second or two? Export Diagnostics either way — Playback lines show "given to … ahead, slowest read …" and any "sound ran out … starting again" with heat and the test.
  2. Pause during a test and leave it: it must stay paused.
  3. Select on Downloaded and on a long show: touch a circle, slide down to the bottom edge and hold — the list should glide on and keep ticking; move the finger up off the edge to stop; lift to end. Same upward. Start on a ticked row to untick a run. A scroll beside the circles must tick nothing.
  4. Same slide on Bookmarks (not tested in the simulator — no bookmarks there) and on a station.

## 1b. Pass 41 (on top of a89cd66)

Commits ea11616 (A: library work off the main thread, slim collection reads, readings ≤ 4/s, slow-read notes, Downloaded lab), be22c13 (B: drag through the ticks), then the docs commits. His exports: `build/phone-1016/` (git-ignored). **Unsigned IPA: run 38888264135 on be22c13 — success** (release `latest`, PodSkipper.ipa 72.8 MB, 16 Oct 11:06 UTC).

- **The cause found (X41-01).** `LibraryIndex` was a `@ModelActor` and ran on the main thread — counts passes ~450 ms, launch feed-refresh merges ~1.9 s (simulator). Now a plain actor; 0 ms on main. Creating a `@ModelActor` off the main thread did **not** move it (measured) — don't try that again.
- **Downloaded lab.** `-LabDownloadedLibrary <results.json>` (debug) adds his 46 found-ads episodes from a Results export as downloads under "Lab ·" shows; `clear` removes them; `bench` times the page's reads. **The simulator's library now has them** (53 downloads). Profiling: `ResponsivenessLabUITests/testPageScrolls` with `TEST_RUNNER_LAB_PAGE=Downloaded|Latest Episodes|show:<title>` and Time Profiler attached (`xctrace record --device <sim> --attach <pid>`; wait up to ~3 min for the app's pid — the first launch under a UI test can be slow; kill any stuck `xctrace` first, one hung recording blocks the next).
- **Drag to choose (X41-02).** `SelectionDrag` in `Views/CollectionKit.swift`. Everything is in screen coordinates (inside list cells a named coordinate space didn't reach the drag); the list's layout frame is the uncovered area on both collections and the show page. Tests: `testPass41DragSelect` (demo) and `ResponsivenessLabUITests/testDragSelectLongList` (`LAB_PAGE`).
- **Heat (X41-03).** keepReading worked on his phone (Theo 254 → 172 s in the model). The rest-policy A/B on one episode is still not done. Keep keepReading as the default.
- **Phone checklist (Pass 41 IPA):**
  1. With the phone at serious and a Find Ads running, open Library › Downloaded: scroll, tick, tap. Then the same after the job ends. Compare with Library and a show page.
  2. Diagnostics › Background: any "Slow on screen: …" lines, with heat.
  3. Select on Downloaded, a show and Bookmarks: slide through the ticks down and up; start on a ticked row; hold at the bottom edge; a scroll beside the ticks.
  4. Optional: Diagnostics › Speed › Heat → "Rest 20 s", the same episode straight after, switch back.
- **Cleanup check (16 Oct):** see evidence §6. Everything listed as kept below is present. `AGENTS.md` came back (recreated 16 Oct 00:43 outside these sessions; untracked, left alone). Evidence before 15 Oct names `.xcresult` bundles that were deleted on 15 Oct: trust its recorded results and the `shots-*/named` screenshots; don't look for the bundles.

## 1. Where the code is

- **`main` is canonical** in `~/Developer/podskipper`. `~/Developer/pk-app` (77b904d, detached) untouched. `~/Developer/pk-sym` is **his own folder of old IPAs — not a worktree; leave it**.
- `stash@{0}` (catalogue transaction WIP) untouched; tag `archive/backup-catalogue-stash-2026-10-02`.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>`. `gh` not installed.
- **Simulator: the PS-Unit simulator no longer exists.** Use iPhone 16 Pro `4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`. Unit: `./Scripts/unit-test.sh 4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`; one class: `xcodebuild test-without-building … -only-testing:PodSkipperTests/<Class>` after `build-for-testing` (and `./Scripts/generate-project.sh --simulator` when files were added). UI: `./Scripts/uitest.sh <Test[,Test]> <tag> <simulator>`.
- Device compile: `./Scripts/device-build.sh` (unsigned Release iphoneos). Core AI code (`CoreAIPreparation`, `CoreAIAdJudge`, library) compiles **only** there.
- Symbolication: device symbols for iOS 27.0.1 are in `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 27.0.1 (24A446)/arm64e/Symbols` (`atos -arch arm64e -l <__TEXT vmaddr>`); app frames: rebuild the exact commit with `Scripts/device-build.sh` in a temporary worktree, `atos -arch arm64 -l 0x100000000`.
- **Compiled Core AI copy** for his iPhone 16 Pro: `build/coreai-aot/qwen3_4b_mixed_4bit_8bit_static.h17p.aimodelc` (2.5 GB, git-ignored; `sourceHash 882606B7…`). Now installed from a visible button under the Qwen3 4B row in Models and Caches; PodSkipper refuses it unless it was compiled from exactly the downloaded graph and for this chip. He has put an identical copy in his iCloud Drive → Downloads; the installer picks it in Files (package type accepted) and downloads it from iCloud with progress.

## 1a. Pass 40 (on top of 2d620d1)

Commits 8c6f0dc (A: heat policy, overflow, HeatLog, Tools/MLXLab) and the Pass 40 B commit after it (list refreshes, LiveQuery, lab harness, docs). His exports are in `build/phone-1015b/` (git-ignored). **Unsigned IPA: run 38727179680 on 41cf5bc — success** (release `latest`).

- **Heat (X40-01/02).** "Keep reading" is the default: no rest at serious, pauses only at critical (10 s out of critical before resuming). The old 20-s rest is a choice in Diagnostics › Speed › Heat, for an A/B on the same episode. Exports now carry `heatPolicy`, `heatTimeline`, `secondsByHeat`, `wasted*Tokens`, `classifiedTokensPerMinute` and per-part free memory/answer start. **First phone read:** compare `classifiedTokensPerMinute` and per-part tok/s for the two policies, both started at serious.
- **MLX overflow (X40-04).** Held answers may be 496 tokens (lean). An overflow is read again in halves, and an empty free answer after one isn't kept. Answers that fitted before are unchanged (lab).
- **Lists (X40-05).** Library, Downloaded/Saved/Latest/Recent, Up Next, New/Search and Settings no longer re-read or redraw on every library save. The mechanism is `StoreChanges` + `LiveQuery` in `Views/StoreChanges.swift`. Lab: `-LabStoreWrites` (debug) + `ResponsivenessLabUITests` (`TEST_RUNNER_LAB_REAL_LIBRARY=1`, optional `TEST_RUNNER_LAB_WRITES=1`, `TEST_RUNNER_LAB_IDLE=30`, `TEST_RUNNER_LAB_VISIT_TABS=1`) with Time Profiler attached (`xctrace record --device <sim> --attach <pid>`). XCUITest tap timings don't measure the app.
- **Core AI 4B (X40-06).** Qwen3.5 4B is not practical on his phone (int8 floor ~5.4 GB, S = 1 prompt reading ~10 tok/s, h17p AOT). Don't download or compile it. Kev-0.8B typed decisions were lab-tested afterwards (evidence §6a, `Tools/DetectionLab/kev_eval.py`): zero-shot it cuts minutes of show or misses most ads, so it is not worth a phone trial.
- **Tools/MLXLab.** The app's MLX path on the Mac. Build it with `xcodebuild -scheme mlx-lab -configuration Release -destination 'platform=macOS' -derivedDataPath ../../build/mlxlab-dd` from `Tools/MLXLab`. Run `build/mlxlab-dd/Build/Products/Release/mlx-lab <model dir> build/phone-1015b/results.json <episode> compare|split|format` with `LAB_ONLY`, `LAB_CAP`, `LAB_STEP`. MLX inference of Qwen3.5 4B 4-bit ran here without trouble; still no Gemma or Core AI 4B inference on this Mac.
- **Phone checklist (Pass 40 IPA):**
  1. Diagnostics › Speed › Heat should say "Keep reading". Find Ads with MLX Qwen3.5 4B 6-bit on WMBD and on Theo #690, with the phone already at serious.
  2. Switch Heat to "Rest 20 s before each part" and repeat one of them straight after. Switch back. Export Results and Diagnostics.
  3. Check whether WMBD part 4 still ran out of room (partReads "ran out of room" / "half").
  4. Browse Library › Downloaded, Saved and Up Next with nothing processing and with a show being added: do touches answer at once?
  5. Optionally, Core AI Qwen3 4B on WMBD for comparison.
- **Storage cleanup (15 Oct):** about 14 GB was removed from `build/`, all of it regenerable:
  - every `TR-*` / `unit-*` `.xcresult` bundle;
  - the raw attachments in `shots-*`: `named/` and `manifest.json` are kept, so the screenshots the evidence cites are still there;
  - the 4.4 GB synthetic backup in `build/bk/`;
  - `Tools/CoreAILab/.build`, `__pycache__`, and a stray Xcode DerivedData entry;
  - `AGENTS.md`, a stale ChatGPT/Codex copy of CLAUDE.md pointing at a missing `Codex/` folder.

  Finder `.DS_Store` files are now git-ignored. Kept: `build/DerivedData` (the labs depend on its package checkouts), `DeviceDerivedData`, `coreai-aot`, `gemma-lab`, `lab`, `tagger`, `own`, `cmp`, `fast`, `phone-*`, `recovery-archive` (catalogue-transaction patch, rollback app, probe bundles) and the pk-* folders. Logs are kept too. `~/Developer/podskipper-archive` was left alone: 12 GB, 10 GB of it old screenshot folders. Outside the repo, about 11 GB more was removed:
  - in the iPhone 16 Pro simulator: three test backups in PodSkipper's Documents (1.5 GB) and an MLX Bonsai 8B download that can't run there (2.2 GB);
  - on the Mac, the Core AI caches of the one-off Oct 12–13 probes (`~/Library/Application Support/coreai-cache/26A434/probe`, `~/Library/Caches/coreai-cache/26A434/probe2`) and Gemma's Mac cache entry, which is useless since Gemma inference is banned on this Mac.

  Kept: the simulator's library and episodes (the lab's test library), CoreAILab's other cache entries, the iOS 27.0.1 device symbols, the SwiftPM cache, `~/.config/podskipper` (keys) and `~/.codex` (ChatGPT's own history; not the project's).

## 1a0. Pass 39 (on top of b457c86)

**Unsigned IPA: run 38691812238 on 8839e72 — success** (release `latest`). Commits 197539d (A: cut check — the Reader fills what model cuts leave out; replay of his export) and the Pass 39 B commit(s) after it (prompt-prefix reuse for MLX, cooling countdown, per-part heat records, video resolver, Gemma refusal, Save star + Bookmarks count, pinned Activity bar on Library and its pages, `CollectionKit` menus/selection; docs). His exports for this pass: `build/phone-1015/` (git-ignored).

- **Engines (X39-01):** MLX Qwen3.5 4B Instruct 6-bit has the best boundaries and granularity; it is not better than the Reader at "no ads heard" by itself. With the new cut check the two combine instead of the Reader overwriting. No default changed.
- **MLX prompt reuse (X39-06):** lab-proven token-identical with a 256-aligned prefix and `.remainder` chunks (Python mlx-lm on his parts); the Swift path (`PromptPrefixCache`, `PrefixedLanguageModel`) has **never run** — MLX doesn't run in the simulator. First phone read: check Results `partReads`/`reusedPromptTokens` and that answers look like before; a parse failure falls back to a whole-prompt retry.
- **Gemma 4 E2B:** now refused on his iPhone 16 Pro even with the compiled copy (two CoreAIRuntime assertions while reading part 1 on b457c86). Don't re-enable without new evidence.
- **Core AI Qwen3.5 4B:** assessed, not pursued (5.77 GB int8, no iPhone build, decode-speed prefill). Don't download or compile it.
- **Video:** discovery reads Apple's `mediaEnclosures`; why his phone showed no picture on episodes that have one is not established — if the player now says the video is "a different length from its audio", alignment (ad-free comparison) is the cause; next step: use the video stream's own audio rendition as the clean copy.
- Library: search moved to the toolbar button so the pinned Activity bar can't collide with it (Pass 35's reason for unpinning).



Commits dd751a3 (A: chart pinch isolated from the sheet's zoom-dismiss recognizers; testPassThree current), 8277469 (B: Core AI engine routes — pipelined-hinted bundles on the sequential engine with CPU-held answers, 2,047 tokens and prompt reuse; Gemma on pipelined generate() with turns/check/cut-back and refused without a compiled copy on non-h18p iPhones; foreground rule from installed delegates; per-family `ModelPromptPlan` for Core AI and MLX, candidate profile), cb510b5 (C: `OnDeviceReaderLearner` — head-only training on his corrections and ≥70 % models' checked reads, anchored, validation-gated, Settings › Ad Skipping › Learned on This iPhone), then the docs/test commit after it.

- **Gemma on his phone:** install the h17p compiled copy (his iCloud Drive → Downloads, or `build/coreai-aot/gemma/…h17p.aimodelc`) via Models and Caches → touch and hold Gemma 4 E2B → Install Compiled Copy, *then* test. Without it PodSkipper now refuses (the on-device compile closed the app twice on e929aad).
- **Never seen on a phone:** the sequential engine (every pipelined-hinted Core AI model now uses it). First phone runs: Qwen3.5 0.8B/2B, LFM2.5 1.2B, Granite 4.0 H 1B, MiniCPM5 1B — Basic + Hard each.
- **Reader retraining failed its gate** (X38-11): weights unchanged. Don't retry with the same data; Batch 4's detector re-tune is next.
- **No Core AI model can run backgrounded here**: his compiled copies are GPU-only (MPSGraph), even the one compiled "for the Neural Engine".
- Mac lab: `Tools/CoreAILab` now runs the app's routes and plan (`LAB_FAMILY=`, `COREAI_LAB_NOREUSE=1` for a true no-reuse control); bundles in `~/Developer/pk-coreai`. Still: no Gemma inference on this Mac.

## 2. Pass 37 (on top of 4fdd2b7)

Batch A — Gemma 4 E2B with its word tables (+ h17p compiled copy at `build/coreai-aot/gemma/gemma4_e2b_qat_decode_int4lin_tbl.h17p.aimodelc`, 2.0 GB, git-ignored, sourceHash FC6830D0…), the two symbolicated iOS terminations (notes HTML import; iCloud push settings write), screen kept awake during model tests, Speed & Audio frequency zoom. Commits 091bda1 (A), 87d802f + e929aad (B); unsigned IPA from run 38536205461 (e929aad, success) — release `latest`. **Do not run Gemma inference in the Mac lab again**: on 14 Oct it hung this Mac into a hardware watchdog reset while reading the first part (loading with tables bound had succeeded). `build/gemma-lab/` holds the downloaded decoder + tables (4.4 GB, git-ignored).

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
