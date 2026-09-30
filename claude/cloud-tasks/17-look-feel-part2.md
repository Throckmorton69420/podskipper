# Cloud task 17 — Look and feel, part 2: Settings layout, the rest of the audit

Branch: `cloud/look-feel-2`. Read `CLAUDE.md` first. Branch from the latest `main` (PRs #12–#14 are merged). Same limits as task 16 (`claude/cloud-tasks/16-look-feel-parity.md`): don't touch `Services/LocalModel/`, `ModelFinder.swift`, the job logic in `ProcessingPipeline.swift`, `VideoSync.swift`. There is no `claude/HANDOFF.md` in the repo; this brief is the whole context.

## 1. Settings is hard to navigate (his words, 30 Sep)
"The settings page is not well organized and somewhat hard to navigate." A section index down the right edge now exists (`SettingsJump` in `Views/SettingsViews.swift`) — keep it working (update its cases if sections change).
- Reorganise like iOS Settings / Apple Podcasts settings: a short top level of clearly named groups (Playback, Ad Skipping, Downloads & Storage, Notifications, Library & Subscriptions, Backup, Diagnostics, About), with detail on pushed sub-pages rather than one very long list. Every existing control must still be reachable; nothing removed. Keep all accessibility identifiers (UI tests use them: `AdFreeCopyToggle`, `DiagnosticsLink`, `ShareDiagnostics`, `model.selfTest`, …).
- Footnotes: one short line each, under the control they explain.

## 2. The parts of task 16 not done in PR #14
Corner radii and empty states made consistent (`Views/Theme.swift` Metrics); swipe actions and context menus on episode/show rows compared with Apple Podcasts (`ApplePodcastsReference/ios27.2b2/DISTILLED/`, read only what you need, never copy Apple code/assets); show page header and episode page layout; Dynamic Type at the largest sizes without clipping; symbol effects on state changes; Reduce Motion respected; no `.blur`/`.saturation`/`.drawingGroup` in anything that redraws every frame.

## PR rules
His phone runs **iOS 27.0**; CI now selects the newest Xcode 27 on the runner. Rebase on `main` before opening the PR, open it ready for review (not draft), one CI check-in, fix any warning from PodSkipper code.

## Done means
PR from `cloud/look-feel-2`, CI green, zero warnings. Description: a before/after table per screen, and the phone test: find five settings by name using the new layout and the index; open Library, a show, an episode, Up Next at normal and the largest text size.
