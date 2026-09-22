# What the simulator will not tell you

Every entry below is something that was **verified correct in a simulator
screenshot and then reported as wrong on an iPhone 16 Pro**. That is the most
expensive failure mode this project has, because it costs a build, a push, a CI
run, a sideload and a round trip through a person who is not a developer — and
the screenshot discipline that catches everything else does not catch it.

Read this before writing anything that draws, animates, or presents.

---

## 1. Large blurs render differently and look broken on device

**Symptom reported:** "the background dynamic effect isn't smooth — it's slow,
low res, boxy-pixellated."

**What was in the code:** a full-screen `.blur(radius: ~70, opaque: true)` over
a stack of four rotating images, recomputed thirty times a second, plus
`.saturation()` and `.brightness()` on top.

**Why the simulator lied:** SwiftUI's `.blur` is Core Animation's gaussian,
which is implemented by shrinking the layer hard, box-blurring the small copy
three times, and scaling it back up. At a large radius across a whole screen the
shrink is severe enough that the scale-back-up arrives as visible squares. The
simulator composites through a different path and shows a clean blur.

**The rule:** do not put a large blur — or any filter (`.blur`, `.saturation`,
`.brightness`, `.colorMultiply`, `.drawingGroup`) — inside anything that redraws
every frame. Bake the effect into the source bitmap once with Core Image, off
the main thread, and let the frame loop be nothing but transforms.

**Related trap:** removing `.blur` makes the *edges* of any layer smaller than
the screen into hard lines. Either compute a scale that guarantees coverage, or
bake an alpha falloff. Do not discover this on the phone.

---

## 2. A view that rebuilds five times a second destroys an open menu

**Symptom reported:** "the player menu when trying to scroll up or down creates
this ghosting effect… I find myself hitting the buttons a few times in order to
get it to work."

**What was in the code:** `PlayerView`'s body read `player.currentTime` — first
through a `ShareLink` label, and after that was removed, still through the
`scrubber` computed property and an `.alert` message.

**Why it matters more than it looks:** `@Observable` dependencies belong to the
**body that read them**, not to the sub-expression. A computed property is part
of the body. So one read of the playhead anywhere in `PlayerView` rebuilt the ⋯
menu's contents five times a second. UIKit draws each new copy of an open menu
over the last (the ghosting), never lets it settle long enough to scroll, and
drops taps that land mid-rebuild (the two-and-three-tap buttons).

**Why the simulator lied:** a screenshot of a menu is a still. Ghosting is a
difference between consecutive frames — it cannot appear in one.

**The rule:** anything that reads a value changing faster than about once a
second lives in its own small `View` struct. In this app that means the
scrubber, the elapsed/remaining row, the Smart Speed saved-seconds line and the
live transcript. Never a computed property of a screen-sized view.

**How to check without a phone:** grep the screen's body and every computed
property it calls for `currentTime`, `smartSpeedSavedSeconds`, or anything else
written on a timer. If one is there, it is a bug whatever the screenshot shows.

---

## 3. Demo data is not the app

The simulator runs on `DemoData`, and what `DemoData` does not contain cannot be
photographed:

- Covers are drawn locally, so **artwork loading, network failure and retry are
  invisible**.
- Audio is two minutes of generated silence, so **nothing about a two-hour file
  is testable** — scrubbing precision, Smart Speed over a real episode, memory.
- There is **no on-device language model**, so ad detection quality cannot be
  assessed at all.
- Until this pass there was **no transcript**, which silently made the live
  transcript, the what-was-skipped page and the trim strip look "empty but
  fine". A transcript is generated now; keep it that way, and if you add a
  screen that shows words, make sure demo data produces some.

**The rule:** when something cannot be shown in the simulator, say so in the
report to Shashank, by name, rather than letting it read as tested.

---

## 4. Things only a phone can answer

Nothing in the simulator bears on any of these, and none of them have ever been
verified:

- AirPods pause/resume, Bluetooth and car routing, AirPlay.
- Lock Screen Now Playing behaviour. (The tap-opens-KSign behaviour is a
  *sideloading artifact* — iOS launches the installer of the app holding the
  audio session. Not fixable in app code.)
- Background survival over hours, and what `BGProcessingTask` actually gets.
- Real transcription speed, and battery cost.
- Scrolling performance on a real library with real artwork.
- Ad-detection quality, which needs real episodes.

---

## 5. The corner-cut lesson, which was geometry and not rendering

**Symptom reported, twice:** "the top right and top left corners still cut."

The cause was never clipping. A sheet has a corner radius in the mid-fifties on
these phones, and `.buttonStyle(.glass)` draws its material *outside* the label's
frame. A 40pt button 22pt in from the edge at a 26pt top inset has the top-left
of its material behind the corner arc. The fix was a 46pt top inset — arithmetic,
not a modifier.

**The rule:** when something is "cut off", work out where the edge actually is
before changing a clip or a shape. And `.clipShape` after `.buttonStyle(.glass)`
shaves the material, so it is never the answer for a glass control.

---

## 6. A test that waits for the wrong thing passes when the feature is broken

**Symptom reported:** "hitting play on an episode that hasn't gone through
find ads opens the countdown, but nothing happens when I press play or when
the countdown ends."

**What was in the code:** `choosePlayNow()` called `clear()` — which sets the
stored callback to nil — and then called the callback. It did nothing, every
time, on every device.

**Why the screenshot run passed it:** the test pressed Play now and then
waited for the element identified `MiniPlayer`. The mini player exists when
nothing is playing too: it shows the next episode in Up Next. The test was
waiting for something that was always there.

**The rule:** assert on the thing that only exists if the feature worked —
here, the mini player *carrying that episode's title*
(`testPlayPromptStartsPlayback`). An identifier that is present in both the
success and the failure state proves nothing.

---

## 7. Ad detection cannot be judged in the simulator — use the lab

The simulator has no language model, and demo audio has no ads. But the Mac
does have the model, so `Tools/DetectionLab/lab.sh` downloads a real episode,
transcribes it with the app's own `TranscriptionService` and runs the app's own
`AdDetector` on it, printing every cut and every decision. What it found on
its first run, none of which any screenshot could have shown:

- **One `LanguageModelSession` for a whole episode.** A session keeps every
  prompt and answer; the context filled after a few windows and every later
  call threw, and the throw was caught and skipped. The old detector found
  one ad break out of four on a SmartLess episode.
- **The default guardrails refuse comedy.** On a Legion of Skanks episode
  about half the windows — sponsor reads included — came back "may contain
  sensitive or unsafe content". `permissiveContentTransformations` fixes it,
  but only for plain-text responses, not `@Generable` ones.
- **Guided generation is slow.** About eight seconds a window against about
  one for the same question answered as a line of text.
- **Numbered-line questions get "line 1".** Asked which of seventy numbered
  lines an intro ends on, the model answered 1 on both episodes. Asked about
  one short piece at a time, it answers correctly.
- **Dynamically inserted ads depend on the user agent.** A plain `curl` of a
  SmartLess episode was 52 MB with no ads; with a Podcasts user agent it was
  62 MB with four ad breaks. The lab fetches with a Podcasts user agent.

- **Delivery style needs the words, not just the model.** Asked whether an ad
  was host-read, the model called a Progressive pre-roll with its legal small
  print host-read, and called produced SmartLess spots "played for laughs"
  because the cut included the hosts' joking before the break. Small-print and
  sponsorship-line phrases now decide "produced" first, over the whole text —
  not the 1,800-character prompt excerpt, which had cut the small print off.
  `LAB_STYLE_ONLY="start-end,…"` asks just this question, in seconds.

**The rule:** any change to `AdDetector` is run through the lab on at least
two real episodes before it is pushed, and the report says what the lab showed
— cut times against the transcript — not what the change was meant to do.

---

## 8. Motion, feel and background time cannot be photographed

Three things in the third pass that no screenshot can settle:

- **How fast the background moves.** B24 passed every screenshot and was
  reported as "hard to tell it was moving". A still shows colour, never speed.
  Judge motion by the numbers (periods and travel) and say it is unverified.
- **Haptics and springs.** The peek-and-snap bar and the tension ring are feel.
  The UI test can prove a tap did not seek (the value did not jump) and that a
  hold did; it cannot prove the recoil feels right.
- **Background continuation.** `BGContinuedProcessingTask` does nothing useful
  in the simulator, and a sideloaded build may be denied it. Never describe it
  as working until it has run on the phone with the screen locked.

## 9. Position-to-time mapping against a moving window

The seek bar converted the finger's x position to a time on every frame,
against a window that was centred on the time being dragged, and zoomed that
window under a held finger. The three reported symptoms — the dot leaping to
the middle and back eleven seconds off, a release at 13:38 landing on 13:32,
and paused seeks being ignored on Play — never showed in a still, and a UI test
that only compares "before" and "after" values passes if the numbers move at
all. The rules now:

- Scrubbing is relative (value += Δx × seconds-per-point × rate). The window is
  frozen for the length of a touch and only pans.
- Nothing changes the scale under a finger that is down.
- A seek while paused must reschedule the audio, not only set `currentTime` —
  `testPassThree` drags while paused, presses Play and asserts the playhead is
  within a few seconds of where the drag ended.

## 10. Glass rules that a still hides

- **A sheet at the large detent is meant to go opaque.** Apple: "When a half
  sheet expands to full height, it transitions to a more opaque appearance." It
  looked like glass in a medium-detent screenshot and went grey on the phone
  when dragged up. Use a tall `.fraction` instead of `.large` when the sheet
  should stay glass, and photograph it dragged up.
- **Anything over a `.glass` button goes in its label.** An overlay on the
  button itself sits under the glass the button draws around its label — the
  bookmark count showed through the glass.
- **Scroll edge effect `.hard` draws a band with a defined edge.** Apple
  Podcasts uses the soft, variable blur. Hard also makes the bottom accessory's
  resize visible as a jumping box.
- **Don't open a sheet from a control at the top.** It rises from the bottom,
  far from the thing tapped. Grow the control in place (`glassEffectID`).

## 11. The local compiler is newer than CI's

The Mac builds with Xcode 27 (Swift 6.4); CI builds with Xcode 26.6. An API
renamed between them compiles locally and fails in CI — `357cada` did exactly
that with `GenerationOptions(samplingMode:)`. Wrap such calls in
`#if compiler(>=6.4)` and never treat a green local build as a green CI.

## 12. The verification order that actually works

1. `./Scripts/local-build.sh build` — a clean compile.
2. **Read the warnings.** `pictureInPictureDidStartPictureInPicture` compiled
   fine, conformed to nothing, was never called, and the only evidence was a
   "nearly matches optional requirement" warning.
3. `./Scripts/local-build.sh shots`, or the `PodSkipperScreens` UI test for full
   navigation — and **open the images**. A screen that the test never reached is
   not evidence about that screen; if a new screen was added, add a step that
   reaches it and photographs it *opened*, not collapsed.
4. Re-read this file for anything in the change that a still cannot show.
5. `./Scripts/push.sh "Subject"`.
6. `./Scripts/watch-ci.sh <sha>` — wait for green and for an IPA artifact. A
   local build passing is not CI passing; `dc845b3` was announced as ready and
   produced no artifact at all.
7. Only then ask for a sideload, naming the SHA.

## 13. Whole-store work on the main thread is invisible in the simulator

Demo data has a handful of shows and a few dozen episodes. The phone had tens
of thousands once whole catalogues were stored, and every one of these was fine
in the simulator and ruinous on the device:

- inserting a back catalogue through `mainContext` (freeze, memory, crash —
  and the "done" flag was only written at the end, so every launch restarted it);
- counts computed by walking `podcast.episodes` inside row bodies
  (`unplayedCount`, `readyCount`, `freshnessLine`, `newSinceLastSeen`,
  `lastUpdatedAt` — three full walks per library tile per redraw);
- `FetchDescriptor<Episode>()` with no predicate on main (totals, history
  import, auto-download, "what plays next");
- a scroll offset held in `@State` and read in the show page's body, so the
  whole page — including a filter and sort over every episode — re-ran on every
  scroll frame;
- decoding a JSON transcript inside a context menu's content, per row.

Rules now: anything that touches more than one show's episodes runs in
`LibraryIndex` (a `@ModelActor` with its own context, batched saves, resumable);
screens read published results from `LibraryIndexStatus`; "the next episode"
style questions are `FetchDescriptor`s with a predicate and `fetchLimit`; a
scroll position is written to an observable that only the view that moves reads.
None of this can be judged from a screenshot — reason about it from the code,
and say it is unverified on the phone.

## 14. The Mac clone under ~/Documents was being evicted by iCloud

`~/Documents` is synced by iCloud Desktop & Documents, which turns files it
thinks are unused into placeholders (`ls -lO` shows `compressed,dataless`). Git
then fails with "Resource deadlock avoided" / "mmap failed". The working clone
is now **`~/Developer/podskipper`** (outside iCloud), with a worktree
**`~/Developer/pk-app`** for builds and UI tests so the detection lab can run in
the first while the app builds in the second. Patches still arrive through the
connected folder `~/Documents/GitHub/podskipper/build/` and are copied across.

A UI test that calls `app.terminate()` and `app.launch()` again inside the test
left `xcodebuild` waiting forever after the runner had exited (twice, on a
freshly booted simulator). Launch arguments a test needs are now added in
`setUpWithError` by test name, before the only launch.

## 15. A grid inside one List row is not lazy

The Library's cover grid was a `LazyVGrid` inside a single `List` row. To the
list that is one cell as tall as the whole library: every cover is laid out,
loaded and drawn at once, and a quick flick pushes that giant cell around —
the stutter reported on the phone. Three demo shows cannot show it. Split a
grid into one list row per line of tiles (or use a `ScrollView` with a lazy
stack), and read shared per-item counts through a per-item observable
(`CountsBox`), not a dictionary every tile reads.

## 16. Background playback does not need a 5 Hz tick

With the screen off nothing draws, so the tick only exists to make jumps.
`PlayerEngine.nextTickDelay()` sleeps until just before the next boundary
(capped at 1 s). Battery effect is device-only; the logic is not.

## 17. Video sync can only be judged by a clock in the picture

The demo's video episode draws its own playhead time into every frame
(`DemoVideo`). A screenshot proves only that the number in the frame and the
time under the scrubber agree at that instant; smoothness, drift over an hour,
HLS stalls and Picture in Picture are device-only. Also: Apple Podcasts' video
for big shows is not in public feeds (delivered to Apple via its own API), so a
feed with video must be found before real-world video can be tested at all.

## 18. A large title judders if something sits between it and its list

Library and Up Next pinned the activity bar under the navigation bar with
`safeAreaBar(edge: .top)`. A large title decides whether to expand from the
list's scroll offset, and a top bar changes the offset the list reports, so at
the very top the two can argue — reported on the phone as the page stuttering up
and down when scrolled back to the top. The simulator did not show it:
`testTopJitter` samples the first row's position for two seconds after a flick
to the top and got one value every time. A still, or a settled measurement,
cannot see a transient that happens during the bounce. Keep anything that
changes height out of the space between a large title and its list; put it in
the list as a row. And keep such a bar a fixed height — the activity bar grew a
third line whenever a publishing message arrived.

## 19. Nothing checked feeds on its own

The overnight task only processed; feeds were refreshed only by pulling the
Library down. A simulator with demo data never fetches a feed, so this was
invisible there. Background refresh (`BGAppRefreshTask`) timing is entirely
iOS's decision and can only be observed on a device.

## 20. Proving the transcript's "where you were" ring took four runs

Three runs said the ring never appeared, and the code was right each time. The
first taps landed on the next line along, a two-second hop, and a hop that
short leaves no ring by design. Others landed inside a cut ad, which is skipped
straight past. Once the ring was drawn, it sat exactly under the playhead where
it could not be seen. The test now taps lines until the scrubber's
accessibility value reads "…, was at m:ss" *and* that time is more than five
seconds from the playhead, then photographs it. When a check of something
drawn fails, find out what the test actually did before changing the code.

## 21. A `Group` with nothing in it never appears, so its `.task` never runs

"Watch on YouTube" was a `Group { if let video { Button… } }.task { find() }`. Until `video` was
found, the Group was empty. An empty Group is not in the hierarchy, so the task that would have
found the video never ran. It compiled, and a screenshot showed nothing — which is also what "no
match" looks like. Give such a view something that is always there: a zero-size `Color.clear` in a
ZStack.

## 22. Apple's pages come from the network at test time

The New and Search tabs now draw Apple's live pages. A UI test photographs whatever Apple is
featuring that day, and a run with no network photographs PodSkipper's fallback shelves. Neither
counts as a regression.

## 23. A cache of parsed data outlives the parser

Apple's pages are cached for six hours as PodSkipper's parsed version, not
as the raw page. A fix to the parser (video episodes' lengths) didn't show
in the next simulator run because that run read the old parsed copy. The
cache file names now include `StoreClient.cacheVersion`. Raise it whenever
the parsing changes, or a phone keeps showing the old reading for up to six
hours after an update.

## 24. Lag during processing doesn't show in a screenshot

The stutter while ads were found came from work on the main thread: the
silence analysis read the whole file there, and hundreds of progress updates
a second each redrew every view showing the bar. A demo file is two minutes
of silence, so none of this runs long enough to notice in the simulator. The
fix is structural (detached analysis, throttled progress); whether it is
enough is a phone check on a real two-hour episode.

## 25. Notifications and background expiry can't be exercised in the simulator run

The status sheet is tested by launching as if a notification had been tapped
(`-StatusDemo`). A real notification tap, a `BGContinuedProcessingTask`
expiring, and the system's own "failed" notice are device-only.

## 26. Entitlement-gated features are invisible in the simulator build

CarPlay, the widgets' App Group and iCloud all depend on entitlements the unsigned simulator and
KSign builds don't carry. In the simulator `WidgetSnapshot.folder` and iCloud are unavailable, so
the Settings page shows them locked and the widgets are photographed only as the in-app gallery,
drawn by the same views. None of the three has run for real.

## 27. HLS video in the simulator plays over the Mac's network

The pass-12 test plays the Podcast Standards Project's real HLS demo. That proves the path, not
phone behaviour on cellular, where the stream drops quality and may stall.

## 28. Detection quality is measured on the Mac, never in the simulator

The simulator has no on-device language model, so the app's detector cannot run there at all. The
detection lab runs the same Swift files on the Mac against macOS's copy of the on-device model, on
real downloads. So a lab pass means the logic is right on those episodes. It says nothing about:

- speed on a phone (the Mac is several times faster);
- whether the phone's model answers identically;
- shows the regression set doesn't cover.

## 29. The video and SponsorBlock lookups were checked with curl, not from the app

The UI tests turn the resolver off, so the demo shows don't go looking on the network. Each network
step was checked separately on the Mac, on 22 September 2026.

**Passed:**

- Stavvy's World #199's page on Apple Podcasts gives the Simplecast stream to `hostStream`.
- That stream's first variant adds up to 5,682.9 s, against 5,682 s of audio, and declares no
  interstitials.
- `YouTubeLink.parsePage` reads 30 uploads, with titles, lengths and dates, from the channel's
  Videos page.
- SponsorBlock returns two sponsor labels for the #199 upload, in the format `SponsorBlockHints.parse`
  reads.

**Could not check:** a Swift command-line tool on this Mac times out on *every* URLSession request,
example.com included, while curl works. So the app's own fetches of these addresses have only run
through the code path. They have not run on a phone.

The upload is 114 s *longer* than the audio, yet its sponsor reads come 3–4 minutes *earlier* in
it. That is why SponsorBlock hints are wide windows, not mapped times.

## 30. Heat, battery and video smoothness are device-only, again

Pass 14 changed three things that a simulator cannot judge:

- `AdDetector.breathe` reads `ProcessInfo.thermalState`, which is always `.nominal` in the simulator,
  so the pacing never engages there.
- `VideoSync`'s gentler correction (half the checks, 0.2 s seek tolerance, no seeking while
  buffering, a 0.12 s dead zone) is about a real HLS stream over a real network.
- The full-screen video view is drawn from the same layer, but tap-to-hide-controls, rotation and
  Picture in Picture behaviour are device behaviour.

What the simulator run does prove: the layouts, that the playhead bar does not move the trim handles
(testPlayer asserts the cut's status is unchanged after scrubbing and stepping), and that the
editor's controls are all reachable.

## 31. A 6.9" simulator hides what a 6.3" phone shows

The pass-14 video layout was photographed on the iPhone 18 Pro Max simulator, where the controls
leave plenty of height and a fitted 16:9 picture comes out full width. On a 6.3" iPhone the same
layout had less height to fit into, so the picture shrank sideways. The screenshot was true and
said nothing about the phone. The UI test now asserts the picture's width equals the window's,
which holds or fails on any size.

## 32. The AirPods bug needed a way to be caused in the simulator

There are no AirPods in the simulator, but the thing they do to the app can be done: iOS pauses the
video player on a route change. `-SimulateRoutePause` makes the app pause its own video player once
it has been playing for five seconds, and testVideoPlayer checks the sound is still playing
afterwards. Real AirPods in and out, and the Lock Screen, remain device checks.
