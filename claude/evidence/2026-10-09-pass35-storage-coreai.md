# Pass 35 evidence — storage safety, Core AI root cause, settings (9–10 Oct 2026)

Inputs: his Pass 35 request; Diagnostics `PodSkipper-diagnostics-1791594124.json` (build 36410ed, iPhone17,1, iOS 27.0.1, exported 2026-10-10T01:02Z); three screenshots (Clear Downloads popover, Downloads and Transcripts, Models and Caches); a screen recording (not opened here).

## 1. Model deletion ("Remove Unused Copies" took his MLX models)

**Cause (proven in code and reproduced in a unit test):** MLX models are stored at `Application Support/Models/<owner>/<repo>` (`ModelStore.folder(for:)` appends the spec id, which contains a slash). Pass 33's `ModelStorage.measure` listed only the top-level folders (`mlx-community`, `ALTICDEV`, `prism-ml`) and compared them with full ids. Nothing ever matched, so every MLX model was filed under "Models no longer offered" (his 6.5 GB) and the MLX list showed nothing (his screenshot: only Core AI Qwen3 4B). "Remove Unused Copies" then deleted them. Not caused by catalog changes or by which model was selected.

**Fix:** `Services/ModelStorage.swift` rewritten. A model is found by its contents (`config.json` / `.download.json` for MLX at depth ≤ 2; `metadata.json` for Core AI); catalog matching only labels it (installed / incomplete / other version / not in list). No bulk "unused" removal of anything holding a model; each model has its own Delete (catalogued complete models go through `ModelStore.delete` / `CoreAIModelLibrary.delete`, which keep the chosen-model and in-use rules). Loose files are separate items, never their owner folder. Removal is confined to the named roots through symlinks and `..`.

## 2. 28.88 GB "Temporary files"

**Not determinable from the export** (the old screen only summed `tmp/`). App-owned writers to `tmp/` (backup staging, exports, clips) cannot plausibly reach that size. Candidates consistent with the evidence: Core AI/Metal compile scratch left when the app was killed mid-compile (every Qwen3 4B crash is in the compiler, §4), and partly received background downloads of multi-GB model files. **Hypothesis, not proven.**

**Built:** per-entry inventory of `tmp/` and `Caches/` (`ModelStorage.scratch`), classified by name into compiled model copies, model-preparation leftovers, interrupted downloads, backup work files, files made for sharing, clips, system caches, demo, and *not identified*. Anything written in the last 15 minutes, or belonging to work under way, is marked in use and never removed. Unknown entries are never in Tidy Up; they can be removed individually with a warning. The phone's next visit to Models and Caches → Temporary Files will show what the 28.88 GB actually is.

## 3. Library failed to open (NSSQLiteErrorDomain 4618)

At 2026-10-09T22:12:35Z: `default.store` in the **App Group container** (`/Containers/Shared/AppGroup/59807BA5…/Library/Application Support/default.store`), app inactive, protected data available. 4618 = `SQLITE_IOERR_SHMOPEN`: SQLite couldn't open/create `default.store-shm`. Context: 339 MB free on his screenshot; "Models and Caches: Freed 9 GB" logged 51 s later. **Consistent with no free space; not proven** (file protection and another process are the other documented causes; protected data was available). The next launch opened normally (single-owner open from Pass 33 retained; nothing replaced or recreated). The export's `libraryRecovery` list was empty although the background log recorded the failure: the old "Delete Older Logs" removed `library-recovery.json` with the other files; it is now its own category in Log Files.

**Built:** the report names the SQLite code in words (`LibraryStore.sqliteMeaning`); `StorageGuard` (2 GB "low", refuses work that would leave < 1 GB) before Core AI downloads (size × 2), Core AI model loads (bundle size), MLX downloads (now the same 1 GB margin) and compiled-copy installs; Storage screens warn when the phone is nearly full.

## 4. Core AI Qwen3 4B — root cause

- MetricKit `diagnostic-1791577471` (2026-10-09 20:24:31Z, after Pass 34's 8-token steps) has a **byte-identical** stack to `diagnostic-1791506927/68` (Pass 33 build): `abort ← libsystem_c ← Metal 0x1b2a80 ← MPSGraph 0x3bd5bc … ← CoreAIDelegates ← CoreAIRuntime ← PodSkipper`.
- Symbolicated against the iOS 27.0.1 (24A446) device symbols on this Mac (`~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 27.0.1 (24A446)`, `atos -arch arm64e`, load address = `__TEXT` vmaddr):
  - `Metal 0x1e68c0` = `MTLGetEnvCase… (.cold.1)`; `Metal 0x1b2a80` = **`MTLReportFailure`**
  - `MPSGraph 0x3bd5bc` = **`-[MPSGraphExecutable specializedModuleWithDevice:shapedEntryPoints:compilationDescriptor:error:]`**
  - `MPSGraph 0x3d95fc` = `-[MPSGraphExecutable applyEntryPointToSymbolAndFileNameMap:device:compilationDescriptor:]`
  - `MPSGraph 0x4064f0 / 0x403b40` = `MPSGraphDelegate.resolveCoreAI(context:)`
- So the abort is in **on-device compilation (specialization)** of a graph entry point, not in inference. That explains: intermittent (once compiled and cached, later runs skip it), why the prompt-width change did nothing (it only changed which entry point was compiled), and why long prompts trigger it (the bundle has `extend_{1024,2048,4096}_{8,16,64}` entry points; ~1,950-token prompts cross into the 2048 family).
- The published iPhone bundle (`mlboydaisuke/qwen3-4b-CoreAI-official@e40878f…/ios`) is **uncompiled IR** (`qwen3_4b_mixed_4bit_8bit_static.aimodel/main.mlirb`, 2,486,265,426 bytes, `compilation.targets: []`). Its model card: "iOS static bundles must be AOT-compiled before device use" (published AOT only for h18p = iPhone 17 Pro).
- **Compiled here for h17p** (iPhone 16 Pro): `xcrun coreai-build compile … --platform iOS --preferred-compute neural-engine --architecture h17p` (Metal toolchain 27.1, coreai-build-3600.83.1): **1,019 s, peak memory footprint 11.99 GB, max RSS 18.1 GB**. Output `build/coreai-aot/qwen3_4b_mixed_4bit_8bit_static.h17p.aimodelc` (2.5 GB; `resources.bin` 2,070,318,588 bytes = 1.93 GiB, under the 2.03 GiB CoreAIKit records as loading on iOS; ANE regions for h17p present). The phone (8 GB RAM) is being asked to do the same compile on-device.
- Upstream corroboration (CoreAIKit source): Whisper's iOS bundle is AOT because "the on-device JIT compiler aborts on the 1.6 GB graph"; Gemma 4 E2B's plain ~2 GB bundle "crash[es] the on-device GPU specializer"; `ChatSession.prewarm` warns an aborted static-shape compile can poison the on-device cache.

**Attribution:** PodSkipper — loads the publisher's uncompiled iPhone bundle as is (Pass 34's 8-token steps did not address the cause). Model bundle — published without an AOT build for this chip. Apple runtime — the on-device specializer aborts the process (`MTLReportFailure`) instead of returning an error; PodSkipper can't catch it. Not a PodSkipper memory leak or prompt bug.

**Built:** `CoreAICompiledCopy` installs a compiled `<name>.<chip>.aimodelc` into the downloaded bundle (validates chip vs device and model stem; staged copy then move; original metadata kept as `metadata.portable.json`; removal restores it byte for byte); UI in Models and Caches → Core AI row menu → Install Compiled Copy… / Remove Compiled Copy. With a compiled copy the reader uses the engine's native prompt widths; without, 8-token steps remain (fewer entry points compiled). Engine name in Diagnostics says "compiled for this iPhone" or "compiled on this iPhone when first used". Crash note at launch states this cause.

**Remaining phone check:** copy `build/coreai-aot/qwen3_4b_mixed_4bit_8bit_static.h17p.aimodelc` to the iPhone (Files), install it on Qwen3 4B, run Basic + Hard once. Not verified that iOS loads this AOT bundle (unknown until the phone runs it); if it fails to load, Remove Compiled Copy restores the download.

## 5. Popovers

Two causes, both in code: (a) the Core AI "closed PodSkipper before" dialog was attached to a zero-height `Color.clear` row at the bottom of the model list — iOS 27 anchors confirmation dialogs to their view, and List rows are lazy, so it appeared off screen (or not at all) until scrolled to; (b) other dialogs were attached to whole lists/pages or full-width rows (Clear Downloads). All 13 `confirmationDialog`s are now centred alerts owned by an always-mounted list (`Confirmation` + `.confirmation(_:)`); the test request clears before running, and the bench refuses a second test while one runs.

## 6. Widgets

The library being in an App Group container proves the signed app has an App Group, but Feather renamed it with the bundle id (`app.ivory2951.coral5096`). `WidgetSnapshot` only looked for `group.com.yourname.podskipper`, hence "needs an App Group". Now it uses the group the app/extension were actually signed with (`SignedEntitlements.appGroups`, moved to `Shared/`). The new status row compares the extension's signed groups with the app's. **Phone check:** the iCloud, Widgets & CarPlay page states whether they match; add a widget.

## 7. Verification

- Unit: `Pass35Tests` 10/10 (nested MLX models installed not unused; unlisted/incomplete labelled; Core AI versions told apart; removal refuses roots, outside paths, symlink escape and `..`; scratch classification and in-use protection; work-under-way protection; StorageGuard; SQLite 4618 text; compiled copy install/remove round trip; refusal of wrong chip/model/no room/not compiled).
- Builds: simulator Debug and device Release iphoneos succeed.
- UI: `testPass35StorageManagement` (see handoff for the latest result).
