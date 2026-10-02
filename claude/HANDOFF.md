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
- Draft PR 22 is pushed and attached; no merge or phone installation. Installed app/data/signing identity remain untouched.

## In progress and next action

Latest source/artifact: `24c03da0eae93dc0649edb4660c231d36aa677ed`, unchanged branch `codex/complete-project-recovery`. All 230 units pass in `build/unit-20261002-180321.xcresult` (matching console preserved). Actual Core AI unsigned device Release passes; verified IPA `build/delivery-24c03da/PodSkipper-24c03da-unsigned.ipa`, SHA-256 `524e792e0c9e553811fa75235ea9aebbd98485c1286ecb877ae24802ed79a780`. Earlier artifacts and rollback `build/rollback-693be6c/PodSkipper.app` remain preserved. See `evidence/2026-10-02-delivery.md`. No install or merge.

Draft PR 22 is attached: https://github.com/Throckmorton69420/podskipper/pull/22 . Latest pushed head `a25f301db6d90ebb50c6b54ab4ab5721210c646c` passes exact-head CI run `37068686265`, job/check `111042690208`: source/Python checks, 212 units, unsigned device build/verification/package/upload; latest-release skipped. IPA artifact `11254902462`, units `11254711408`. Its app source is `ead23f1`; local discovery and preview commits still require a consolidated push and their own exact-head CI. Older `04224e9` CI also remains green. Use read-only Code Review CI diagnostics, no quota-limited review-bot retries.

Preserve all earlier commits, particularly `6394f68` (history), `2f841ea` (cleanup/diagnostics), `2073fde` (rendered video/exact launch), `8a80623` (serialized reply checkpoints/projection writes), `28d5811` (Station grouping/manual order), and `3540ce5` (exact PR-head CI/main-only releases). No agent source drafts remain. Root continues solo at requested Extra High; do not restart analysis or repeat verified work. High was recommended as optional for bounded request/package/CI tasks, without pausing. No effort change is assumed.

`9343380` corrects short-brand matches extending ads into ordinary speech. Six regression tests fail before the fix; 201 units pass afterward. One compiled cached replay covers all 17 fixtures without new inference: false cuts improve on three, fourteen unchanged cuts, small ad-tail increases recorded, sixteen strict failures remain. Detector version stays 25 to avoid bulk completed-episode reprocessing/invalidation of unchanged model replies. `ead23f1` adds video/download lifetime ownership and cleanup safety; 212 units pass including 11 disposable race/cancellation/path/failure cases. See Reader and video-cleanup evidence reports; real AV export/phone races remain unverified.

`1211433` checks HTTP/transport/decode/cancellation across charts, lookup and episode search, preserves ranking/deduplication and CatalogLoader retry state. `24c03da` propagates lookup errors in both previews and resolves only the exact requested directory show. All 230 units pass, including 12 discovery and 6 preview cases. See `evidence/2026-10-02-discovery-errors.md`. No new full destination UI tour is claimed for these helper/request fixes.

A temporary, separate LibraryIndex characterization shows a saved catalogue marker is visible after another context commits (`unindexed=0`, `indexed=1`). The executor-affinity diagnostic failed its off-main assumption (`executorMain=true` for both constructors); this does not establish a production threading fix or reliable construction strategy. Preserve diagnostic source in ignored `build/LibraryContextCharacterizationTests.swift` and failed result `build/unit-library-context-characterization-fixed.xcresult`/log. It is excluded from the passing 230-test product suite and delivery. Next substantial source batch is EpisodeCatalogue/LibraryIndex save-failure propagation through all follow/import/refresh/catalog callers, with private-context rollback, durable partial batches and honest completion markers. Investigate executor affinity with an appropriately isolated probe before changing worker construction; do not claim background behavior from the existing comment. Do not roll back another context's listening work.

Actual decoded-video test at `2073fde` has nine inspected clock/pause/synchronization/fullscreen images (`build/TR-recovery-video-ready-route.xcresult`), superseding rejected black-frame presence checks. Station native reorder/Cancel/Save/reopen/grouping/exact Play All sequence passes in 91.454 seconds (five portrait images accepted); focused whole-display orientation passes in 35.521 seconds (four inspected). Landscape controls are reachable but mini-player glass still obscures some content. U08/shared scroll-edge contrast and Station accessibility remain open; see data-Stations/UI evidence. Preserve the earlier 195-unit/Python, chapter, accessibility and backup checkpoint results rather than rerunning them without a relevant change.

Optional signed-IPA path question remains pending; independent work continues. Detection quality (16 strict failures), full destination/editorial parity, shared glass/scroll contrast, controlled phone heat/memory/background/routes, real backup/publishing/import integrations, and device video extraction/cleanup verification remain open. Installed app/data/identity are untouched, and new source has not been phone-tested. Synced attachment stays read-only. No new chat is needed while these checkpoints preserve continuation; do not label this checkpoint whole-product completion.

## Latest phone feedback and changed next action

User tested GitHub “Build unsigned IPA #300: Pull request 22” through Feather. Exact source revision of #300 is not yet mapped; do not assign a SHA from the run number alone. Models/tests fail on the phone; the model page is redundant and poorly organized. Chart still occupies too much height while scrolling settings. Activity Pause/Stop controls differ in size and Stop Finding Ads truncates. These reports override older visual/functionality acceptance. Prioritize runtime diagnosis and a rebuilt model/comparison flow, compact chart presentation, and full-label equal Activity actions before resuming the catalogue draft.

User chose to continue at Extra High after the context conflict; no effort change assumed. Local Xcode 27.0/27A266a access is confirmed, and previous builds/tests already ran on this Mac. Move validation off GitHub; user wants GitHub workflow for IPA build/delivery. No confirmed debugger/UI access to the Feather-signed iPhone app; do not imply phone control or use Xcode installation as a shortcut. Read-only app metadata confirms the same Feather bundle identity, but that does not prove debugger/runtime access. A concise question about the failed engine/test behavior is pending.

Catalogue draft is safely parked in the named local stash, archive and patch; see `evidence/2026-10-02-catalogue-transactions.md`. The final 252-test review exposes a real main/worker context conflict that erases catalog markers and episode relationships after a later main-context edit save. It must be repaired before that draft is delivered. Never blindly apply the stash over subsequent changes to shared files. All earlier commits, source artifacts, passing results and failed diagnostic bundles remain preserved; branch unchanged. Stable delivered app source remains `24c03da`; PR checkpoint `ad59221` CI was still running at last read.

## Verification rules

Builds prove compilation; screenshots inspected after exercising behavior prove simulator appearance; fixture measurements prove lab behavior; current phone checks prove phone behavior. Record exact revisions. Local atomic commits, consolidated complete PRs/pushes, no broken or incomplete merges. Preserve rollback and signing identity. No silent processing audio.
