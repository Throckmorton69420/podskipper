# Pass 36 evidence — Core AI loading, Stop, model-test records, model storage (13 Oct 2026)

Inputs: his Pass 36 request; Diagnostics `PodSkipper-diagnostics-partial-1791860129.json` (build **4075f0e**, iPhone17,1, iOS 27.0.1, exported 2026-10-13T02:55Z, scope 6–13 Oct, `partial: true`). Starting HEAD 4075f0e; `stash@{0}` untouched.

## 1. What the export shows (latest build only unless dated otherwise)

Times UTC (MetricKit's own stamps are local EDT; converted).

| When | What | Kind |
|---|---|---|
| 12 Oct 08:52 | "Temporary files: Removed 11 items, freeing 36.8 GB" — names not recorded | cleanup (old log had no item list) |
| 12 Oct 18:43 | Qwen3 4B finished downloading again | download |
| 12 Oct 18:42 | MetricKit **disk-write** report: 4,295 MB, stack `libODIECompiler → CoreAICompiler → MPSGraph → write` | resource report, not a crash |
| 12 Oct 18:43–18:46, 18:55–18:57 | MetricKit **CPU** reports: 90 s CPU in 164 s / 104 s, stacks in `MPSGraph → AppleNeuralEngine → ANECompiler` and `CoreAICompiler` | resource report, not a crash |
| 12 Oct 18:54, 18:58; 13 Oct 02:14, 02:50, 02:54 | Launch notes: "closed while Core AI Qwen3 4B was reading a test (loading)" | app ended during load; **no crash diagnostic** for any of them; no daily report yet covers 12–13 Oct, so forced quit vs. iOS termination is undetermined |
| 13 Oct 02:33 | Temporary files: removed 2.09 GB (1 item) | cleanup |
| 13 Oct 02:36 | Qwen3 4B downloaded again | download |
| 13 Oct 02:37–02:39 | MetricKit **CPU** report (90 s in 124 s), same compiler stacks | resource report |
| 9 Oct 19:44, 12 Oct 18:59 | Gemma 4 E2B Basic/Hard: "GPU buffer allocation failed: per-token input 'ple_table' (9,620,726,743,040 bytes)" | deterministic **load failure** |
| 9 Oct 09:45–09:46 | Core AI Qwen3 4B Hard 39 %, Basic 0 %, **~30 s each** | completed runs (model was already prepared) |

Historical (older builds, not re-analysed): Pass 33–35 MPSGraph specializer aborts (`MTLReportFailure`), 9 Oct Gemma "closed" record, 7 Oct memory-pressure background exits.

No Qwen3 4B crash report exists for the latest build. The latest incidents are **long on-device preparation** (ANE/Core AI compile) that never completed because the app was closed each time, plus repeated preparation after downloads and a 36.8 GB temporary-file removal.

## 2. Core AI preparation — measured facts (Mac, Core AI 3600.83, macOS 27 SDK)

Probe: `scratchpad/probe/probe.swift` (not committed) calling the public API.

- `AIModel.specialize(contentsOf:options:cache:cachePolicy:)` exists; `AIModelCache.default.model(for:options:)` reports a prepared copy **without** preparing (cache miss → false, after → true; a new process sees it: second run 0.005–0.011 s).
- **Cancelling the Swift task does not stop it**: cancelled at 0.3 s, LFM2.5 1.2B preparation ran to the end (8.5 s) and was stored.
- The language engines prepare through `PreparedModel.prepare(at:)` (coreai-models `EngineFactory`, `CoreAIStaticShapeEngine`, `CoreAISequentialEngine`), with options from the graph names (static `extend_*`+`load_embeddings` → Neural Engine; otherwise GPU + `expectFrequentReshapes`). Preparing with identical options makes the engine's own load a cache hit.
- Cache policy `.default` has purge conditions (`storagePressure`, `sourceAssetChangedOrDeleted`); `.persistent` exists.
- On the Mac the prepared entries are **not** in files the process creates by name: `~/Library/Caches/coreai-cache` received only `sync/<build>/<hash>.lock` and an empty `tmp/`; nothing else under `~/Library` or the user temp/cache dirs changed. So file names cannot establish which prepared copy belongs to which model; Core AI's own API can (`deleteEntries(for:)`).
- `AIModel.deviceArchitectureName` gives the chip name ("h13s" on this Mac; expected "h17p" on iPhone 16 Pro — phone unverified).
- A compiled copy's `metadata.json` `sourceHash` equals the source graph's `main.hash` (SHA-256 of `main.mlirb`): checked by compiling Qwen3 0.6B for h17p (`9752CAF7…` both). The h17p Qwen3 4B copy built in Pass 35 records `sourceHash 882606B7…`.

## 3. Gemma 4 E2B

CoreAIKit 0.7.3 source: Gemma 4 is a decoder bundle **plus** a separate PLE tables bundle (`GemmaModelID`, `ios-frontend/gemma4_qat_gather_raw`) loaded by `GemmaRuntime`; "a chat entry whose bundle needs the Gemma load path — static PLE inputs — can't ride the stock ModelRuntime". Its iOS decoder is AOT for h18p only; the plain bundle "crash[es] the on-device GPU specializer". PodSkipper loaded the decoder alone through the generic engine, so `ple_table` had no size. No supported path on iPhone 16 Pro → marked unsupported with that reason (not a PodSkipper-fixable bug in this pass).

## 4. Model-test records

- Recovery after a closure only added a record when the model had **no** result for that sample (`where result(engine, sample) == nil`), so a new closure was hidden behind any earlier result (confirmed in code at 4075f0e: `ModelBench.init` and `recordClosed`).
- Stops left no record at all (`catch is CancellationError` was silent).
- Records carried no app build or stage.

## 5. Storage

- Pass 35 classified any tmp/Caches name containing `coreai`, `mpsgraph`, `mlir`, `e5rt`… as "Model preparation leftovers" and made it **safe by kind** (in Tidy Up). That included Core AI's own `coreai-cache` store and compiler files whose owner and reuse are unknown. The 36.8 GB removal has no item list, so whether it removed Qwen3 4B's prepared copy is **not provable**; the timeline (prepared on 9 Oct → re-preparation on 12 Oct after the removal and re-download) is consistent with it.
- Core AI deletion removed the **whole repository folder** (all revisions/builds) when no other catalog entry shared it, and cleared the whole E5 compiled cache when no Core AI model remained.
- Models and Caches "Delete" waited at most 10 s (40 × 250 ms) for the owners, then measured whatever was there.
- Exports: background events kept 150 entries (≈2 days here), playback 300, timings 200 — a 7-day export was silently partial for those parts.

## 6. Changes (Pass 36 batch A)

See catalog rows X36-01…X36-09 and the commit. Verification is in §7.

## 7. Verification

- Unit (iPhone 16 Pro simulator 4DB432A8; the PS-Unit simulator no longer exists): Pass36Tests 7/7, ModelBenchTests 11/11 (one test renamed: a stop after work began now records `stopped`), Pass35Tests 13/13 (Tidy Up expectation updated: compiler-named files no longer included), DiagnosticsLogTests 14/14 (cap test updated to the new limits).
- Full suite before the export changes: 364 run, 1 skipped, 1 failing test (the old 150-entry cap assertion, since updated and passing). The earlier environmental `ChapterPlaybackTests` audio failure did not occur in this run. One later run hung before the test runner connected (simulator); the retry passed.
- Device Release `iphoneos` build (unsigned): **BUILD SUCCEEDED** (the Core AI preparation code is device-only and compiles only there).
- Not verified anywhere: preparation, Stop-during-preparation, the prepared-state readout, Gemma's unsupported row, deletion of prepared entries, compiled-copy source matching — all need the phone.

## 8. His 13 Oct phone on 0aea7c6 (Diagnostics `…1791873094`) and corrections

- He installed the Mac-compiled h17p copy (06:13:04, accepted: chip and source matched); 27 s later PodSkipper's new preparation step started on it and was still running at Stop (06:26) and when he closed the app (closure recorded 15:51 after start). Stop showed "Stopping…" until he closed the app (the Pass 36 batch-A design waited for the native work).
- **Measured on the Mac (Core AI 3600.83, `ANECompilerService`, Qwen3 0.6B iPhone static bundle, empty cache):** engine-style load `AIModel(contentsOf:)` = **1,995 s**; `coreai-build compile … --preferred-compute neural-engine --architecture h13s` = 1,546 s; loading that compiled `.aimodelc` = 1,645 s in a run that overlapped a stopped one; **clean re-run 270 s**. So an AOT copy cuts the on-device Neural Engine work about 7× but doesn't remove it (publisher: ≈194 s cold on iPhone 17 Pro). His phone was still preparing with the h17p copy after 16 min — far beyond that; cause unknown until the next MetricKit report (a version mismatch between the Mac's coreai-build 3600.83.1 / Metal 27.1 and iOS 27.0.1 making Core AI recompile from the IR is one hypothesis, unproven). Publisher's card for this model: iPhone 17 Pro AOT "cold spec ≈194 s".
- His own history agrees: Qwen3 0.6B's first run on 7 Oct took 706 s, the next 47 s; Qwen3 4B ran in 30–83 s on 5–9 Oct because a preparation from early October was cached. The default cache policy purges on "source asset changed or deleted": his 12 Oct delete + re-download removed it.
- **Wrong in batch A:** (1) the advice that a Mac-compiled copy avoids on-phone preparation — it only shortens it (Mac: 33 → 4.5 min), and on his phone it didn't complete in 16 min; (2) the pinned "Test in Progress" section — he asked for the running test to stay visible in its Core AI section (and its own row) when another model becomes chosen, not for a new section.
- **Corrections (batch B):** Qwen3 4B and 0.6B use the publisher's GPU build (`macos/`, same revision; 10.9 s preparation for 4B on the Mac; same family of build as LFM2.5/Granite/MiniCPM5 that his phone runs). Stop during preparation now ends the test at once; the native work keeps the heavy-work slot by itself until it ends (`HeavyWorkCoordinator.transfer`), shown in the Core AI section with "Close PodSkipper Now" as the only immediate end. Compare page reverted to its pre-Pass-36 layout; the running test also shows in its engine section when another model becomes chosen. The visible "Install a Copy Compiled on a Mac…" button is removed (context menu kept).
