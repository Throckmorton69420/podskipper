# PodSkipper — Current Handoff

Updated 3 October 2026 after Build 301 regression implementation. Read the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md), [Request Catalog](REQUEST-CATALOG.md), then [Implementation Plan](../IMPLEMENTATION-PLAN.md). Archived history is provenance only; do not repeat completed reconciliation.

## Current engineering checkpoint

- Editable checkout `/Users/shashankpandya/Developer/podskipper-recovery`, branch `codex/complete-project-recovery`, implementing commit **8698c0ab984a653a45df16bbe5c713a0db8cbd3e**. Subsequent documentation checkpoint changes no app source. Draft [PR #22](https://github.com/Throckmorton69420/podskipper/pull/22) remains open/draft/unmerged. **Delivered app/docs head 252be96ae41ba1cdd93b8cca4304938905cdecee**, **Build 303/run 37100498970/job 111138914957 passed**, artifact **11266116502**. [Unsigned download](https://github.com/Throckmorton69420/podskipper/actions/runs/37100498970/artifacts/11266116502). Post-build receipt is a local documentation-only checkpoint; no second IPA is required to record delivery.
- Documentation-only reconciliation **146a3de** integrated deliberately at **577c5f2**, retaining unpublished **63fd199** and WIP documentation **aadde54**. Dirty source was preserved and reconciled into 8698c0a. Pre-integration snapshot: ignored `build/build301-pre-reconcile-20261003T034357Z.{tar.gz,patch,json}`. No reset, stash application or synced Sources edit.
- **Final local 242 units pass**, `build/unit-20261003-012655.xcresult`; **unsigned Release iphoneos build succeeds**, `build/device-build.log`, Xcode 27.0/27A266a. GitHub workflow now only compiles/verifies/packages the unsigned IPA; local Mac performs tests and UI validation.
- **Changed simulator flows pass**: Activity 82.324 s and sound detents/EQ/landscape 112.885 s (`TR-build301-delivery-ui`); full model/Settings walkthrough 84.667 s (`TR-build301-delivery-models-final`); largest accessibility text/Increase Contrast Activity 62.159 s (`TR-build301-accessibility-repaired`, Activity only), models/player/sound 158.593 s (`TR-build301-accessibility-models-sound-final`). Actual exported screenshots inspected. Intermediate failures are superseded only by the named passing tests.
- **Build 301 physical failures remain authoritative.** New design/runtime changes are locally verified, not phone accepted. Feather-installed app/container is inaccessible here; no phone installation/data/signing/capability operation was performed. User's installation identity must stay consistent.

## What changed / remaining runtime limits

Direct consistent Core AI/MLX libraries, selected-name/readiness Settings, four visible engine comparison rows with right-side Basic/Hard and default-collapsed Core AI/MLX catalogues, download/enabled/compatible selection guards, shared cellular controls, scoped delete and retained histories. Sole active test/queue/Stop/error identity is explicit. Exact model repository/revision/variant and complete failure measurements are retained; legacy unknown histories stay unknown.

Core AI benchmark wrapper uses public templating/guided engine with non-thinking mode, context/token guards and awaited cancellation. It is **benchmark-only**: Mac guided results completed but made wrong cuts, so episode path/default were not promoted. Legacy ChatSession episode cancellation cannot be proved joined through its public API. MLX readiness validates manifest/required files/JSON; download target is separate from inference selection. Core AI staged atomic downloads retain completed files and honor shared cellular preference; no fresh model weights were fetched this batch.

Compact equal-geometry Simple/Detailed plots, native medium/large thin-material sheet, roomy-portrait-only pinning, scrolling landscape/accessibility chart and actual EQ gesture verification. Shared equal full-label actions fix player/Activity dimensions; accessibility player controls scroll and video/audio retains full spoken labels.

Supplied diagnostics (`PodSkipper-diagnostics-1790992954.json`, SHA256 efbb3f2980f637bf0320306a4ae1af069d63f8618d2a468320f64141da5937d6) show five Nemotron load failures and three incomplete Core AI Qwen Basic answers; **no MLX run in this export**. Nemotron OS load root cause and user's MLX failure remain unproved. Background task IDs do not match the Feather runtime identity and GPU/inference entitlement capability is missing; this is a separate signed-copy blocker. Old timing/MetricKit records lack matching source identity; no fabricated Build 301 thermal/crash conclusion. Full evidence and phone checklist: [Build 301 regression report](evidence/2026-10-03-build301-device-regressions.md).

## Rollback and parked catalogue investigation

Prior working delivery app source **24c03da**, document head **ad592214**, Build 301 run **37072594995** / job **111055261901**, 230 units and unsigned compile/package succeeded. Preserve ignored `build/delivery-24c03da/PodSkipper-24c03da-unsigned.ipa` (69,212,819 bytes, SHA256 `524e792e0c9e553811fa75235ea9aebbd98485c1286ecb877ae24802ed79a780`) and earlier 693be6c rollback. That artifact has reported phone failures and is not an acceptance baseline.

`stash@{0}` remains untouched: “Catalogue transaction WIP: 252 tests with one confirmed cross-context regression; preserve for later repair”. Preserve `build/catalogue-transaction-final-working.tar.gz/.patch` and [catalogue evidence](evidence/2026-10-02-catalogue-transactions.md). Worker marker/52 relationships are erased by a later pending-main-title save (nil marker/1 relationship); 52 episode rows remain. Earlier 250 pass does not close the 252/one-failure gate. Delivered LibraryIndex still ignores save failures/can match title: L21 blocks reliable bulk history/import integration. Do not pop/apply the draft blindly.

## Accepted implementation evidence to reuse

| Checkpoint | What evidence establishes | Remaining gate |
|---|---|---|
| 01ce71a | Shared model destination/typography/native sheet/benchmark identity and inspected earlier detents/orientations | Current phone model/sheet/Activity regressions override appearance closure. |
| Processing checkpoints +8a80623 | Durable job records/sticky stops/versioned checkpoints/heavy-work leases, deterministic integration and late-reply/projection changes | All observers/real queue/relaunch/background/heat/routes on phone. |
| 37430af/d95b821/6b2d987 | Model capture/evidence rules/publishing joins/chapters/exact position; 106 units and eight-image chapter exact 45 s tour | Real model quality/editor/audio/publishing and full destination acceptance. |
| 6394f68/2f841ea | Genuine scoped history matching and cleanup/diagnostic safety; journal/roundtrip/corruption/retention tests | Actual picker/import/full backup/reinstall/cleanup integrations. |
| 2073fde | Changing decoded video frames/sync/fullscreen screenshots and exact launch; supersedes rejected black-frame checks | Phone sources/audio DSP/sync/PiP/cleanup/heat. |
| 28d5811 | Station grouping/manualorder/Cancel/Save/reopen/exactPlay All inspected;15 Station tests recorded | Complete parity/recommendations/landscape/accessibility. |
| 9343380 | Three cached false-cut improvements,14 unchanged; bounded matcher tests |16 of 17 strict fixture failures, held-out/real model quality; Apple default unchanged. |
| ead23f1/1211433/24c03da | Video cleanup lifetime/request/preview error tests;230-unit delivered suite | Phone races and full child-destination parity not implied. |

Detailed paths/limits remain in existing `claude/evidence/` and [Evidence Audit](reconciliation/EVIDENCE-AUDIT.md). Old evidence remains chronological, not current authority. Do not rerun unrelated tours/download whole catalogue solely because this handoff is shorter.

## Next action and whole-product scope

Exact-head unsigned delivery is complete and recorded on PR #22. Local `build/delivery-252be96/PodSkipper-Build-303-unsigned.ipa` is 69,253,983 bytes, SHA256 `9402c83e857449357b56c64a31dcba58786d708e3e718701066f904e457d3b78`; archive SHA256 matches GitHub, unsigned verification passes, exact CI checkout/generated stamp and executable long subject/date match. See `build/delivery-252be96/manifest.json` and `ci-verification.txt`. Next, user tests this artifact through existing Feather workflow: same failing Core AI/MLX models Basic/Hard/load/Stop/revisit/history, download/enable/select/delete/cellular, four-row Settings/libraries and expanded sound/Activity/player controls. Fresh diagnostics are needed if inference still fails. Keep PR draft until required local/CI/phone gates pass.

Continue the existing plan after this coherent source batch: Batch 2 processing observers/queue/recovery/resources/background/thermal/routes; Batch 3 parked catalogue conflict before bulk integration; Batch 4 quality/corrections (16 of 17 strict fixture failures), Batch 5 full destination/player/video parity, Batch 6 data/publishing/supported signed capabilities. All 178 request rows remain assigned. Current source subset success does not close these gates.

Extra High remains the agreed setting for this batch. Before a later phase, recommend a different level only for a material reasoning benefit; no repeated reassessment. No Siri/PCC, artwork swipe scrub, YouTube ad blocking, reduced quick check, SponsorBlock study or gray Settings index unless reopened. Apple Intelligence default/training gates remain; no silent processing audio, caffeinate, unrelated signing changes or broken merge.

## Documentation reconciliation checkpoint

Created compact authoritative specification, rebuilt178-row catalog and dependency plan, corrected stale build/access/architecture/status claims, indexed122 User blocks +7 tool-answer groups +12 later records +F301, preserved all 196 legacy rows, and archived replaced active documents. Exact raw history remains byte-identical locally; source-management UI replacement was not performed because synced Sources is read-only. See [Reconciliation Report](reconciliation/RECONCILIATION-REPORT.md) and [Archive](archive/2026-10-02-reconciliation/README.md). Validation is document coverage/link/hash/diff validation, not new app behavior.
