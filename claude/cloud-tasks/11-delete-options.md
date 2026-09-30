> Superseded by task 15 (storage + video stream-only in one PR). Don't run this brief.

# Cloud task 11 — Delete old Diagnostics logs; pick downloads and transcripts to delete

Branch: `cloud/delete-options`. Read `CLAUDE.md` first. Branch from current `main`. Don't touch `Services/LocalModel/`, `ModelFinder.swift`, `VideoSync.swift`, or the job logic in `ProcessingPipeline.swift`.

His words (30 Sep): delete older Diagnostics logs on the Diagnostics page; individually select downloaded episodes and transcripts to delete, and see their sizes.

## 1. Diagnostics page
- Show what the Diagnostics folder holds (`Diagnostics.folder`: background log, timings, MetricKit reports, exports) with sizes.
- "Delete Older Logs" with a choice (older than 1 day / 7 days / all) behind a confirmation that says exactly what goes. Never delete the current background log's last 150 lines unless "all" is chosen; the self-test line (`SelfTestRecord`) and the model's window cap (`Breadcrumb`) are settings, not logs — leave them.
- Refresh the sizes after deleting.

## 2. Downloads and transcripts (Settings → Storage, or wherever storage lives now — find it)
- A list of every episode with a downloaded file and/or a saved transcript: show, title, file size, transcript size, total at the top.
- Edit mode with multi-select (Apple-style `EditButton` + selection), and swipe-to-delete per row. Actions: "Delete Download" (audio/video file only; cuts and transcript stay), "Delete Transcript" (transcript + its word timings; the episode's cuts stay; say plainly that finding ads again will need a new transcription), "Delete Both".
- Sort by size / date / show. Never touch the currently playing episode's file without saying so; never touch files he saved outside the app.
- Keep the standing model from HANDOFF §10: this is separate from "Delete Stored Backup Data" and "Clear downloads"; each confirmation says exactly what it removes.

## Rules
- Whole-library work off the main thread (`LibraryIndex` or a limited `FetchDescriptor`); sizes computed in a detached task and cached per screen visit.
- Accessibility identifiers on every new control (`storage.*`, `diagnostics.*`).

## Done means
PR from `cloud/delete-options`, CI green, zero warnings. Description lists screens changed and the phone test: open Diagnostics → see sizes → delete older than 7 days → sizes drop; open storage list → select two episodes → Delete Download → space freed, cuts still shown, episode streams.
