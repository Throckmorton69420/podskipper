# PodSkipper — Current Implementation and Acceptance Plan

Rebuilt 2 October 2026 from the [Specification](PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md), [178-row catalog](claude/REQUEST-CATALOG.md), actual draft PR #22 and latest phone feedback. This is the current dependency/acceptance plan. Historical passes/B1–B195 and previous plan remain [archived](claude/archive/2026-10-02-reconciliation/README.md). Latest evidence state is in [Handoff](claude/HANDOFF.md).

Build 301/ad592214 phone acceptance failed in models/comparison/sound/Activity. Regression implementation **8698c0a** preserves the reconciled specification and prior work: final local **242 units**, unsigned device compile and changed simulator flows/screens pass. Exact unsigned delivery **252be96 / Build 303** passes compilation/signature verification/package/upload (run37100498970/artifact11266116502), recorded on draft PR #22; **physical inference and design acceptance remain open**. The catalogue 252/one-failure investigation stays parked. See [current evidence](claude/evidence/2026-10-03-build301-device-regressions.md); no whole-product completion is claimed.

**Status at Pass 32 (7 October 2026).** PR #22 is merged; `main` is canonical. Passes 28–32 delivered Batch 1 follow-ups (per-model Basic/Hard in Compare Models, honest progress, chart collapse/resize/pin, EQ reach, Diagnostics folds), Batch 2 pieces (resumable model jobs — phone verified 5 Oct; heat/restart/stall handling — unverified) and Batch 4 pieces (ModelCutCheck, graded corrections, veto, merge-on-lock, overlap editing, keep-last-good-result, Core AI crash guard). The Pass 28–32 overlay at the top of the [catalog](claude/REQUEST-CATALOG.md) is the current status; this plan's batch order and gates still apply. Next: his phone results on the Pass 32 build, then the stopped Qwen/Ministral prompt lab, the full 17-fixture lab per show, the parked catalogue stash (Batch 3), and Batches 5–6.

**Status at Pass 33 (9 October 2026).** His phone run on 3ba90ff (= Pass 32 app code) reopened Compare folds, test progress, Core AI stability, storage after deletes, heat and audio, and added a library-integrity requirement (P23). Pass 33 fixed or instrumented each (catalog overlay X33-01…13, P23; [evidence](claude/evidence/2026-10-09-pass33-phone-evidence.md)) and completed A04's per-show Speed & Audio with Reset. Order unchanged; P23 joins Batch 2 as a gate for anything that opens the library (intents, restore, background launch). All Pass 33 items await his phone.

## Dependencies and execution order

| Batch | Work | Dependency | Exit gate |
|---|---|---|---|
| 0 | Preserve exact baseline/WIP/rollback and scope decisions | Before all edits | No losing installed data, local drafts or source evidence; no inferred signing access. |
| 1 | Latest model/Settings/comparison/runtime and sound/Activity failures | 0; shared resource ownership from existing processing layer | Actual four-row UX, readiness/selection parity, bounded tests/cancellation and inspected responsive sheets/actions; then same-model iPhone tests. |
| 2 | Durable queue/projections, real stops/recovery, background/heat/routes | 0; coordinate1 model resource lifecycle | Deterministic queue/stops/checkpoints, full observer consistency, measured phone battery/charger/playback cases. |
| 3 | Catalogue transaction/identity/executor conflict | 0; ahead of bulk catalogue/history/restore integration | Pending main edits and52+ relationships/marker survive; injected save failures cannot fake complete; no swallowed identity errors or main-thread assumptions. |
| 4 | Context/boundaries/corrections and real quality | 1 for engine evidence;2 for resumable work;3 where source data required | Affected fixtures then all 17, reliable/held-out labels, no catastrophic/material regressions and per-show goals measured before default/training changes. |
| 5 | Full destination parity/player/editor/audio/video | 1 shared design;2 jobs;3 catalogue;4 correction semantics | All destinations and interactions inspected, followed by actual phone routes/audio/video/sync/performance. |
| 6 | Full data/publishing and supported capabilities | 2 jobs;3 catalogue;4 corrections;5 shared actions | Disposable end-to-end round trips plus real upload/offline/retry/reinstall/picker routes and signed supported integrations. |

Batches may reuse validated existing code; do not recreate completed infrastructure. Independent low-risk work can proceed inside an owned checkout, but do not start concurrent heavy model work or overwrite unpublished drafts. A passed subset does not close the whole batch.

## Batch 1 — current phone regressions

Locally implemented in 8698c0a; physical acceptance remains pending: one shared page, **four visible engine rows**, test buttons beside each; Core AI/MLX inline collapsed catalogue controls. Open actual library directly; show selected downloaded names/Ready, matching section order, Reader explanation, matching cellular/results/controls, downloadable candidates and inference selection only when ready/enabled. Repair tall Delete and typography. Preserve exact run/sample/model/policy, queued/running/error/stop states and histories across navigation. Diagnose Nemotron startup and unfinished Core AI Qwen3/MLX Qwen3.5 tests with actual diagnostic evidence; don't silently remove variants or report benchmark errors as success.

Compact shared chart keeps controls useful at large detent, preserves glass, equal Simple/Detailed geometry/scale, labels/frequency regions, accessibility/landscape scrolling. Match Activity action dimensions/icons/full labels.

Gate: local focused build/tests, inspected model route graph/screens at normal/large text and portrait/landscape/detents, cancellation/late reply isolation; then exact artifact iPhone 16 Pro Basic/Hard on selected engines with actual finish/error/stop. Mac guided-response success is not phone quality. No new default until Batch 4.

## Batch2 — processing/resource and phone behavior

Audit existing durable job store and all consumers before editing. Exercise queued/running/paused/stopped/interrupted/failed/completed, order, cross-show additions, independent cancel/retry, sticky stops past historical list limits, late writes, restart after relaunch, transcript/reply checkpoints, notification exact routing and prepare/publish joining. Show measured stages/totals/time and finished results everywhere. Keep KeepAwake artificial-audio no-op; measure legitimate playback routes separately.

Gate: deterministic integration tests and controlled phone runs battery/charger, screen unlocked/locked, playback/no playback, system refusal/expiration, network/resource waits, heavy-work priority and full-library launch/scroll/heat/memory/battery. Record actual OS-limited resumable state rather than indefinite progress. Preserve completed transcripts and explicit word-time charging repair path.

## Batch 3 — catalogue prerequisite

Preserve/reproduce parked private-context relationship/marker failure before applying a fix. Transaction design must retain pending main listening/title edits while protecting catalogue updates, rollback only its own changes, commit durable partial batches honestly, propagate parse/save/network failures through follow/import/refresh/fill, and use exact episode identity rather than title-only conflation. Verify executor affinity with an isolated probe; no claim based on @ModelActor comment.

Gate: test private merge + pending main edits + later save across52+ episodes; completion/partial markers; collision/cancellation/save failure/disk error; linked episodes and listening state intact. Full-history/history-import success waits for this gate.

## Batch 4 — quality and trustworthy review

Keep paid/plugs cut/funny reads kept policy, independently refine class/boundaries/evidence and separate skip preferences. Validate ad-free copies/fingerprints and cached transcript/replies; actual edits/deletions/additions/locks must measurably change future show behavior. Preserve original/pending/final decisions. Verify approximate MSSP/LoS and other reported regions against media; evaluate promising models on user's episodes with diverse held-out labels.

Gate: affected fixtures first; one full cached17-fixture replay after a validated detection change, per-show ads-heard/program-cut/boundary/class reports and no catastrophic/material regression. Current16 strict failures are a failed gate, not completion. Goals≤10s/h ads heard/≤5s/h program wrongly cut. Reader Mac training stays deferred until reliable labels/held-out/deployment gate; public metadata research remains allowed while SponsorBlock study is declined.

## Batch5 — complete experience

Audit New/Search/categories/shelves/See All/results/previews/show/episode/people/Library/Up Next/Stations, including cached/offline/error/unknown states, full public history, persistent filters, real new counts, shared menus/metadata/HTML/artwork, station order/recommendations and download rules. Existing chapter/Station/decoded-frame evidence is reused, with missing destinations and regressions exercised.

Test exact-episode stream/countdown/dismissal/prepare/autoplay/end-forward/session restore; timeline label/inspection/precision coordinates/paused seek/ghost/transcript; bookmarks, native gestures/haptics, full correction editor and clips. Validate one sound-plan presets+repairs+inheritance audibly, including video. Resolve same-episode native/public video, fullscreen/swipe/PiP/switch/cuts/source limitations and safe streaming/temporary cleanup.

Gate: complete actual simulator tour of destinations/actions, two orientations/detents/large text/contrast/motion settings; then exact artifact phone call/AirPods/Bose/Bluetooth/AirPlay/Lock Screen/Live Activity routes and actual video frames/audio sync/DSP/performance. Private/unavailable content gets precise source limitation, not fabricated access or blanket omission.

## Batch6 — data, publishing and capability acceptance

Exercise full backup/staged restore/journal/rollback/newest N/delete/orphans/version migration/reinstall on disposable data, old/corrupt/iCloud placeholder/disk full/interrupted cases. Separate cleanup categories/ages/selection and preserve external/playing files. Real OPML selection/history import must handle missing catalogue/genuine play records/showidentity/unmatched progress without changing unplayed state incorrectly.

Exercise publish-existing-corrections/selected batches/reorder/cancel/offline/relaunch/retry/auto-publish/corrected audio/upload/one feed-per-show, true step/readystate/feed copy/open. Validate actual signed widget/CarPlay/iCloud/Live Activity/Intents/Actionbutton support; no assumptions from code or old Ksign certificate.

Gate: journal/unit failure scenarios plus actual disposable full flows and real supported integration evidence. Unknown capability/access remains open; no unrelated entitlement or installed app/data/identity change.

## Requirement assignment

Every row is assigned below, including decisions and declines. Acceptance wording/status/origin remain in the catalog; do not paste old done labels into this plan.

**0: Standing decisions and withdrawn scope** — M16, D07, D08, D18, B11, F07, G01, G02, G03, G04, G05, G06, G07, G08, G09, G10, G11, G12, W01, W02, W03, W04, W05, W06, W07, W08, W09, W10

**1: Model and current UI failures** — U01, U02, U03, U04, U05, U06, U09, U16, M01, M02, M03, M04, M05, M06, M07, M08, M09, M10, M11, M12, M13, M14, M15, M17, M18, M19

**2: Processing and phone resources** — P01, P02, P03, P04, P05, P06, P07, P08, P09, P10, P11, P12, P13, P14, P15, P16, P17, P18, P19, P20

**3: Catalogue transactions** — L08, L09, L10, L21

**4: Detection quality** — D01, D02, D03, D04, D05, D06, D09, D10, D11, D12, D13, D14, D15, D16, D17, D19

**5: Complete destinations/player/video** — U07, U08, U10, U11, U12, U13, U14, U15, U17, U18, L01, L02, L03, L04, L05, L06, L07, L11, L12, L13, L14, L15, L16, L17, L18, L19, L20, L22, A01, A02, A03, A04, A05, A06, A07, A08, A09, A10, A11, A12, A13, A14, A15, A16, A17, A18, A19, A20, A21, A22, A23, A24, A25, A26, V01, V02, V03, V04, V05, V06, V07, V08

**6: Data/publishing/capabilities** — B01, B02, B03, B04, B05, B06, B07, B08, B09, B10, B12, F01, F02, F03, F04, F05, F06, C01, C02, C03, C04, C05

## Verification and delivery rules

Local Xcode builds/tests/UI inspection precede consolidated unsigned-IPA delivery. Run checks appropriate to changed behavior; reuse earlier valid results unless a relevant change invalidates them. Record exact source/artifact/run and distinguish source present, built, unit/integration measured, simulator appearance/behavior, and actual phone acceptance. No fabricated CPU/GPU/ANE/battery/peak telemetry; unavailable is unknown.

Each completed batch updates catalog/handoff with implementing commit, evidence paths, unresolved acceptance and next action. Keep rollback, no caffeinate, no quota-wasting polling/reviews, no broken/incomplete merge. This plan finishes only after all required gates pass or the user explicitly changes scope; a usage limit is not completion.
