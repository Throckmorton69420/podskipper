# PodSkipper

A sideloadable iOS podcast player that transcribes episodes on-device and cuts the ads out — including host-read ones. No server, no API key, no subscription, no audio leaving your phone.

**This is a working skeleton, not a finished app.** Read "What this is and isn't" before you spend a weekend on it.

---

## What this is and isn't

**What's here and genuinely done:** the hard part. On-device transcription with timestamps, ad classification with a real prompt and a prefilter, boundary merging, a player that skips cleanly, background scheduling so processing happens overnight, and a UI that shows you where the cuts are so a bad one is visible rather than a mystery jump.

**What's missing** versus Apple Podcasts: CarPlay, Apple Watch, iCloud sync across devices, OPML import/export, a podcast directory search, chapters, silence trimming, voice boost, sleep timer, smart playlists, per-show playback settings, widgets, Siri and Shortcuts, and a background download manager that survives app termination. Each is anywhere from an afternoon to a week.

I'd rather hand you a solid 60% that compiles into something you'd actually use than a fake 100%. Apple has had fifteen years and a team on the other one.

**This code has never been compiled.** I don't have Xcode. Expect to fix API signatures on the first build — especially in `TranscriptionService.swift`, where `SpeechAnalyzer` is new enough that I'm working from documentation rather than from having run it. The architecture is sound; the exact method names may need nudging.

---

## Why this is possible now

Two iOS 26 frameworks changed the math:

**SpeechAnalyzer / SpeechTranscriber** replaced `SFSpeechRecognizer`. The old API capped you at roughly a minute per request and often round-tripped to a server. The new one is built for long-form audio, runs entirely on-device, and — critically — gives you word-level time ranges via the `.audioTimeRange` attribute. Without timestamps you have a transcript and no idea where the ads are.

**Foundation Models** gives you Apple's ~3B on-device LLM with guided generation, which constrains decoding so the model physically cannot return malformed JSON. That's what makes classification with a small model reliable enough to act on.

The binding constraint is that model's **4,096-token context window**. An hour-long transcript is roughly three times that, so it can't be classified in one shot. `TranscriptionService.windows()` slices it into overlapping 45-second windows and `AdDetector` classifies each independently — overlap matters, because an ad read straddling a boundary would otherwise look like half a sentence to the model on both sides.

A keyword prefilter runs before any inference, so only windows that look plausibly ad-like (plus their neighbours, plus the first and last 90 seconds) reach the model. That cuts inference calls by roughly an order of magnitude on a typical episode.

---

## Requirements

- **iPhone 15 Pro or newer.** Foundation Models needs Apple Intelligence. The app checks `SystemLanguageModel.default.availability` and tells you in Settings if it's unavailable, but there's no fallback path written — if you need one, WhisperKit plus a heuristic classifier is the usual substitute.
- **iOS 26 or later.** Non-negotiable; SpeechAnalyzer doesn't exist before it.
- **Xcode 26 or later on a Mac.**
- ~500 MB free for the speech model on first run.

---

## Building it

1. Xcode → **File → New → Project → iOS → App**. Name it `PodSkipper`, interface SwiftUI, storage **SwiftData**.
2. Delete the generated `ContentView.swift` and `PodSkipperApp.swift` — `Views/Views.swift` here contains the `@main` entry point.
3. Drag the `PodSkipper/` folder from this bundle into the project navigator, **Copy items if needed** checked.
4. Select the project → target → **Signing & Capabilities**:
   - Set your Team.
   - Change the bundle identifier to something unique to you, e.g. `com.yourname.podskipper`.
   - Add the **Background Modes** capability, tick **Audio, AirPlay, and Picture in Picture** and **Background processing**.
5. Target → **Info** tab → add an array key `BGTaskSchedulerPermittedIdentifiers` with one string item: `com.yourname.podskipper.process`. It must match `ProcessingPipeline.backgroundTaskID` exactly — update the constant in the code to match your bundle ID.
6. Build to your device. First launch will download the speech model.

---

## Signing and sideloading — read the cost part

Here's the thing worth knowing before you start: **Skipper costs $9.99 once. This costs $99 a year, or a chore every seven days.**

**Free Apple ID:** certificates expire after 7 days and you're capped at 3 sideloaded apps. When it lapses the icon stays on your home screen and tapping it does nothing until you re-sign. SideStore refreshes on-device over a local VPN so you don't need to plug into a laptop weekly, and LiveContainer works around the 3-app cap by running several apps in one signed slot — but nothing touches the 7-day clock.

**Paid Apple Developer Program, $99/year:** certificates last a year, the 3-app cap disappears, and you get 100 device registrations. This is the only genuinely set-and-forget option.

Do this because you want to build it and own it, not to save money. The money argument lost before you opened Xcode.

**A workflow that suits you specifically:** point a GitHub Actions workflow at this repo to build the `.ipa` on every push to main. Then you can pull a fresh build to your phone from the Actions artifact URL and import it into LiveContainer without touching the Mac at all. That's the same shape as the scheduled-workflow setup you already run.

---

## Where to go next, in order of payoff

1. **Feed refresh.** There's no background poll yet — new episodes only appear when you re-add a show. Add a `BGAppRefreshTask` that re-fetches each feed and enqueues new episodes.
2. **Resumable downloads.** `ProcessingPipeline.download` uses a simple `URLSession.download`. Move it to a background `URLSessionConfiguration` so a 90 MB episode survives the app being backgrounded.
3. **Correction feedback loop.** `AdSegment.userVerdict` exists and the player respects `.notAnAd`, but nothing writes it yet. Add swipe actions on the timeline. Then store confirmed sponsor names and short-circuit the model when the same sponsor recurs — that's how MinusPod gets faster over time, and it works just as well here.
4. **CarPlay.** `CPNowPlayingTemplate` plus a list template. Genuinely not much code once playback is solid.
5. **Fallback for older iPhones.** WhisperKit runs Whisper via CoreML and works well below the Apple Intelligence line.

---

## Legal note

This is for your own listening. Don't redistribute the app or the stripped audio. Podcast ads pay for podcasts, and most shows count a download whether or not you heard the ad — but a show you actually value is better supported by its paid ad-free feed than by anything in this repo.
