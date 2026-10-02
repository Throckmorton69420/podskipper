# Podskipper request catalog

This is the current implementation and acceptance record. Latest phone feedback wins over older completion claims. The attached Claude conversation, its pass-27g catalog, `IMPLEMENTATION-PLAN.md` (including B1–B195), and the prior project chats remain historical evidence, not proof that the current build works.

Status: **OPEN**, **PARTIAL**, **BUILT / UNVERIFIED**, **SIM VERIFIED**, **LAB VERIFIED**, **PHONE VERIFIED**, **BLOCKED**, **DECLINED**. Record the revision and date with every verification. A successful build is not behavioral verification.

## Current phone regressions and design

| ID | Requirement and acceptance | Current status | Evidence / implementation |
|---|---|---|---|
| U01 | Core AI selection expands inline with a rotating disclosure chevron; choosing a model does not push another page. | SIMULATOR VERIFIED | 01ce71a; inline expand/select/collapse UI test and inspected screenshots; phone pending |
| U02 | One Compare models page from AI settings and both libraries; no duplicated benchmarks or recursive links between libraries. | SIMULATOR VERIFIED | 01ce71a; one shared destination, cross-library loops removed; broader tour pending |
| U03 | Model screens use the same readable typography as settings; headings never overlap scrolling content. | SIMULATOR VERIFIED | 01ce71a; shared body/footnote typography and scrolling headings inspected; phone pending |
| U04 | Speed & Audio uses medium/large system detents; the expanded sheet does not partially occlude player corner buttons. | SIMULATOR VERIFIED | 01ce71a; medium/large detent geometry and inspected player screenshots; phone pending |
| U05 | Simple/Detailed share plot size, ±15 dB axes, readable labels and accessible controls; no black slab or sharp panel edge. | SIMULATOR VERIFIED | 01ce71a; equal plot dimensions tested; shared ±15 dB curve and readable legends inspected |
| U06 | Chart pinned only when expanded portrait has room; landscape/accessibility content scrolls together. | PARTIAL | 01ce71a; portrait adaptive pinning and landscape controls verified; accessibility screenshot pending |
| U07 | Shared type/spacing/radii/targets throughout; app size preference does not suppress system accessibility sizes. | PARTIAL | 01ce71a; root and point-based shared text honor accessibility; whole-app audit pending |
| U08 | Consistent haptics/motion/glass, Reduce Motion/Transparency and Increase Contrast; no per-frame expensive effects. | BUILT / UNVERIFIED | Existing implementation needs whole-app checks |

## Processing, background, and performance

| ID | Requirement and acceptance | Current status | Evidence / implementation |
|---|---|---|---|
| P01 | One persisted authoritative processing job per episode drives all UI and queue consumers. | PARTIAL | Persisted jobs-v1 store drives queue, pause/stop, progress, Activity and publishing joins; compatibility episode/result fields retained. Unit verified; phone pending |
| P02 | Ordered, duplicate-free queue survives relaunch; batch additions, reordering and removal preserve every request. | UNIT VERIFIED | Pipeline batch ordering/dedup, interrupted-head relaunch and pause/resume order pass on disposable episodes |
| P03 | Pause, user stop, system interruption and failure stay distinct; user stops persist until explicit retry without history eviction. | UNIT VERIFIED | 351 sticky stop records survive relaunch; explicit pause/system interruption distinct; late success rejected |
| P04 | Shared heavy-work/inference ownership; user requests take priority; tests, preparation and maintenance do not compete independently. | UNIT VERIFIED | Pipeline and comparison exclusivity tested; download-only preparation, maintenance/catch-up/style leases; phone profiling pending |
| P05 | Checkpoint transcript/answers/stages; resume OS interruptions without repeating completed transcription or applying late cancelled results. | PARTIAL | Checkpoint keys/model snapshots preserved, late progress guarded, worker cleanup awaited; real transcription recovery phone pending |
| P06 | Honest continued-processing progress and waits; assertion expiration cleanup; battery/charger and playback/no-playback checks. | PARTIAL | Removed timer-driven ad-free/card progress; iOS 27 asynchronous scheduling, measured progress tests, expiration cancels/checkpoints; phone pending |
| P07 | No silent processing audio; legitimate playback retains routing and audio session ownership. | BUILT / UNVERIFIED | KeepAwake is now an inert compatibility shim |
| P08 | Activity popup/page share steps, progress, queue and Pause/Resume/Stop/Restart; notification opens the actual task. | PARTIAL | Shared Activity presentation plus durable pause/failure reasons and resource waits; updated tour pending |
| P09 | Acceptable launch/scroll/processing heat, memory and battery; measure on full library and iPhone. | PARTIAL | Previous phone stutter/serious heat; profiling remains |
| P10 | Incomplete transcription resumes; explicit overnight work respects settings and never automatically redoes completed transcripts. | PARTIAL | Historical resumable/overnight requests |

## Models and detection

| ID | Requirement and acceptance | Current status | Evidence / implementation |
|---|---|---|---|
| M01 | Separate Apple Intelligence, Reader, MLX and supported Core AI adapters with exact selection captured at job start. | PARTIAL | Job captures exact engine/model; explicit model passed to MLX/Core AI; runtime phone checks pending |
| M02 | Exact model/sample/policy/run identities preserve history; unknown legacy Core AI results are never attributed to today's selection. | UNIT VERIFIED | 01ce71a; distinct models/samples/run history and legacy unknown-model migration tests |
| M03 | Basic/Hard retained; same semantic policy/gold across engines; cancelled test always releases state and never saves late success. | PARTIAL | 01ce71a; cancellation cleanup and post-answer stop tests pass; Core AI now uses shared JudgePrompt; phone inference pending |
| M04 | Compatibility, performance/thermal and real-episode quality remain distinct; unavailable telemetry says unknown. | PARTIAL | 01ce71a; unknown telemetry is explicit and compatibility/real quality separated; device profiling pending |
| M05 | Model enable switches, ranking, download/delete and 99–100% completion work; no up-front memory refusal. | BUILT / UNVERIFIED | Preserve existing model catalog and runAgain/watchdog |
| D01 | Exact compatible ad-free alignment/fingerprints first; reject shortened/mismatched mirrors and preserve negative evidence. | BUILT / UNVERIFIED | Existing AdFreeCopy / AdPrints; inspect affected fixtures |
| D02 | Cached word-timed transcript → Reader candidates → contextual judge → boundary refinement, preserving the working detector. | PARTIAL | Existing sentence detector and MLX/Core AI finder |
| D03 | Classify paid/host ads, self/guest/network plugs, recurring segments, intro/outro/credits, ordinary discussion and comedy separately. | PARTIAL | All plugs cut; funny reads kept by default |
| D04 | Original/corrected/added/rejected/locked cuts survive reruns; per-show feedback measurably changes decisions. | BUILT / UNVERIFIED | Use Episode.apply; never direct userVerdict mutation |
| D05 | Per-show quality report; no catastrophic cuts or material regression. Targets ≤10 s/h ads heard, ≤5 s/h show cut. | OPEN | 17 shipped-Reader fixture run completed; 16 fail strict acceptance, existing quality goals remain unmet. See evidence report |
| D06 | Evaluate promising models on his episodes before changing Apple Intelligence default; measured runtime path, not guessed CPU/GPU/ANE. | OPEN | Prior Basic results are historical evidence only |
| D07 | Mac Reader training from reliable corrections, held-out shows and deployment regression gate. | OPEN | Previously parked; follow quality/correction work |

## Podcast experience

| ID | Requirement and acceptance | Current status | Evidence / implementation |
|---|---|---|---|
| L01 | New/Search/category/shelf/See All/results/preview/people pages match iOS 27.2 beta 2 patterns with cached/offline/error/empty states. | PARTIAL | Audit destinations, not just top-level pages |
| L02 | Chronological New counts; stable feed refresh/indexing; history import does not manufacture played/new status. | BUILT / UNVERIFIED | Latest LibraryIndex fixes require acceptance |
| L03 | Persist sort/filter/season/year settings; batch actions affect visible or explicitly selected episodes. | PARTIAL | Historical parity backlog |
| L04 | Episode sections/actions consistent: people, chapters/art/editing, transcript, information, related episodes, share at time. | PARTIAL | Chapter editing/art still outstanding |
| L05 | Stations group by show/manual order; favorite categories and discovery recommendations remain functional. | PARTIAL | Existing stations; remaining organization gaps |
| L06 | Auto-download rules and per-show remove-played-downloads controls are clear and affect only rule-owned downloads. | PARTIAL | Historical remaining request |
| A01 | Countdown plays exact episode; swipe cancels; prepare N ahead and autoplay preserve queue/show order without duplicates. | BUILT / UNVERIFIED | Existing coordinator and PrepareAhead |
| A02 | Timeline inspection/precision scrub/skip gates/bookmarks/correction editor/clip export work consistently. | BUILT / UNVERIFIED | Existing feature suite needs regression tour |
| A03 | Calls/AirPods/AirPlay/Bluetooth/Lock Screen/Live Activity reflect actual playback state. | BUILT / UNVERIFIED | Must check current signed iPhone build |
| A04 | One resolved sound model feeds chart/DSP; inherited per-show settings, preset+repairs, normalization, Smart Speed and mono agree. | PARTIAL | Older phone report: seems to work |
| V01 | Supported RSS/public host video switches/fullscreen/swipe/PiP stay in sync around cuts; streaming is not retained. | BUILT / UNVERIFIED | Private Apple/Spotify sources remain unavailable |

## Data, publishing, capabilities and build

| ID | Requirement and acceptance | Current status | Evidence / implementation |
|---|---|---|---|
| B01 | Full backup/restore/retention/delete/stage/rollback/reinstall round trips on disposable data. | PARTIAL | 10 disposable-data tests pass: journaled swap/rollback, archive round trip, checkpoints/defaults/cache preservation, retention and individual deletion; signed reinstall pending. See evidence/2026-10-02-backup-restore.md |
| B02 | Corrupt/old/iCloud-placeholder/interrupted/disk-full failures are useful and leave originals intact. | PARTIAL | Legacy/corrupt/missing/same-size-damaged archives, interrupted swaps and injected insufficient space tested; physical iCloud/disk exhaustion pending |
| B03 | Separate downloads/transcripts/logs/stored-backup cleanup; externally saved files untouched. | BUILT / UNVERIFIED | Historical storage requests |
| B04 | OPML/history imports handle scoped matching, duplicates, missing catalog and Apple default play-state records. | BUILT / UNVERIFIED | Existing Mac history export/import |
| F01 | Idempotent publishing reuses detection/corrections; one show URL, selected batches/reorder/cancel/retry/offline/auto-publish. | BUILT / UNVERIFIED | Existing PublishQueue must share processing identity |
| C01 | Inspect actual signed capabilities; exercise widgets/CarPlay/iCloud/Live Activity where available. | BLOCKED | Re-signed capability access not yet established |
| C02 | Consistent iOS 27 local/generated/CI targets; unsigned IPA; exact artifact revision; no unrelated entitlement/identity changes. | PARTIAL | PR 21 repaired head; local baseline build pending |

## Declined and fixed defaults

Siri/PCC; swipe-to-scrub on artwork; YouTube ad blocking; a lesser locked-screen quick check; SponsorBlock ground-truth study; Contacts-style Settings index remain DECLINED. Apple Intelligence stays default unless a model wins on real episodes. Funny reads stay by default; plugs are cut. EQ preset is the base. No heavy background work starts independently of user action/configuration. Completed transcripts are reused. Memory warnings do not refuse downloads or loads up front.

## Historical catalog

The original pass-27g catalog follows below as dated evidence. Its phone statuses and signing assumptions do not automatically describe the recovered build.

# PodSkipper — Request Catalog
## Pass 27g (30 Sep 2026)

Maintained by Claude with `project_write`. Rows changed in pass 27 are marked *(p27)*. Status words: PHONE VERIFIED · SIM VERIFIED · LAB VERIFIED · BUILT / UNVERIFIED · PARTIAL · OPEN · BLOCKED · DECLINED. A green build proves only that it compiles.

**Work split:** cloud credit ≈ $4. No UI work in the cloud (no simulator there). Any cloud brief must name exact files, current and target behaviour, and acceptance checks.

---

# P0 — AD DETECTION

| Requirement | Status | Task / evidence |
|---|---|---|
| Apple Intelligence finds the ads — default | PHONE VERIFIED on screen and locked on the charger | — |
| Apple Intelligence locked on battery | BLOCKED by iOS; workaround (reader now, Apple re-read on next open) BUILT / UNVERIFIED | — |
| Open models to test himself; his whole list *(p27)* | 24 models incl. Nemotron (config patched) and Bonsai 27B (downloadable); 30 Sep Basic results ranked in HANDOFF §1 — BUILT / UNVERIFIED | 4b4fac6 |
| **Models ranked best first, results kept per model, on/off switch per model** *(p27)* | SIM VERIFIED layout; ranking from his imported results unverified | 4b4fac6 |
| **Harder standard test + Apple Intelligence and reader through the same tests** *(p27)* | BUILT / UNVERIFIED | 4b4fac6 |
| Test keeps running / can be stopped after leaving the screen *(p27)* | BUILT / UNVERIFIED (was: button greyed, PHONE 30 Sep) | 4b4fac6 |
| **Model downloads finish without Pause → Download** *(p27)* | Root cause fixed (re-entrant run dropped) + watchdog — BUILT / UNVERIFIED (was: stuck at 99–100 %, PHONE twice) | 4b4fac6 |
| "Also on this iPhone" line removed; "On iPhone" badge per model *(p27)* | SIM VERIFIED | 4b4fac6 |
| Model list selectable, never greyed out | BUILT / UNVERIFIED | cb66644 |
| Lenient answer reading | BUILT / UNVERIFIED | d9a99d6 |
| Model memory safety (GPU only, breadcrumb cap; log names the model) | Breadcrumb PHONE VERIFIED | 26643f0, 4b4fac6 |
| Catch-up: 3 tries, then the reader stands (Apple Intelligence only) | PHONE VERIFIED | — |
| His thumbs/edits fed to the model per show | BUILT / UNVERIFIED | 05 |
| Reader as first pass / fallback; both answers saved | BUILT | 05 |
| Stitched-in ads always cut | BUILT / UNVERIFIED | 05 |
| Cutting rules *(settled — never ask him)*: all plugs cut; 2 Bears Mountain Dew = ad; CumTown keep comedic reads, cut only plain reads | rule | — |
| Detection targets ≤10 s/h ads heard, ≤5 s/h show cut | OPEN | results export |
| "That was an ad" / "Skip back" | BUILT / UNVERIFIED | 07 |
| Train the reader on his Mac | OPEN — parked | — |
| Transcript reuse | PHONE VERIFIED | — |
| Resumable transcription | BUILT / UNVERIFIED | 03 |
| Overnight retranscription | OPEN | — |

# P0 — BACKGROUND / HEAT

| Requirement | Status |
|---|---|
| Locked job on battery finishes (reader) | PHONE VERIFIED (29 Sep, 14 jobs) |
| Locked job on the charger with Apple Intelligence | PHONE VERIFIED (30 Sep) |
| Heat acceptable | PARTIAL — "serious" during jobs |
| Multipoint headphones | BUILT / UNVERIFIED; loss accepted |
| One processing state per episode | OPEN |

# P1 — ACTIVITY

| Requirement | Status | Task |
|---|---|---|
| Plain current step | BUILT / UNVERIFIED | 05 |
| Activity pop-up identical to the page | BUILT / UNVERIFIED (PR #9) | 10 |
| Pause / Resume in Activity | BUILT / UNVERIFIED (PR #13) | 14 |

# P1 — BACKUP / STORAGE

| Requirement | Status | Task |
|---|---|---|
| Export / restore; delete one backup | PHONE VERIFIED | — |
| Keep newest N backups | BUILT / UNVERIFIED | 03 |
| See/delete stored backup data | SIM VERIFIED | — |
| Delete older Diagnostics logs; pick downloads/transcripts to delete | BUILT / UNVERIFIED (PR #11) | 15 |
| Restore after reinstall; iCloud Drive restore | BUILT / UNVERIFIED | — |

# P1 — LIBRARY

| Requirement | Status | Task |
|---|---|---|
| Apple-style "New" episodes and counts | BUILT / UNVERIFIED (PR #10) | 12 |

# P1 — PERFORMANCE

| Requirement | Status | Task |
|---|---|---|
| Smooth scrolling | FAILED ON PHONE (d9a99d6) → per-row scroll transitions off in cb66644; BUILT / UNVERIFIED | 08 |
| App launch | BUILT / UNVERIFIED | 09 |

# P1 — VIDEO

| Requirement | Status | Task |
|---|---|---|
| Full-width video, full screen, swipe down | PHONE VERIFIED | — |
| Video from feed, YouTube match, always start in video | BUILT / UNVERIFIED | 06 |
| Switch lag; audio behind video | BUILT / UNVERIFIED (PR #8) | 09 |
| Video streamed only, never kept | BUILT / UNVERIFIED (PR #11) | 15 |
| Picture-in-picture | BUILT / UNVERIFIED | — |

# P1 — PLAYER

| Requirement | Status | Task |
|---|---|---|
| Play before download; clip sharing; per-show autoplay | BUILT / UNVERIFIED | 07, 02 |
| AirPods play/pause; Lock Screen after pause | BUILT / UNVERIFIED | — |
| Corner buttons | PHONE VERIFIED | — |
| Dynamic Type | PARTIAL (PR #14 buttons) | — |

# P1 — AUDIO / EQ

| Requirement | Status | Task |
|---|---|---|
| One sound model, live curve | PHONE: "seems to work" | 01 |
| Per-show sound | BUILT / UNVERIFIED | 02 |
| **Sound chart intuitive: colour-coded bands, clear loudness scale** *(p27)* | Zone bars (cb66644) not enough (PHONE 30 Sep) → colour-coded band chart with ±12 dB scale + chips: SIM VERIFIED | 4b4fac6 |

# P2 — LOOK AND FEEL / SETTINGS

| Requirement | Status | Task |
|---|---|---|
| Settings easy to navigate | Groups with sub-pages, iOS Settings style: SIM VERIFIED | cb66644 |
| Buttons sized to their label, text centred | BUILT / UNVERIFIED (PR #14) | 16 |
| Card/panel corner radii unified | BUILT / UNVERIFIED (PR #15) | 17 |
| Empty states, Apple Podcasts parity (swipes, show header, episode page), motion | OPEN | — |
| Haptics, symbol effects, Reduce Motion | BUILT / UNVERIFIED | 10 |

# P2 — LIBRARY / LOCK SCREEN / PUBLISHING

Unchanged from pass 25.

# BUILD

| Requirement | Status |
|---|---|
| CI builds with the iOS 27 SDK | BUILT / UNVERIFIED — workflow picks the newest Xcode 27 on the runner if present |

# BLOCKED

Widgets, CarPlay, iCloud sync (KSign limits). GPU in the background for sideloads. Background-inference / continued-processing entitlements (enterprise profile carries none). Apple Intelligence rate limit locked on battery.

# DECLINED

Swipe-to-scrub on artwork · Siri/Private Cloud Compute · blocking YouTube's own ads · a lesser "quick check" when locked · SponsorBlock ground-truth study · a Contacts-style index strip in Settings.

# STANDING DECISIONS

- Latest message wins. The background run is the full process (reader when Apple Intelligence is held back); the chosen finder re-reads on screen.
- Nothing heavy starts in the background on its own; finished transcripts are never redone.
- Funny host reads kept by default. Guest plugs cut. Multipoint loss accepted.
- EQ preset is the base. Identity `com.worksin.two`; KSign `com.worksin.one`.
- Memory: let iOS manage it; never refuse a download or a load up front.
- Apple Intelligence stays default unless an open model clearly wins on his real episodes.
- Follow Apple's own patterns (iOS Settings, Apple Podcasts) rather than inventing controls.

# NEXT PRIORITY

1. His phone check of 4b4fac6 (downloads, ranking, Hard test, Compare).
2. Winners on real episodes vs Apple Intelligence.
3. Scrolling, heat, one processing state; reader-training plan.
