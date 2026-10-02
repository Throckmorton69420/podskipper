# Podskipper implementation handoff

## Current workspace and baseline

- Worktree: `/Users/shashankpandya/Developer/podskipper-recovery`
- Branch: `codex/complete-project-recovery`
- Baseline: PR 21, `2415eb399481f201cdb046d82f31b1071480842d`; CI build succeeded. PR remains open.
- Original Developer and Documents checkouts and installed phone app are preserved.
- Xcode 27.0 (27A266a); primary simulator iPhone 16 Pro `4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`.
- Paired physical iPhone 16 Pro is available; installed PodSkipper has re-signed identity `app.ivory2951.coral5096`. Its build revision and container/debug access are not yet verified. Never replace its data or install from Xcode for convenience.
- Synced project files under `sources/` are read-only reference material.

## Execution order

1. Reproducible repaired baseline and current request catalog.
2. Current model navigation/typography and Speed & Audio geometry regressions.
3. Persisted processing state, cancellation, shared heavy-work ownership, background recovery and heat.
4. Trustworthy model histories/policy and evidence-first detection quality.
5. Full navigation/parity/player/audio/video acceptance and remaining features.
6. Disposable-data migration/backup/publishing recovery and supported capability checks.

`REQUEST-CATALOG.md` contains individual acceptance criteria. `IMPLEMENTATION-PLAN.md` retains B1–B195 historical details. Latest user feedback wins over either document's older status.

## Completed checkpoints

- `0b94452`: preserved PR 21 baseline; canonical whole-project catalog; simulator build excludes Apple's device-only Core AI runtime without changing the device build.
- `01ce71a`: shared Compare models page, inline Core AI picker with observed selection, scrolling headings, medium/large native audio sheet, equal chart geometry and readable legends, accessibility size support in shared typography, benchmark model/run/policy identity and cancellation cleanup, hosted unit-test target and CI regression gate.
- Simulator UI evidence: `testCoreAIModelDisclosure` passed (48.8 s), `testSoundSheetDetents` passed (47.0 s); inspected collapsed/expanded/comparison and both sheet detents plus landscape controls. `testSettingsAndSound` earlier passed (95.1 s). Screenshots under `build/shots-recovery-coreai-observed`, `build/shots-recovery-sheet-native`, `build/shots-recovery-sound`.
- Processing checkpoint: durable versioned job records with compatibility projections; sticky stops, distinct pause/interruption/failure, retry delays, exact model capture, queue-task joining and interrupted-head ordering. Shared heavy-work leases outlive cancelled audio/model cleanup; preparation fetches bytes only. Activity shows saved failure/interruption reasons. No fake background progress; iOS 27 asynchronous submission records refusals.
- 33 unit tests passed, including five pipeline integration tests and seven copied-data migration tests, in `build/unit-20261002-002015.xcresult` (confirm actual bundle name from log before reporting).
- All 17 shipped-Reader fixtures completed using copied caches and bundled weights; 16 fail strict acceptance. No detection changes or claims that targets are met; this is an in-sample baseline, not held-out validation. See `evidence/2026-10-02-reader-regression.md`.
- No new device build, physical-phone behavior, full UI tour, accessibility-size screenshots, PR push, or merge yet. The installed app remains untouched.

## In progress and next action

Build the actual device target and run the broader navigation tour, Reader comparison UI test, and accessibility-size/contrast screenshots. Complete the Core AI enabled-model controls. Review/push a complete batch and check CI on its exact revision. Data audit found restore rollback can leave newly installed files mixed with originals, removes its retry marker too early, and silently ignores checkpoint/default restoration errors; fix and test on disposable data before marking backup safe. Remaining detection quality, parity/player/video, import/publishing and phone acceptance stay active. Do not call the product complete after this batch.

## Verification rules

Builds prove compilation; screenshots inspected after exercising behavior prove simulator appearance; fixture measurements prove lab behavior; current phone checks prove phone behavior. Record exact revisions. Local atomic commits, consolidated complete PRs/pushes, no broken or incomplete merges. Preserve rollback and signing identity. No silent processing audio.
