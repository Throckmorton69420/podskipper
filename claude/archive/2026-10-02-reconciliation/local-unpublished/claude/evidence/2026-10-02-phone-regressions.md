# Build #300 phone regressions and local repair evidence

## Installation and evidence boundary

The user installs through Feather. This task has no confirmed UI, runtime or debugger access to that installation. No phone installation, app-data operation or signing change was performed. Local Xcode and simulator validation require no additional user access; GitHub is being restricted to unsigned IPA compilation and delivery.

Build #300 maps to PR 22 head `a25f301db6d90ebb50c6b54ab4ab5721210c646c`, app source `ead23f1`, run `37068686265`. The newer, previously pushed `ad592214ad6b5d56691f8a2792ac0cbe9e2990be` has successful exact-head CI run `37072594995` / check `111055261901`, including 230 units and unsigned packaging. Neither result validates this new working batch or proves phone behavior.

The user reported Core AI Nemotron 3 Nano 4B failing before Basic/Hard starts, Core AI Qwen3 4B and MLX Qwen3.5 4B running slowly then reporting an unfinished Basic test, redundant model screens, an excessively tall pinned chart, and unequal/truncated Activity buttons. These reports supersede earlier acceptance.

## Changes

- Libraries own selection, availability, download/delete and enabled models. One comparison destination owns one engine selector, Basic/Hard selection, one runner and per-model run history. Core AI selection remains an inline disclosure; library comparison links start with their own engine family.
- Benchmarks wait for the shared heavy-work lease instead of silently refusing to start. Selected model/sample are captured before waiting; queued cancellation leaves the current owner alone. Run identities reject late status updates; the lease stays held until cleanup completes.
- MLX/Core AI failures retain the actual loading/inference/answer failure, response prefix, elapsed time and available measurements. A truncated answer may still be salvaged for interrupted episode recovery but cannot count as a completed benchmark. Failed tests have no accuracy score.
- Qwen/Nemotron classification uses the kit's public tokenizer/runtime, disables hidden thinking in the template, and constrains JSON to the unchanged shared schema. Public logits support selects sequential or GPU constraint handling without forcing hybrid models into an incompatible engine. Package pins, weights, sample truth, cutting policy and default engine are unchanged.
- Activity uses one equal-dimension layout for Pause/Stop and Resume/Stop, with explicit text and a stacked fallback when labels cannot fit. Open Episode has its own row. A value-based Settings group route fixes the real nested Activity navigation failure.
- The expanded portrait sheet pins only the playback summary, mode selector and 96-point plot. Band details/legends scroll with settings. Other sizes use a 120-point scrolling plot. Both modes use one sound plan and ±15 dB scale. Layout/text-size changes allow pin eligibility to be measured again.
- Removed the obsolete Settings toggle promising silent processing audio. Its legacy preference remains compatible; the UI describes actual system-granted background execution.

## Mac Core AI probe: completion is separate from quality

Pinned CoreAIKit 0.7.3 / CoreAIModels 0.2.8-zoo / swift-transformers 1.3.4. The standalone local probe copies the app's `CoreAIClassifierSession.swift`; both files have SHA-256 `04b2320980ced861bb47c54625b8c9023cf3ed8d2cb6b8a6903099c8c035cb31`. It uses the shared rules/schema and Basic sample text. Original small-model probe duration metadata was 4:00 rather than the app's 3:59; subsequent 4B probe uses 3:59. This is runtime diagnosis, not a claimed app benchmark score.

- CoreAIKit's first URLSession download timed out before inference (NSURLError -1001). Curl fetched the same listing and pinned files; all sizes and available LFS hashes were validated. No inference conclusion follows from the network failure.
- Qwen3 0.6B macOS bundle: revision `943eb6a4f967de53d7e1458d75deac0b68ac3d85`, 351,561,081 bytes. Non-thinking unconstrained output exhausted 2,048 tokens and remained incomplete; measured prompt 3.27 s / generation 18.62 s. The guided path completed four parts in 515 tokens, prompt 1.68 s / generation 7.60 s. Its broad false labels fail quality acceptance.
- Qwen3 4B macOS bundle: revision `f3d6746370fbb73ee57f2de9ebe111eb628287f1`, 2,279,340,184 bytes. Guided Basic output completes four parts in 479 tokens; load 14.66 s, prompt 6.13 s, generation 13.03 s. It wrongly labels ordinary conversation as INTRO/SELF_PROMO and marks the straightforward sponsorship funny. **Quality fails.** No default model promotion or real-episode quality claim.
- These are macOS variants. Nemotron's phone startup error, iOS Qwen3 4B behavior and MLX Qwen3.5 4B behavior remain unverified. Missing hardware/peak/battery measurements stay unknown.

Probe source, prompts, manifests, output and logs remain under ignored `build/model-runtime-probe/` and `build/model-runtime-probe-*.log`. Thrown errors terminate the CLI harness; that is not evidence of an app crash. Only two Core AI bundles were downloaded, not the whole catalog.

## Simulator verification and rejected attempts

`build/TR-phone-ui-refined.xcresult`: Core AI inline select/collapse → shared comparison → actual Reader Basic run passes in 56.351 s. Current result is 92% sample match / 3.2 s, with unknown measurements labeled explicitly. Four images inspected. This does not establish real-episode quality targets. The separate paused Episode Status presentation passes in 14.683 s; it is not the Activity popup.

Activity exposed real unequal heights/icon-only layout and Settings navigation failures. Those are corrected. Its final run `build/TR-phone-ui-viewport.xcresult` passes in 84.691 s, exercising both popup and page, equal width/height, complete Stop Finding Ads labels, queued-job removal/folding and actual Stop completion. The earlier idle-text assertion looked above the viewport after the large Now row collapsed; the final test waits for the running Pause control to disappear and scrolls to the resulting status. The inspected final status is “Starting the next one…” with two waiting jobs retained.

Chart portrait assertions already establish equal plot dimensions and pinned area under one-third of the window. Earlier landscape attempts scrolled to the bottom rather than finding Speech; their failed bundles remain preserved and are not accepted as passing tests. The final focused check targets the actual sound settings list, rather than the first collection view in a stack of presentations. Final chart, accessibility, unit and device-build results will be recorded after completion.

Shared bottom-glass underlap and popup pinned-section contrast remain open under U08. The catalogue context-conflict draft is still parked in the named stash; it is not included in this batch. Whole-product completion and phone acceptance remain open.
