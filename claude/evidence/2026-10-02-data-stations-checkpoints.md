> **Dated evidence/reference.** Findings and verification apply only to the named revision/inputs. Current specification, catalog and handoff govern scope/status; later user failures override earlier pass labels. Do not execute obsolete future-work directions from this report.

# Data, Stations and resumable replies — 2 October 2026

## Verified checkpoints

`6394f68` preserves history import provenance and exact feed/episode identity. Eleven disposable history cases cover duplicate/conflicting records, repeated titles, case-sensitive paths, feed aliases, explicit local playback, and Apple default/manual played states. The Python exporter regression passes against a copied source with a checksum proving the original database is unchanged.

`2f841ea` makes category cleanup report removed, absent, failed and protected items. Eleven disposable cleanup cases preserve active/queued work, corrections, external/unrelated data and failed references; transcript cleanup invalidates resumable stages while keeping pause/stop intent. Fourteen diagnostics cases cover dated entries, serialized writes, relaunch replay, corrupt/duplicate identities, failure preservation and report-shaped directories/symlinks. Backup cleanup honors in-use source/work paths. No live phone cleanup, restoration or history import was performed.

`2073fde` adds exact preview routing, truthful destination loading/empty/error states and validated video fixtures. Seven video service cases decode changing nonblack clock frames. The launch-link fix preserves a requested episode until asynchronous setup finishes. `testVideoPlayer` passed in 75.721 seconds (`build/TR-recovery-video-ready-route.xcresult`); all nine images were inspected, including inline color/clock content, audio/video changes, pause, fullscreen and return. Earlier black-frame presence tests do not establish rendering. This is simulator fixture evidence; real routing/PiP/public media remain phone checks.

## Processing and Station batch

Code checkpoints: `8a80623` (reply checkpoints/projection writes) and `28d5811` (Stations). Final combined source passed **195 unit tests, zero failures**, in `build/unit-20261002-164453.xcresult`; console: `build/unit-20261002-164453.log`. The earlier 195-test checkpoint (`build/unit-20261002-161705.xcresult`) is preserved. The copied-data Python history exporter regression passed again.

- Fifteen Station cases preserve membership/per-show limits, hidden manual ranks and independent station/global queue order. A consistent SQLite copy of the frozen pre-change station schema migrates successfully with default grouping/ranks and preserved listening position, chapters and locked added cuts. Disk reopen and backup snapshot tests preserve new fields. Only disposable data was migrated.
- Six processing-persistence cases measure 100 durable progress writes with 120 retained stopped jobs and **zero unchanged compatibility-array writes** after baseline. Changed pause/stop/reorder projections and relaunch repair still persist. Failed authoritative writes do not advance the memo. This is a measured write-count improvement, not a phone heat or disk-volume result.
- Six checkpoint cases serialize snapshot/write/discard and reject late callbacks after completion. Failed saves retain dirty replies for retry; corrupt current files and unversioned history stay intact. Explicit transcript cleanup removes both cache generations.
- Five response cases distinguish prompt, instructions, token budget, policy, detector and OS runtime; reject cancellation before cache access and immediately after response; stop launching remaining batch prompts; retain ordered results and the captured cache. Tests use injected responses and make no model inference requests.

Version 2 reply keys identify Apple Intelligence's system-default model and available variant display name, guardrails, greedy sampling and OS/build runtime. Apple exposes no exact downloadable model revision here. Legacy prompt-only replies cannot establish that identity and remain history; completed transcripts are unaffected.

Station UI: the full native reorder/Cancel/Save/reopen/grouping/exact Play All sequence passed in 91.454 seconds (`build/TR-recovery-station-held-reorder.xcresult`). Five portrait screenshots were inspected and accepted; the sixth, landscape, used an app-window capture that clipped the display and is rejected as appearance evidence. The test now uses the existing suite's whole-display API and waits for rendered orientation. The focused grouping/portrait/landscape sequence passed in 35.521 seconds (`build/TR-recovery-station-display-ready.xcresult`); all four screenshots were inspected.

Native switch tests tap the nested UISwitch, not the wider accessibility row. Native reorder uses its identified handle and a 0.7-second pickup hold. Tests wait for Station navigation before opening options. No production toggle workaround was retained.

The correct landscape image confirms reachable controls but also shows the baseline mini-player glass obscuring some row content while scrolling. This remains a shared whole-app scroll-edge/contrast acceptance issue (U08), not fully verified landscape appearance. A row being hittable alone does not prove every label is readable. Large-text/VoiceOver Station acceptance remains pending.

## Limits

Station order is local; CloudSync currently excludes stations. Full editorial/destination parity, controlled phone performance/background/routing checks, real publishing/restore/import integrations, actual signed capabilities and detection-quality goals remain open. The 17 cached Reader fixtures still have 16 strict failures; Apple Intelligence remains the default. No merge, phone installation or signing-identity change is implied by these checks.
