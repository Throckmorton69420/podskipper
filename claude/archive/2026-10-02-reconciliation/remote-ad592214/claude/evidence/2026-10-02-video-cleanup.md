# Video temporary-file safety — 2 October 2026

This batch follows `9343380` (short-brand boundary correction). It changes file lifetime and cleanup only; the previously inspected decoded-video/fullscreen/mode-switch tour remains separate evidence of playback rendering.

## Behavior

Launch video cleanup now enumerates off the main actor, then fetches current references and checks live owners in the same actor turn as each short unlink. It yields between chunks and refreshes references afterwards. Newly active downloads, queued processing, playback and publishing protect their files; unreferenced files wait while an owner may still be writing them. Direct download entry points retain episode ownership through their awaits. Extraction protects both source and destination until the exporter and final cleanup unwind, including cancellation.

Cleanup uses the existing direct-child regular-file deletion boundary. Paths outside the episodes folder, links and folders are refused. A missing source retires a stale reference without claiming freed bytes. Failed deletion keeps the reference and FileIndex entry; a successfully deleted legacy video points to its actual regular extracted audio when available. Transcripts, corrections, listening history and unrelated files are preserved. Enumeration and save failures are reported; temporary unlink failure is logged for later retry instead of pretending the file disappeared.

## Verification

All 212 combined unit tests passed with zero failures in `build/unit-20261002-173724.xcresult`; console copied to `build/unit-20261002-173724.log`. Eleven new cases use disposable files and in-memory SwiftData:

- Source/destination survive video housekeeping and global download cleanup while extraction owns them.
- Ownership introduced during directory enumeration and before a later unlink is respected.
- Failed unlink retains references/index while successful removal preserves extracted audio/transcript/history.
- Missing source, outside paths, links and directories produce truthful, scoped outcomes.
- Cancellation retains ownership until the simulated exporter returns and source cleanup completes; a late result cannot become success.
- Extraction failure removes only its owned source; failed source unlink retains its index for retry.
- Overlapping owners cannot release each other's episode/files; enumeration failure changes no references.

The initial compile found a Swift actor-isolation error in the default ownership closure; it was corrected before the successful combined run. This is not a phone test or an AVAssetExportSession cancellation measurement: exporter timing is injected to make the ownership race deterministic. Real phone download/extraction, system storage errors, thermal behavior, routes and PiP remain open. No live data operation, installation, signing change or merge occurred.
