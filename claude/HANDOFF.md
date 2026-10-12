# PodSkipper — Handoff (Pass 35, 12 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) — the **Pass 35 overlay** (X35-01…22) at its top, then older overlays and the base rows — and [Pass 35 evidence](evidence/2026-10-09-pass35-storage-coreai.md). Then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) (Pass 35 decisions paragraph) and [Implementation Plan](../IMPLEMENTATION-PLAN.md).

## 1. Where the code is

- **`main` is canonical** in `~/Developer/podskipper`. `~/Developer/pk-app` (77b904d, detached) untouched. `~/Developer/pk-sym` is **his own folder of old IPAs — not a worktree; leave it**.
- `stash@{0}` (catalogue transaction WIP) untouched; tag `archive/backup-catalogue-stash-2026-10-02`.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>`. `gh` not installed.
- Simulator PS-Unit F51033BC-3FEA-4D44-BF85-06F492C6933F. Unit: `./Scripts/unit-test.sh <id>`; one class: `xcodebuild test … -scheme PodSkipperTests -only-testing:PodSkipperTests/<Class>` (after `./Scripts/generate-project.sh --simulator` when files were added). UI: `./Scripts/uitest.sh <Test[,Test]> <tag> PS-Unit` → `build/shots-<tag>/named`.
- Symbolication: device symbols for iOS 27.0.1 are in `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 27.0.1 (24A446)/arm64e/Symbols` (Apple frames: `atos -arch arm64e -l <__TEXT vmaddr>`). App frames: rebuild the exact commit in a temporary worktree with `Scripts/device-build.sh` (point `-clonedSourcePackagesDirPath` at this checkout's `build/DerivedData/SourcePackages`), then `atos -arch arm64 -l 0x100000000`.
- **Compiled Core AI copy** for his iPhone 16 Pro: `build/coreai-aot/qwen3_4b_mixed_4bit_8bit_static.h17p.aimodelc` (2.5 GB, git-ignored; recipe in evidence §4). He moves it to the phone himself (AirDrop/Files); Models and Caches → Qwen3 4B row → *Install Compiled Copy…* takes the folder.

## 2. Pass 35 commits (on top of 36410ed)

13c14e7 storage safety + Core AI + confirmations + Settings regroup · a8d6243 editor crash/Undo/Library editor · 48e4bc7 backup store location · 3d4e4dd granular Backup & Restore + WAL fix · 7d88ba2 / 7691680 Diagnostics centre · ef2ef6b iCloud records sync · then the docs commit. See the catalog rows for what each covers.

## 3. Findings to keep

Proven: MLX models deleted by the old inventory (flat names vs owner/repo); Core AI abort is MPSGraph's on-device specializer (`MTLReportFailure`), identical before/after Pass 34, bundle published as uncompiled IR, AOT compile needs ~12 GB; editor crash = feed duration < audio length; backups read/restored the wrong store folder on App Group installs; WAL backup copies failed iOS read-only validation; Feather renames the App Group (store in group container; widgets looked for the original name); toolbar `EditButton` drives the stack's edit mode; bottom-bar toolbars sit under the app's tab bar (use `SelectionActionBar`); a `Group`'s modifiers apply to every row (host page-level presentations with `.confirmationHost()` / `askConfirmation`).

Hypotheses: 28.88 GB tmp = compile scratch from killed compiles and/or partial background downloads (the new Temporary Files page will show); SQLite 4618 = no free space; iOS loads the h17p AOT copy; Library stutter cause (reasoned, not measured).

## 4. Verification

See evidence §7 and §9. Summary: full unit suite 357 (1 environmental audio failure, 1 skipped); new focused unit classes all pass; five UI flows pass in PS-Unit; device Release build passes. `testPassNineteen` fixed (7e29a25: starts the queue first) and passes. Pushed 6c2b7e4 on 12 Oct; CI run 38219110418. **No phone verification of anything in Pass 35.**

## 5. Next steps

1. His phone on the Pass 35 IPA (checks listed in the delivery message / evidence): Models and Caches lists all models (re-download the MLX models the old bug deleted); Temporary Files breakdown (cause of 28.88 GB); install the compiled Qwen3 4B copy, one Basic + Hard; editor near the end of a long episode (handles, transcript, Play to end mark, Undo, Meet next); Library Edit + no overlap/stutter; make a new backup (old ones may lack the live library), restore inventory; Diagnostics pages; iCloud page status on iPhone and iPad (does "Last received" ever change?); widgets status line.
2. Not started: Apple Podcasts parity pass (use his screen recording + the app); CloudKit whole-library sync (only if his signed capabilities show an iCloud container).
3. Base plan batches continue (catalogue stash repair, parity, publishing acceptance).
