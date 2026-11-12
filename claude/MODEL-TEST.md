# The PodSkipper test — how ad finders are compared (Pass 59, 7 Nov 2026; §9 added in Pass 63, 11 Nov)

Written for his 7 Nov questions: per-hour numbers from different episodes can't be compared; why two made-up tests (Basic/Hard); what a sensible score weighs; is a model better than the Reader; what the CPU copy is and when it reads. Tool: `Tools/ReaderData/podtest.py`. Lab runs: `build/p59/` (git-ignored).

## 1. What was wrong with the old numbers

- **Different episodes per engine.** "On Your Episodes" in Compare Models put the Reader on 26 episodes beside Bonsai 2 on 3, Apple Intelligence on 8 and Qwen3.5 4B Instruct on 29. Ad load alone runs from **0 s/h** (Chapo, Peter Attia: plugs only) to **361 s/h** (2 Bears 1 Cave, Bad Friends) across his 16 labelled shows, so those rows measured which episodes each engine happened to read as much as the engine. Seconds per hour is a fine unit **on the same episodes** (every engine then faces the same ad load); across different episodes it isn't, and neither is a percentage (shows differ in how hard their ads are, not just how many).
- **Basic/Hard** are two made-up samples of 40 and 50 lines. Basic gives most engines 100 %; Hard agrees only loosely with real episodes (Spearman ≈ 0.53). They show whether a model loads, answers in the right form and follows the rules. They are now labelled as quick checks.
- **Not a counting error.** Plugs (the hosts' and a guest's), other shows' promos, intros and outros are labelled as their own kinds and always count as "should be skipped": missing them counts as heard, cutting them is never counted as cutting the show. Disclaimers, the host's introduction of a guest's work and the joke that leads into a read are labelled EITHER: neither way counts. The show is everything else. Caveat: the labels are mine (Claude's) from the transcripts under a written policy (`Tools/ReaderData/LABEL-POLICY.md`), not his decisions; his own corrections on the phone always win.

## 2. The score

One number from 0 to 100 per engine: **how much of the interruption it removes, net of the damage it does.**

Cost of an episode, in seconds:

| what | cost |
|---|---|
| each second of an ad, plug, promo, intro or outro still heard | 1 |
| ...except the first and last 2 s of each break (a cut a moment early or late is not counted) | 0 |
| each break you'd notice (more than 5 s of it heard) | +10 |
| each second of the show cut (except 1 s next to a break) | 2 |
| each jump in the show (a show cut longer than 2 s) | +10 |

Skipping nothing costs every break's length plus 10 s each: that is **0**. Skipping every break exactly is **100**. An engine that cuts a lot of the show can go below 0. Every show counts the same (a show with 8 labelled episodes can't outvote one with 2).

### His two scenarios, worked

Engine A finds every break but leaves a little at each edge; engine B cuts every ad exactly but misses one plug.

| episode | A, 1–2 s left at each edge | A, 4 s left at each edge | A, 6 s left at each edge | B, misses one plug |
|---|---|---|---|---|
| 12 ads (10 s – 2 min) + 3 plugs of 2 min | **99.9** | 95.0 | 78.0 | 89.8 |
| 4 ads (2–4 min) + 4 plugs of 30–45 s | **100.0** | 96.6 | 84.6 | 95.1 |

A cut a second or two late costs nothing; once what's left of each break is long enough to notice (6 s at each edge = 8 s heard per break), A is worse than missing one plug, and the episode with more breaks punishes it more. Missing a 2-min plug costs more than missing a 40-s one.

## 3. Two views of the same run

- **Everyday** — whole episodes, as he hears them: the score above.
- **Challenge** — the same episodes cut into situations, each counting the same however rare: host read, recorded spot, back-to-back spots, short spot (< 20 s), long read (> 2 min), pre-roll (first minute), post-roll (last 2 min), a plug round the host opens, the show's own plug, another show's promo, intro, outro and credits, and two traps: show talk with selling words in it, and talk about tours, tickets and merch (both to keep). A situation counts as handled when less than 5 s of it is heard (or, for a trap, when it isn't cut).

Both come from one run, so a hard situation that shows up once in 70 episodes still counts as much as host reads do.

## 4. Fair by construction

- **Paired.** An engine is ranked only on episodes the engines it's compared with have also been scored on.
- **No training on the test.** The Reader is scored only on episodes it never learned from: his 11 test episodes (the shipped Reader never saw them) and, for shows it has never seen, the show-held-out readers (each trained without that show). Episodes labelled from a future export are added to the test and never trained on.
- **Intervals.** 95 % intervals resample shows, then episodes within them.

## 5. Results (7 Nov 2026)

The app's cut check as it is from Pass 59 (the Reader's ads and sure plugs stay; see §6).

**His 11 test episodes (7 shows; no Reader trained on them):**

| engine | Everyday (95 %) | Challenge | breaks noticed | skippable heard | show cut s/h |
|---|---|---|---|---|---|
| Reader | **92.4** (88–97) | 92 | 7 / 80 | 4 % | 3.0 |
| Qwen3.5 4B, GPU copy (MLX, Mac) + Reader | 88.2 (81–97) | 88 | 11 / 80 | 6 % | 3.5 |
| Qwen3.5 4B, CPU copy (Mac, 10 episodes) + Reader | 87.3 (80–96) | 90 | 9 / 80 | 6 % | 5.3 |

**His phone's own model reads** (40 labelled episodes; each row paired with the Reader on that engine's episodes; the Reader learned from about two thirds of these, so both columns are kinder than on a new show):

| engine | episodes | engine + Reader | Reader alone | difference (95 %) |
|---|---|---|---|---|
| Qwen3.5 4B (MLX) | 27 | 91.2 | 91.5 | −0.3 (−3.7…+3.7) |
| Qwen3.5 4B Instruct 6-bit (MLX) | 30 | 91.2 | 91.9 | −0.7 (−4.6…+3.3) |
| MiniCPM5 2B (Core AI) | 18 | 86.3 | 91.7 | −5.3 (−9.2…−1.0) |
| Qwen3 4B (Core AI) | 21 | 83.1 | 92.3 | −9.2 (−15.0…−5.0) |
| Apple Intelligence (its reads before November) | 8 | 71.0 | 95.1 | −24.1 |
| Bonsai 2 4B (MLX) | 3 | 92.7 | 93.2 | too few |

**Shows the Reader has never seen** (all 71 labelled episodes, 16 shows, each scored by a Reader trained without that show): **76.3** (67–84). Where it fails (Challenge): intro 21 %, outro and credits 41 %, plug rounds 67 %, long reads 78 %, the show's own plugs 79 %; host reads, recorded spots and back-to-back spots 96–97 %.

**A model on a show the Reader has never seen** (model's own cuts plus that held-out Reader's, kept together without the app's check): Qwen3.5 4B catches breaks the Reader misses (41 → 25 noticed of 220) but adds show cuts (8.8 → 14.6 s/h); net +2.6 (−1.7…+7.1). Qwen3.5 4B Instruct +0.4. Core AI's Qwen3 4B −19, MiniCPM5 2B −36 (they cut a lot of the show).

### What this says

1. On shows it knows, **the Reader alone is as good as any engine or better.** No model helps there by more than the interval's width.
2. On a new show the Reader drops to about 76, and **Qwen3.5 4B is the only model that helps** (it catches openers, credits and plug rounds the Reader misses).
3. **Core AI's Qwen3 4B and MiniCPM5 2B make results worse** (they cut the show). Not recommended as the chosen model.
4. Apple Intelligence's reads were worse than the Reader's; measured on 8 episodes under an older pipeline.

## 6. The change it led to (Pass 59)

Before, a model's silence dropped the Reader's cuts unless the Reader was very sure and the words sold something. Now **the Reader's ads stay, and its plugs and promos when it is at least 65 sure**, unless the model calls them a joke ad or a regular bit; the model adds what the Reader missed (`ModelCutCheck.standsWithModel`). Intros and outros keep Pass 58's edge rule, and a long stretch whose only evidence is that it repeats elsewhere (a rerun) still needs more.

Replayed on all 129 model reads (paired, before → now): CPU copy 87.3 → 87.3, MLX lab 85.4 → 88.2, phone Qwen3.5 4B 90.9 → 91.2, Instruct 90.0 → 91.2, Core AI Qwen3 4B 81.7 → 83.1, MiniCPM5 2B 84.4 → 86.3 — **0 to +2.8 points, no more of the show cut**.

Every Reader cut standing, whatever its kind, scored about a point more again (e.g. Instruct 92.3, MLX lab 89.0). Not shipped: that point comes from the Reader's mid-episode "outros" and half-sure plugs, which Passes 45 and 58 found cutting the show on his phone (a guest's tour talk, a This American Life rerun); the Reader learned most of these episodes, so its false alarms there are rarer than on a new show and the replay can't show the cost.

## 7. Which engine reads, when (and why)

**Pass 63 changed this: see §9.3.** There are now five choices in Find Ads With (a CPU model is one of them), a "When Locked or in the Background" setting, several CPU models, and the CPU model also stands in for Apple Intelligence off screen. The table and the "why" below describe Pass 59–62.

The Reader always reads first (seconds, on the processor, any time). Then, for the engine chosen in Settings › Find Ads With:

| chosen | PodSkipper on screen | locked / another app, on battery | locked, overnight on the charger |
|---|---|---|---|
| PodSkipper Reader | Reader | Reader | Reader |
| an MLX model (e.g. Qwen3.5 4B, Bonsai 2) | that model on the graphics chip | **CPU copy** (paced, ≤ 45 % of one core) | **CPU copy** at full speed |
| a Core AI model | that model | **CPU copy** (paced) | **CPU copy** at full speed |
| Apple Intelligence | Apple Intelligence | Reader now; Apple Intelligence when you open the app | Apple Intelligence |

Without the CPU copy downloaded (or switched off), the MLX and Core AI rows fall back to: Reader now, the chosen model when you next open the app (on a charger, Apple Intelligence reads meanwhile if available).

Why:
- **iOS refuses the graphics chip** to an app that isn't on screen unless it is signed with Background GPU Access, which his builds aren't. Every MLX and Core AI model is built for the graphics chip, so none can read off screen. The processor is allowed, within a limit (about half of one core averaged over a minute, or iOS ends the app; lifted in the overnight task that waits for a charger).
- **The CPU copy is one model, Qwen3.5 4B** (not Qwen3 4B): a 2.6 GB download (GGUF, 4-bit) read by llama.cpp, which is compiled into the app. It is the best model measured (§5) and fast enough on the processor (39–76 tokens/s on the Mac's cores). Another model would need its own CPU build and another 2–3 GB.
- **It stands in for whichever MLX or Core AI model is chosen.** Its read is a real model read: it stays when you open the app (re-reading with the chosen model costs battery and heat, and no chosen model measured better than Qwen3.5 4B). Find Ads Again reads it with the chosen model.
- **Apple Intelligence** is held back by iOS off screen on battery; Apple's model isn't the CPU copy's, so it isn't swapped in.
- **Can the CPU copy be the default?** In effect, yes: choose Qwen3.5 4B under Open-source models (MLX). With the CPU copy downloaded it reads on the graphics chip while the app is open and on the processor when it isn't — the same model either way, just two files. A separate "CPU only" choice would only make on-screen reads slower and hotter.
- **Compare Models** now has its own section for the CPU copy (Basic/Hard run at full speed).

## 8. The test on the phone (Pass 60, built; not yet run on his phone)

**Compare Models › The PodSkipper Test › Run the Test.** Every engine reads his 11 test episodes from the transcripts already on his iPhone and is scored with the same score, beside the Reader on the same episodes. Needed for Core AI and Apple Intelligence, which only run on the phone.

- **What reads, in order:** the Reader (always; every model starts from its cuts), the chosen MLX model, the CPU copy (at full speed, screen on), the chosen Core AI model, Apple Intelligence. Each can be left out with its switch; one that isn't downloaded or is switched off in Compare Models says so and doesn't read.
- **The app's own path, nothing saved:** the Reader (`AdDetector.detectSentences`, the stored silences, ad-free comparison and repeated recordings, his show's lessons, Settings' confidence and padding), then for a model `ModelFinder.focusRanges` (Core AI: `fastRanges`, as in Find Ads) → the model → `ModelFinder.checkedCuts`. Up to 3 tries per read as Find Ads. Nothing is written to the episode: the cuts he listens with don't change. Left out: SponsorBlock hints (fetched from the internet; a test reads the same input every time) and **his lessons whose words occur in that very episode** (they would hand the engine the answer; counted per read). Not left out: what the Reader learned on his phone from his corrections (`OnDeviceReaderLearner`) — it can't be undone per episode; the shipped Reader never saw these episodes, but the phone's learned head may have.
- **The episodes:** `Resources/Detection/PodTest.json` (`podtest.py pack`): per episode only the labelled time spans, kinds, their Challenge situations, the traps and the duration — no transcript text, no titles (the repo is public). An episode not in his library, without a transcript, or whose length differs from the labelled one by more than 3 s (another version of the file: times wouldn't line up) is listed as not read, with the reason.
- **Score:** `PodTestScore` (Swift) = `podtest.py` `score_pack` / `everyday` / `challenge`. `PodTestScoreTests.testSwiftScoresMatchPython`: on 7 cut sets (the lab's Reader, MLX, CPU, a Core AI read, nothing cut, everything cut, every break exactly) every per-episode number and both scores agree within 1e-9 (fixture `Tests/Fixtures/PodTestParity.json`, `podtest.py parity …`). The phone shows Everyday and Challenge without intervals; the export carries every read's cuts, so `podtest.py test - --phone <export>` gives intervals on the Mac.
- **Long runs:** the screen stays on while it runs; leaving PodSkipper pauses it ("Paused: open PodSkipper to carry on") and it carries on when he's back (a model read interrupted mid-way reuses the answers it had). The run is saved after every read (`Application Support/PodTest/runs.json`, last 20 runs); if PodSkipper closes, **Resume** carries on where it stopped; a read that closed the app twice is recorded as failed, not tried again. Stop ends it; Resume or Start Over after.
- **Results:** each finder's Everyday score beside the Reader's on the episodes both read; its page shows Situations handled, breaks noticed, show cut per hour, each situation, and each episode (score, Reader's score, cuts, share read, time, failures). Earlier runs are kept.
- **Export:** Diagnostics (Model tests part) carries `podTest.runs` — per engine and episode: outcome, cuts (start, end, kind), seconds, parts, share read, lessons left out.

**Still to do:** run it on his phone (PHONE-CHECKLIST 21c), then score the export on the Mac. **More test episodes:** his next export's episodes become test episodes (labelled, never trained on), especially new shows — `podtest.py pack` rebuilds the app's copy.

## 9. Basic and Hard, version 4, and who reads when (Pass 63, 11 Nov; built, not yet run on his phone)

His 10 Nov run (build 07da0d7): the Reader scored 80 % on Basic and **0 %** on Hard; Apple Intelligence 0 % on Hard; nine models answered "lines 0–92" or "0–163" as one ad or one intro; CPU tests sat at 0 % until they ended.

### 9.1 The two samples (`Services/LocalModel/BenchScripts.swift`, `BenchSample.swift`, `BenchTimings.swift`)

Both are made-up episodes, so no engine has seen them. What changed is that they now have the **shape of real audio**: every line's length and the pause before it are drawn from his own labelled episodes (`Tools/ReaderData/bench_timing.py` — numbers only, no words), each word has its own time, and pauses of 0.45 s or more are passed on as silences, as the recognizer's are.

| | Basic "Kitchen Table" | Hard "Late Shift" |
|---|---|---|
| Length | 73 lines, 4.6 min | 380 lines, 21 min |
| For | a quick check that an engine loads, answers in the right form and follows the rules | an episode read the way Find Ads reads his |
| Holds | recorded pre-roll, a spoken intro, one host read, credits, recorded post-roll | 17 breaks covering every PodSkipper Test situation: intro, two spots back to back, a tour plug, a 30-line read then a short one, a guest's plug round, a mid-roll of spot + another show's promo + spot, a read the hosts wander off in the middle of, a plug round in conversation, credits, a Patreon plug after them, two post-rolls |
| To keep | talk about a pot nobody paid for | brand talk (Costco), a joke ad ("Pete's Back Brace … use code OUCH for nothing off"), tour stories, a listener's gadget, a ticket story |
| How a model reads it | the whole sample in one go | the Reader first, then the model on the stretches Find Ads would show it (`ModelFinder.focusRanges`; Core AI `fastRanges`), then `ModelFinder.checkedCuts` |

Hard is 21 minutes because the Reader's position facts ("in the first ten minutes", "in the last ten") were both true for every line of a 14-minute sample, and it then read whole stretches wrongly — one cause of the 0 %.

### 9.2 The score (`PodTestScore.Quality`)

Four parts, each shown:

- **Ads cut** — share of every break's seconds removed (2 s at each edge of a break may be left).
- **Show kept** — share of the show's seconds still there (1 s beside a break, and the pause between two breaks back to back, count as neither).
- **Edges** — of the breaks found, how many starts and ends are within 3 s.
- **Kinds** — of the breaks found, how many were given the right kind (ad, plug, another show's promo, intro or credits).

**Score = ads cut × show kept² × (0.8 + 0.1 × edges + 0.1 × kinds).** Cutting nothing is 0; cutting everything is 0 (nothing of the show kept); every break exactly and named right is 100. One cut two lines too long costs a few points, not all of them: the old score (the Everyday formula on one short sample) went to 0 when the seconds of show cut, counted double, reached the seconds of ads — which a single over-long cut did. Losing a tenth of the show costs about twice what hearing a tenth of the ads does (0.81 against 0.90).

For a model, two scores are saved and shown: **the model alone** (its own answer after the guards of §9.4, before the cut check) and **with PodSkipper's check** (what Find Ads would save). Results of versions 1–3 are kept in the history but not ranked.

Where it shows: under each Basic/Hard button ("Score 97 · Ads cut 99% · Show kept 100% · Edges 32 of 34 · Kinds 15 of 17", then the model-alone line), in each run's details, and in the scoreboard (Score, Ads cut, Show kept per finder and test).

### 9.3 Who reads when (`Services/FinderRouting.swift`; the pipeline follows the same rules)

Settings › Ad Skipping › **Find Ads With** has five choices, and **When Locked or in the Background** (The CPU model reads / Wait for the screen) sits under it for the three that can't read off screen. One sentence under them says what will happen.

| chosen | on screen | locked or another app in front | read again when he's back |
|---|---|---|---|
| PodSkipper Reader | Reader | Reader | — |
| Apple Intelligence | Apple Intelligence | the CPU model (on battery; if "The CPU model reads" and one is downloaded), else the Reader's cuts | Apple Intelligence |
| Open-source models (MLX, graphics chip) | the MLX model | the CPU model, whose read is kept; else the Reader's cuts | only if it waited |
| Core AI models | the Core AI model | the same | only if it waited |
| CPU models (processor) | the CPU model | the CPU model (paced on battery, full speed on the charger overnight) | — |

"Use It on Screen Too" is gone: with an MLX or Core AI model chosen and that switch on, the CPU model was already reading everything, so that combination is moved once to the fifth choice (`FinderRouting.migratePrimarySwitch`); with Apple Intelligence or the Reader chosen it did nothing and nothing changes.

**CPU models** (`CPUReading.catalog`, each a GGUF pinned to a commit with its size and SHA-256; llama.cpp b12283): Qwen3.5 4B (Q4_0, the default), Qwen3.5 4B Instruct 6-bit (Q6_K), Qwen3.5 2B, **Liquid LFM3 1.7B** (new), LFM2.5 1.2B. They are in Compare models (CPU Models (Processor) › All CPU Models) and in Settings › Ad Skipping › CPU model library whether or not they are downloaded; a deleted one keeps its row, its latest results and its runs.

Mac lab, 11 Nov, 4 threads, the answers the app's code produced (`Tools/CPULab`, `build/p63/cpu-*.json`, scored by `lab-bench`) — **not phone results**:

| CPU model | Basic alone | Basic checked | Hard alone | Hard checked |
|---|---|---|---|---|
| PodSkipper Reader (no model) | 91 | — | 97 | — |
| Qwen3.5 4B Q4_0 | 98 | 96 | 98 | 99 |
| Qwen3.5 4B Q6_K (Instruct) | not run | not run | 98 | 99 |
| Liquid LFM3 1.7B | 94 | 91 | 27 | 96 |
| Qwen3.5 2B | 0 (answers nothing) | 87 | not run | not run |
| LFM2.5 1.2B | 23 (3 show lines cut) | 81 | not run | not run |

Read with care: only the two Qwen3.5 4B files do the job by themselves. LFM3 1.7B is good on a short sample and finds few of a long episode's ads; with the check its Hard score is the Reader's. Qwen3.5 2B and LFM2.5 1.2B add nothing or do harm: when a model is silent, the check keeps the Reader's ads and sure plugs but not its unsure credits, so "checked" can be below the Reader alone.

### 9.4 What stops a whole-sample answer (`JudgePrompt.shifted`, every family)

- "SHOW" is no longer a label a model can give; the instructions say parts hold only what would be skipped; a SHOW entry in a free answer is dropped.
- A part that covers more than **half** of the stretch it was shown (`maxCutShare`, now 0.5 for every family; it was 0.6 for two and unlimited for the rest), or restates the stretch whole (also for the 8–29-line stretches Core AI is shown), is dropped.
- A part longer than its kind can be (intro 150 s, recorded ad 7 min, host read 9 min, plug 10 min, credits 7 min, joke 4 min) is dropped.
- Parts that label the same lines differently (LFM2.5 1.2B: one stretch as promo, plug, intro and outro at once) are all dropped.
- If what is left still cuts more than 70 % of a stretch of four minutes or more (Qwen3.5 2B on the CPU: every three lines "a host read"), every cut part of that answer is dropped.
- On the CPU the answer is held to the form by a grammar (`JudgePrompt.leanGrammar`, llama.cpp's sampler), so it can always be read.
- A short "ad" that says it isn't one ("for nothing off", "this show needs a sponsor", "they're not paying us") is kept in the show, by the Reader (`SegmentDetector.saysItIsNotAnAd`) and by the cut check.

Per family (`ModelPromptPlan`): LFM3 is asked with a short guided set of rules (`Profile.guided`: go through the lines, give first and last line, last larger than first) — with the ordinary rules it scored 6–36 % on Basic, with these 94 %. The quoted empty answer was taken out of the small models' rules: held to the form, a small model primed with `{"parts": []}` closes the list at once. Qwen3.5 4B keeps the listener's rules, with the joke ad's tells spelled out (Hard alone 93 → 98).

### 9.5 Progress and time left

The bar is only ever work done. On the CPU the engine reports after every batch of prompt tokens and every token of the answer (`LlamaEngine.answer(progress:)` → `CPUJudge.Reporter` → `WorkMeter`), so the bar moves from the first seconds, with "Reading the sample on the CPU · part 1 of 2 · 42% · 21 tokens a second", then "Writing its answer · 37 tokens · 3.3 a second". Core AI reports nothing while it reads a prompt, so nothing is added until that read is done (the clock used to add an earlier run's speed × time, which ran to 72–80 % and stopped); the line under the bar says so. Time left comes from this run's own speed; until that has been measured it says "Measuring speed…".

