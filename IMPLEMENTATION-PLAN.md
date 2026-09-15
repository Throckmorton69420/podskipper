# PodSkipper — Implementation Plan

The live backlog and phase order. Updated as work lands; this file, not a
snapshot in the project instructions, is the record of what remains.

Reference of record: the extracted **Apple Podcasts, iOS 27.0 RC, build 24A435**
app bundle. Everything attributed to Apple below was read out of that bundle,
not recalled.

---

## 0. Status — verified against the code, not against memory

Last audited at `a821d83`. Every line below was checked by reading the source,
because the summaries had drifted from the truth in both directions.

**32 planned items: 13 done · 2 written but unverifiable without a device ·
8 partial · 8 not started · 1 unknown.**

| | Item | State |
|---|---|---|
| 1 | Playback state machine (`PlaybackPhase`) | **done** |
| 2 | AVAudioSession, Now Playing, AirPods | written — device only |
| 3 | External playback synchronisation | written — device only |
| 4 | Crash / relaunch restore | **done** |
| 5 | Artwork cache (`ArtworkStore`) | **done** |
| 6 | Per-episode processing state | **not started** — still one global `currentEpisodeGUID` |
| 7 | Scroll and navigation profiling | partial — decode moved off the main actor, never profiled |
| 8 | Two-column library grid | **done** |
| 9 | Persisted sort + filter, "Filtered by" chip | partial — filter persists per show; **sort does not**; no chip |
| 10 | Episode row that adapts | **done** |
| 11 | Freshness replacing "100 new" | **done** |
| 12 | Bottom Now Playing bar + marquee | **done** |
| 13 | Selection state + batch actions | **not started** — no selection state exists |
| 14 | Per-show "Default (…)" three-state | partial — speed and one toggle only |
| 15 | Play-without-processing countdown | **done** |
| 16 | Ad-skip toggle in the player | partial — exists, was not gated on the episode being processed |
| 17 | Segment-typed timeline, tap-to-inspect, precision scrub | partial — colours only until now; see B2 |
| 18 | Separate intro and outro toggles | **done** |
| 19 | Conservative / Balanced / Aggressive | **done** |
| 20 | Background pre-processing of the next ~2 | partial — processes **one**, and only when idle |
| 21 | Autoplay state machine + ordering | partial — ordering fixed; no prompt for an unprocessed next episode |
| 22 | De-esser, Enhance Dialogue, bass, mud | **done** |
| 23 | Speech-tuned EQ presets | **done** |
| 24 | Speed and Audio sheet | **done** |
| 25 | Data-driven shelf renderer | **not started** |
| 26 | Real category destination pages | **not started** |
| 27 | Favourite categories | **not started** |
| 28 | Apple Podcasts migration investigation | **not started** |
| 29 | Publishing fixes, no duplicate processing | unknown — never verified |
| 30 | Scroll-driven polish effects | **not started** |
| 31 | Density and scale pass | partial |
| 32 | Performance and regression pass | **not started** |

Outside the 32, still outstanding from earlier: **widgets, Live Activities and
CarPlay**; **video podcast support** (code paths exist, never run); per-show
"Remove Played Downloads".

---

## 1. Current architecture

**Data.** SwiftData. `Podcast` → `Episode` → `AdSegment`, plus `Chapter`,
`ListeningSession`, `AppSettings`. Segments are typed (`ad`, `self-promo`,
`other-show-promo`, `intro`, `outro`, `content`) and each type has its own skip
toggle resolved episode → show → default. One shared `ModelContainer`, published
at launch through `AppLibrary` so intents and background work never build a
second, detached one.

**Playback.** `PlayerEngine` — a `@MainActor @Observable` singleton — owns an
`AudioEngine` (AVAudioEngine graph: Smart Speed, voice boost, 10-band EQ,
sample-accurate seek) and a `VideoEngine` (AVPlayer + AVPlayerLayer + PiP),
both behind the `PlaybackEngine` protocol. Ad skipping is seeking, so it is
identical on both paths. Playhead writes are accumulated in memory and flushed
every 5s and on every transport event — the fix for the original navigation lag,
which was `tick()` writing to SwiftData five times a second and invalidating
every `@Query` in the app.

**Processing.** `ProcessingPipeline` — also a `@MainActor @Observable`
singleton — with a `Stage` enum (`idle` → `downloading` → `transcribing` →
`detecting` → `analyzing` → `saving`), weighted progress and an ETA. Behind it:
`TranscriptionService` (actor), `AdDetector` (actor, FoundationModels with
`@Generable` verdicts), `AudioAnalyzer` (silence), `MediaExtractor` (video →
m4a so transcription can run), `AudioCutter`.

**Persistence of playback.** `PlaybackState` writes guid + position + rate to
`UserDefaults` on every transport event, so a crash is survivable.

**Discovery.** `TasteProfile` builds a taste vector from NaturalLanguage
sentence embeddings weighted by actual listen-through; `DiscoverService` and
`PodcastSearch` do catalog lookup. Nothing leaves the device except genre names.

**Surface.** `Views/Theme.swift` is the single design-token source (`Metrics`,
`SectionHeader`, `AdaptiveRow`, `ArtworkBackdrop`, `AmbientArtwork`).
`LibraryViews`, `PlayerViews`, `DiscoverViews`, `PublishView`, `SettingsViews`,
`QueueViews`, `FilterViews`, `StatsViews`. XcodeGen `project.yml`; CI on
`macos-26`; `UITests/ScreenshotTests.swift` drives the screenshot workflow.

---

## 2. Current problems

Ordered by how much else depends on them.

**P1 — Playback state is a Boolean, not a state machine.** `PlayerEngine`
exposes `isPlaying: Bool`, with `loadError: String?` as a separate side channel.
There is no representation of *loading*, *buffering*, *interrupted*, or *failed*.
Nearly every reported playback bug is a direct consequence:

- AirPods pause works but resume does not — an `AVAudioSession` interruption
  with `.shouldResume` has nowhere to be recorded, so nothing knows it may
  resume.
- The Lock Screen shows a pause icon while the progress bar does not advance —
  `MPNowPlayingInfoCenter` is written from `isPlaying` and from the engine's
  real rate at different moments, and they disagree.
- Another app starts playing: PodSkipper stops, but the UI still shows pause —
  the engine stopped, `isPlaying` did not.

**P2 — Processing state is global, not per-episode.** `ProcessingPipeline` has
one `currentEpisodeGUID` and one `isRunning`. A batch, or background
pre-processing of the next two episodes, cannot be represented at all. Progress
also drives `@Observable` updates at whatever rate the stage reports, which is
the likeliest cause of the UI freezing during ad removal.

**P3 — No selection state.** Batch actions (mark played/unplayed, process,
download, delete, queue) have nowhere to live.

**P4 — No autoplay state.** `queueProvider` is a closure returning the next
episode; there is no notion of *waiting*, *processing the next one*, or *ready*,
and no correct ordering rule when the list is sorted newest-first.

**P5 — Sort and filter are view-local.** Choosing "Unplayed", leaving the show
and returning reverts to "All Episodes" because the choice was never persisted.

**P6 — Artwork loading is not a cache.** Icons disappear after Find Ads, which
points at images being re-fetched or re-decoded on view identity change rather
than held in a keyed store.

**P7 — Now Playing widget opens the wrong app.** Tapping it opens KSign. This is
almost certainly a `MPNowPlayingInfoCenter` / `nowPlayingInfo` ownership problem
or a sideloading artifact of how the app is signed, not a SwiftUI problem. It
needs diagnosing on device before a fix is designed.

**P8 — Library grid renders one column on iPhone.** Should be two.

**P9 — "100 new" is meaningless.** Every unplayed episode counts as new, so a
freshly followed show reads "100 new".

**P10 — Episode row does not adapt.** "Find Ads" clips when the duration string
is long (`1h 54m` vs `54m`); the three-dot is not stably right-justified.

**P11 — Bottom Now Playing bar is too small**, and its progress bar overlays the
artwork and title. The title does not scroll.

**P12 — Ad settings are not understandable.** "Minimum confidence: 60" means
nothing to a listener. Intro and outro share one toggle.

**P13 — Timeline is not legible.** It does not communicate which spans are ads
vs promos vs intro/outro, where they start and end, or how long they are.

**P14 — Category selection draws an outline, not a page.** No real category
destination exists.

**P15 — Publishing re-runs ad detection** on already-processed episodes, and
tapping an episode on the Publish tab does not open the player correctly.

**P16 — Overall scale and density still under Apple's**, unevenly.

---

## 3. Apple Podcasts behaviours worth adopting

Read out of the reference bundle (`Localizable.loctable`, 2157 English strings).

**Freshness.** Apple's format is `NEW_EPISODES_AND_LAST_UPDATED_DATE_FORMAT` =
`"%@ · %d new"` — last-updated date *and* a new count, where "new" means new
since you last looked, not "unplayed". That is the fix for P9: keep a per-show
`lastSeenAt`, count against it, and lead with the date.

**Sort and filter are separate controls.** `EPISODES_SORT_BUTTON` "Sort" and
`EPISODES_FILTER_BUTTON` "Filter". Episode sorts: Newest to Oldest / Oldest to
Newest, Date Published, Date Downloaded, Date Saved. Show sorts: Recently
Updated, Title, Date Added, Date Followed, Manual, Group By Show. An active
filter is shown inline as a chip —
`EPISODE_FILTER_INFO_COMPOUND_FORMAT` = `"{{symbol:line.3.horizontal.decrease}} Filtered by: %@"` —
with `CLEAR_ALL_FILTERS` available. Adopt the chip: it makes a persisted filter
visible instead of mysterious.

**Batch actions scoped to the filter.** `MARK_FILTERED_AS_PLAYED` /
`MARK_FILTERED_AS_UNPLAYED` — act on what is currently shown, not on a
hand-built selection. Worth having *alongside* explicit selection, not instead
of it. Selection vocabulary: "Edit" to enter, "Select All" / "Select None",
`ONE_SELECTED_FORMAT` = "1 Selected".

**Per-show overrides are three-state and labelled with the resolved default.**
`SHOW_SETTINGS_HIDE_PLAYED_EPISODES_DEFAULT_OFF` = "Default (Off)", alongside
explicit "On"/"Off". Entering a custom value prompts "Save custom settings for
this show?" and the show then reads "Custom settings will be used when playing
episodes of %@". This is exactly PodSkipper's episode → show → default
resolution, and it gives the right label format for every per-show toggle.

**Audio adjustments live in one sheet with plain-English names.** Apple's screen
is "Speed and Audio Adjustments" / "Adjust Speed and Clarity", described as
"Find the perfect speed between 0.5–3× and hear voices more clearly." Its voice
control is called **"Enhance Dialogue"**. Adopt both the grouping and the
naming: PodSkipper's de-esser, clarity, bass and mud controls belong in that
sheet, named for what they do, with the numbers on an advanced screen.

**Precise scrubbing is rate-based, not magnification.** Apple announces
"Hi-Speed Scrubbing", "Half-Speed Scrubbing", "Quarter-Speed Scrubbing" —
dragging vertically away from the bar reduces the scrub rate. That answers the
open question about how iOS does timeline magnification: it does not. Adopt
rate tiers for precision, and use tap / long-press for segment inspection.

**Autoplay is "Continue Playing"** — "Continue playing after an episode ends."
`SMART_PLAY_BUTTON_PLAY_NEXT_EPISODE` = "Play Next Episode".

**Queue vocabulary:** Up Next, Playing Next, Play Next, Play Last, Add to Queue,
Remove from Up Next, and a "Now Playing" section header inside the queue.

**Discovery is category-first and personalised.** Apple has Favorite Categories
chosen at onboarding and synced, "Manage Favorite Categories", "See All %d
Categories", "Find in Categories", plus Top Charts. The shelf architecture is a
separate framework (`ShelfKit`, `ShelfKitCollectionViews`) — horizontal rows of
typed cards, composed from a feed, not hard-coded per category. PodSkipper's
category pages must be built the same way: one data-driven shelf renderer, many
section types. Never a hard-coded Comedy page.

**Empty states are written, not blank.** "All Caught Up", "No New Episodes",
"Your Queue is Empty", "Check back later to see if any new episodes have been
added."

---

## 4. PodSkipper-specific improvements

These have no Apple analogue and are the reason the app exists. They must not be
diluted in the pursuit of parity.

- **Play without processing.** A Play on an unprocessed episode offers "Play
  without processing" vs "Find ads first", with a 5-second countdown defaulting
  to plain playback. Silence must be the safe answer.
- **Ad-skipping toggle in the player** — hear the unmodified episode without
  reprocessing it.
- **Segment-typed timeline** — ads, self-promo, other-show promo, intro, outro,
  each visually distinct, with boundaries and durations readable.
- **Conservative / Balanced / Aggressive** in place of "Minimum confidence: 60",
  each with a plain-English sentence. The number survives on an advanced screen.
- **Separate intro and outro toggles.**
- **Background pre-processing of the next ~2 episodes**, so autoplay is not a
  wait.
- **Never re-detect** an already-processed episode when publishing.
- **Audio repair for speech**: reduce sibilance, enhance dialogue, reduce boom,
  reduce boxiness — each labelled for the symptom, not the filter.
- **Migration from Apple Podcasts** — see the honest limits in §7.

---

## 5. Dependencies

```
P1 playback state machine
 ├── AirPods resume, Lock Screen accuracy, external-audio sync
 ├── crash recovery (needs a state to restore *into*)
 ├── autoplay state machine (P4) — needs "ended" to be a state, not a callback
 └── ad-skip toggle + play-without-processing (both change what plays mid-session)

P2 per-episode processing state
 ├── batch processing (P3)
 ├── background pre-processing → autoplay readiness (P4)
 ├── per-row progress without a global banner
 └── no-duplicate-processing on publish (P15)

P3 selection state ──── batch actions ──── filter-scoped batch actions

P5 persisted sort/filter ──── the "Filtered by" chip ──── two-column grid (P8)
        (all three are the same Library rework)

P6 artwork cache ──── everything visual; do it before the density pass

Shelf renderer ──── category pages ──── Discover ──── recommendations surface

Density/scale pass (P16) and the polish effects come LAST — they are cheap to
redo and expensive to do twice, and every phase above changes layout.
```

The brief's suggested order is sound and I am keeping it, with one change:
**artwork caching (P6) moves earlier**, into the first foundation chunk rather
than after performance work. Icons vanishing is the most visible defect in the
app, its fix is self-contained, and every screenshot used to verify later phases
is misleading while it persists.

---

## 6. Recommended order

Each chunk is a complete, buildable set of files. Push, then run the app build
workflow, then the screenshots workflow.

### Phase 1 — Foundation
1. `PlaybackState` machine — `idle / loading / playing / paused / buffering / interrupted / stopped / failed`, one authoritative value in `PlayerEngine`. Every writer (remote commands, interruptions, route changes, errors, end-of-episode) writes to it; every reader — UI, Now Playing, widgets — reads from it.
2. AVAudioSession + Now Playing + AirPods: interruption `.shouldResume`, route-change handling, `MPNowPlayingInfoCenter` written from the single state.
3. External playback synchronisation (falls out of 1–2).
4. Crash/relaunch restore into the state machine, resumable from the bottom bar.
5. Artwork cache — one keyed, size-aware store; decode off the main actor.
6. Per-episode processing state + get processing off the UI update path.
7. Scroll and navigation profiling pass against the result.

### Phase 2 — Core podcast UX
8. Two-column library grid.
9. Persisted sort + filter per show, with the "Filtered by" chip.
10. Episode row that adapts to any title, duration and state; three-dot stably right-justified.
11. Freshness replacing "100 new".
12. Bottom Now Playing bar: larger, progress separated from artwork and title, marquee title.
13. Selection state + batch actions, including filter-scoped mark-as-played.
14. Per-show settings with "Default (…)" three-state overrides.

### Phase 3 — Processing UX
15. Play-without-processing prompt with the 5-second countdown.
16. Ad-skipping toggle in the player.
17. Segment-typed timeline with rate-tiered scrubbing and tap-to-inspect.
18. Separate intro and outro toggles.
19. Conservative / Balanced / Aggressive.
20. Background pre-processing of upcoming episodes.
21. Autoplay state machine with correct next-episode ordering.

### Phase 4 — Audio
22. De-esser, Enhance Dialogue, bass/boom reduction, mud reduction.
23. Expanded speech-tuned EQ presets.
24. The "Speed and Audio" sheet in the player.

### Phase 5 — Discovery
25. Data-driven shelf renderer.
26. Real category destination pages built on it.
27. Explore More Categories, favourite categories.

### Phase 6 — Migration and publishing
28. Apple Podcasts history investigation (see §7).
29. RSS / publishing workflow fixes; episode tap opens the player; no duplicate processing.

### Phase 7 — Polish
30. Scroll-driven animation, focal-point highlighting, ambient glow, parallax.
31. Final density and scale pass against the reference bundle.
32. Full performance and regression pass.

### Still outstanding from before
Widgets, Live Activities, CarPlay — a new extension target in `project.yml`,
its own chunk, after Phase 3.

---

## 6b. Reported and open — device testing

Confirmed fixed **on a phone**: the Now Playing title scrolls; the outro is
being cut; the Barstool Sports discussion is no longer cut; the player's top
corners are no longer cut (`9aa8f7a`).

| | What | Where it stands |
|---|---|---|
| B1 | Skip Ads / Skip Intro / Skip Outro appear on an episode that has never been processed. Wanted: a Find Ads control in the player instead, its progress shown there, and the switches appearing only once it finishes. | fixed, not yet confirmed on device |
| B2 | The timeline does not say which span is an ad, an intro, self-promotion or an outro. Wanted: touch a marked span to see its name, hold to crop the scale around it for fine scrubbing. | fixed, not yet confirmed on device |
| B3 | The player's top-left and top-right corners are cut off. | **fixed and confirmed on device** at `9aa8f7a`. It was geometry, not clipping — see `claude/DEVICE-vs-SIMULATOR.md` §5 |
| B4 | Tapping the Lock Screen Now Playing widget does nothing. | **open** — device-only diagnosis. Note it opening KSign is a sideloading artifact and will behave correctly through TestFlight |
| B5 | Endless low vibration after pressing previous at the start of the ad-free part. | fixed — `ClosedRange` contains its own `upperBound`, so seeking to the end of an ad landed back inside it. Same bug existed silently in the Smart Speed path |
| B6 | Batch selection and batch actions. | **open** — item 13 |
| B7 | Search and Discover are undercooked. | **open** — items 25–27 |
| B8 | Countdown when play is pressed before Find Ads has run. | fixed — the `isDownloaded` guard meant the question was skipped precisely when it mattered |
| B9 | The ambient player background is slow, low-res and boxy-pixellated on device, though clean in the simulator. | fixed — the full-screen per-frame `.blur` was Core Animation's downsampled gaussian. Blur, saturation and brightness are now baked into the source once with Core Image and the frame loop is transforms only |
| B10 | The ⋯ menu ghosts, flickers and needs two or three taps. | fixed — `PlayerView`'s body read the playhead, so the menu's contents were rebuilt five times a second. The scrubber and the Smart Speed line are now their own `View` types |
| B11 | The timeline looks "choppy", as though hundreds of things were removed, on an episode where only a 46-second intro was cut. | fixed — `rebuildMarkers()` was drawing every measured silence as a blue bar. Silences are an input to Smart Speed, not removed content, and are no longer drawn |
| B12 | A cut is nearly invisible on the timeline. | fixed — a fixed-size down-pointing tick now sits over every active cut, whatever the zoom |
| B13 | The what-was-skipped page shows no transcript, has plus/minus buttons instead of trim handles, and "Listen" requires toggling Skip Ads off by hand. | fixed — a Photos-style trim strip with draggable handles over a speech-density texture; a preview player that suspends *all* skipping for one stretch and puts the playhead back afterwards; a large transcript that follows along and says "music, a sting or silence" when there are no words |
| B14 | Thumbs up / down appear to do nothing. | fixed — corrections are now filed against the **show** and folded into the detector's instructions as worked examples on the next run, the same mechanism `knownSponsors` already uses. Before this they only stopped one segment being skipped in one episode |
| B15 | `.opml` files are no longer greyed out but still cannot be picked. | fixed, **unverified** — three changes: the declared type moved out of the reserved `public.` namespace to `org.opml.opml`; `.item` added to the allowed types so nothing can be dimmed; the read is now security-scoped *and* file-coordinated with an iCloud download, and any failure is shown in an alert instead of a grey footnote |
| B16 | The minimised now-playing bar is too small to read. | **open** |
| B17 | The bottom translucent bar grows above the now-playing box and shrinks back when scrolling to the top. | **open** |
| B18 | Publish: re-processes an already-processed episode; the ad-free feed should be one link per show with a podcast-page-like view. | **open** — partially addressed (the filter no longer defaults to an empty tab, and a published episode no longer offers a live Publish button) |

---

## 7. Risks and technical limitations

**The compiler is on the Mac, not in the sandbox.** `./Scripts/local-build.sh
build` is about fifty seconds and is the real check; the Linux parser catches
syntax only, and every build failure this project has hit was a type or scope
error invisible to it. CI is the ship gate, watched with
`./Scripts/watch-ci.sh`, not the development loop.

**The Mac is on Xcode 27 and CI is on `macos-26`.** Since the Xcode 27 update
the two are no longer compiling against the same SDK, so a green local build is
no longer quite the same evidence it was. If a divergence ever appears, pin the
runner rather than guessing which one is right. An Xcode update also resets its
licence, which blocks `xcodebuild` *and* `git` (the macOS `git` is an Xcode
shim) until `sudo xcodebuild -license accept` is run — that needs a person.
`/Library/Developer/CommandLineTools/usr/bin/git` still works in the meantime.

**No real hardware has ever run this app.** Everything verified so far is
simulator screenshots against demo data. Battery, overnight background survival,
AirPlay and Bluetooth routing, and real transcription speed are all unverified.
Several Phase 1 items — AirPods resume, the Now Playing widget target, route
changes — **cannot be verified in the simulator at all**. They will be
implemented to the documented contract and must be flagged as unverified until
run on a device.

**Apple Podcasts migration is probably not possible.** iOS gives no third-party
app access to another app's played state, positions, or subscriptions; the
Podcasts database is inside its own container. The realistic paths are OPML
export of subscriptions (which carries no played state) and a Shortcuts-driven
export if one exists. This will be investigated and reported honestly rather
than promised.

**The Now Playing widget opening KSign** may be an artifact of how the app is
signed and sideloaded rather than an app bug. Diagnose before designing a fix.

**Foundation Models availability** varies by device and language. Detection must
degrade to the transcript-and-silence path rather than fail.

**Per-frame scroll effects are a real cost.** Phase 7's effects go on a list
that must stay at 120 Hz; each one is profiled after it lands, and anything that
costs a frame comes back out.

---

## 8. Testing strategy

Every feature is exercised in both the normal and the interrupted case.

**Per chunk:** parse-check every changed file; grep for the old identifier after
any rename; run the repo's CI guards; push; read the build log; run the
screenshot workflow; look at the images before claiming anything.

**Interrupted cases to cover, by phase:**

- *Phase 1:* processing while navigating; processing while playing; another app
  taking the audio session; backgrounded during processing; terminated during
  processing; relaunched after playback; AirPods pause/resume; Lock Screen
  play/pause; route change mid-episode.
- *Phase 2:* long titles; long durations (`1h 54m`); changing sort and returning
  later; changing filter and returning later; artwork loading during processing;
  a show with zero episodes; a show with 500.
- *Phase 3:* autoplay when the next episode is processed; when it is not; batch
  processing several episodes; cancelling mid-batch; partial failure in a batch.
- *Phase 5:* category navigation with a slow or failed catalog response.
- *Phase 6:* publishing an already-processed episode.

**What cannot be tested here**, and must be reported as such every time: any
behaviour requiring real hardware, real Bluetooth, a real Lock Screen, or real
background execution over hours.
