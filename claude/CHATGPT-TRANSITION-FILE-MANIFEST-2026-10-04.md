# ChatGPT transition file manifest — 4 October 2026

This is the exact GitHub compare manifest from `ad592214ad6b5d56691f8a2792ac0cbe9e2990be` to remote PR head `252be96ae41ba1cdd93b8cca4304938905cdecee`.

**Transcript status:** the user subsequently supplied the complete ChatGPT/Codex thread export as an 80,123-line Markdown file. The remote compare below is exact for GitHub, while post-remote local-only work is documented separately below and in `CHATGPT-TRANSCRIPT-AUDIT-2026-10-04.md`.

Compare status: **ahead**, 6 commits ahead, 87 changed paths.

## Added files (46)

| Path | Additions | Deletions |
|---|---:|---:|
| `PodSkipper — Product Specification & Decisions.md` | 63 | 0 |
| `Services/CoreAIClassifierSession.swift` | 110 | 0 |
| `Services/CoreAIModelDownload.swift` | 129 | 0 |
| `Services/LocalModel/ModelAnswerFailure.swift` | 13 | 0 |
| `Tests/CoreAIModelDownloadTests.swift` | 115 | 0 |
| `Tests/ModelReadinessTests.swift` | 50 | 0 |
| `Views/ModelComparisonView.swift` | 238 | 0 |
| `claude/archive/2026-10-02-reconciliation/INTEGRITY.md` | 30 | 0 |
| `claude/archive/2026-10-02-reconciliation/README.md` | 11 | 0 |
| `claude/archive/2026-10-02-reconciliation/local-unpublished/claude/HANDOFF.md` | 69 | 0 |
| `claude/archive/2026-10-02-reconciliation/local-unpublished/claude/REQUEST-CATALOG.md` | 234 | 0 |
| `claude/archive/2026-10-02-reconciliation/local-unpublished/claude/evidence/2026-10-02-phone-regressions.md` | 40 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/ApplePodcastsReference/ios27.0/DISTILLED/README.md` | 19 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/CLAUDE.md` | 53 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/IMPLEMENTATION-PLAN.md` | 651 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/PLAIN-ENGLISH-GUIDE.md` | 1364 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/PUBLISHING.md` | 118 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/README.md` | 84 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/DETECTION-AUDIT.md` | 857 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/DEVICE-vs-SIMULATOR.md` | 485 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/HANDOFF.md` | 61 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/REQUEST-CATALOG.md` | 234 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-backup-restore.md` | 20 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-data-stations-checkpoints.md` | 30 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-delivery.md` | 42 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-destination-parity-a-critical.md` | 44 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-discovery-errors.md` | 19 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-next-audit.md` | 36 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-phone-baseline.md` | 22 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-processing-publishing-chapters.md` | 17 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-reader-regression.md` | 81 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-ui-tour.md` | 31 | 0 |
| `claude/archive/2026-10-02-reconciliation/remote-ad592214/claude/evidence/2026-10-02-video-cleanup.md` | 23 | 0 |
| `claude/cloud-tasks/README.md` | 5 | 0 |
| `claude/evidence/2026-10-02-catalogue-transactions.md` | 13 | 0 |
| `claude/evidence/2026-10-02-phone-regressions.md` | 44 | 0 |
| `claude/evidence/2026-10-03-build301-device-regressions.md` | 77 | 0 |
| `claude/reconciliation/EVIDENCE-AUDIT.md` | 122 | 0 |
| `claude/reconciliation/LATEST-DEVICE-FEEDBACK.md` | 28 | 0 |
| `claude/reconciliation/LEGACY-CROSSWALK.md` | 204 | 0 |
| `claude/reconciliation/MODEL-CANDIDATES.md` | 63 | 0 |
| `claude/reconciliation/RECONCILIATION-REPORT.md` | 198 | 0 |
| `claude/reconciliation/SOURCE-INDEX.md` | 178 | 0 |
| `claude/reconciliation/SUPERSESSION.md` | 35 | 0 |
| `claude/reconciliation/VALIDATION.md` | 14 | 0 |
| `claude/reconciliation/requirements.tsv` | 179 | 0 |

## Modified files (41)

| Path | Additions | Deletions |
|---|---:|---:|
| `.github/workflows/build-ipa.yml` | 4 | 86 |
| `ApplePodcastsReference/ios27.0/DISTILLED/README.md` | 2 | 0 |
| `CLAUDE.md` | 17 | 53 |
| `IMPLEMENTATION-PLAN.md` | 85 | 651 |
| `Models/Models.swift` | 11 | 3 |
| `PLAIN-ENGLISH-GUIDE.md` | 2 | 0 |
| `PUBLISHING.md` | 2 | 0 |
| `README.md` | 10 | 77 |
| `Services/CoreAIAdJudge.swift` | 103 | 22 |
| `Services/CoreAIModelLibrary.swift` | 74 | 29 |
| `Services/Diagnostics.swift` | 1 | 0 |
| `Services/LocalModel/JudgePrompt.swift` | 13 | 0 |
| `Services/LocalModel/LocalJudge.swift` | 23 | 8 |
| `Services/LocalModel/LocalModelSpec.swift` | 1 | 1 |
| `Services/LocalModel/ModelBench.swift` | 93 | 42 |
| `Services/LocalModel/ModelStore.swift` | 121 | 56 |
| `Services/ProcessingPipeline.swift` | 3 | 1 |
| `Tests/ModelBenchTests.swift` | 83 | 1 |
| `UITests/ScreenshotTests.swift` | 333 | 73 |
| `Views/ActivityNow.swift` | 40 | 45 |
| `Views/AudioControls.swift` | 77 | 67 |
| `Views/LocalModelView.swift` | 124 | 673 |
| `Views/PlayerViews.swift` | 81 | 53 |
| `Views/SettingsViews.swift` | 35 | 81 |
| `Views/Theme.swift` | 49 | 0 |
| `Views/WorkDetailView.swift` | 9 | 6 |
| `claude/DETECTION-AUDIT.md` | 2 | 0 |
| `claude/DEVICE-vs-SIMULATOR.md` | 2 | 0 |
| `claude/HANDOFF.md` | 36 | 43 |
| `claude/REQUEST-CATALOG.md` | 252 | 234 |
| `claude/evidence/2026-10-02-backup-restore.md` | 2 | 0 |
| `claude/evidence/2026-10-02-data-stations-checkpoints.md` | 2 | 0 |
| `claude/evidence/2026-10-02-delivery.md` | 2 | 0 |
| `claude/evidence/2026-10-02-destination-parity-a-critical.md` | 2 | 0 |
| `claude/evidence/2026-10-02-discovery-errors.md` | 2 | 0 |
| `claude/evidence/2026-10-02-next-audit.md` | 2 | 0 |
| `claude/evidence/2026-10-02-phone-baseline.md` | 2 | 0 |
| `claude/evidence/2026-10-02-processing-publishing-chapters.md` | 2 | 0 |
| `claude/evidence/2026-10-02-reader-regression.md` | 2 | 0 |
| `claude/evidence/2026-10-02-ui-tour.md` | 2 | 0 |
| `claude/evidence/2026-10-02-video-cleanup.md` | 2 | 0 |

## Removed files (0)

None in this compare window.

## Implementation commit 8698c0a — files requiring source-level review

The primary pushed implementation commit is `8698c0ab984a653a45df16bbe5c713a0db8cbd3e`. It changed these paths:

- `.github/workflows/build-ipa.yml`
- `Models/Models.swift`
- `Services/CoreAIAdJudge.swift`
- `Services/CoreAIClassifierSession.swift` **(new)**
- `Services/CoreAIModelDownload.swift` **(new)**
- `Services/CoreAIModelLibrary.swift`
- `Services/Diagnostics.swift`
- `Services/LocalModel/JudgePrompt.swift`
- `Services/LocalModel/LocalJudge.swift`
- `Services/LocalModel/LocalModelSpec.swift`
- `Services/LocalModel/ModelAnswerFailure.swift` **(new)**
- `Services/LocalModel/ModelBench.swift`
- `Services/LocalModel/ModelStore.swift`
- `Services/ProcessingPipeline.swift`
- `Tests/CoreAIModelDownloadTests.swift` **(new)**
- `Tests/ModelBenchTests.swift`
- `Tests/ModelReadinessTests.swift` **(new)**
- `UITests/ScreenshotTests.swift`
- `Views/ActivityNow.swift`
- `Views/AudioControls.swift`
- `Views/LocalModelView.swift`
- `Views/ModelComparisonView.swift` **(new)**
- `Views/PlayerViews.swift`
- `Views/SettingsViews.swift`
- `Views/Theme.swift`
- `Views/WorkDetailView.swift`

## Documentation checkpoint 252be96

`252be96ae41ba1cdd93b8cca4304938905cdecee` changed only:

- `IMPLEMENTATION-PLAN.md`
- `claude/HANDOFF.md`
- `claude/REQUEST-CATALOG.md`
- `claude/evidence/2026-10-03-build301-device-regressions.md` **(new)**

## Post-remote local-only continuation — NOT represented by the 87-path GitHub compare

The full transcript proves that ChatGPT/Codex continued after remote Build #303.

### Active UX4 checkout

Expected checkout:

`/Users/shashankpandya/Developer/podskipper-recovery`

Last transcript state:

- branch `codex/complete-project-recovery`;
- local HEAD `59c3afd0557d298137d26408e25b4a3e6d9c21c9`;
- **14 modified files + 5 untracked files**;
- parked catalogue stash preserved;
- work intentionally held while acceptance-enforcement infrastructure was being developed.

GitHub cannot resolve `59c3afd...`. The transcript does not provide a trustworthy final path-by-path snapshot of those 19 dirty/untracked paths after every subsequent edit. Therefore Claude must obtain the exact list from the live checkout rather than infer it from this remote manifest.

Known local-only work areas included player/video geometry, Activity, AudioControls/Speed & Audio, model comparison/download/runtime/recovery, tests and acceptance-related integration. Read `CHATGPT-TRANSCRIPT-AUDIT-2026-10-04.md` for the detailed scope and superseding user corrections.

### Separate acceptance-enforcement checkout

Expected checkout:

`/Users/shashankpandya/Desktop/2026-10-02/referenced-chatgpt-conversation-this-is-an/work/podskipper-acceptance`

Transcript branch: `codex/acceptance-gates`

Local commits named in the transcript:

- `6f30ce0`
- `cfebe4d`

Neither commit nor a matching remote acceptance branch is currently visible on GitHub.

A later final command attempted:

`git commit -m 'Repair acceptance gates and preserve bounded UX4 integration handoff'`

immediately before a usage-limit failure. **Do not assume that commit succeeded.**

The enforcement checkout itself needs forensic inspection before integration. Its first validator implementation was shown to allow five false acceptances; later repairs and adversarial tests were still draft because the dedicated simulator smoke lacked a completed receipt and an independent reviewer ran out of usage.

### Other local-only evidence

The named catalogue transaction stash, rollback artifacts and ignored build evidence are not represented by GitHub compare output. Preserve them and do not blindly pop/apply them over newer UX4 work.

## Interpretation rule

This file has two distinct purposes:

1. the tables above are the exact **remote GitHub** transition from `ad592214` to `252be96`;
2. the local-only section records that materially newer unpublished work exists and must be recovered from disk.

Do not overwrite the local checkouts with the remote branch simply because GitHub has a cleaner history.
