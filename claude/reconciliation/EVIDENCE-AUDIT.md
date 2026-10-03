# Reconciliation evidence audit — 2 October 2026

This documentation audit reconciles available user source, current PR code, historical implementation reports and latest phone feedback. It does **not** run new app tests, install a build, merge the PR or change app code. Record the documentation commit separately from this app baseline.

## Revisions and evidence boundary

| Evidence | Verified state / implication |
|---|---|
| Live draft PR #22 | [Recover model UI, processing, data safety and exact playback](https://github.com/Throckmorton69420/podskipper/pull/22), open/draft/unmerged, audited head `ad592214ad6b5d56691f8a2792ac0cbe9e2990be`; 26 commits,125 files before this docs change. |
| Build 301 | [Actions run 37072594995](https://github.com/Throckmorton69420/podskipper/actions/runs/37072594995), exact head ad592214, completed success. Job 111055261901: source/Python checks, regression tests, unsigned build/verification/package/upload passed; latest release skipped. This proves those steps, not phone acceptance. |
| App source / local IPA | 24c03da0eae93dc0649edb4660c231d36aa677ed; ad592214 adds documentation. Recorded 230 units passing plus unsigned arm64 iOS 27 IPA SHA256 `524e792e0c9e553811fa75235ea9aebbd98485c1286ecb877ae24802ed79a780`. Local artifact matches its documented source, not a new post-reconciliation build. |
| Build 300 | Earlier run 37068686265 at a25f301, 212 units; app source ead23f1. C010 calls its installed Build 300; keep distinct from F301. |
| Latest phone | C010/C012 and later F301 describe iPhone 16 Pro failures. F301 explicitly identifies Build 301. Missing attached diagnostic content remains unknown. |
| Active engineering checkout | `/Users/shashankpandya/Developer/podskipper-recovery`; local unpushed 63fd19916c782fccfedd2b6e79668e859e63f435 plus dirty runtime/UI/workflow/docs and untracked files. Not the delivered PR head. This audit uses an isolated clean clone and leaves that checkout untouched. |
| Catalogue draft | Parked transactional investigation is NOT delivered. It has a real failing context-conflict test; preserve stash/archive/patch/results and reproduce before adoption. |
| Installed app | Actual Feather app/container/debug/signature/capabilities unavailable per C011. Historical handoff claim of confirmed devicectl container/group access is retracted, not carried forward as fact. |

Source was read directly in the clean clone. Passing suite and screenshot claims below are dated records with exact checkpoint/evidence paths; they are not rerun claims. The live workflow conclusion/steps were checked independently. Source contains 230 test functions at the audited head; a count alone is not pass evidence.

## Requirement-group evidence

<a id="eu"></a>
### EU

Views/Theme.swift, LocalModelView.swift and AudioControls.swift; earlier screenshot tours at 01ce71a/6b2d987. Those tours precede C010/F301 and do not close current appearance failures.

<a id="ep"></a>
### EP

ProcessingJobStore, HeavyWorkCoordinator, ProcessingPipeline and DetectionCheckpoint exist; pipeline/cancellation/migration units and 8a80623 checkpoint changes are recorded. Phone background, responsiveness and actual stops remain acceptance gates.

<a id="em"></a>
### EM

ModelBench and CoreAIModelLibrary/LocalModelSpec exist; 01ce71a/37430af add identities/snapshots and tests. Current Basic runs and selected model readiness failed on the phone; runtime compatibility is not proved by a catalogue entry.

<a id="ed"></a>
### ED

AdFreeCopy, AdPrints, SegmentEvidence, correction models and detector/lab exist. 9343380 improves three cached cases; 16 of 17 fixtures still fail strict acceptance, with no held-out or new-engine phone quality proof.

<a id="el"></a>
### EL

Directory/catalogue, episode destinations, Stations and download rules exist. 1211433/24c03da cover request and preview errors; 28d5811 covers Station order. Full destination/reference parity and catalogue safety remain open.

<a id="ea"></a>
### EA

PlayerEngine has PlaybackPhase and session restoration; 6b2d987/2073fde include exact-position/launch/video checks. Remote routes, audible DSP, precision editor and current sound-sheet appearance still need acceptance.

<a id="ev"></a>
### EV

Resolver/player/stream-cleanup paths exist. 2073fde has inspected changing frames and 212-unit cleanup checkpoint at ead23f1; public source availability, real-phone sync/DSP/cleanup remain open.

<a id="eb"></a>
### EB

Backup/restore journal, HistoryImport and cleanup implementation exist; disposable round trips and scoped matching units are recorded (6394f68/2f841ea). Real picker/history/reinstall integrations remain open.

<a id="ef"></a>
### EF

Publishing joins processing jobs and preserves retry/feed state in 37430af. Offline phone failure and real upload/export/feed/relaunch integration are not closed by those unit records.

<a id="ec"></a>
### EC

Intents, CarPlay, CloudSync and widget/Live Activity source exists. Actual Feather-signed capabilities, route support and phone behavior are unknown; older container-access assertion is retracted.

<a id="eg"></a>
### EG

User decisions govern future work; this documentation change itself adds no app behavior. Latest C010 moves tests/UI inspection locally and retains GitHub unsigned IPA delivery.

<a id="ew"></a>
### EW

Explicit adopted declines/supersessions retained; these are scope decisions, not completed features.

## Corrected stale status claims

| Old active-document claim | Current source/evidence | Reconciled implication |
|---|---|---|
| Per-episode processing “not started”; one global currentEpisodeGUID | ProcessingJobStore, shared HeavyWorkCoordinator and versioned DetectionCheckpoint in ProcessingPipeline | Built/partially tested; background/queue/phone acceptance remains open P01–P20. |
| Player only has isPlaying Bool, no state machine | PlayerEngine.swift:24 has PlaybackPhase; restoreLastSession:801 exists | Architecture claim obsolete; verify routes/session restoration under A03/A05/A16. |
| Chapters/manual Station order absent | Chapter editor exact 45 s eight-image simulator tour at6b2d987; Station reorder/Cancel/Save/reopen/Play All at28d5811 | Partial implementation with specific simulator evidence, not missing or wholly accepted. |
| Latest pushed build is a25f301/300; new CI pending | Live PR ad592214 and successful exact-head301 | Delivery history is superseded; existing dated evidence files remain historical reports. |
| Device container/capabilities accessed | C011 says actual Feather-installed app/data cannot be accessed | Capability/container/debug acceptance unknown C01/A17/B12. |
| Old PHONE VERIFIED means current acceptance | C010/C012/F301 model/chart/Activity failures | Current regressions/open gates override old labels; preserve older success as dated history. |
| Private Apple catalogue/editorial or all older history categorically impossible | Existing public catalogue/shelf/cache/fill implementation and accepted public research | Public data/features remain in scope; specific inaccessible sources get precise limitations, not blanket omission. |
| New source has not been phone tested | F301 explicitly says user installed/tested301 | Replace generic statement with actual reported phone failures; no overall success implied. |
| README never compiled / reader-only / iOS 26 missing feature skeleton | Exact-head build301, four engines, source/tests for chapters/stations/import/widgets etc | Replace misleading current introduction; archive old explanation rather than treating it as truth. |

## Source-corroborated latest failures

- SettingsViews.swift:465–536 changes AI section order with engine and :503 hardcodes **Choose and download** despite selected Core AI model. M07 is open.
- LocalModelView.swift:89–96 retains a preliminary Core AI selected-model page before the catalogue; current selection button near :660 gates enabled only. CoreAIModelLibrary.swift:168 selects unconditionally. Latest direct catalogue and downloaded-only selection requests M06/M08 remain open.
- Current comparison UI has shared busy state and global run progress. A shared destination exists, but F301 four-row layout/active identity/errors are not accepted. Unit histories/cancellation do not prove actual phone runtime M03/M09–M11/M19.
- F301 expanded sound sheet and Activity controls failed after older native-detent screenshots. Local compact chart/equal-button draft is unpublished and cannot close U04/U06/U09.

<a id="catalogue"></a>
## Catalogue persistence finding

Delivered LibraryIndex.swift merge:70 uses ignored saves at122/128 and catalogue merge:146 uses ignored saves at196/198. Title-based duplicate matching can conflate episodes; a completion marker can advance after failed saves. Existing comment that @ModelActor guarantees a background executor is not verified: local characterization reported executorMain=true for both tested constructors.

A separate parked transactional draft reached250 passing units, then its252-test final run failed `CataloguePersistenceTests.testSuccessfulPrivateMergePreservesPendingMainEditsAndCompletionOnLaterSave`: fresh saved marker/52 linked episodes became nil marker/one relationship after pending main-context edits were saved. This is evidence about the unpublished draft, not a failing test claimed on ad592214. Preserve stash, `build/catalogue-transaction-final-working.tar.gz`, patch and results in the engineering checkout; do not pop blindly or roll back another context's listening edits. L21/P09/L08–L10 stay open.

## Unpublished phone-regression draft

Local snapshot is preserved under `../archive/2026-10-02-reconciliation/local-unpublished/`. It includes guided Core AI nonthinking Qwen/Nemotron experiment, visible queue/run identity and failed replies, Activity equal/wrapping actions, compact sound chart, and a workflow shift to local tests. Recorded local simulator84.69 s result and Mac Qwen guided responses are partial evidence only. Mac Qwen responses complete Basic but include wrong classifications; Nemotron/MLX startup and iPhone behavior remain unverified. Last screenshot/build attempt reported code 65 before pause; exact current dirty tree final checks remain unfinished.

Its proposed **single engine selector/one runner** conflicts with latest F301 **four visible engine rows/tests at right**. Keep shared ownership/run identity infrastructure if sound, but align visible design with M09–M10. Do not relabel this assistant draft as a settled user design or delivered fix.

## Quality and integration limits

All 17 cached Reader fixtures complete;16 strict failures remain. `9343380` improves three false-cut cases while14 retain identical cuts and some ad tails increase. Detector version25/default/weights unchanged. Historical/current policy reports expose program-cut regression; no fresh model inference or held-out success is proved. See [Reader evidence](../evidence/2026-10-02-reader-regression.md). D05 remains failed.

Backup journal/round-trip/corruption/retention cases,11 history matching cases,15 Station cases and source request/preview regression cases are meaningful but do not certify live phone picker/reinstall/publishing/capabilities. Video2073fde inspected changing decoded frames supersedes older black-frame-only tests; real phone source/sync/DSP/cleanup remains open. Complete navigation destinations and reference geometry were not closed by request helper tests.

Existing evidence files are chronological observations. Their implementation claims are interpreted against this audit and latest phone feedback; they are never independent product authority. No requirement was dropped merely because old documentation marked it done.
