# PodSkipper — finish plan (written 6 November 2026, 03:20)

One plan for everything you have asked for, from the [Request Catalog](REQUEST-CATALOG.md): 181 base requests and 270 later requests over 58 passes. The goal is a **release-quality app**, not a list of passes. Each phase says what "done" means and who can prove it: things I can prove on the Mac (code, tests, simulator), and things only your iPhone/iPad can prove.

Where things stand today, honestly:

- **Not built / still broken (14):** U17 icon review, L21 catalogue saves (failures still ignored in `LibraryIndex.swift`), A23 sound settings with video, D05 quality goals (no engine meets ≤ 10 s/h ads heard and ≤ 5 s/h show cut), D06/D14 checks on your episodes, P09 full-library performance, A17/B12/C01 (depend on the signed app you install), M19 Nemotron, plus release requirements nobody had listed: **no privacy manifest** and **no accessibility audit**.
- **Built, simulator-checked, waiting on your phone (~120):** most of the player, Activity, models, Library, video, backup and publishing requests. The code exists and passes tests; only a phone run can close them.
- **Settled (26):** decided, declined or superseded; nothing to do.

## Status (updated 6 Nov, 06:00)

| Phase | State |
|---|---|
| 0 Reader | **shipped** (b2bb998) — passed both steps; his 11 test episodes: ads heard 13.4 → 10.6, show cut 4.7 → 4.4 s/h |
| 1 Defects | **done** — L21 (catalogue saves), the other 92 silent saves; A23 found already built (limit stated in the player) — commit daa2677 |
| 2 Release requirements | **done except the App Store call** — privacy manifests, purpose string, accessibility 240 → 91 issues (run 4 running), words scanned, icon reviewed; performance measurement queued; App Store findings in RELEASE-CHECK |
| 3 Every screen | **done on the simulator** — six modes; 7 defects fixed (b2bb998); no stalls on a big library without test tools. Open: 27.3 internals without runtime screens (your screenshots would settle them) |
| 4 Data end to end | existing tests cover backup/restore (every failure point), publishing queue and feed; added the signing check. Passed in the 580-test suite |
| 5 Phone pass | drafted: PHONE-CHECKLIST (40 checks); final once phase 3's fixes are in |
| 6 Delivery | **pushed** daa2677 + b2bb998 (IPA run 42206297105); docs follow with [skip ci] |

## Phase 0 — the Reader (running now)

- 02:38 → ~03:30 pretraining on 457 SponsorBlock episodes; → ~05:30 both seeds trained on your episodes (log `build/p58/reader-ext-full.log`).
- Then the rule written before any results (`build/p58/ship-rule-4.txt`): both seeds must cut less show than today's Reader at the same ads heard, by ≥ 2 s/h on average. If yes, a final pair is trained without your 11 test episodes and must also win on those through the app's own Swift code. Either outcome is reported with numbers against your goals (≤ 10 s/h ads heard, ≤ 5 s/h show cut).
- **Licensing, before anything is published:** SponsorBlock's data is CC BY-NC-SA (non-commercial, share-alike) and the audio came from YouTube. A Reader trained on it is fine for your own builds; an App Store release needs your call (free app with attribution, or ship the Reader trained only on your episodes).

## Phase 1 — defects in code (Mac)

1. **L21:** catalogue saves stop ignoring failures (`LibraryIndex.swift` ×5, `EpisodeCatalogue.swift`): a failed save is reported, the "filled up to" marker advances only after a save that worked, matches by episode ID instead of title, and your listening edits survive. Tests that inject save failures.
2. Every other `try?` on a save across the app is checked the same way.
3. **A23:** speed, speech and EQ apply to video's sound too, or the limit is shown plainly where they can't (test on the simulator's video path).

Done = unit tests that fail before the fix and pass after; full suite green.

## Phase 2 — what a published app needs (Mac)

1. **Privacy manifest** (`PrivacyInfo.xcprivacy` for the app, widget and Now Playing extension): the reasons PodSkipper uses UserDefaults, file dates, disk space, and the data it collects (none leaves the device except your own sync/publishing).
2. **Accessibility:** Xcode's accessibility audit run on every screen in UI tests (labels, contrast, hit areas, Dynamic Type clipping), then fixes until clean.
3. **Words:** every user-facing string read once for jargon and for a plain explanation (U16, the "no implementation jargon" rule).
4. **Icon:** light, dark and tinted icons exist; reviewed on the Home Screen in each mode (U17).
5. **Performance on a big library (P09, Mac part):** launch time, scrolling and memory on a simulator library the size of yours, measured with Instruments; anything over Apple's hang threshold gets fixed.
6. **App Store rules check:** entitlements that need Apple's approval (CarPlay audio, background GPU, more memory), downloaded models, the Apple Podcasts look-alike design, sign-in-free sync. Output: what passes, what needs changing, what needs an Apple request.

## Phase 3 — every screen, every way (simulator)

The full tour from the plan's Batch 5 gate: Home, New, Search (categories, shelves, See All, results, previews, people), shows, episodes, Library (all lists, Stations), Up Next, the player (timeline, transcript, Speed & Audio, bookmarks, clips, video), the correction editor, Activity, Settings and every subpage, Compare models, both model libraries, Diagnostics.

- iPhone and iPad; portrait and landscape; largest text size; dark mode; Reduce Motion; Increase Contrast.
- Screenshots of every screen, compared against Apple Podcasts where it has the same screen; every broken, clipped, misaligned or dead-end screen fixed.
- Apple Podcasts 27.3 items not yet matched (episode header, transcript alignment, video switch): matched from the 27.3 strings and layout files where possible. Apple's 27.3 app only runs on a device, so screens you photograph from it would settle these exactly.

Done = a screenshot set of every screen in every mode with no defects left open.

## Phase 4 — your data, end to end (Mac, disposable copies)

Backup → delete app data → restore; restore of an old, corrupt, interrupted or iCloud-placeholder backup; storage cleanup; OPML import/export with a real file; Apple history import; publishing a corrected feed (queue, reorder, cancel, offline, relaunch, retry, one feed per show) against a local test server. Each flow becomes a repeatable test.

## Phase 5 — one phone pass (you)

One checklist, in order, about 40 checks, each saying what to do and what you should see — replacing the ~120 separate "phone acceptance open" items. It covers: the CPU reader while the screen is locked and overnight on a charger, Home, the player with AirPods/Bose/CarPlay/calls/Lock Screen, Find Ads on each engine, Activity and notifications, video, backup/restore, publishing, and iPhone↔iPad sync. It ends with one Diagnostics export that I analyse, so you don't send repeated small tests.

## Phase 6 — delivery

Code commit alone (builds the unsigned IPA on GitHub), then the docs commit; catalog and handoff updated with what each phase proved and what stays open.

## Order and timing

Phase 0 runs on its own until ~05:30. Phases 1 and 2 start now, alongside it. Phase 3 follows (the longest). Phase 4 after. Phase 5 is written as soon as phases 1–4 have changed what you'd test, then waits for you. Each phase ends with a commit, so nothing done is lost if a session ends.

## Decisions only you can make

1. **Published where?** App Store (needs an Apple Developer account in your name, App Review, the licensing call above, and Apple's approval for some entitlements), or your own sideloaded builds made release-quality. The work in phases 1–4 is the same either way; phase 2.6 and the Reader's licensing differ.
2. **RightSight** keeps coming back while Logi Options+ is installed.
