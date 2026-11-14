# PodSkipper — finish plan (written 6 November 2026, 03:20)

One plan for everything you have asked for, from the [Request Catalog](REQUEST-CATALOG.md): 181 base requests and 270 later requests over 58 passes. The goal is a **release-quality app**, not a list of passes. Each phase says what "done" means and who can prove it: things I can prove on the Mac (code, tests, simulator), and things only your iPhone/iPad can prove.

Where things stand today, honestly:

- **Not built / still broken (14):** U17 icon review, L21 catalogue saves (failures still ignored in `LibraryIndex.swift`), A23 sound settings with video, D05 quality goals (no engine meets ≤ 10 s/h ads heard and ≤ 5 s/h show cut), D06/D14 checks on your episodes, P09 full-library performance, A17/B12/C01 (depend on the signed app you install), M19 Nemotron, plus release requirements nobody had listed: **no privacy manifest** and **no accessibility audit**.
- **Built, simulator-checked, waiting on your phone (~120):** most of the player, Activity, models, Library, video, backup and publishing requests. The code exists and passes tests; only a phone run can close them.
- **Settled (26):** decided, declined or superseded; nothing to do.

## Status (updated 14 Nov, Pass 65)

| Phase | State |
|---|---|
| 0 Reader | **shipped** (b2bb998) — passed both steps; his 11 test episodes: ads heard 13.4 → 10.6, show cut 4.7 → 4.4 s/h. Goal ≤ 10 heard: not yet met (10.6–11.7 depending on how saved) |
| 0b Model reads | **cut check fixed** (X58-15): every engine hears fewer ads, none cuts more show; still, the Reader alone hears fewer ads than any model on the same episodes — keep the Reader as the finder |
| 0f Pass 64 (13 Nov) | **built (simulator + device build + Mac lab):** his 3cee01c run, seven objectives (TASKS.md) — Stop ends at once (run tokens, llama.cpp abort), Core AI load gate and compiler-scratch purge, no disk access in Compare Models' bodies (the three watchdog kills), the model alone as the headline, the check's conversation veto (Hard show lines cut 240 → 96 on his 80 answers), grammar fix (Qwen3.5 2B CPU alone 0 → 34 %), Core AI answers 512, samples v5, Reader 98 on Hard (11 test episodes still 91.8, goal 93 not met), distillation script, external drive (app + Mac script), Compare Models queue/time left/telemetry/folds. Catalog X64 rows; phone checks 21l–21r |
| 0g Pass 65 (14 Nov) | **built (simulator + Mac lab):** his Gemini-drafted continuation — Part 1 re-checked (two more main-thread disk reads moved off it), the large-text UI test fixed (it had run at the default size since Pass 31) and four large-text layouts fixed, the drive script's Core AI compiles for the GPU (Apple's Neural Engine compiler crashes); SPoRC + SponsorBlock pipeline audited and run: **38 verified episodes**, too few to train on under the rule written first; a 4B teacher scores 64.5 vs the Reader's 91.8; Kaggle 27B teacher runner ready. Catalog X65 rows |
| 0e Pass 63 (11 Nov) | **built (simulator + Mac lab):** his 07da0d7 run, eight workstreams — the Reader 91 on Basic and 97 on Hard (was 80 and 0) and a little less show cut on shows it hasn't seen (7.7 from 8.8 s/h); learning starts at launch and seconds after a correction, with Update Learned Reader; Basic/Hard version 4 with real timing and a four-part score (ads cut, show kept, edges, kinds; the model alone and with PodSkipper's check); no family can answer with the whole sample; CPU models listed before download and after delete, a fifth choice in Find Ads With, "When Locked or in the Background", one sentence saying who reads when; CPU progress from the first batch, time left from this run's speed; llama.cpp b12283 and Liquid LFM3 1.7B (CPU); Core AI's catalog resolved per chip and size, space checked before preparing, leftovers removed. Catalog X63 rows, [MODEL-TEST §9](MODEL-TEST.md) |
| 0d Pass 62 (8 Nov) | **built (simulator):** his 2d2f608 run — the finished test's table no longer hidden by a stopped run (Keep Earlier Results), centred buttons; Basic/Hard v3 (representative, PodSkipper-Test scoring) and a live scoreboard instead of typed-in Mac numbers; any downloaded MLX/CPU/Core AI model in one test run; four CPU models (Qwen3.5 4B Q4/Q6 Instruct twin, 2B, LFM2.5 1.2B; LFM3 not loadable in llama.cpp b12110), 640-token answers with halving, exact prefix-state reuse; exports streamed to disk; video with different breaks plays with its own sound; Reader learning steps within the lab limits; CPU model for Apple Intelligence off screen. Catalog X62 rows |
| 0c Model test (7 Nov) | **built (lab):** the PodSkipper test ([MODEL-TEST](MODEL-TEST.md)) — one 0–100 score on the same episodes for every engine, plus a Challenge view by situation; Compare Models' unfair table replaced; the CPU copy is an engine there; the Reader's ads and sure plugs now stay when a model reads (0 to +2.8 points for every engine, no more show cut). **Pass 60: built on the phone** — Compare Models › The PodSkipper Test › Run the Test (MODEL-TEST §8); Swift score = lab score (unit test). **Open:** his run on the phone (checklist 21c), then the export scored on the Mac |
| 1 Defects | **done** — L21, 92 silent saves, A23; plus his 6 Nov Speed and Audio report (X58-16: the choice stays; per-speaker) |
| 2 Release requirements | privacy manifests, purpose string, words, icon **done**; accessibility: audit completes every screen, the one fixed-background failure fixed, the rest is text under floating glass (as Apple's); performance on his library size **measured** (opens in < 0.2 s, first screen ≤ 1 s, idle 4 % CPU, ≤ 207 MB); App Store call **his** |
| 3 Every screen | **done on the simulator** (six modes, 7 defects fixed). 27.3: episode hero header, transcript highlighting rework, video toggle logic — internal changes with no screens or public description; need screenshots of Apple's app on 27.3 |
| 4 Data end to end | existing tests cover backup/restore failure points, publishing queue and feed, signing |
| 5 Phone pass | PHONE-CHECKLIST, 46 checks, current for the Pass 63 IPA |
| 6 Delivery | each batch: code push alone (IPA), then docs. Pass 63: 3cee01c pushed alone on 12 Nov after he renewed the GitHub token; IPA run 43205931258 started (result not checked) |

### Every open item and who closes it

| Item | Who | What closes it |
|---|---|---|
| Reader ≥ 93 on his 11 test episodes (his 13 Nov target; Hard ≥ 98 is met) | me → **you** | 91.8 in the lab after Pass 64 (kind split changed nothing there). Next: a teacher read of the unlabelled pool with `Scripts/distill_reader.py`, trained and judged under the rule in that file. A cloud teacher sends his episodes' transcripts to the provider he picks — **his call** (provider, key); the local teacher (Qwen3.5 4B Instruct 6-bit on the Mac's CPU or MLX) needs nothing from him |
| Models on the external drive | **running** → you | `ssd_models.sh` restarted 14 Nov with GPU compiles (Apple's Neural Engine compiler crashed it); then checklist 21o–21p |
| `testAccessibleModelsAndSound` | **done (Pass 65)** | the tests' large-text launch value wasn't one UIKit knows, so they ran at the default size; fixed, passes at the real size, and the four layouts it then showed broken are fixed (X65-02). Phone: try the largest text size once (checklist 21s) |
| ~120 built features never seen on his phone | **you** | PHONE-CHECKLIST, then one Diagnostics export |
| Reader learning rolled back, then never tried again (his 8 and 10 Nov exports) | **built (Pass 62, 63)** → you | `trustStep` keeps the largest step within the lab limits; Pass 63 found the retry was unreachable and only ran in idle upkeep — now it runs at launch and seconds after a correction, and Update Learned Reader runs it by hand. Lab check on his 29 corrections: a head is kept (`inUse true`), and it changes no cut on any of his 71 labelled episodes — no gain and no harm yet, because the shipped Reader already gets the corrected episodes right. Closes with his next export's `readerLearning.inUse` (checklist 21j) |
| iOS 27.0 simulator | **done** | already gone since the 8 Nov Mac cleanup; only the 27.2 runtime and its iPhone 16 Pro remain (X63-08) |
| Every model family on the new Basic/Hard | **you** → me | the CPU models were measured on the Mac (MODEL-TEST §9.3); the MLX and Core AI families and Apple Intelligence only run on the phone — checklist 21f, then the export |
| A real CPU read's progress bar and time left | **you** | built and unit-tested from the engine's reports; seen moving in the simulator only through a stand-in read (checklist 21b) |
| Core AI: LFM3 1.7B portable build, Mistral 7B's Mac build, preparation with little space | **you** | resolved from the catalog and unit-tested; never loaded on a device (checklist 21k, 22) |
| D05 quality goal (≤ 10 s/h ads heard) | **running** → you (Kaggle sign-in) | Reader 10.6–11.7 on unseen episodes of shows it knows; on shows it has never seen (show-held-out, 71 episodes) about 34 s/h heard, 7.7 s/h show cut (Everyday 77.2). Pass 65: SPoRC + SponsorBlock gave only 38 episodes (not trained). **Both routes under rule 6:** route 1 running since 14 Nov 02:35 — 1,776 new SponsorBlock podcast episodes from 544 channels, then training and steps A/B on its own (report `~/Developer/pk-data/sb65/REPORT.txt`, ~2–3 days); route 2 measured 14 Nov: Qwen3.8 27B scores 63.5 vs the Reader's 91.8 on his test episodes (finds 79/80 breaks but cuts 33 s/h of show on comedy shows) — does not qualify, labels nothing. Route 1: all audio fetched (1,717), transcription ~60 % at 13:00 14 Nov; training and steps A/B follow on their own |
| D06/D14 checks on his own episodes | you → me | his next export (the Reader judged on episodes he hasn't labelled) |
| Accessibility: 100 audit flags | me | checked by eye: text under the floating tab bar/mini player and on the mini player's glass (as Apple's); the one failure on a fixed background fixed. The audit no longer names elements on this simulator — re-check when Xcode does |
| P09 big-library speed | you (phone) | simulator measured (X58-17): no problem found; phone checks 4 and 38 for hitches and heat |
| 27.3 episode header ("hero" cards), video switch | you (screenshots) | screens of Apple Podcasts on a device running iOS 27.3 (his phone is on 27.2; the iPad's version isn't recorded). 27.3's transcript rework aligns words to their timings; PodSkipper's transcripts already carry a timing for every word (0 mismatches in 74,656 lines), so it highlights word by word already |
| Sync on the main thread | **built (Pass 60)** → you | his 7 Nov export: three 4-s main-thread stalls at 17:58–17:59 UTC on 6 Nov, right after "Cloudflare sync: sent 39". Now `CloudRecordsBuilder` (plain actor, own context) reads the library and decides what to send and apply off the main thread; other devices' records are applied on main 25 at a time with a run-loop turn between; an edit made during the sync is kept; the push holds a background task until the records are written, then the relay sends. Tests: the old sync tests unchanged and passing, new off-main/batch/edit tests, and two syncs on a disposable copy of the simulator's library (HANDOFF §1u). Phone: no "stalled" lines at the background transition in his next export (checklist 38–40). Pass 62: the full listening push already runs off main since Pass 60 (`ListeningWriter`); only `notePaused`'s one-episode push stays on main — measure the transition in the next export |
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
