# Cloud task 03 — Old backups clean themselves up; interrupted transcription resumes

Branch: `cloud/backups-resume`. Read `CLAUDE.md` first. Two independent parts; do both in this branch.

## Part A — old backups pile up

Catalog: "Old backups pile up — PARTIAL: visible and deletable; nothing removes them automatically."

Code: `Services/BackupService.swift`, `Views/BackupViews.swift`.

1. A setting on the backup screen: "Keep the newest __ backups" (default 3; options 1, 2, 3, 5, 10, All).
2. After every successful backup the app makes, delete its own older backup files beyond that number. Only files the app itself created in its own backup folder — **never** anything he saved elsewhere (Files, iCloud Drive, AirDrop), never the backup just made, never one in use by a restore.
3. Show a one-line note after cleanup ("Removed 2 older backups, 1.4 GB freed").

## Part B — an interrupted transcription starts over from zero

When iOS ends a background window part way through transcribing, the next attempt transcribes the whole episode again, so a long episode can be stopped again and again and never finish (seen 29 Sep: nine attempts, each ended after ~4.5 min).

Code: `Services/TranscriptionService.swift` only (plus a new file if you want). **Do not edit `Services/ProcessingPipeline.swift`** — the Mac session will wire your new API in.

1. A new entry point, e.g. `transcribe(fileURL:checkpointKey:progress:)`, that saves what's been transcribed so far to a small checkpoint file in Application Support (lines + audio time reached) at least every ~60 s of audio and when cancelled.
2. On the next call with the same key, it loads the checkpoint and transcribes only from a little before the time reached (e.g. 5 s earlier, dropping duplicate overlapping lines), with timestamps continuing correctly (feed `SpeechAnalyzer` buffers read from `AVAudioFile` starting at that frame with the right start time — confirm the exact `SpeechAnalyzer` / `AnalyzerInput` API in Apple's docs).
3. On success, delete the checkpoint and return the full, time-sorted transcript — same shape as today's `transcribe(fileURL:)`, which must keep working unchanged.
4. A checkpoint older than 7 days, or for a missing file, is ignored and deleted.

## Done means

PR open from `cloud/backups-resume`, CI green with zero warnings. For Part B, state in the PR that it can only be verified on the phone after the Mac session wires it in, and give the exact function signature and how the pipeline should call it.
