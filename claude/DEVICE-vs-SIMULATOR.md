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

## 10. The local compiler is newer than CI's

The Mac builds with Xcode 27 (Swift 6.4); CI builds with Xcode 26.6. An API
renamed between them compiles locally and fails in CI — `357cada` did exactly
that with `GenerationOptions(samplingMode:)`. Wrap such calls in
`#if compiler(>=6.4)` and never treat a green local build as a green CI.

## 11. The verification order that actually works

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
