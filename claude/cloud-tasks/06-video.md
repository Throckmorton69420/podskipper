# Cloud task 06 — Video: find it for every episode that has it, start in video, start fast

Branch: `cloud/video`. Read `CLAUDE.md` first. Can run in parallel with task 05 (different files). Don't edit the files task 05 owns (`ProcessingPipeline`, `SegmentDetector`, `AdDetector`, `NotificationService`, `ActivityView`, `DiagnosticsView`) or the `CLAUDE.md` list.

## Where things stand (catalog)

Phone-verified already: full-width video, tap artwork → video, full-screen, swipe down from full-screen. Built but unverified: feed video preference, Apple catalog fallback, YouTube last, picture-in-picture. **Open:** every episode that has video exposes it (PARTIAL); Stavvy's World #198/#199 and other missing-video cases; **always start in video**; **video startup lag**.

Code: `Services/VideoSourceResolver.swift`, `Services/VideoSync.swift`, `Services/YouTubeLink.swift`, `Services/MediaExtractor.swift`, `Services/FeedParser.swift`, `Views/PlayerViews.swift`, `Views/YouTubeWatchView.swift`, `Services/PlayerEngine.swift` (video parts only).

## His requirements (his words, condensed)

- Video should work like Apple Podcasts: one episode, one timeline; switch audio ↔ video without losing sync; the ad-free (cut) playback applies to video too; EQ/voice boost/smart speed still work while watching.
- Source priority: 1) the feed's native video (`podcast:alternateEnclosure` with HLS `.m3u8`, or a video `<enclosure>`), 2) another native video enclosure, 3) another legitimate public source, 4) YouTube last. Never reverse-engineer Apple's private HLS.
- Episodes with video show a small video icon + "Video" next to the date in lists, like Apple Podcasts.

## What to build

1. **Find video for every episode that has it.** Audit `FeedParser` for `podcast:alternateEnclosure` (all `podcast:source` children, pick HLS first), video MIME enclosures, and `media:content` video. For Stavvy's World (Simplecast) check what its RSS actually exposes for #198/#199 and document it in the PR; if the only source is YouTube, make the YouTube match reliable for it (title/number/date matching in `YouTubeLink`). Add a small unit-style test file with a sample feed snippet for each case if the project has a test target that CI builds; otherwise a `#if DEBUG` self-check.
2. **"Always start in video"** setting (global, default off) plus a per-show override on the show's settings screen from task 02 (`Views/ShowSoundView.swift` or the show settings it lives in): when on and the episode has video, playback opens in video.
3. **Startup lag.** Measure where time goes when switching to video (resolve source → load asset → first frame). Fixes: resolve the video source when the episode is loaded (not when video is tapped), cache resolved URLs on the episode, preload the `AVPlayerItem` (`preferredForwardBufferDuration`, `automaticallyWaitsToMinimizeStalling` tuned) while audio plays, keep the player layer alive between switches. Add timing lines to the background log ("Video ready in 0.8 s").
4. **Video icon + "Video"** label next to the date in episode rows when a video source is known.

## Done means

PR from `cloud/video`, CI green with zero warnings, and a PR description listing: what each feed exposes for Stavvy's World #198/#199 (and one Megaphone show), what's BUILT / UNVERIFIED, and exact phone tests (play Stavvy's World #199 → tap artwork → video appears within ~1 s, in sync; turn on Always start in video → next episode opens in video; audio settings still apply).
