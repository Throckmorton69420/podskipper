# Processing, publishing, chapter and playback verification — 2 October 2026

Code checkpoints: `37430af` (model snapshot/sample identity), `d95b821` (comparison/publishing), `6b2d987` (chapters/playback/accessibility). The combined source was verified before those local commits; they partition that same tested source. No merge or phone installation was performed.

## Automated verification

`Scripts/unit-test.sh` passed **106 tests, zero failures**, in `build/unit-20261002-043652.xcresult`. Preserved console: `build/unit-20261002-043652.log`. This includes 20 structural/fingerprint tests, 3 cached-cut safety tests, 21 publishing tests, 11 chapter service tests, actual short-audio chapter playback, 5 playback-intent tests, and the prior processing/backup/model suites.

Publishing tests exercise duplicate selected batches, interrupted-head relaunch, offline retries, sticky automatic cancellation, explicit retry, exact queue ownership/progress, pending detection reruns, stale upload cleanup, and per-invocation result summaries. Feed tests verify corrected-audio reuse, stable feed identity after show rename, previous feed members, transactional removal and cancellation. Corrupt/future/duplicate-ID/unsafe-order archives are preserved and block new work. These are injected disposable-data tests; actual R2 connectivity and phone background expiration remain unverified.

Chapter service tests cover add/edit/delete rollback, local corrections surviving publisher refresh even after the last chapter is deleted, Podcasting2.0 JSON/inline feed namespaces, URL/time validation, bounded embedded artwork and portable artwork paths. The short audio test verifies playback near the requested end position while allowing the measured engine output latency. It is not a device route test.

`ChapterEditorUITests/testAddEditCancelValidatePlayAndDeleteChapter` passed 116.199 s in `build/TR-recovery-chapters-modal.xcresult`; all 8 screenshots inspected at `build/shots-recovery-chapters-modal/named`. It exercises cancel, invalid artwork with a readable error and dismissed keyboard, stale-error clearing, add, exact title/time replacement, exact Quiet Hours episode near 45 s, delete confirmation and preservation of the empty local chapter list. The test resets only exact seeded demo GUID markers, never real library corrections.

## Remaining acceptance

Real feed/embedded-media chapter extraction, restored artwork after reinstall, large-text/VoiceOver chapter use, public streaming/fullscreen/PiP synchronization around cuts, countdown UI dismissal, actual publishing service/retry/auto-publish, and phone thermal/background/audio routing remain open. The 17 cached Reader fixtures still have 16 failures; see the separate regression report. None of these compilation/unit/UI results establish detection quality or whole-product completion.
