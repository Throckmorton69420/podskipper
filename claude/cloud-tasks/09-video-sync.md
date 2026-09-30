# Cloud task 09 — Video in sync with the sound, and a faster switch to video

Branch: `cloud/video-sync`. Read `CLAUDE.md` first. Branch from current `main`. Files: `Services/VideoSync.swift`, `Services/VideoSourceResolver.swift`, `Services/PlayerEngine.swift` (video parts only), `Services/AudioEngine.swift` (latency reporting only), `Views/PlayerViews.swift` (video surface only). Don't touch `Services/LocalModel/`, `ModelFinder.swift`, `ProcessingPipeline.swift`.

## His phone report (30 Sep, build f1566fe, iPhone 16 Pro, often on Bluetooth headphones)

1. "When switching to the video for a podcast, there's a noticeable lag."
2. "The audio is slightly delayed / out of sync with the video" — the picture is ahead of the sound.
3. "The app starts off a bit slow" (launch).

## Likely causes to check first (confirm in code before changing)

- Sound plays through PodSkipper's `AVAudioEngine` (EQ, ad cuts) while the picture is a muted `AVPlayer` kept at the same *media* time. That ignores output latency: `AVAudioSession.outputLatency` + `ioBufferDuration` + the engine's own buffering — ~10–40 ms on the speaker, **~150–300 ms on Bluetooth**. So the picture runs ahead by exactly that. Fix: hold the video back by the measured latency (recompute when the route changes — `AVAudioSession.routeChangeNotification`), and sync with host time (`AVPlayer.setRate(_:time:atHostTime:)` against the audio engine's render host time) rather than seeking. Correct drift gently (small rate nudges, e.g. 0.98–1.02×, for drift < 0.25 s; seek only above that). Never seek the audio to follow the video.
- Ad cuts: when the sound jumps over a cut, the picture must jump with it in the same moment (a pre-rolled seek to the cut's end, then `setRate(atHostTime:)`).
- Switching lag: task 06 preloads while the app is on screen. Check it actually happens (source resolved at episode load, `AVPlayerItem` created and `preroll(atRate:)` done, layer kept mounted), that the first frame isn't waiting for a seek to complete with zero tolerance (use a small tolerance, then correct), and that a YouTube source doesn't re-resolve every time.
- Launch: find work done at launch on the main thread (model download start is already delayed 5 s; check library index building, artwork, feeds, SwiftData fetches, the reader's weights, MLX initialisation). Move it after the first frame and off the main thread. Log "Launch: first screen in N ms" to the background log.

## Also

- Add Diagnostics numbers: measured output latency and route name, video offset applied, drift corrections per minute, "Video ready in N s".
- Keep EQ/repairs working while watching.

## Done means

PR from `cloud/video-sync`, CI green (zero warnings from PodSkipper's code), description listing each cause found (with file/line) and the fix, plus phone tests: speaker and Bluetooth — watch lips for 2 minutes, skip over an ad, switch audio↔video 5 times; report "Video ready" times from the log.
