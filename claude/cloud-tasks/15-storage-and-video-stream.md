# Cloud task 15 — Storage: delete what you pick, old logs, and never keep video

Branch: `cloud/storage`. Read `CLAUDE.md` first. Branch from current `main`. This task **replaces tasks 11 and 13** (do both, in one PR, in this order). Don't touch `Services/LocalModel/`, `ModelFinder.swift`, `VideoSync.swift`, or the job logic in `ProcessingPipeline.swift` beyond the video-download path named below.

Budget: this session has a small, fixed budget. Read files by section (grep first), don't read whole large files, don't run the full screenshot tour, and stop at a green, buildable PR. If you run short, finish part A cleanly and describe what's left of part B in the PR.

## Part A — delete options (his words, 30 Sep)
"Delete older Diagnostics logs on the Diagnostics page; individually select downloaded episodes and transcripts to delete, and see their sizes."
1. Diagnostics page: sizes of what `Diagnostics.folder` holds; "Delete Older Logs" (older than 1 day / 7 days / all) behind a confirmation saying exactly what goes. Leave the `SelfTestRecord` line and the `Breadcrumb` window cap (they're settings, not logs).
2. Storage (Settings → Storage): a screen listing every episode with a downloaded file and/or a saved transcript — show, title, file size, transcript size, a total at the top. Apple-style edit mode with multi-select plus swipe-to-delete. Actions: Delete Download (file only; cuts and transcript stay), Delete Transcript (say plainly that finding ads again will need a new transcription), Delete Both. Sort by size/date/show. Never touch files saved outside the app. Keep these separate from "Delete Stored Backup Data" and "Clear downloads".
3. Sizes computed off the main thread (a limited `FetchDescriptor`, `Task.detached`), once per visit.

## Part B — video is streamed, never kept (his rule)
1. Find every path that downloads a video file (`Episode.isVideo`, the audio extraction around `extractedAudioFilename` in `ProcessingPipeline`, auto-download, Download buttons, PrepareAhead). Downloads become audio only; video playback always streams.
2. For a show whose only enclosure is video: use an audio `podcast:alternateEnclosure` if the feed has one; otherwise download to a temporary file, extract the audio, and delete the video file in the same job (also on failure/cancel). Never leave a video file in the app's storage.
3. One-time cleanup: delete video files already downloaded (keep extracted audio); log the space freed in the background log.

## Done means
One PR from `cloud/storage`, CI green, zero warnings from PodSkipper's code, accessibility identifiers `storage.*` / `diagnostics.*`. PR description: every changed file, and the phone test — Diagnostics → Delete Older Logs (7 days) → sizes drop; Storage → select two episodes → Delete Download → space freed, cuts still shown, episode streams; a video-only episode → Find Ads finishes and Storage shows no video file for it.
