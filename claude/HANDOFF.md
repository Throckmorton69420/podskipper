# PodSkipper — Handoff (Pass 35, 10 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) — the **Pass 35 overlay** (X35-01…14) at its top, then Pass 34/33 and older overlays, then the 178 base rows — and [Pass 35 evidence](evidence/2026-10-09-pass35-storage-coreai.md). Then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) and [Implementation Plan](../IMPLEMENTATION-PLAN.md).

## 1. Where the code is

- **`main` is canonical.** Work in `~/Developer/podskipper`. `~/Developer/pk-app` is a second worktree (77b904d, detached), untouched.
- `stash@{0}` (catalogue transaction WIP) untouched; tag `archive/backup-catalogue-stash-2026-10-02`. Do not pop it casually.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>`. `gh` is not installed.
- Simulator PS-Unit F51033BC-3FEA-4D44-BF85-06F492C6933F: `./Scripts/unit-test.sh <id>`; one class: `xcodebuild test … -scheme PodSkipperTests -only-testing:PodSkipperTests/Pass35Tests` (see the script for the rest); UI: `./Scripts/uitest.sh <Test> <tag> PS-Unit` (shots in `build/shots-<tag>/named`).
- Device symbols for his iOS 27.0.1 are on this Mac: `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 27.0.1 (24A446)/arm64e/Symbols/…`. Apple frames: `atos -arch arm64e -o <framework> -l <__TEXT vmaddr> <vmaddr+offset>` (vmaddr from `otool -arch arm64e -l`).
- **Compiled Core AI copy:** `build/coreai-aot/qwen3_4b_mixed_4bit_8bit_static.h17p.aimodelc` (2.5 GB, git-ignored). Recipe in the evidence file §4 (needs ~12 GB RAM, ~17 min). Not uploaded anywhere: he decides how to move it to the phone (AirDrop/Files); the app's Models and Caches → Qwen3 4B row → *Install Compiled Copy…* takes the folder.
- `AGENTS.md` (untracked, another tool's) left untouched.

## 2. Pass 35 batches

| Batch | Scope | State |
|---|---|---|
| 1 | Model inventory bug (MLX deleted), temp inventory, StorageGuard, SQLite 4618 text, Core AI root cause + compiled copy, confirmations → alerts | **Built and tested** (see §4) |
| 2 | Downloaded Episodes/Transcripts manager, Log Files, Tidy Up, Clear Downloads | **Built**; UI test `testPass35StorageManagement` |
| 3 | Settings IA (done: groups regrouped, Import & Export under Backup & Restore, Publishing group, Devices group); CSV share fixed (`FileResultRow`); **granular backup/restore/backup deletion: NOT STARTED** | partial |
| 4 | Diagnostics centre: overview, Device & Resources first, model tests structured (reuse Compare history), Episodes Processed page, Corrections detail, Audio Output chronology, iOS reports detail/share, granular Diagnostics/Results export, rename "Clear Timings" into data management, "Model largest part" → "MLX reading part size (after a crash)" | **NOT STARTED** |
| 5 | Sync: truthful status DONE (`DevicesSection`, `CloudSync.lastReceived`); widgets App Group resolution DONE; **CloudKit continuity for settings/corrections/bookmarks/stations/history NOT STARTED** (design: CKRecord per entity keyed by stable ids — guid, feedURL, correction ids — with modification dates and tombstones in a private database zone; SwiftData store untouched; KVS remains for shows/positions) | partial |

## 3. Findings to keep

Proven: X35-01 cause (flat names vs owner/repo ids). Core AI abort location (MPSGraph on-device specializer, `MTLReportFailure`), identical before/after Pass 34; Qwen3 4B iPhone bundle is uncompiled IR; AOT compile needs ~12 GB. The store is in an App Group container on his phone (so a group is granted; Feather renamed it). Tidy Up's "Import" title (shared alert state). Edit didn't work because toolbar `EditButton` drives the stack's edit mode. Bottom-bar toolbars are hidden under the app's tab bar — use `SelectionActionBar` (`.safeAreaBar`).

Hypotheses: 28.88 GB tmp = compile scratch from killed compiles and/or partial background downloads (inventory will tell); SQLite 4618 = no free space; that iOS loads the h17p AOT copy (unverified until the phone runs it).

## 4. Verification this pass

- Unit: `Pass35Tests` 10/10. Old Pass 33 storage tests retired (they encoded the bug). Full suite not re-run yet this pass — run `./Scripts/unit-test.sh` before delivery.
- Builds: simulator Debug ✓; device Release iphoneos ✓ (before the selection-bar/Devices/CSV edits — rebuild before delivery).
- UI: `testPass35StorageManagement` — long-press menu ✓, Select ✓ (selection count), action bar reachability (rerun pending at time of writing; check `build/test-p35-storage.log`).
- Not run: phone. No CI build triggered this pass yet.

## 5. Next steps

1. Finish Batch 1–2 checkpoint: commit (done if `git log` shows "Pass 35 batch 1–2").
2. Batch 3 granular backup: inventory of `BackupService` manifest/archive layout first (`Services/BackupService.swift`, `BackupRestoreTransaction.swift`); category selection needs dependency rules (episodes ↔ shows ↔ ad segments ↔ corrections).
3. Batch 4 diagnostics centre (`Views/DiagnosticsView.swift`, `Services/Diagnostics.swift` export).
4. Batch 5 CloudKit sync (needs the iCloud container entitlement in his signing: check `SignedEntitlements.present` on the phone via the Devices page first).
5. Consolidated delivery: full unit suite, device build, push, one CI IPA.

Phone checks for this checkpoint: Models and Caches lists all models (his deleted MLX models must be re-downloaded — they're gone); Temporary Files breakdown (photo it for the 28.88 GB cause); Install Compiled Copy on Qwen3 4B then Basic + Hard once; Downloaded Episodes select/long-press/remove; Tidy Up; Log Files open/share; the iCloud, Widgets & CarPlay page's three status lines; add a widget.
