# Shipped Reader baseline — 2 October 2026

All 17 fixtures completed. 16 failed the existing strict region/boundary acceptance; these results do not satisfy the quality goal. The per-hour figures are estimated against the existing word-anchored fixture labels. Interior advertisements joined into one break can also fail individual-boundary checks, so inspect affected regions as well as these totals. No catastrophic-minute-cut claim can be made from averages alone.

This run uses the shipped two-reader ensemble, existing copied transcripts/ad-free/fingerprint caches, zero model questions, and the unchanged detector from PR 21. It measures current in-sample fixture behavior; it does not establish held-out show quality or phone heat/runtime. Apple Intelligence remains the default.

Command: `Scripts/run-four.sh`; copied working cache `build/lab`; logs `build/seg-<key>.log`; summary `build/detection-recovery-summary.log`. The harness now loads app weights explicitly because a command-line executable has no app resource bundle, and returns failure when a fixture fails.

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
