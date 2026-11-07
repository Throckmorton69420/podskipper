# The PodSkipper test — how ad finders are compared (Pass 59, 7 Nov 2026)

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

## 8. What's next for the test

- **On the phone:** a "Run the test" in Compare Models that reads his test episodes (already on his phone) with each engine, without changing the cuts he listens with, and scores them with this score. Needed for Core AI and Apple Intelligence, which only run on the phone. Not built yet; see FINISH-PLAN.
- **More test episodes:** his next export's episodes become test episodes (labelled, never trained on), especially new shows.
