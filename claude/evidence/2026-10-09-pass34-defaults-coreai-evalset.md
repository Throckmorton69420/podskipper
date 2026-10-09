# Pass 34 evidence (9 October 2026): Speed & Audio defaults, Core AI Qwen3 4B crash, Reader evaluation set

Inputs: his request of 9 Oct (three items), Diagnostics `PodSkipper-diagnostics-1791578021.json` (build **8bbe5dd**, iPhone17,1, iOS 27.0.1, exported 20:33Z), the five Results exports and nine Diagnostics exports in his iCloud Downloads, the lab fixtures and caches in this checkout. Nothing was downloaded to the phone, no model was rerun, no CI was triggered.

## 1. Speed & Audio defaults and Reset All (A04, X33-04)

**Cause.** Reset was correct in mechanism and wrong in target: it removes every Speed and Audio key so each reads back as the *registered* default, and the registered defaults (`Models/Models.swift`, `AppSettings.init`) had `"normalize": true` and `"rumble": true`. Every other Speed and Audio key already registered off/neutral. Full list checked (24 keys in `AppSettings.soundKeys`): speed 1.0; Smart Speed off; Volume Normalization **on → off**; Even Out Volume off; Mono off; Equalizer off, preset Flat, gains flat; Reduce Rumble **on → off**; Reduce Boom, Reduce Muddiness, Reduce Nasal Tone, Enhance Dialogue, Reduce Harshness, Reduce Sibilance, Brighten Muffled Voices off (strength sliders keep their defaults, which are inaudible while the fix is off). There is no other sound effect in the app (`Repair.allCases` is these eight).

**Fix.**
- Registered defaults are now the neutral baseline (new installs and Reset both read them).
- `SoundSettingsMigration.keepPreviousDefaults` runs once per install: on an *existing* install (one that has the sound model's version key, written every launch since Pass 29, or older legacy keys) it stores Volume Normalization and Reduce Rumble as **on** wherever he never set them, so an ordinary update doesn't silently change what he hears. A value he set is untouched. A fresh install stores nothing. After the one-time step, Reset removes the keys and lands on neutral.
- Per-show settings are untouched by the update; Reset still offers "and N shows" separately, with Undo.
- The Reset confirmation text now states the neutral baseline (it used to say "Volume Normalization on … only Remove Rumble on").

**Tests (PS-Unit, iOS 27.0 simulator).** `Pass33Tests`: `testResetRestoresFreshDefaultsAndUndoes` now asserts his baseline field by field (`assertNeutral`: speed 1×, Smart Speed, normalization, Even Out, Mono, EQ off/Flat/flat gains, every `Repair` off); new `testFreshInstallIsNeutral` (nothing stored on a fresh domain; registered defaults neutral) and `testUpdateKeepsWhatAnExistingInstallHeard` (old on-defaults stored as on, his own off kept, the step runs once so a later Reset isn't undone). 19/19 pass. The first run failed and caught two test-design errors (a suite `UserDefaults` also reads the app's domain; Reset re-stores values through `didSet`) — the migration now reads only the stored domain.

Phone check needed: after installing, his current sound is unchanged; Reset Speed and Audio… → all off, 1×, EQ flat.

## 2. Core AI Qwen3 4B crash

### What the evidence already showed (not re-tested)

| Question | Evidence | Status |
|---|---|---|
| Is prompt-prefix reuse the cause? | Off on iPhone since 3ba90ff; same abort on 5 Oct (before reuse existed) and 9 Oct | **Ruled out** (Pass 33) |
| Is it memory (jetsam)? | Signal 6 abort, not SIGKILL; free memory 6.7–6.8 GB before runs | Not jetsam |
| Is it crossing the 2,048 context bucket? | 5 Oct whole episode read ~3,500-token parts across 2,048 without crashing | Not shown |
| Where in the run? | Pass 33 in-flight note, three crashes on 8bbe5dd (before 09:18, ~20:24, before 20:32): every one "reading about 1952 prompt tokens · StaticShapeEngine" — the note switches to "writing" at the first answer token, so all three were **prompt reading** | **New: reading (prefill)** |
| Is it the input? | The same tests (greedy, same prompt) passed at 09:45–09:46 on the same build, between crashes | Intermittent, not input-determined |
| Which code? | MetricKit 8bbe5dd stack (delivered 20:24:31): `respondDirectly` → coreai-models `StaticShapeEngine` (`buildInputs`/graph run) → CoreAIDelegates → CoreAIRuntime → MPSGraph → Metal → `abort` | GPU (MPSGraph) path of Core AI |

### What changed this pass

- The static-shape engine reads a prompt longer than 64 tokens with its 64-token-wide `prompt_opt_<ctx>_64` graphs and writes the answer with its 8-token-wide `extend_<ctx>_8` graphs (coreai-models `CoreAIStaticShapeEngine.forwardGraph`/`inference`). Every crash is in the 64-wide reading; the 8-wide writing has never crashed (thousands of steps, including a full 17-part episode).
- Upstream: **apple/coreai-models #201** (open; Apple filed internal feedback 29 Aug) and **#27**: on iOS 27, MPSGraph's scratch heap overflows on multi-token prefill chunks and aborts with signal 6 (`allocateMTLBufferFromMTLHeap … exceeds heap total` → `failed assertion … ViewOp`); the overflowing buffer scales with the chunk width S, and S=1 avoids it. This is an Apple runtime fault PodSkipper can't catch, which matches our stack and signal.
- **Correction (`Services/CoreAIClassifierSession.swift`, `StaticPrefill`)**: for the static-shape engine, PodSkipper now feeds the prompt in 8-token steps (each `generate` call extends the engine's cache by ≤ 8 tokens, aligned, so the engine picks its 8-wide graph), and the first answer step reads the last ≤ 8 tokens and gets the scores. Same tokens, same cache, same greedy answer. Expected reading speed: an 8-wide pass costs about one writing step (~15/s on his phone → ~120 prompt tokens/s), similar to or faster than the 80–107/s measured with the 64-wide graphs; not yet measured on the phone.
- The crash note now names it: "StaticShapeEngine · prompt in 8-token steps", so the next Diagnostics distinguishes the new path.
- Unit test `Pass34Tests.testStaticPromptIsReadInNarrowSteps` (step plan); Release iphoneos device compile succeeds (`./Scripts/device-build.sh`, warnings pre-existing).

Status: **hypothesis-driven correction, built; phone unverified.** It is the evidence-supported change, not a proof: S=64 also ran cleanly many times, so it is intermittent; if a crash recurs with the new note, the narrow path is refuted too.

### If it still crashes: what's left, honestly

The abort is inside Apple's runtime (MPSGraph), not PodSkipper code; PodSkipper can't catch it. Remaining levers, in order: (1) Apple's fix to #201 in a later iOS 27.x — nothing else to do in-app; (2) `.cpuOnly` specialization avoids MPSGraph entirely but would make a 4B model impractically slow; (3) use another engine for this job: MLX Qwen3.5 4B / 4B Instruct 6-bit already run well on his phone (Pass 33 matrix) and Apple Intelligence is the default. Further crash warnings are not the answer; the existing stability record already keeps work he didn't ask for off a model that closed the app twice.

Also seen, not fixed: Core AI Gemma 4 E2B's direct reader fails to open ("GPU buffer allocation failed: per-token input 'ple_table' (9,620,726,743,040 bytes)") and falls back to the chat session — a nonsensical size from the runtime's input description, same family as #201's Gemma bundle issues.

## 3. Reader evaluation: inventory, tool, findings

### Inventory (local, 9 Oct)

| Source | What it is | Tier | Amount |
|---|---|---|---|
| Results exports (5: e11df06 ×2, 960c13a, 77b904d, 3ba90ff) | per episode: phone transcript with word times, final stretches, Reader stretches, every detection attempt with its saved cuts, his ledger corrections and stretch verdicts/locks | predictions + **user** | 37 unique episodes, 16 shows, all with transcripts |
| His own decisions in them | confirmed / not an ad / locked / edited | **user** (only ground truth that is his) | **2 episodes, 1 show (LoS), 1,151 s** |
| Diagnostics edit counts (9 exports) | per-episode counts only | — | 3 more episodes with edits (Stavvy ×2, CumTown ×1) whose details were never exported |
| Lab fixtures `Tools/DetectionLab/regression/*.json` | word-anchored regions | **claude** (careful, but a model's) | 17 fixtures, 12 shows; 3 are episodes in his exports |
| Inserted-ad maps `build/lab/*.dai.json` | frame-exact stitched-ad spans from the host's ad-free copy | independently validated boundaries (lab copies only) | 12 episodes; 16 fixture regions verified, 14 "inserted-unverified" |
| `extra-gold.json` | one 2 Bears episode, sentence-indexed | claude | 1 |
| Lab transcripts / audio `build/lab` | Mac lab's own transcripts and MP3s | inputs | 86 transcripts, 28 MP3s |
| Model test history (Diagnostics `modelTests`) | Basic/Hard sample answers | predictions | 236 runs (samples, not real episodes) |
| SponsorBlock | crowd segments on YouTube uploads | **sponsorblock** (crowd, with votes) | sparse: 2 Whiskey Ginger uploads matched, 1 segment (0 votes) |

Pass 33's "2 corrected episodes from one show" is accurate for **his** decisions; the rest is either model-labelled, lab-only or predictions.

### Tool: `Tools/DetectionLab/evalset.py` (offline; never changes skipping)

```
python3 Tools/DetectionLab/evalset.py build ~/Library/Mobile\ Documents/com~apple~CloudDocs/Downloads/PodSkipper-results-*.json
python3 Tools/DetectionLab/evalset.py find-videos        # first run writes build/evalset/channels.csv to fill in
python3 Tools/DetectionLab/evalset.py sponsorblock [--fetch-captions]
python3 Tools/DetectionLab/evalset.py evaluate --tiers user,claude [--finder detected|reader|final]
```

- `build`: one file per episode in `build/evalset/episodes/` with the transcript, predictions (`detected` = latest attempt's saved cuts, `reader`, `final`) and labels by tier; `inventory.md`; `videos.csv`.
- Fixtures are resolved on the lab transcript they were written against, then carried onto the phone's clock by word alignment (refuses across a stitched-ad discontinuity). Directly on the phone's words 36 regions failed; via the lab transcript 23 remain unplaced (mostly stitched ads that differ per download) and are listed, not silently dropped.
- `find-videos`: matches episodes to YouTube uploads from each channel's public feed (latest ~15 uploads; older ones by hand). `sponsorblock`: SponsorBlock API, cached; with captions (`--fetch-captions` uses `yt-dlp --skip-download`, captions only; or put `.vtt`/`.json3` files in `build/evalset/captions/`) segments are placed on the podcast clock where the texts line up. YouTube uploads don't carry stitched-in ads, so SponsorBlock can only check host-read ads, plugs, intros and outros.
- `evaluate`: per show — labelled skip seconds heard, labelled program seconds cut, missed stretches, mean edge error per break — with a fixed dev/held-out split by show name.

### Findings

- On his own decisions (LoS 954, 958) the app's detection left **64 s of 1,141 s** audible, cut 5 s of a 5 s "not an ad", missed nothing, mean edge error 2.8 s per break. With the Claude fixtures (LoS 956/957, Bad Friends) too: LoS 153 s heard of 2,803 s, Bad Friends 8 s of 353 s, edge error 12–15 s.
- Two traps corrected in the tool, not the app: (a) a stretch's stored "detected" edges are rewritten when he merges stretches (LoS 954: three detected stretches, one locked) — scoring that against his lock wrongly showed 277 s heard; the tool uses the attempt's saved cuts; (b) LoS 957's GLD ad is labelled in the fixture but its anchor didn't match the phone's wording, which made the app look as if it cut 150 s of conversation.
- **No Reader rule or weight changed this pass.** One show of his own labels can't distinguish a real improvement from overfitting; the D07 gate (reliable corrections, diverse held-out shows) is not met.

### What can improve now vs needs more verified examples

- Now: the evaluation set itself; every future Results export adds to it (`build` merges). Fix fixture anchors where the phone's wording differs.
- Needs more of his decisions (target ≥ 3 shows per split, ≥ 20 reviewed breaks each): edge refinement rules, bridging gaps between adjacent stretches (his two LoS edits both joined neighbours across 2–40 s gaps — on-device bridged-gap lessons already learn this per show), Reader retraining (D07).
- How to show an improvement without overfitting: change → `evaluate` on dev shows; accept only if held-out shows don't get worse on both heard and wrongly-cut seconds; report the user-tier numbers separately from claude/sponsorblock tiers.
