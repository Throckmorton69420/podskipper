# Podskipper implementation handoff

## Current workspace and baseline

- Worktree: `/Users/shashankpandya/Developer/podskipper-recovery`
- Branch: `codex/complete-project-recovery`
- Baseline: PR 21, `2415eb399481f201cdb046d82f31b1071480842d`; CI build succeeded. PR remains open.
- Original Developer and Documents checkouts and installed phone app are preserved.
- Xcode 27.0 (27A266a); primary simulator iPhone 16 Pro `4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`.
- Paired physical iPhone 16 Pro is available; installed PodSkipper has re-signed identity `app.ivory2951.coral5096`. Read-only devicectl now confirms container access and 5 re-signed app groups; copied timing records identify installed f8a7c4a. Exact signature/debug access remain unverified. Never replace its data or install from Xcode for convenience.
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
- `693be6c`: independent generated device project; unsigned Release device build passed at that revision. Artifact: `build/DeviceDerivedData/Build/Products/Release-iphoneos/PodSkipper.app`, BuildInfo commit matches. No installation or phone changes.
- Serial top-level/show/player UI tour passed: `build/TR-recovery-full-serial.xcresult`; all 25 screenshots inspected. Category/shelf/people/episode destinations and countdown acceptance still need focused tests. Screens exposed blank video failure UI and mini-player underlap to address.
- Backup restore checkpoint: 43 tests passed in `build/unit-20261002-005713.xcresult`, including 10 journal/round-trip/corruption/retention tests. See `evidence/2026-10-02-backup-restore.md`. No live data operations.
- `37430af`, `d95b821`, `6b2d987`: enabled-model/sample snapshots, validated structural/fingerprint evidence and durable publishing, chapter editing and guarded exact-position playback/accessibility. 106 unit tests passed (`build/unit-20261002-043652.xcresult`). Chapter 8-screen add/edit/error/exact45 s episode/delete tour passed 116.199 s and all screenshots inspected (`build/TR-recovery-chapters-modal.xcresult`). Accessibility model/sound test passed 88.866 s/all 4 images inspected; original simulator accessibility preferences restored.
- Latest failure-video test passed 29.906 s/all 2 images inspected (`build/TR-recovery-video-error-final.xcresult`). Normal video test passed presence/navigation assertions but all images were black; that is NOT frame rendering verification. Validated decoded video at `2073fde` now supersedes it; see the current checkpoint below.
- Current-policy cached Reader regression: all 17 fixtures complete,16 strict failures remain; program-cut rates worsen on several fixtures. No default change or quality-goal claim. Both historical/current tables are in the regression report.
- Read-only physical app diagnostics copied to `build/phone-diagnostics-20261002`. Current f8a7c4a timings include3 serious thermal outcomes; MetricKit CPU/write/hang/memory baseline documented. The new branch has not been installed or phone-tested.
- New PR push/merge remain unperformed. Installed app/data/signing identity remain untouched.

## In progress and next action

Latest source checkpoint: `3540ce5`, on unchanged branch `codex/complete-project-recovery`; a documentation checkpoint follows. Preserve `6394f68` (history), `2f841ea` (cleanup/diagnostics), `2073fde` (rendered video/exact launch routing), `8a80623` (serialized reply checkpoints/projection writes), `28d5811` (Station grouping/manual order), and `3540ce5` (exact PR-head CI/main-only latest release). No agent source drafts remain to integrate. Root continues solo at the user's requested Extra High; do not restart analysis or repeat verified work. High is sufficient for the upcoming bounded package/CI phase; recommended as optional, without pausing work.

Final combined source passed 195 units, zero failures, in `build/unit-20261002-164453.xcresult` (console copied to matching `.log`), plus the disposable Python history-export regression. Earlier 163/195 checkpoints remain preserved. Actual decoded-video tour passed in `build/TR-recovery-video-ready-route.xcresult`; all nine images were inspected and show decoded clocks, synchronization, pause, mode switching and fullscreen/dismissal. It supersedes the earlier rejected black-frame presence test.

Station full native reorder/Cancel/Save/reopen/grouping/exact Play All sequence passed in 91.454 seconds (`build/TR-recovery-station-held-reorder.xcresult`); five portrait images accepted, clipped app-window landscape image rejected. Focused whole-display grouping/portrait/landscape test passed in 35.521 seconds (`build/TR-recovery-station-display-ready.xcresult`); all four inspected. Landscape controls are reachable, but native mini-player glass still obscures some row content while scrolling. U08/shared scroll-edge contrast and Station accessibility remain open.

Next: unsigned device Release compile including real Core AI, package unsigned IPA with exact commit/SHA, draft PR against main, attach it and inspect CI on its exact pushed head. Preserve rollback `693be6c` app clone in `build/rollback-693be6c/PodSkipper.app`. No install or merge. See `evidence/2026-10-02-data-stations-checkpoints.md` for migrations/cache tests and partial UI evidence.

Optional signed-IPA path question remains pending for capability inspection. Other implementation continues independently. Detection quality (16 strict fixture failures), full destination/editorial parity, shared glass/scroll contrast, controlled phone heat/memory/background/routes, real backup/publishing/import integrations, and the VideoAudio temporary-file cleanup race remain open. New source has not been installed or phone-tested. Synced project attachment remains read-only. Do not call the product complete after this batch.

## Verification rules

Builds prove compilation; screenshots inspected after exercising behavior prove simulator appearance; fixture measurements prove lab behavior; current phone checks prove phone behavior. Record exact revisions. Local atomic commits, consolidated complete PRs/pushes, no broken or incomplete merges. Preserve rollback and signing identity. No silent processing audio.
