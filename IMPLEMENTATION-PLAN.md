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
| 7 | Scroll and navigation profiling | partial — decode, silence analysis and transcript encoding off the main actor; processing progress throttled to 4 Hz (B113); never profiled on a device |
| 8 | Two-column library grid | **done** |
| 9 | Persisted sort + filter, "Filtered by" chip | partial — filter persists per show; **sort does not**; no chip |
| 10 | Episode row that adapts | **done** |
| 11 | Freshness replacing "100 new" | **done** |
| 12 | Bottom Now Playing bar + marquee | **done** |
| 13 | Selection state + batch actions | written — show page selection mode, see B6; publish queue B31 |
| 14 | Per-show "Default (…)" three-state | partial — speed and one toggle only |
| 15 | Play-without-processing countdown | **done** |
| 16 | Ad-skip toggle in the player | partial — exists, was not gated on the episode being processed |
| 17 | Segment-typed timeline, tap-to-inspect, precision scrub | partial — colours only until now; see B2 |
| 18 | Separate intro and outro toggles | **done** |
| 19 | Conservative / Balanced / Aggressive | **done** |
| 20 | Background pre-processing of the next ~2 | written — see B20, B29 |
| 21 | Autoplay state machine + ordering | written — prompts for an unprocessed next episode when the app is open |
| 22 | De-esser, Enhance Dialogue, bass, mud | **done** |
| 23 | Speech-tuned EQ presets | **done** |
| 24 | Speed and Audio sheet | **done** |
| 25 | Data-driven shelf renderer | partial — `NavigationShelf` on Discover |
| 26 | Real category destination pages | **done** — `CategoryView` |
| 27 | Favourite categories | **done** — Discover shelves (B86) |
| 28 | Apple Podcasts migration investigation | written — history export from the Mac's synced library + in-app import, see B30 |
| 29 | Publishing fixes, no duplicate processing | unknown — never verified |
| 30 | Scroll-driven polish effects | **not started** |
| 31 | Density and scale pass | partial |
| 32 | Performance and regression pass | partial — main-thread whole-store work moved to `LibraryIndex` (B64); never profiled on a device |

### Still missing — the running tally

Kept here so nothing drops out between passes. Update it every pass.

| Area | What is missing | Notes |
|---|---|---|
| Video | Tested on a real video feed (none of his shows publish video — Stavvy's World checked again, B96); Watch on YouTube (B108) needs a device check; "Video" filter; video downloads sized separately; PiP controls for the following player | B87 |
| Search & Discover | Search scopes; Apple's editorial shelves (not public); the 27.2 Home "insights" banner (server content) | B86, B91 done; New / Search split to match Apple (B103) |
| Catalogue beyond the feed | Episodes older than what a publisher's feed lists | Feeds are the only source; Apple also has its own archive, which apps cannot read |
| CarPlay | Browsing and Up Next in the car | Needs the CarPlay audio entitlement — paid account + TestFlight (B94) |
| Widgets | Home Screen widgets (Up Next, now playing) | Need an App Group to share data — paid account (B94) |
| Transcript search | — | Done in the player (B90) |
| Stations | Group by show, manual order | Stations exist (B92) |
| Sync | iCloud sync of library and positions across devices | Needs the iCloud entitlement — paid account (B94) |
| Chapters | Editing, and chapter art | Read-only today |
| Lock Screen tap | System Now Playing tap on a sideloaded build | Not fixable in app code; Live Activity card is the workaround (B55) |
| Siri / Apple Intelligence (PCC) | Dropped at his request | Revisit only if asked |
| Real-device checks | Background survival, battery, AirPlay/CarPlay routing, real transcription speed, Live Activity on a KSign build, performance with a full catalogue (B64) | Only on the phone |
| Episode page | Apple-style episode page exists now (B68); no "more from this show" or share-at-time on it yet | |
| Auto-publish | — | Done (B93) |
| Delivery style backfill | Episodes processed with both keep-settings off have no host-read/produced label | Re-run Find Ads after turning one on |

Outside the 32, still outstanding from earlier: per-show "Remove Played Downloads" UI.

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
| B6 | Batch selection and batch actions. | fixed, not yet confirmed on device — show page ⋯ → Select Episodes. Checkbox rows, "N Selected", Select All/None, Done; bottom bar Mark as Played/Unplayed, Find Ads, and ⋯ with Add to Up Next, Download, Remove Download, Star, Archive. Acts on the visible (filtered) rows, which is item 13's filter-scoped mark-as-played. The tab bar hides while selecting |
| B7 | Search and Discover are undercooked. | fixed, not yet confirmed on device — rebuilt as the Podcasts Search tab: For You, Top Shows shelf with See All, Top Episodes, colour category tiles opening a category page, search grouped into Your Library / Shows / Episodes with recent searches, and a show preview page with Follow instead of subscribing on tap. Items 25–27 |
| B8 | Countdown when play is pressed before Find Ads has run. | fixed — the `isDownloaded` guard meant the question was skipped precisely when it mattered |
| B9 | The ambient player background is slow, low-res and boxy-pixellated on device, though clean in the simulator. | fixed — the full-screen per-frame `.blur` was Core Animation's downsampled gaussian. Blur, saturation and brightness are now baked into the source once with Core Image and the frame loop is transforms only |
| B10 | The ⋯ menu ghosts, flickers and needs two or three taps. | fixed — `PlayerView`'s body read the playhead, so the menu's contents were rebuilt five times a second. The scrubber and the Smart Speed line are now their own `View` types |
| B11 | The timeline looks "choppy", as though hundreds of things were removed, on an episode where only a 46-second intro was cut. | fixed — `rebuildMarkers()` was drawing every measured silence as a blue bar. Silences are an input to Smart Speed, not removed content, and are no longer drawn |
| B12 | A cut is nearly invisible on the timeline. | fixed — a fixed-size down-pointing tick now sits over every active cut, whatever the zoom |
| B13 | The what-was-skipped page shows no transcript, has plus/minus buttons instead of trim handles, and "Listen" requires toggling Skip Ads off by hand. | fixed — a Photos-style trim strip with draggable handles over a speech-density texture; a preview player that suspends *all* skipping for one stretch and puts the playhead back afterwards; a large transcript that follows along and says "music, a sting or silence" when there are no words |
| B14 | Thumbs up / down appear to do nothing. | fixed — corrections are now filed against the **show** and folded into the detector's instructions as worked examples on the next run, the same mechanism `knownSponsors` already uses. Before this they only stopped one segment being skipped in one episode |
| B15 | `.opml` files are no longer greyed out but still cannot be picked. | fixed, **unverified** — three changes: the declared type moved out of the reserved `public.` namespace to `org.opml.opml`; `.item` added to the allowed types so nothing can be dimmed; the read is now security-scoped *and* file-coordinated with an iCloud download, and any failure is shown in an alert instead of a grey footnote |
| B16 | The minimised now-playing bar is too small to read. | fixed at `0617c24`, not explicitly confirmed — the tab bar no longer minimises, so there is no minimised bar (B17, the same change, was confirmed) |
| B17 | The bottom translucent bar grows above the now-playing box and shrinks back when scrolling to the top. | **fixed and confirmed on device** (`0617c24`) — same change as B16 |
| B18 | Publish: re-processes an already-processed episode; the ad-free feed should be one link per show with a podcast-page-like view. | one link per show and Add to Podcasts **confirmed on device** (`0617c24`). "Re-processes" reported again: it does not — the banner said "Step 2/4 · Removing ads from audio" for the step that writes the cut audio file. Now "Publishing 2/4 · Writing the ad-free audio file"; unverified on device |
| B19 | Play on an unprocessed episode opens the countdown, and neither Play now nor the countdown running out plays anything. | fixed, not yet confirmed on device — `choosePlayNow()` cleared the stored callback and then called it. The old UI test passed because it waited for the mini player, which exists when nothing plays. `testPlayPromptStartsPlayback` waits for the episode's title instead |
| B20 | "Prepare 2 episodes ahead" does nothing. | fixed, not yet confirmed on device — upcoming episodes had to be already downloaded (usually none on a phone), a second lookup always returned the first answer, and a request that arrived while something else was processing was dropped. Now resolves the queue then the show without a download requirement, and deferred work resumes when the busy job ends. Autoplay into an unprocessed episode now shows the countdown when the app is open |
| B21 | Import OPML opens a picker in which no file can be selected. | fixed, **unverified** — `.fileImporter` replaced by `UIDocumentPickerViewController` presented from UIKit, in multiple-selection mode (circles and an Open button), as a copy. A simulator test photographs the picker; selecting a real file needs the phone |
| B22 | Ad and intro/outro detection is not context aware; "promote" in the sense of awareness was cut; an intro was missed. | rebuilt and measured in the new detection lab (`Tools/DetectionLab`) on SmartLess and Legion of Skanks episodes — see `claude/DEVICE-vs-SIMULATOR.md` §7. Old detector: 1 of 4 ad breaks on SmartLess; about half of Legion of Skanks refused by guardrails. New: every break on both, edges mostly on the sentence, openings and closings found after/before pre- and post-rolls. Quality on the phone's own episodes still unverified |
| B23 | Is a true feedback engine possible? | partly — thumbs now also feed an on-device embedding memory (NLEmbedding) shared across shows; a cut reading like a rejected passage (cosine ≥ 0.81, threshold measured in the lab) is not made. Not retraining; stated as such in the guide |
| B24 | A better dynamic background in the player. | replaced — an animated `MeshGradient` built from a 3×3 sample of the cover's colours; no blur or image in the frame loop. Unverified on device (a still cannot show motion) |
| B25 | Player background moves too slowly and is mostly one colour. | fixed, motion unverified on device — periods 7–15 s (were 13–29), a little more travel, colours rotate every 30 s eased; colours are now picked from a 6×6 sample for difference from each other, and a single-colour cover gets neighbouring shades so there is still depth |
| B26 | Accidental taps on the progress bar seek. Wanted peek-and-snap, a tension commit, a fading mark, haptics; also on What was skipped. | fixed, feel unverified on device — tap peeks and springs back with a fading time mark; still hold fills a ring and commits with a rigid haptic at ~0.8 s; drag commits on release and marks the origin. Trim handles snap back unless dragged or held |
| B27 | Audio settings and What was skipped sheets are not Liquid Glass like the rest. | fixed — both painted black over the sheet and opened at full height (the one detent iOS draws opaque). `glassSheet()`: medium + large detents, hidden list background |
| B28 | Star does not fill; bookmark should fill with a count, tap = quick label, hold = bookmarks page; haptics. | fixed — `BookmarkButton` (own view with its own `@Query`), `EpisodeBookmarksView` |
| B29 | Prepare N ahead still does nothing. | reworked, unverified on device — `PrepareAhead` re-asks on launch, foreground, episode load, Up Next change, job end and every 60 s while playing; Up Next shows the targets and their state with Prepare Now. Requests arriving during a speculative job were dropped; now merged. Failed episodes are not retried automatically |
| B30 | OPML has no listening history; wanted a (semi-)automated import from Apple Podcasts. | written — `Tools/ApplePodcastsExport/export-history.sh` reads a copy of the Mac's synced `MTLibrary.sqlite` (playState 0 played / 1 in progress / 2 unplayed) into iCloud Drive; Settings → Import Apple Podcasts History applies it. Export run on his Mac: 20 followed, 11,963 played, 179 in progress. Import unverified on device |
| B31 | Publish starts at step 2 of 4; wanted an expandable detail view, reorderable queue, streaming text; multiple selected episodes should queue. | fixed, unverified on device — per-episode step plan; `PublishQueue` (finds ads first where needed); banner shows the latest log line and opens `WorkDetailView` with steps, reorderable waiting list and log; cut and upload report real progress |
| B32 | Apple's guardrails refuse comedy; keep comedic ad reads. | explained in the guide; `permissiveContentTransformations` already in place. New: a separate post-detection question per ad (`classifyStyle`) → Keep Host-Read Ads / Keep Ads Played for Laughs, both off by default. Detection itself unchanged (LoS re-run: same cuts). Lab, 13 ads on LoS/SmartLess/Conan, judged against the transcripts: produced vs host plausible on all; "bit" right on LoS GLD, wrong on a Conan credits-plus-trailer chunk. Small print ("and affiliates", "terms apply") decides produced before the model is asked — the model alone called a Progressive pre-roll host-read |
| B33 | iOS 27 Apple Intelligence, SponsorBlock, Podcasting 2.0, embedded chapters. | answered in the guide. PCC needs app eligibility and the iOS 27 SDK (CI runs Xcode 26.6); SponsorBlock timings are YouTube-video timings; Podcasting 2.0 transcripts are a future input |
| B34 | Video podcasts toggle. | **open** — not in this pass |
| B35 | Automatic downloads like Apple Podcasts, with advanced filters. | written — `AutoDownload`: Off / Only New / All Unplayed × most recent 1–10 or last 1–30 days, default + per show, Find Ads Right Away, Wi-Fi only, minimum length, title exclusions; only removes what a rule downloaded. Unverified on device (demo feeds are local) |
| B36 | Keep working in the background while downloading / transcribing / publishing. | written, unverified on device — `BackgroundWork` submits a `BGContinuedProcessingTaskRequest` when a job starts and reports real progress each second; falls back to the 30 s assertion. Whether transcription and the language model may run in that state, and whether a KSign-signed build keeps the task identifier, are unknown |
| B37 | Lock Screen Now Playing tap does nothing. | not fixable in app code while sideloaded (same as B4) |
| B38 | Batch selection opens what looks like a smaller separate page without covers or notes. | fixed — selection happens on the show page with the full `EpisodeRow` and a tick; the header stays; row buttons are disabled while selecting |
| B39 | Pages and menus opened from tabs are not Liquid Glass. | partly — sheets use `glassSheet()` (medium/large detents; `amoledScreen` turns see-through inside one); Audio, Bookmarks and Activity zoom out of the control that opened them. Pushed pages stay black by design |
| B40 | Whole-app size setting; default text a tad too large. | written — Settings → Display → Text and Icon Size, six steps; `UIScale` scales `Metrics`, every `.system(size:)` and player button sizes, and `dynamicTypeSize` scales text styles. Default is 0.94 of the old size |
| B41 | Touch and hold an episode for its ⋯ menu, everywhere. | written — `EpisodeMenuItems` shared by the ⋯ menu and `.contextMenu` on `EpisodeRow` and `EpisodeCompactRow` (show pages, Up Next, collections, playlists) |
| B42 | Bottom navigation like Apple Podcasts on iOS 27. | changed — `tabBarMinimizeBehavior(.onScrollDown)`, which is what the Podcasts binary sets; the mini player goes inline beside the collapsed tab button |
| B43 | Bookmark button smaller than its neighbours. | fixed — a normal `.glass` button with the badge overlaid; hold is a simultaneous gesture |
| B44 | History import marked unplayed Cum Town episodes played; 11,000 "not in library". | fixed — Apple's back catalogue has playState 0 + manually-set + source 6 with no play dates; "played" now needs a play count, a user-marked date or a non-source-6 last-played date (3,266, not 11,963). Matching is per show; the import is authoritative both ways except episodes actually listened to in PodSkipper. No guid is shared across shows in his library, so the mislabel was the rule, not cross-show matching. "Not in library" is real: PodSkipper keeps 50 per show |
| B45 | Seek bar: hold-zoom jumps, drag lands off, paused seek ignored on Play. | fixed — relative scrubbing with Apple's rate tiers, frozen window, no zoom under a held finger; `PlayerEngine.seek` while paused now reschedules on play. `testPassThree` asserts a paused drag then Play starts where the drag ended (47 → 92 s, played from 94 s) |
| B46 | Background now twice as fast; wanted ~25 %. | fixed — periods 10.4–23.2 s (original 13–29), colour rotation 56 s |
| B47 | Add to Up Next doesn't add. | fixed — it did add, but Up Next lists only unplayed episodes and B44 had marked them played. `Episode.addToUpNext` makes a played episode unplayed; Play Next goes above everything; Add to Up Next goes last |
| B48 | Activity sheet rises from the bottom when the banner at the top is tapped. | fixed — zoom transition from the banner (and from the page's Activity link) |
| B49 | iOS 27 Private Cloud Compute. | researched — needs the `com.apple.developer.private-cloud-compute` managed entitlement (request form; Small Business Program; under 2 M downloads), a paid developer account, and App Store / TestFlight / ad hoc distribution. The local Xcode 27 can build it; a KSign re-sign would drop the entitlement. Waiting on whether he has a paid account |
| B50 | Lock Screen tap. | open — his iPhone is paired with the Mac (`devicectl`), but Xcode has no Apple account signed in, so a direct Xcode install (which would show whether KSign is the cause) needs him to add one |
| B51 | (found while testing B47) Autoplay and Up Next's "Show Priority" sort played same-priority episodes in reverse queue order. | fixed — the tuple compared `-b.queueOrder` against `-a.queueOrder`, so the higher order number came first. Seen in a screenshot: the ready-ahead card named the second and third episodes, not the first |
| B52 | The top and bottom bars draw a transparent box with a defined border on every tab; the bottom one jumps when scrolling up fast. | changed — `.soft` scroll edge effect everywhere (`hard` is "a more opaque blur with a defined edge"); show page no longer paints a navigation bar background. Whether the bottom accessory's expand animation still jumps is device-only |
| B53 | Show page: a sharp border between the tinted header and the episode list. | fixed — the backdrop was a fixed 554 pt with a hard cut; it now ends with the measured header and fades over 110 pt |
| B54 | Only 50 episodes per show. | fixed — `EpisodeCatalogue` stores every item the feed lists on follow, import and refresh; a one-time backfill runs at launch. Only episodes newer than the last refresh count as new for Up Next and notifications. Unverified with a 2,000-episode feed on the phone |
| B55 | Lock Screen Now Playing tap does nothing. | workaround — a Live Activity card (`PodSkipperNowPlaying` widget extension) beside Now Playing that opens `podskipper://player`; Settings → Playback → Lock Screen Shortcut. Cause of the system tap: most likely the re-signed `application-identifier` does not name PodSkipper. Unverified on a KSign build — extensions and Live Activities may be refused under some certificates |
| B56 | Player Find Ads greyed out for a while after pressing play. | fixed — it was disabled while prepare-ahead ran. `processNow` cancels speculative work (now checks cancellation between stages, keeps its transcript) and starts; the player refreshes skip ranges when the current episode finishes processing |
| B57 | Speed and Audio / What was skipped turn dull grey when dragged up. | changed — detents `.medium` + `.fraction(0.93)`; Apple's docs: a sheet at full height "transitions to a more opaque appearance". `testPassThree` photographs the tall state |
| B58 | Bookmark count badge behind the glass. | fixed — the badge is part of the button's label, so it draws above the glass; red like a system badge; icon white like its neighbours |
| B59 | Publish page should look like the show page, ideally combined. | done — publishing is a mode of the show page (Publish/Feed button, or from the Publish tab); feed link in the header, publish filters, Find Ads / Publish bar; rows show an "in feed" mark. `PublishShowView` is no longer reachable |
| B60 | Activity opens as a bottom sheet from a bar at the top, then goes grey. | fixed — the bar expands in place into the activity card, one glass shape morphing (`glassEffectID`), collapsing with its chevron or a swipe up; it stays after the queue finishes until cleared |
| B61 | Up Next hides played episodes. | fixed — Up Next shows everything queued, with Unplayed and Played filters; queuing no longer changes played state |
| B62 | Autoplay should follow the show's sort order. | fixed — an episode started from a show continues in that show's order (newest→oldest or oldest→newest), then Up Next; one started from Up Next continues through Up Next |
| B63 | Bring back zoom on the seek bar without accidental seeks. | redesigned — loupe (90 s glass ribbon above the bar), bar/loupe/quarter scales by finger height, edge catching, tether preview that springs back, 0.4 s hold to commit, "where you were" ring for 5 s (tap to return), pinch zoom kept. Feel is device-only; `testPassThree` checks a released drag springs back and a held drag commits |
| B64 | App laggy, freezes, choppy scrolling, crashes, heat and battery drain after whole catalogues. | fixed in code — `LibraryIndex` (`@ModelActor`) does catalogue merging, counts, totals and the history import off the main thread in batched saves, resumably (`Podcast.catalogueIndexedAt`); screens read `LibraryIndexStatus`; show page scroll no longer re-evaluates its body; next-episode, auto-download and publish pools are predicate fetches; transcript no longer decoded per row menu. Device-only to confirm |
| B65 | Want catalogue-indexing progress and to know when the history import will work. | fixed — Library banner and Settings row ("Getting every episode · n of m shows", paused reasons, "Ready to import"); the import waits for indexing before matching |
| B66 | Import summary: 5063 "not in PodSkipper's list… newest 50". | fixed — the summary separates shows you don't follow from episodes no longer in a feed; the "newest 50" wording is gone. Re-run the import once indexing says ready |
| B67 | LoS 955 intro cut at 0:51; it ends at 1:10. | fixed in the detector — the intro runs through a ≥5 s speech gap within 30 s of its end (the theme's instrumental). Lab: LoS 955 intro 0:32–1:10 (was 0:47), LoS 952 0:28–1:09; Conan intros unchanged. Still in 955: a false cut at 4:48–5:30 (the hosts joking about doing an ad), present before this change too |
| B68 | "Getting the next 2 ready" skipped Jun 5 and left out hand-queued episodes. | fixed — order is Up Next first, then the show; played episodes are skipped and the card says so, with each episode's date and reason; tapping opens the new episode page |
| B69 | Up Next rows lack dates and descriptions. | fixed — Up Next uses the full episode row with the show name above |
| B70 | Live Activity occupies the Dynamic Island and survives the app being swiped away. | fixed — off by default (new key), only while playing, ended on pause, on termination and at every launch; updates only on episode/play-state change |
| B71 | Star lags; star yellow vs bookmark white. | fixed — optimistic `StarButton` with a deferred save; white like every other Now Playing control (Apple's equivalent is "Save Episode", monochrome) |
| B72 | Loupe too translucent; the title shows through. | fixed — dark fill under a dark-tinted glass |
| B73 | Mini player lacks artwork and release date. | fixed — cover in the collapsed pill too; date under the title (collapsed) and before time left (expanded) |
| B74 | Offline download: the bar said both "failed" and "finished". | fixed — downloads and publishing wait for a connection (`NetworkStatus`, `waitsForConnectivity`); outcome titles "Published" / "Couldn't publish" / "Finished with problems" |
| B75 | Publish tab redundant with the Library. | fixed — tab removed; Library → Ad-Free Feeds; feed badge on show covers; Ready to Publish and In Feed filters; Remove from Feed in the selection bar and episode menu; "Find ads and publish N?" confirmation |
| B76 | Library still stutters on a quick swipe up. | fixed in code — cover grid split into one list row per line (a grid in one row was a single enormous, non-lazy cell); per-show counts observed per show (`CountsBox`) so one show's numbers don't redraw every tile. Feel is device-only |
| B77 | More battery / heat work. | done — background tick sleeps to the next boundary (≤1 s) instead of 5 Hz; speculative processing waits in Low Power Mode and at serious/critical thermal state; video track disabled when not visible; Discover recommendations read listening totals from the background count |
| B78 | Publish from a selected episode on a show page. | fixed — Publish in the selection bar and Publish… in the episode menu open publish mode with those episodes ticked |
| B79 | Up Next: two played, queued episodes "Waiting" and never processed; listed twice. | fixed — watchdog restarts a stalled background job (2 min without starting anything); refresh every minute whenever the app is open; unplayed prepared first; card is one line, rows carry "Getting ready next". Root cause of the original stall not identified from the code — the watchdog covers it |
| B80 | Up Next page lacks the expandable activity bar. | fixed — `.processingBanner` on Up Next |
| B81 | Autoplay continuation not visible in Up Next. | fixed — "Then from <show>" section lists what autoplay continues with (not added to the queue; swipe to add) |
| B82 | Show name in the bar when scrolled overlaps text. | fixed — removed |
| B83 | Lock Screen card should stay while paused. | fixed — shown whenever an episode is loaded; ended on termination and at launch. Limit: a suspended app gets no termination callback |
| B84 | Zoomed strip too opaque. | fixed — 0.62 black under 0.35-tinted glass |
| B85 | Video toggle, in sync. | done — Video / Audio switch on one `AVPlayer`; audio-only disables the video track. Unverified on a real video feed |
| B86 | Deeper search and discovery. | partial — Your Episodes and Said in Your Episodes (transcript search, play from the moment) in search; favourite categories as Discover shelves |
| B87 | "No video feature". | investigated — none of his 19 feeds carry video; Apple's video is delivered to Apple privately (not RSS). Built: `podcast:alternateEnclosure` video + video enclosures; sound through the audio engine (all effects), picture a muted `AVPlayer` following it (`VideoSync`); streamed video with a different length than the audio is refused with a message. Sync checked only by timecode screenshots in the simulator |
| B88 | False cut LoS 955 4:48–5:30. | fixed — review "selling=no" with no strong ad wording now drops a cut; a cut containing the show's own welcome with no ad wording is dropped. Lab: 955 fixed; 952, Conan ×2, SmartLess 2 unchanged; SmartLess 1's guest hello no longer an ad (now inside the intro) |
| B89 | Lock Screen card should look like the app. | done — cover (≤2.6 KB JPEG in the state), show · date, 2-line title, self-moving progress, countdown, ads removed, back/play/forward (LiveActivityIntents run in the app); preview in Settings. Marquee impossible in a Live Activity |
| B90 | Search the transcript in the player. | done |
| B91 | Search by host / guest; Apple-style shelves; More Like This on episode page. | done — `authorTerm` search + `podcast:person` tags; "Because You Listen to" shelves; episode page People / More from / You Might Also Like. Apple editorial not public |
| B92 | Stations. | done — renamed from Playlists; newest-N-per-show; "Next:" line; store-side narrowing |
| B93 | Publishing: auto-publish. | done — per show |
| B95 | Found while testing: a touch-and-hold menu on Up Next closed by itself a few seconds after opening while something played. | fixed — the playhead was written to the library every 5 s, refreshing every episode list; now the crash-safe copy goes to a small file every 5 s and the library once a minute (and on pause/seek/change/leave). Less battery too |
| B94 | iCloud sync, CarPlay, widgets. | not built — need Apple-granted entitlements a KSign sideload cannot carry (iCloud container, CarPlay audio, App Group for widget data) |
| B96 | No Video toggle on Stavvy's World #198. | not a bug — the feed and Apple's public lookup list it as audio only (`episodeContentType: audio`); Apple's video is private to Apple. Toggle appears only with feed video |
| B97 | Show the episode's date in the player. | done — "Show · Sep 14" (year added before this year) |
| B98 | Lock Screen card doesn't need play / back / forward. | done — removed from the Lock Screen card; kept in the expanded Dynamic Island |
| B99 | Transcript tap should leave the scrubber's "where you were" dot. | done — `PlayerEngine.jump(to:)` records the origin; `SeekBar` shows the ring for 10 s, tap to return; transcript lines and search hits use it |
| B100 | Stutter up and down at the top of Library and Up Next. | changed, device check needed — activity bar moved from `safeAreaBar(edge: .top)` under a large title into the list as its first row; bar fixed at two lines. Not reproducible in the simulator (measured: first row steady at the top) |
| B101 | Pull to refresh a show and the library, without breaking processing or publishing. | done — show page `.refreshable`; refreshes deduplicated (a second pull joins the first); feeds now also checked on foreground (30 min), by a `BGAppRefreshTask` (~2 h) and before overnight processing — previously never automatic |
| B102 | Explicit, Bonus, Trailer and Video marks on episodes; year headings between years. | done — `itunes:explicit` (episode, else show) and `itunes:episodeType` parsed and backfilled on refresh; year headings on the show page; year in the date elsewhere |
| B103 | Apple Podcasts 27.2 beta 2: New tab, Search is categories only. | done — New and Search split; Create Station; Mark Filtered as Played/Unplayed. Tabs unchanged in the bundle (server layout); findings §6 |
| B104 | Swiping the play-without-ads question away should stop autoplay; left alone it should play. | done — swipe cancels (setting `promptSwipeCancels`, default on); countdown still plays |
| B105 | New page doesn't match Apple's; Search categories don't match. | done — Apple's own page data from podcasts.apple.com (`StoreClient`), every shelf type drawn (`StoreViews`); fallback to own shelves; findings §7 |
| B106 | More Apple features. | done — Hide Played, season picker, Share from Here (Apple link with t=), Recently Played |
| B107 | Performance / battery the way Apple does it. | done — artwork stored ≤1200 px, mzstatic asked for size; per-list predicate fetches; store pages cached 6 h |
| B108 | Video like Apple / Spotify / YouTube. | done as far as possible — Watch on YouTube via the show's channel feed + YouTube's embedded player; Apple/Spotify video not obtainable (findings §8) |
| B109 | Skip forward at the end restarted the episode. | fixed — a seek reaching the end while playing ends the episode (next per Up Next / show order); paused, it parks 1 s short |
| B110 | Block YouTube's ads in the player with AdGuard; embed a tweaked YouTube IPA. | declined as asked — YouTube's embed terms forbid altering its ads, and iOS can't host another app. Instead, the YouTube sheet has YouTube App (`youtube://`, with time), Safari (`x-safari-https`, so AdGuard's action works) and Share Link |
| B111 | Activity bar pinned on Library and Up Next, as on the show page. | done — `.processingBanner` (safeAreaBar) on both; the list-row version was removed. Device check: the earlier judder at the top of these large-title pages |
| B112 | Tapping a failure notification should open that task and show its current state. | done — `NotificationRouter` (UNUserNotificationCenterDelegate) → `AppRouter` → `EpisodeStatusView` sheet (live state, Try Again, Play); PodSkipper posts its own notices on a failure while away and when the background task expires; opening the app after an expiry opens the episode (the system's own "failed" notice can't carry data) |
| B113 | Scrolling lags while ads are found. | done — AudioAnalyzer detached off the main actor (it read the whole file there); `ProgressThrottle` (≤4 Hz) for transcriber, analyser and detector; transcript encode off main. Device check: whether the lag has gone |
| B114 | New icon, with light and dark versions. | done — "hop" wave; light, dark and tinted appearances, generated by `prepare-build.sh` from `Resources/AppIcon-1024{,-dark,-tinted}.png` |


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
