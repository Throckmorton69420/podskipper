> **Dated evidence/reference.** Findings and verification apply only to the named revision/inputs. Current specification, catalog and handoff govern scope/status; later user failures override earlier pass labels. Do not execute obsolete future-work directions from this report.

# Shipped Reader baseline — 2 October 2026

All 17 fixtures completed. 16 failed the existing strict region/boundary acceptance; these results do not satisfy the quality goal. The per-hour figures are estimated against the existing word-anchored fixture labels. Interior advertisements joined into one break can also fail individual-boundary checks, so inspect affected regions as well as these totals. No catastrophic-minute-cut claim can be made from averages alone.

This run uses the shipped two-reader ensemble, existing copied transcripts/ad-free/fingerprint caches, zero model questions, and the unchanged detector from PR 21. It measures current in-sample fixture behavior; it does not establish held-out show quality or phone heat/runtime. Apple Intelligence remains the default.

Historical cache mode: `LAB_HISTORICAL_EVIDENCE=1 Scripts/run-four.sh`; copied working cache `build/lab`; preserved logs `build/reader-historical-baseline/seg-<key>.log`; summary `build/detection-recovery-summary.log`. The harness now loads app weights explicitly because a command-line executable has no app resource bundle, and returns failure when a fixture fails.

| Fixture | Ads heard, s/h | Program cut, s/h | Mac seconds | Model questions |
|---|---:|---:|---:|---:|
| stav199 | 0.6 | 7.4 | 5 | 0 |
| mssp633 | 9.2 | 1.9 | 4 | 0 |
| mssp636 | 13.4 | 6.9 | 4 | 0 |
| los952 | 4.3 | 12.7 | 5 | 0 |
| los956 | 1.9 | 7.0 | 7 | 0 |
| ymh1 | 17.3 | 15.4 | 4 | 0 |
| bears1 | 1.5 | 8.5 | 4 | 0 |
| badf1 | 1.0 | 6.8 | 4 | 0 |
| theo1 | 2.7 | 0.9 | 3 | 0 |
| wg1 | 3.6 | 16.9 | 5 | 0 |
| afs2 | 18.9 | 11.5 | 3 | 0 |
| chaos1 | 47.1 | 4.5 | 7 | 0 |
| bears2 | 31.0 | 34.5 | 4 | 0 |
| stavb199 | 0.0 | 29.1 | 0 | 0 |
| los957 | 52.7 | 58.0 | 10 | 0 |
| ct284 | 45.3 | 55.0 | 5 | 0 |
| ct262 | 0.0 | 0.0 | 8 | 0 |

Weights SHA-256:

- Resources/Detection/TaggerWeights-2.bin: 2d4e5d93bc7342a39bd1f8ec04c80f9ed0ea30f01d0973d5b820488fa7a0c78f
- Resources/Detection/TaggerWeights.bin: d6cf74e63ecd1cc62c3d710d85b09c8dcf737a87af71ee87b1b5ac0d75741fb5


## Current evidence policy regression

The current-policy run uses `LAB_NOMODEL=1 Scripts/run-four.sh` and the same shipped Reader weights/transcripts. It does not run fresh Apple Intelligence, Core AI, MLX, or live network comparison. Unversioned ad-free insertions and unverifiable positive fingerprints are retained as history but excluded from automatic cuts and detector evidence. The old `.cheap.json` cache is used only in explicitly requested historical mode.

All 17 fixtures completed; **16 still fail strict acceptance**. Results changed materially on several fixtures, including higher program-cut rates for `stav199`, `mssp633`, `mssp636`, and `theo1`. Removing stale structural evidence alone does not establish detector quality, and this batch must not be described as meeting the no-material-regression or false-cut goals. Apple Intelligence remains the default. Investigate changed regions and boundary/context decisions before any default change or Reader deployment.

Current summary: `build/detection-conservative-summary.log`; current per-fixture logs: `build/seg-<key>.log`. Both modes ask zero model questions. Timing below is Mac cached-detector work, not full episode processing or phone thermal evidence.

| Fixture | Ads heard, s/h | Program cut, s/h | Mac seconds |
|---|---:|---:|---:|
| stav199 | 8.7 | 14.5 | 5 |
| mssp633 | 2.7 | 6.7 | 3 |
| mssp636 | 14.1 | 10.8 | 4 |
| los952 | 5.0 | 13.4 | 5 |
| los956 | 0.4 | 7.0 | 6 |
| ymh1 | 17.3 | 15.4 | 4 |
| bears1 | 1.5 | 8.5 | 3 |
| badf1 | 2.8 | 7.1 | 4 |
| theo1 | 0.7 | 16.4 | 3 |
| wg1 | 3.6 | 16.9 | 3 |
| afs2 | 18.9 | 11.5 | 2 |
| chaos1 | 47.1 | 4.5 | 4 |
| bears2 | 31.0 | 34.5 | 3 |
| stavb199 | 0.0 | 29.1 | 0 |
| los957 | 52.7 | 58.0 | 8 |
| ct284 | 45.3 | 55.0 | 3 |
| ct262 | 0.0 | 0.0 | 3 |

The structural comparison tests prove rejection of malformed, shortened and unbracketed candidates in synthetic fixtures. A short interior program edit can still resemble an insertion, and sampling cannot prove every unsampled audio frame. This limitation and the measured Reader failures remain open acceptance items.

## Short brand boundary correction

The short-name matcher previously accepted word prefixes and substrings after removing every space. That extended the Star Wars advertisement into "start" in Theo's opening speech, and Quo into "quote" after its read. Short names now require an exact word or recognized domain; recognizer-split names join complete adjacent words. Existing longer compound-brand matching remains supported. No model, weights, prompts, semantic policy or default changed.

Six regression tests failed with seven assertions before the fix (`build/unit-brand-before.xcresult`). The combined 201-test suite then passed with zero failures (`build/unit-20261002-171745.xcresult`, copied console at the matching `.log`). Tests exercise exact/domain/split recognition and both directions of actual segment growth across ordinary speech.

All 17 fixtures were replayed from one compiled source snapshot, using the same copied transcripts, evidence and shipped weights, with zero model questions. Preserved pre-change logs/cuts are in `build/reader-conservative-baseline`; new logs/cuts and machine-readable summary are in `build/reader-brand-boundary`. The affected episode was checked first; the remaining replay reused that compiled binary. Only three fixtures changed cuts; the other fourteen have identical cuts (runtime text may differ).

| Fixture | Ads heard before → after, s/h | Program cut before → after, s/h | Strict failures before → after |
|---|---:|---:|---:|
| stav199 | 8.7 → 9.3 | 14.5 → 5.0 | 7 → 5 |
| theo1 | 0.7 → 2.3 | 16.4 → 2.5 | 5 → 4 |
| ct284 | 45.3 → 45.7 | 55.0 → 49.7 | 15 → 14 |

The changed regions remove ordinary speech after Quo, leave Theo's opening alone, and stop Ridge's closing read before the next program passage. Small remaining ad tails increase ads heard by 0.4–1.6 seconds/hour on these three fixtures; they remain documented rather than hidden by the false-cut improvement. No newly missed fixture ad or new wrong cut appears in this replay. **Sixteen fixtures still fail strict acceptance**; large errors elsewhere, funny-read handling, intro/outro distinctions and real/held-out episode quality remain unresolved. This is a bounded matcher correction, not a successful detector-quality gate.

`AdDetector.version` remains 25. Bumping it would enqueue all older completed episodes for automatic re-labelling and change the response checkpoint key despite identical model requests. This correction applies to new runs and explicitly requested reruns; it does not trigger bulk reprocessing, discard completed transcripts, or invalidate answers. A future broader detector-policy migration needs its own quality gate and resource/cancellation evidence.
