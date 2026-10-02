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
- 19 baseline/benchmark/resource tests passed; 6 new persisted-job tests also passed on copied temporary data, for 25 total in `build/unit-20261001-235324.xcresult`. The new job store is not yet connected to pipeline clients or committed.
- No new device build, physical-phone behavior, full UI tour, accessibility-size screenshots, PR push, or detection regression claim yet. No merge or phone installation.

## In progress and next action

Uncommitted: pipeline shared resource leases, sticky stops, light download-only preparation, Activity pause/wait presentation, and `ProcessingJobStore` with migration tests. Connect pipeline queue/pause/stop/progress and selected engines to job-store projections, validate cancellation and relaunch integration, then build the actual device target. After that inspect accessibility screenshots and the full navigation tour, review the complete batch, push/attach a PR and check CI on its exact revision. The remaining detection, parity/player/video, backup/import/publishing and device acceptance catalog stays active; do not call the product complete after this batch.

## Verification rules

Builds prove compilation; screenshots inspected after exercising behavior prove simulator appearance; fixture measurements prove lab behavior; current phone checks prove phone behavior. Record exact revisions. Local atomic commits, consolidated complete PRs/pushes, no broken or incomplete merges. Preserve rollback and signing identity. No silent processing audio.
