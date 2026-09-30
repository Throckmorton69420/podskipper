> Superseded by task 15 (storage + video stream-only in one PR). Don't run this brief.

# Cloud task 13 — Video is streamed, never downloaded or kept

Branch: `cloud/video-stream-only`. Read `CLAUDE.md` first. Branch from current `main`. Coordinate with, don't rewrite, `Services/VideoSync.swift` (task 09, merged). Don't touch `Services/LocalModel/` or `ModelFinder.swift`.

His rule (30 Sep): video is streamed only, never downloaded. Task 07's notes say "video episodes still download first" — change that.

## What to build
- Find every path that downloads a video file (feed enclosures that are video — `Episode.isVideo`, the audio extraction at `ProcessingPipeline` ~line 631 `extractedAudioFilename`, auto-download, "Download" buttons, PrepareAhead, backups). 
- Playback of video always streams the remote URL (`publicVideoURL` / enclosure / HLS / YouTube as today). Downloads are audio only.
- For a show whose only enclosure is video, ad finding still needs audio: in order, (1) use an audio alternate enclosure if the feed has one (`podcast:alternateEnclosure`), (2) otherwise read only the audio track over the network if AVFoundation allows it without saving the video, (3) otherwise download to a temporary file, extract the audio, and delete the video file immediately (same job, even on failure/cancel). Never leave a video file in the app's storage. Say in the episode's status line which of these happened.
- A one-time cleanup that deletes video files already downloaded (keep their extracted audio), and logs how much space it freed in the background log.
- Settings text wherever downloads are described: "Video always streams; downloads are audio only."

## Done means
PR from `cloud/video-stream-only`, CI green, zero warnings. List every changed path. Phone test in the description: pick a video-only episode → Find Ads → it finishes; Settings → storage shows no video file for it; play in video → picture streams.
