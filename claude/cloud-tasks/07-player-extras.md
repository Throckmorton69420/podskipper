# Cloud task 07 — Player: "That was an ad", "Skip back", play before download, clip sharing

Branch: `cloud/player-extras`. Read `CLAUDE.md` first. Branch from current `main` (video task 06 is merged). Runs in parallel with task 05: **don't edit** the files task 05 owns (`ProcessingPipeline`, `SegmentDetector`, `AdDetector`, `NotificationService`, `ActivityView`, `DiagnosticsView`, the results export) or the `CLAUDE.md` list. Your files: `Services/PlayerEngine.swift`, `Services/PlaybackRequest.swift`, `Services/AudioEngine.swift` (only if needed for streaming), `Views/PlayerViews.swift`, `Views/SkipReportView.swift`, `Models/Models.swift`, new files.

All four are open rows in his request catalog. Keep each small, Apple-native, and in the player's existing style (Liquid Glass, subtle haptics like the rest of the player).

## 1. "That was an ad" (he heard an ad that wasn't cut)

- A button in the player's "…" menu and as a long-press option on the play position: **That was an ad**.
- It creates a new user-added segment of kind `.ad` covering the last 30 s before the play position (clamped to the episode), marked as his correction (`origin` = user, `verdict` = confirmed — use `Episode.apply(_:to:)` / the existing correction path, never set `segment.userVerdict` directly), then opens the existing "What was skipped" editor (`SkipReportView`) scrolled to it, so he can drag the edges to the real start and end.
- It is saved as a correction for that show (the same store the thumbs up/down use, `podcast.corrections`), so future ad finding learns from it.
- Playback jumps to the new segment's end.

## 2. "Skip back" (hear what was just skipped)

- When the player skips an ad, the existing skip notice (`lastSkip`) gets a **Skip back** button for 8 s: it jumps back to the skipped segment's start and plays through it once without skipping it again (that one segment only, until playback passes its end).
- If he then taps thumbs down (or "Not an ad") there, it goes through the existing correction path.

## 3. Play before download

- Today `load()` refuses an episode that isn't downloaded ("This episode isn't downloaded yet…"). Instead: start playing by streaming the enclosure URL right away (AVPlayer/progressive download), while the normal download continues; when the download finishes, switch to the local file at the same position with no audible gap.
- Ad skipping works during streaming if the episode already has cuts; otherwise it plays as-is (the existing "play without ads?" prompt still applies).
- Cellular: follow the app's existing download/cellular setting; if streaming isn't allowed on cellular, say so plainly.
- EQ and the audio repairs must still apply while streaming. If the current engine can't process a stream, say in the PR which parts don't apply while streaming and why.

## 4. Clip sharing

- Player "…" menu → **Share Clip**: a sheet with the waveform/timeline around the current position, draggable start and end (default: 30 s before to 30 s after, max 3 min), a play-preview button, and **Share**.
- Export: an `.m4a` with the ad cuts removed, the episode artwork as cover, and title "Show — Episode (mm:ss–mm:ss)"; shared through the system share sheet. Optional toggle "Include transcript text" adds the clip's transcript as text alongside.
- Export off the main thread (`AVAssetExportSession`); show progress.

## Done means

PR from `cloud/player-extras`, CI green with zero warnings, description with phone tests for each of the four (e.g. "Play any episode, tap … → That was an ad: a 30-s segment appears in What was skipped and playback jumps past it; drag its start earlier; play again: it's skipped").
