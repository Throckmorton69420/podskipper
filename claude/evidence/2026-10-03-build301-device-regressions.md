# Build 301 device acceptance and regression batch

## Authoritative input

User tested unsigned Build 301 after signing/installing through Feather on iPhone 16 Pro. This task has no access to that installed app/container and performs no phone installation, data operation or signing-identity change. Current acceptance replaces older simulator success. Required comparison design is four visible engine rows with Basic/Hard beside each, default-collapsed Core AI/MLX catalogs, and direct library lists.

Original read-only export: `/Users/shashankpandya/Library/Mobile Documents/com~apple~CloudDocs/Downloads/PodSkipper-diagnostics-1790992954.json`.
Ignored preserved copy: `build/build301-diagnostics/PodSkipper-diagnostics-1790992954.json`.
SHA256: `efbb3f2980f637bf0320306a4ae1af069d63f8618d2a468320f64141da5937d6`.
Export: `2026-10-03T02:02:34Z`, app `1.0 (1)`, source stamp `ad59221`, device `iPhone17,1`, OS `27.0.1`.

## Diagnostic facts and limits

- Five Nemotron-3-Nano 4B failures (three Basic, two Hard), during loading: `CoreAIDelegates.AIModelError error 0`. This does not establish why the OS failed loading. Do not rename it a generation timeout or claim repaired device loading without a phone retest.
- Three Qwen3 4B Basic failures: incomplete/readability failure. Exported old results lose answer/timing information, reporting zero tokens/s and zero seconds. The new runner preserves failed answer measurements and distinguishes no output, invalid JSON and exhausted token budgets.
- The export's Model tests fact contains no MLX run. User's MLX failure remains acceptance evidence, but this export does not reproduce its error.
- Earlier background event `2026-10-02T07:48:41Z`: `A generation is already running on this session — consume it or call cancelGeneration() first.` Event has no per-event build identity. Kit `ChatSession.reset()` cancels without joining its producer; its stream consumer can also leave generation alive. The app-owned benchmark wrapper cancels/joins the public engine before releasing its resource lease. Episode classification remains on the prior path pending quality acceptance; do not promote guided generation merely because it returns JSON.
- Timing records mix earlier builds: newest records use `a25f301` (Build 300); others include `f8a7c4a` and `5072122`. Historical long processing/thermal measurements are not Build 301 benchmark timings.
- Signed runtime reports Bundle ID `app.ivory2951.coral5096`, but declared continued-processing IDs belong to `com.yourname.podskipper` / `com.worksin.two`. `Declared for this app: No`; iOS refuses `app.ivory2951.coral5096.continue.*`. Background GPU/inference entitlements reported missing; extended address/memory reported present. This is a capability blocker for that installed copy, independent of foreground benchmark classification. Do not change identity or unrelated entitlements.

## Preserved engineering baseline and implementation

Branch `codex/complete-project-recovery`. Documentation-only merge `577c5f2` retains `146a3de`, parking commit `63fd199`, and WIP evidence `aadde54`. All unfinished source is retained. Pre-reconciliation snapshot: `build/build301-pre-reconcile-20261003T034357Z.{tar.gz,patch,json}`. Catalogue conflict investigation remains parked in `stash@{0}`; its 252-test/one-failure evidence remains authoritative and has not been reapplied.

Implementation commit **8698c0ab984a653a45df16bbe5c713a0db8cbd3e**. The subsequent documentation checkpoint changes no app source. PR #22 remains draft; no merge or phone installation is authorized by this evidence.

## Implemented behavior

- Settings uses consistent engine explanation/library/Compare/Reader order and selected downloaded model name/readiness. Both libraries open directly, share catalogue rows and cellular preference, and link to one comparison page. Missing, disabled and incompatible models cannot be selected; selection is guarded in the service as well as the view.
- Comparison restores the requested four engine rows with Basic/Hard beside each at normal text size. Core AI/MLX catalogues start collapsed. Large accessibility text stacks controls so full labels fit. Only the requested engine is active; global heavy-work ownership disables competing tests, and queued/stopping/error states are explicit.
- Benchmark records retain exact model/repository/revision/variant, sample/policy/run identity, histories, measured duration and detailed failures. Unknown historical Core AI model identity stays unknown. Tests survive navigation. Run guards prevent late replies from changing another run; cancellation keeps the lease until the runner unwinds. Failed/incomplete answers have no accuracy score.
- Core AI benchmark Qwen/Nemotron uses the public engine with non-thinking template, a 2,048-token budget, context guard and awaited cancellation. Strict complete-answer parsing distinguishes incomplete, malformed and absent output. The existing episode path is retained: Mac guided probes returned complete JSON but made wrong cuts. Kit ChatSession episode cancellation still cannot be proved joined through its public API; this is not a whole-system runtime closure.
- Core AI downloads honor the shared cellular rule, pinned catalogue bundle and atomic Kit cache layout. Interrupted staging retains completed files; inference cannot use a partial install. MLX selection is separated from the download target, validates required files/JSON/manifest, and respects downloaded/enabled state. Deletion is serialized against inference and blocks selection while removing; benchmark history is retained. Model weights were not downloaded afresh during this batch.
- Speed & Audio uses native medium/large detents and thin material throughout, a compact common Simple/Detailed plot and shared ±15 dB scale. Detailed information sits below the plot. Pinning is limited to roomy expanded portrait; landscape/accessibility scroll the chart with controls. Shared equal-action layout fixes full Pause/Stop labels and player toggle dimensions. Player controls scroll at accessibility sizes/landscape; video/audio switches keep full spoken labels.
- GitHub now compiles/verifies/packages the exact PR-head unsigned IPA; builds/tests/simulator interaction run locally on the Mac. Identity, provisioning and entitlements are unchanged.

## Additional diagnostic and catalogue checks

MetricKit in the supplied export contains two daily reports, two CPU exceptions (1 October: approximately 90 CPU seconds in 147 and 90 sampled seconds), and one disk-write exception (1 October, approximately 1,074 MB). There is no crash or hang diagnostic among these five records. They have app version/build 1.0/1 and the re-signed bundle ID, but no source revision; they do not prove a Build 301 benchmark crash, OOM or root cause.

Public pinned Hugging Face listings were checked without fetching model weights: Qwen3 4B `e40878faa776f8d048d592991e9e958f16736f88/ios` has 11 files, metadata, valid positive sizes and 2,502,148,395 bytes; Nemotron `0f9e01aa8d3f569be4b067a67ff7681591c235c4/ios-h18p/nemotron_3_nano_4b_decode_int8hu` has 14 files, metadata, valid positive sizes and 4,628,965,401 bytes. Catalogue completeness is not evidence that iPhone loading succeeds.

## Local validation of the implementation tree

Toolchain: Xcode 27.0 (27A266a), macOS 27.0.1, iPhone 16 Pro simulator iOS 27, `4DB432A8-4FE6-48C0-A4EE-535CDA6142D8`.

| Gate | Exact evidence | Result and limit |
|---|---|---|
| Final hosted unit suite | `build/unit-20261003-012655.xcresult`, `build/unit-test.log` | **242 tests, zero failures**, 18.029 seconds test execution. Includes readiness/partial/corrupt bundle, atomic download/interruption, identity/history, cancellation/lease and existing processing/data/playback suites. |
| Actual unsigned device target | `build/device-build.log`, `build/device-project/PodSkipper.xcodeproj` | **Release iphoneos BUILD SUCCEEDED**, signing disabled, no install. Existing iOS 27 deprecation warnings in DemoVideo/PlayerEngine remain. |
| Normal Activity | `build/TR-build301-delivery-ui.xcresult` | **PASS 82.324 s**: popup/page, equal full-label actions, queue/finished/stop flows. |
| Native sound detents/orientation/control gestures | same result bundle, `testSoundSheetDetents` | **PASS 112.885 s**: medium/large, matching Simple/Detailed geometry, actual EQ thumb movement, repairs and landscape controls. |
| Complete model/Settings walkthrough | `build/TR-build301-delivery-models-final.xcresult` | **PASS 84.667 s**: direct libraries, four rows/disclosure defaults, downloaded/enabled selection guards, switch engines, Reader Basic and retained history. Earlier combined model-test failure was a test touching Settings before the target row was visible; corrected interaction passes on unchanged app source. |
| Largest accessibility text + Increase Contrast, Activity | `build/TR-build301-accessibility-repaired.xcresult`, `testAccessibleActivityActions` | **PASS 62.159 s**: equal stacked complete labels, each popup action reachable by scrolling. Other tests in this intermediate bundle were superseded below. |
| Largest accessibility text + Increase Contrast, models/player/sound | `build/TR-build301-accessibility-models-sound-final.xcresult` | **PASS 158.593 s**: model controls, four-row page with accessible stacking, scrollable player controls, unpinned chart and reachable Smart Speed. |

Actual exported screenshots were inspected, including:

- `build/shots-build301-delivery-models-final/named/small/`: `models-05b-settings-picker`, `models-07-mlx-library`, and direct-library/four-engine/inline/Reader-result captures.
- `build/shots-build301-delivery-ui/named/small/`: `a0a-activity-popup`, `a1-activity`, `player-01-shared-actions`, `sheet-01-medium`, `sheet-02-large-simple`, `sheet-03-large-detailed`, `sheet-03a-equalizer-adjusted`, `sheet-04-landscape-controls`.
- `build/shots-build301-accessibility-repaired/named/small/`: `accessible-activity-pause`, `accessible-activity-actions`.
- `build/shots-build301-accessibility-models-sound-final/named/small/`: `accessible-player-controls`, `accessible-compare-coreAI`, `accessible-04-audio-controls`.

Screens use demo episodes; Core AI demo downloaded readiness is not physical inference. Reader Basic is a real simulator classifier run (~92%, ~3.4 s), not a real-episode quality gate. Test setup forces portrait; simulator text size/contrast were restored to large/disabled. No Reduce Transparency-specific tour, real phone load, cellular transfer, heat or background completion is claimed. Older failed chart/layout/test attempts remain preserved but are superseded only by the named passing tests.

## Delivery and remaining acceptance

Local source/tests/UI gates above are complete. The documentation checkpoint is delivered with this source in draft [PR #22](https://github.com/Throckmorton69420/podskipper/pull/22). Delivered head **252be96ae41ba1cdd93b8cca4304938905cdecee**, **Build #303**, run **37100498970**, job **111138914957**: exact-head compilation, unsigned verification, package and upload all succeed; main release is skipped. Artifact **11266116502**, [unsigned download](https://github.com/Throckmorton69420/podskipper/actions/runs/37100498970/artifacts/11266116502). Code Review check tool confirms this exact head succeeds.

Downloaded archive size **69,000,357 bytes** / SHA256 `bb0b3dff6c232fb53d8341ce6163ad4a5265fed2d6b88ea122559126477e2c09` matches GitHub's digest. IPA **69,253,983 bytes**, SHA256 `9402c83e857449357b56c64a31dcba58786d708e3e718701066f904e457d3b78`, preserved at `build/delivery-252be96/PodSkipper-Build-303-unsigned.ipa`; receipt `manifest.json`, checksum and `ci-verification.txt` are in that ignored directory. Executable is unsigned; bundle ID `com.yourname.podskipper`, minimum iOS27.0. Exact CI checkout and generated BuildInfo are 252be96, and executable long subject/build date match. A naive ASCII search for the optimized seven-character Swift stamp did not find it; this was not used as evidence of a wrong artifact. No phone execution is claimed.

This post-build receipt is kept as a local documentation-only commit rather than starting another identical IPA build; the published PR/artifact revision remains 252be96. Preserve that local commit on continuation. No source or test changes occurred after local gates.

Phone checks on the newly delivered artifact remain required, using the user's existing Feather identity/install workflow:

1. Settings selected-name/order/Reader description; direct Core AI/MLX lists; disabled missing models; enable/select/delete, matching controls and cellular setting. Verify real stopped/resumed downloads without discarding working caches.
2. Apple Intelligence, Reader, Nemotron 3 Nano 4B Core AI, Qwen3 4B Core AI and Qwen3.5 4B MLX Basic/Hard: actual load, visible sole active engine/stage, completion/error, Stop while queued/loading/generating, retained history and navigation. Export fresh diagnostics if any load/answer still fails. Nemotron root cause and MLX reported startup failure remain open.
3. Player equal toggles; medium/large glass sound sheet, compact plots in both modes, reachable EQ/speech/repair controls, landscape and large text; Activity popup/page full equal actions.
4. Background capability refusal in the re-signed copy remains a separate recorded blocker; this batch does not change the app identity or add entitlements.

Whole-product Batch 2 resources/jobs/thermal, Batch 3 parked catalogue conflict (252 tests/one confirmed main-context overwrite), Batch 4 quality (16 of 17 strict fixtures still failing), full destination/player/video parity and data/publishing/capabilities remain open. Apple Intelligence remains default. This is a validated implementation batch with physical acceptance pending, not product completion.
