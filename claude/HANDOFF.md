# PodSkipper — Handoff (Pass 36, 13 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) — the **Pass 36 overlay** (X36-01…11) at its top, then Pass 35 and older overlays and the base rows — and [Pass 36 evidence](evidence/2026-10-13-pass36-coreai-loading.md) (Pass 35's is [here](evidence/2026-10-09-pass35-storage-coreai.md)). Then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) and [Implementation Plan](../IMPLEMENTATION-PLAN.md).

## 1. Where the code is

- **`main` is canonical** in `~/Developer/podskipper`. `~/Developer/pk-app` (77b904d, detached) untouched. `~/Developer/pk-sym` is **his own folder of old IPAs — not a worktree; leave it**.
- `stash@{0}` (catalogue transaction WIP) untouched; tag `archive/backup-catalogue-stash-2026-10-02`.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>`. `gh` not installed.
- **Simulator: the PS-Unit simulator no longer exists.** Use iPhone 16 Pro `4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`. Unit: `./Scripts/unit-test.sh 4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`; one class: `xcodebuild test-without-building … -only-testing:PodSkipperTests/<Class>` after `build-for-testing` (and `./Scripts/generate-project.sh --simulator` when files were added). UI: `./Scripts/uitest.sh <Test[,Test]> <tag> <simulator>`.
- Device compile: `./Scripts/device-build.sh` (unsigned Release iphoneos). Core AI code (`CoreAIPreparation`, `CoreAIAdJudge`, library) compiles **only** there.
- Symbolication: device symbols for iOS 27.0.1 are in `~/Library/Developer/Xcode/iOS DeviceSupport/iPhone17,1 27.0.1 (24A446)/arm64e/Symbols` (`atos -arch arm64e -l <__TEXT vmaddr>`); app frames: rebuild the exact commit with `Scripts/device-build.sh` in a temporary worktree, `atos -arch arm64 -l 0x100000000`.
- **Compiled Core AI copy** for his iPhone 16 Pro: `build/coreai-aot/qwen3_4b_mixed_4bit_8bit_static.h17p.aimodelc` (2.5 GB, git-ignored; `sourceHash 882606B7…`). Now installed from a visible button under the Qwen3 4B row in Models and Caches; PodSkipper refuses it unless it was compiled from exactly the downloaded graph and for this chip.

## 2. Pass 36 (on top of 4075f0e)

Batch A — Core AI loading/Stop, model-test records, model storage safety: see catalog X36-01…10 and the commit after 4075f0e.

## 3. Findings to keep

Proven/measured: Qwen3 4B's latest "Loading 0 %" incidents are Core AI's on-phone preparation (ANE/Core AI compiler CPU and 4.3 GB disk-write reports; no crash report); `AIModel.specialize` ignores task cancellation and finishes (Mac); `AIModelCache.model(for:options:)` reads prepared state without work; prepared entries aren't attributable by file name (Mac); compiled `sourceHash` = source `main.hash`; Gemma 4 E2B needs a separate PLE tables bundle + h18p-only AOT (CoreAIKit source) — unsupported here; old recovery hid new failures behind old results; stops left no record; storage exports were silently truncated by log caps.

Hypotheses (unproven): the 36.8 GB "temporary files" removal on 12 Oct removed Qwen3 4B's prepared copy (no item list was kept then — there is now); the five "closed while loading" launches were forced quits (no crash or daily report yet); iOS accepts the h17p AOT copy; on-phone preparation of Qwen3 4B completes when left alone (it did once before 9 Oct 09:45).

## 4. Verification

See evidence §7 and the delivery message. Focused unit classes pass (Pass36 7, ModelBench 11, Pass35 13); device Release build passes. **No phone verification of anything in Pass 36.**

## 5. Next steps

1. His phone on the Pass 36 IPA — the short checklist in the delivery message (Qwen3 4B one test left to finish preparing; Stop during preparation; second test reuses it; Gemma row; delete one Core AI model and read the result; Temporary Files text; optional compiled-copy install).
2. Pass 35 continuation (X36-11), in plan order: record-level Diagnostics/Results selection; record-level backup/restore; iCloud cross-device (needs his iPad); widgets/CarPlay against installed entitlements; Apple Podcasts parity pass; then Batches 3–6.
3. If he wants in-app delivery of the compiled Qwen3 4B copy: decide where it may be hosted (publishing decision; Apache-2.0 permits redistribution with notice).
