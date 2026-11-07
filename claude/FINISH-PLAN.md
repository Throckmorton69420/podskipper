# PodSkipper — finish plan (written 6 November 2026, 03:20)

One plan for everything you have asked for, from the [Request Catalog](REQUEST-CATALOG.md): 181 base requests and 270 later requests over 58 passes. The goal is a **release-quality app**, not a list of passes. Each phase says what "done" means and who can prove it: things I can prove on the Mac (code, tests, simulator), and things only your iPhone/iPad can prove.

Where things stand today, honestly:

- **Not built / still broken (14):** U17 icon review, L21 catalogue saves (failures still ignored in `LibraryIndex.swift`), A23 sound settings with video, D05 quality goals (no engine meets ≤ 10 s/h ads heard and ≤ 5 s/h show cut), D06/D14 checks on your episodes, P09 full-library performance, A17/B12/C01 (depend on the signed app you install), M19 Nemotron, plus release requirements nobody had listed: **no privacy manifest** and **no accessibility audit**.
- **Built, simulator-checked, waiting on your phone (~120):** most of the player, Activity, models, Library, video, backup and publishing requests. The code exists and passes tests; only a phone run can close them.
- **Settled (26):** decided, declined or superseded; nothing to do.

## Status (updated 7 Nov, Pass 60)

| Phase | State |
|---|---|
| 0 Reader | **shipped** (b2bb998) — passed both steps; his 11 test episodes: ads heard 13.4 → 10.6, show cut 4.7 → 4.4 s/h. Goal ≤ 10 heard: not yet met (10.6–11.7 depending on how saved) |
| 0b Model reads | **cut check fixed** (X58-15): every engine hears fewer ads, none cuts more show; still, the Reader alone hears fewer ads than any model on the same episodes — keep the Reader as the finder |
| 0c Model test (7 Nov) | **built (lab):** the PodSkipper test ([MODEL-TEST](MODEL-TEST.md)) — one 0–100 score on the same episodes for every engine, plus a Challenge view by situation; Compare Models' unfair table replaced; the CPU copy is an engine there; the Reader's ads and sure plugs now stay when a model reads (0 to +2.8 points for every engine, no more show cut). **Pass 60: built on the phone** — Compare Models › The PodSkipper Test › Run the Test (MODEL-TEST §8); Swift score = lab score (unit test). **Open:** his run on the phone (checklist 21c), then the export scored on the Mac |
| 1 Defects | **done** — L21, 92 silent saves, A23; plus his 6 Nov Speed and Audio report (X58-16: the choice stays; per-speaker) |
| 2 Release requirements | privacy manifests, purpose string, words, icon **done**; accessibility: audit completes every screen, the one fixed-background failure fixed, the rest is text under floating glass (as Apple's); performance on his library size **measured** (opens in < 0.2 s, first screen ≤ 1 s, idle 4 % CPU, ≤ 207 MB); App Store call **his** |
| 3 Every screen | **done on the simulator** (six modes, 7 defects fixed). 27.3: episode hero header, transcript highlighting rework, video toggle logic — internal changes with no screens or public description; need screenshots of Apple's app on 27.3 |
| 4 Data end to end | existing tests cover backup/restore failure points, publishing queue and feed, signing |
| 5 Phone pass | PHONE-CHECKLIST, 42 checks, current for the next IPA |
| 6 Delivery | each batch: code push alone (IPA), then docs |

### Every open item and who closes it

| Item | Who | What closes it |
|---|---|---|
| ~120 built features never seen on his phone | **you** | PHONE-CHECKLIST, then one Diagnostics export |
| D05 quality goal (≤ 10 s/h ads heard) | me | Reader 10.6–11.7 on unseen episodes of shows it knows; on shows it has never seen (show-held-out, 71 episodes) about 34 s/h heard, 10 s/h show cut — new shows are the weak spot. Next: more labelled episodes from his next export (new shows especially), retrain under a rule written first |
| D06/D14 checks on his own episodes | you → me | his next export (the Reader judged on episodes he hasn't labelled) |
| Accessibility: 100 audit flags | me | checked by eye: text under the floating tab bar/mini player and on the mini player's glass (as Apple's); the one failure on a fixed background fixed. The audit no longer names elements on this simulator — re-check when Xcode does |
| P09 big-library speed | you (phone) | simulator measured (X58-17): no problem found; phone checks 4 and 38 for hitches and heat |
| 27.3 episode header ("hero" cards), video switch | you (screenshots) | screens of Apple Podcasts on a device running iOS 27.3 (his phone is on 27.2; the iPad's version isn't recorded). 27.3's transcript rework aligns words to their timings; PodSkipper's transcripts already carry a timing for every word (0 mismatches in 74,656 lines), so it highlights word by word already |
| Sync on the main thread | **built (Pass 60)** → you | his 7 Nov export: three 4-s main-thread stalls at 17:58–17:59 UTC on 6 Nov, right after "Cloudflare sync: sent 39". Now `CloudRecordsBuilder` (plain actor, own context) reads the library and decides what to send and apply off the main thread; other devices' records are applied on main 25 at a time with a run-loop turn between; an edit made during the sync is kept; the push holds a background task until the records are written, then the relay sends. Tests: the old sync tests unchanged and passing, new off-main/batch/edit tests, and two syncs on a disposable copy of the simulator's library (HANDOFF §1u). Phone: no "stalled" lines at the background transition in his next export (checklist 38–40). Still on main at the transition: `pushListening` (up to 3,000 episodes' positions) — measure in the next export |
| PodSkipper test on the phone | **built (Pass 60)** → you | Compare Models › The PodSkipper Test › Run the Test (checklist 21c), then one export; I score it with `podtest.py test - --phone <export>` |
| M19 Nemotron, Core AI Qwen closures | you | Core AI's own loader errors on Nemotron and its GPU crashes on Qwen3 4B (X33-05, X34-02: Apple's MPSGraph issue upstream); mitigations built; phone check 22 says whether they still happen |
| A17/B12/C01 (Lock Screen tap, CarPlay, widgets in a signed app) | you | depend on how the app is signed (CarPlay needs Apple's approval) |
| Where it's published | **you** | see "Decisions only you can make" below |

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

1. **Published where?** "Ready to be published" can mean two different things, and only he knows which:
   - **Your own builds** (what happens now): GitHub builds an unsigned IPA, he signs and installs it himself with Feather. Nothing is reviewed by Apple; only his devices run it. Nothing else to decide.
   - **The App Store** (anyone can download it): needs a paid Apple Developer account in his name, his own bundle ID, App Review — which may object to an app made to look like Apple Podcasts (guideline 5.2.5) and to a feature that re-hosts other people's audio (publishing) — Apple's approval for Background GPU, CarPlay audio and more memory, and a Reader not trained on SponsorBlock's non-commercial data. See RELEASE-CHECK.
   Everything in phases 1–4 is the same either way.
