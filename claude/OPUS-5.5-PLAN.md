# PodSkipper — Pass 66 continuation plan (for the next session)

Written 16 November 2026 after Pass 66 batch 1 (code `d2d20b4`, docs `c1f8628`, both on `main`).
Read this file, then `TASKS.md` (end), then `claude/HANDOFF.md` §1z.

## 0b. Batch 2 (16–17 Nov) — what of this plan is done

- §6 gates for batch 1: done (IPA ok; full suite fixed: 706 / 0). Hard 98 with four: done (`wordlessAdSure` 0.75).
- §2 distillation: soft-target option built; soft targets dumped for labelled (ens4), unlabelled (silver/probs),
  all 2,075 SponsorBlock and 2,497 SPoRC episodes; `build/p66/distill/gatea.sh` (started by `chain.sh` after the
  dumps; log `build/p66/distill/gatea.log`) then `gateb.sh`. **Read `build/p66/gatea.txt` first.**
- §3 silver prep: done (probs, batch file); the teacher read itself needs his Kaggle go-ahead.
- §4.1–4.4: done except the Kaggle quick runs themselves (each uploads his 11 test transcripts — ask).
- §5: done; SponsorBlock tops out at 1,376 podcast picks at ≥ 90 %; SPoRC gives volume (`sporc_scale.py`).
  Fetching sb66 (~14 h) is his call.
- §6 audit: done (`build/p66/audit-downloads/findings.md`). Open: `testAccessibleModelsAndSound` re-run on an idle
  Mac; 27.3 hero header and video toggle need 27.3 device screens.

## 0. Where things stand

**Shipped in batch 1 (unit-tested and lab-measured; nothing is phone-verified):**

| Change | Evidence | Number |
|---|---|---|
| Four Readers read together (`Resources/Detection/TaggerWeights.bin`, `-2`, `-3`, `-4`) | `build/p66/ship-four.txt` | 11 test episodes: PodSkipper test 91.8 → 93.6, heard 10.6 → 8.6 s/h, show cut 4.4 → 4.0 s/h. 71 show-held-out episodes: 76.2 → 78.6 |
| Spoken credits at the end are an outro (`SegmentDetector.creditsAtTheEnd`) | `build/p66/credits-rule.txt`, `build/p66/wf-outro/output.txt` | Basic sample 88 → 93. Test episodes unchanged (93.6). Show-held-out 78.6 → 78.7. Fold analysis: +15.4 s of labelled credits, 0 s of show |
| Cut check reads long openers and sign-offs line by line (`ModelCutCheck.vetoConversation`, `edgeProved` 30 s) | `build/p66/veto/` | 27B teacher answers, 60 fold episodes: 70.4 → 77.9. 11 test episodes: 83.0 → 85.5 |

**Known gaps in batch 1:**

1. The Hard sample scores 97 with four Readers (98 with the pair). The user's 13 Nov target is Hard ≥ 98.
2. The full unit suite was not run after the credits rule. It ran once before it: 693 tests, 3 failures, all fixed since. Focused run after the rule: 39 tests, 0 failures.
3. No device build and no UI tests were run in batch 1.
4. The test-episode gain has a wide interval: paired +1.7 (−0.9 … +3.8) on 11 episodes.

**Two background workflows stopped at the usage limit.** They left partial files in `build/p66/` (git-ignored). The table says what is real.

| Folder | What is there | State |
|---|---|---|
| `build/p66/wf-outro/` | `analysis.py`, `output.txt` (credits and outro numbers on the 60 fold episodes) | Complete. Used for the credits rule |
| `build/p66/wf-tests/` | `wf-score` (scores a sample with extra cuts), `runs.txt` | Complete |
| `build/p66/wf-decode/` | Per-line probabilities of both samples for the pair and the four | Complete |
| `build/p66/teacher/` | `diagnose.py`, `diagnose-qwen38-27b.json` (406 teacher parts with right/wrong sentence counts) | Data complete. No written summary. See section 4 |
| `build/p66/teacher-models/` | `raw-1.txt`, `raw-2.txt`, `raw-3.txt`, `hf-files-1.txt` (Hugging Face file listings), `result.md` | Listings only. No ranking was written |
| `build/p66/corpus-select/` | `sb.duckdb` (2.09 GB: table `st` 20,003,418 segment rows, table `info` 11,681,194 video rows), `build_cache.py` | Database complete. No funnel, no channel table, no picks |
| `build/p66/corpus-captions/` | `rejects.py`, `rejects.pkl` (every SPoRC match with its reject reason and nearby sentences), `result.md`, `subs/` | Captions: YouTube answered HTTP 429 on the first video. `rejects.pkl` is complete but nobody read the samples |
| `build/p66/silver/probs/` | Empty | Not done |
| `build/p66/audit-downloads/` | Empty | Not done. No audit findings exist |

Not built at all: the 11-episode quick mode in `kaggle_teacher.py`, the why-first prompt, the unlabelled batch file, the review of the batch 1 diff.

## 1. Rules for this work

1. Do not reject a checkpoint, a teacher model or a dataset from one aggregate score. First find the exact failure with a per-episode, per-sentence diff: `build/p66/diffcuts.py <cuts.json> <name>… --show <show> --text` and `Tools/DetectionLab/check_sweep.py`. Example: finalsb "failed" on show cut, but the cause was two cuts in one episode.
2. Do not add a rule without a measured change. Measure on the 60 fold episodes (held-out Reader answers) and confirm once on the 11 test episodes. Delete a rule that changes nothing. Example: the weak-plug-word rule changed no result and was removed.
3. Do not repeat long inference. Use the saved outputs first:
   - Show-held-out Reader probabilities: `build/p58/ext13`, `build/p58/ext17`, `build/p65/sx13sb`, `build/p65/sx17sb`, averaged in `build/p66/ext2`, `build/p66/sx2`, `build/p66/ens4`.
   - Teacher answers: `build/p57/teachers/qwen38-27b/`, `build/p57/teachers/q35-4b/`.
   - Cuts: `build/p66/test-ens.json`, `build/p66/frontier-ens.json`, `build/p66/test-credits.json`, `build/p66/frontier-credits.json`.
4. Never tune on the 11 test episodes. Always train with `HOLD_TEST=1`.
5. One training run at a time. `Tools/ReaderData/reader_run.sh` and `sb_scale_run.sh` hold lockfiles. Start long jobs with `Tools/ReaderData/detach.py <log> <command>`.
6. Push the code commit alone first. Push the `[skip ci]` docs commit after it. Use `~/Developer/pk-tools/gitauth.sh push ORIGIN "${SHA}:refs/heads/main"`.
7. Fold episodes need held-out probabilities (`--probs build/p66/ext2` or `LAB_TAGPROBS`). The shipped Readers trained on the fold episodes.

Standard measurement commands (run from the repository root; `PY=~/Developer/pk-ml/bin/python`):

```bash
export READER_OUT=p66 LAB_SEGMENTS=$PWD/build/p66/lab-segments
D=$PWD/Resources/Detection; W4=$D/TaggerWeights.bin:$D/TaggerWeights-2.bin:$D/TaggerWeights-3.bin:$D/TaggerWeights-4.bin
# rebuild the lab detector after any change to Services/SegmentDetector.swift
zsh Tools/DetectionLab/lab.sh build-segments $PWD/build/p66/lab-segments $PWD
# 11 test episodes
$PY -I Tools/ReaderData/test_cuts.py build/p66/test-NEW.json test reader:new=<w1.bin>:<w2.bin>
$PY -I Tools/ReaderData/podtest.py test four=build/p66/test-credits.json:four new=build/p66/test-NEW.json:new
$PY -I Tools/ReaderData/compare.py test four=build/p66/test-credits.json:four new=build/p66/test-NEW.json:new --gaps --shows
# 71 show-held-out episodes
$PY -I Tools/ReaderData/frontier.py build/p66/frontier-NEW.json new=<run dir with probs/> --deltas=0 --bin build/p66/lab-segments --results build/phone-1029/results.json --gaps
$PY -I Tools/ReaderData/podtest.py folds four=build/p66/frontier-credits.json:ens4@0 new=build/p66/frontier-NEW.json:new@0
# the phone's samples (rebuild lab-bench first; the command is in Tools/DetectionLab/LabBench.swift)
LAB_TAGGER=<weights joined by colons> build/p66/lab-bench basic | grep "^Reader"
LAB_TAGGER=<weights joined by colons> build/p66/lab-bench hard  | grep "^Reader"
```

Baseline to beat (four Readers with the credits rule):

| Set | PodSkipper test | Heard s/h | Show cut s/h |
|---|---|---|---|
| 11 test episodes | 93.6 | 8.6 | 4.0 (compare.py) |
| 71 show-held-out | 78.7 | — | 6.3 (podtest) |
| Basic / Hard samples | 93 / 97 | — | — |

## 2. Make the four Readers one pair again

**Goal:** two weight files that score like the four. That removes 54 MB of app size and about 150 MB of memory while reading.

**Facts to know first:**

- `build/p66/reader/` holds transcripts and reply caches. It does not hold probabilities.
- Four-reader probabilities for any transcript come from the Swift reader in seconds: `LAB_TAGGER=$W4 LAB_TAGDUMP=<out.json> build/p66/lab-segments <transcript.json> "" "" ""`. Rows are `[start, end, p_show, p_ad, p_self, p_cross, p_intro, p_outro]`.
- Show-held-out four-reader probabilities for the 71 labelled episodes already exist in `build/p66/ens4/probs/`.
- The four are two recipes: Pass 58's (`build/p58/final58`, stage 1 `build/p58/pre13.pt`) and finalsb (`build/p65/finalsb`, stage 1 `build/p65/pre13sb.pt`).

**Steps:**

1. Read `Tools/DetectionLab/reader_distill.py` (`train`, `showfolds`, the loss) and `Tools/DetectionLab/tagger.py`. Check if training accepts soft targets. If it does not, add one option: an environment variable `SOFT=<probs dir>` that adds a KL term to the four Readers' probabilities for each sentence. Keep the default path unchanged.
2. Make the soft targets without leaking:
   - For the 60 fold episodes use `build/p66/ens4/probs/` (show-held-out).
   - For the 11 test episodes: do not use them at all (`HOLD_TEST=1`).
   - For the 71 unlabelled episodes and the SponsorBlock episodes (`~/Developer/pk-data/sb58/episodes.json`, `~/Developer/pk-data/sb65/episodes.json`): dump with `LAB_TAGDUMP` and the four shipped Readers. This is the large extra signal.
3. Fold check first. Train show-held-out folds from `build/p65/pre13sb.pt` with the soft targets: `INIT=$PWD/build/p65/pre13sb.pt SEEDS=13 SOFT=… $PY -I -u Tools/DetectionLab/reader_distill.py showfolds build/phone-1029/results.json dist13 3` and the same for seed 17. Average the two with `build/p66/avgprobs.py`.
4. Gate A (folds): the distilled pair's show-held-out PodSkipper test ≥ 78.2 and show cut ≤ 6.8 s/h (within 0.5 of the four).
5. Only if gate A passes: train the final pair with `HOLD_TEST=1` (`reader_run.sh`'s `stepb` shows the exact sequence: `train`, `tagger.py style` for each reader, parity dump).
6. Gate B (11 test episodes, one run): PodSkipper test ≥ 93.0, heard ≤ 9.1 s/h, show cut ≤ 4.5 s/h, Basic ≥ 90, Hard ≥ 97, Swift/Python parity max |Δp| ≤ 2e-6.
7. If gate B passes: replace `TaggerWeights.bin` and `-2.bin`, delete `-3` and `-4`, rebuild the anchor (`ANCHOR_BIN=$PWD/build/p66/lab-segments TAG=anchor $PY -I -u Tools/DetectionLab/tagger.py anchor Resources/Detection <w1> <w2>`), bump `AdDetector.version`, update `Tests/Pass66Tests.swift` (`testFourReadersAreBundledWithTheirAnchorSet` expects 4). If a gate fails, keep the four and record the numbers.

**Hard sample (97):** three ad lines after a promo are named a promo. The condition is in `SegmentDetector.kindsApart` / `sentenceKind` (an ad carved from a plug needs a hand-off or a code and mean ad ≥ 0.8; the four give 0.73–0.84). Per-line values: `build/p66/wf-decode/hard-four.txt`. Any change needs the fold and test check of section 1.

## 3. Silver labels on the 71 unlabelled episodes (item 3)

**State:** nothing was produced. The 27B teacher has read only the 71 labelled episodes. `reader_distill.py` uses teacher labels only for unlabelled episodes. So a silver run needs a teacher read of the unlabelled pool first.

1. Count the records: `python3 Tools/ReaderData/silver.py stats q35-4b` and `… stats qwen38-27b`. Record labelled / unlabelled / test counts.
2. Dump the Reader's probabilities for the unlabelled episodes to `build/p66/silver/probs/<key>.json` in the layout `silver.py` reads for `SILVER_PROBS` (compare with `build/p65/sx13sb/probs/<key>.json`: `{"fold": …, "rows": […]}`). Use `LAB_TAGDUMP` with the four Readers. Check `reader_distill.py` for "agreement" pseudo-labels: if the unlabelled episodes fed training that way, say so in the result, because the veto is then less independent.
3. Write the teacher batch for the unlabelled pool with the same builder that wrote `build/p57/teachers/qwen38-27b/batch-input.jsonl` (find it in `Scripts/distill_reader.py`): output `build/p66/qwen38-27b-unlabelled-batch.jsonl`. Check: unique ids, no labelled or test episode, token estimate.
4. The teacher read needs Kaggle GPU hours and sends the transcripts of his episodes to Kaggle. That is the user's decision. Do section 4 first so the better teacher does the read.
5. After a read exists: `SILVER_PROBS=build/p66/silver SILVER_SHOW=0.85 TEACHER=<name> zsh Tools/ReaderData/reader_run.sh tb <episodes.json list> sx13 sx17 stepa` with `PRE`, `TWIN13`, `TWIN17` set as rule 6 amendment 1 says (`build/p65/ship-rule-6.txt`).
6. Gate: both seeds better than their twins at matched heard, show-held-out PodSkipper test ≥ +0.5, show cut ≤ +0.5 s/h. Then a `HOLD_TEST=1` pair must pass gate B of section 2.

Known numbers: the veto at show ≥ 0.85 lifts the 27B's ad-sentence precision from 0.746 to 0.970 on the 60 fold episodes and removes 7 % of true ad sentences (`build/p65/silver-veto-qwen38-27b.txt`).

## 4. Teacher quick check and next teacher models (item 5)

**4.1 Why the 27B was imprecise.** Run this once to get the table by label (it reads the saved file, no model):

```bash
~/Developer/pk-ml/bin/python -I - <<'EOF'
import json, collections
d = json.load(open("build/p66/teacher/diagnose-qwen38-27b.json"))
w = collections.Counter(); n = collections.Counter(); r = collections.Counter()
for p in d: w[p["label"]] += p["wrongSec"]; r[p["label"]] += p["rightSec"]; n[p["label"]] += p["wrong"]
for k, v in w.most_common(): print(f"{k:16} wrong {v:7.0f} s in {n[k]:4d} sentences · right {r[k]:7.0f} s")
EOF
```

The table from that command is appended at the end of this file. Each record also has `why` (the teacher's own reason), `gold` (the labels it overlaps), `atWindowStart` / `atWindowEnd` and the first sentences (`text`). Read the 30 largest `wrongSec` parts before changing the prompt.

**4.2 Quick mode in `Tools/ReaderData/kaggle_teacher.py` (not built yet).**

1. Add `quick --model <hf repo> --file <gguf> [--prompt-variant baseline|why-first] [--reasoning-budget N]`.
2. It builds the batch for the 11 test episodes only (the existing builder), runs it through the same llama.cpp server path as the full run, collects, runs `Tools/DetectionLab/check_sweep.py teacher:<name> test`, and prints the score beside the Reader's, tokens per second and projected hours for the 71-episode pool.
3. Expected time on Kaggle 2 × T4: the 27B did 363 windows in 2.4 h (about 197 prompt tokens per second). The 11 test episodes are about 56 windows, so about 22 minutes plus model download.
4. State in the docstring: this is a go / no-go check, not a tuning set.
5. Add the why-first variant: field `why` before `label` in the schema and grammar, default unchanged. Prove the default is byte-identical: rebuild one window and compare with the stored line in `build/p57/teachers/qwen38-27b/batch-input.jsonl`. Check that `JudgePrompt.parse` (Swift) and `distill_reader.py collect` accept either field order.
6. Smoke-test on this Mac with one episode and a small GGUF through `build/p65/llama-server-mac/bin/llama-server`. Never run a Gemma model on this Mac.
7. Pass gate for a teacher: its checked score on the 11 test episodes ≥ the Reader's (91.6 with the pair as Reader; re-measure with the four). The 27B is at 85.5.

**4.3 Candidate models.** The listings are verified against Hugging Face (`build/p66/teacher-models/raw-*.txt`). The ranking below is my reading of sizes only: no quality or speed measurement exists.

| Candidate | File | Size | Fits 32 GB? | Note |
|---|---|---|---|---|
| `nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB-GGUF` | `NVIDIA-Nemotron-3.5-Bolt-74B-A9B-24GB.gguf` | 22.02 GB | Yes | 74B mixture of experts, 9B active. Licence not read: check it. Needs a llama.cpp build with `nemotron_h_moe` |
| `unsloth/gemma-4-31B-it-GGUF` | `gemma-4-31B-it-Q4_K_M.gguf` or `-Q5_K_M.gguf` | 18.32 / 21.66 GB | Yes | Apache-2.0. Dense. Different family from Qwen |
| `unsloth/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-GGUF` | `…-UD-Q4_K_XL.gguf` | 25.51 GB | Yes, tight | 3B active: fast, room for a reasoning budget |
| `ornith-ai/Ornith-1.5-35B-A3B-GGUF` | `Ornith-1.5-35B-Q4_K_M.gguf` | 21.71 GB | Yes | MIT |
| `meta-models/Muse-Glimmer-30B-GGUF` | `Muse-Glimmer-30B-KQuant-Dynamic-Q4_K_XL.gguf` | 19.65 GB | Yes | Apache-2.0 |
| `unsloth/gemma-4-26B-A4B-it-GGUF` | `gemma-4-26B-A4B-it-UD-Q5_K_M.gguf` | 21.15 GB | Yes | Apache-2.0, 4B active |

Does not fit: `unsloth/Qwen3.8-Flash-Next-GGUF` (smallest split is over 80 GB), `Ornith-1.5-122B`, `Qwen3.5-122B-A10B`. `google/gemma-4-31B-it-qat` and `mistralai/Mistral-Medium-3.5` were named in the request but are not in the saved listings: verify them with `build/p66/teacher-models/hf.sh` before use.

Order of work: build 4.2, then run the quick check for Nemotron Bolt 24GB and gemma-4-31B, baseline prompt and why-first. Pair two families (for example Nemotron and Gemma) for agreement labels only if each passes alone or the agreement set passes. Each Kaggle run uploads his 11 test transcripts: ask the user before the first upload of a new batch.

**4.4 Prompt fixes to test** (after reading the wrong parts): say what an INTRO is not (the hosts' first talk, the guest introduction); say that a guest talking about their own work in an interview is the show; say that a joke about a product is the show unless there is an offer or a hand-off.

## 5. More pretraining data from SponsorBlock (item 6)

**Use `build/p66/corpus-select/sb.duckdb`.** Do not read the CSV dump again (8 GB). Tables:

- `st(videoID, category, actionType, s, e, votes, locked, dur, hidden, sh, views, uuid)` — YouTube segments in the seven categories.
- `info(videoID, channelID, title, published)`.

```bash
~/Developer/pk-ml/bin/python -I -c "
import duckdb; c = duckdb.connect('build/p66/corpus-select/sb.duckdb', read_only=True)
print(c.execute(\"select count(distinct videoID) from st where category='sponsor' and actionType='skip' and (locked=1 or votes>0) and hidden=0 and sh=0\").fetchone())"
```

1. Funnel: count videos and channels after each rule of `sb_scale.py select` (segment locked or voted up, no whole-video mark, ≥ 200 views on the segment, 30 min–4 h where `dur` is known, `PODCASTY` title, not his shows, channel caps, not in sb58 / sb65). The title rule is the suspected bottleneck: measure it.
2. Channel-level podcast detection in a new `Tools/ReaderData/sb_channels.py`: (a) channel has ≥ N videos that pass `PODCASTY`; (b) video-title prefix or channel name equals a SPoRC show name after normalisation (`/Volumes/Samsung PSSD T9 Media/PodSkipper/data/sporc/metadata/podcast_catalog.parquet`, column `primary_category` gives the genre); guard against generic names. Note: `info` has `channelID` but no channel name; the show-name match must use video titles.
3. Print 40 random added channels with sample titles. Estimate precision by reading them. Gate: ≥ 90 % are podcasts.
4. New `sb_scale.py select2` (leave `select` unchanged): all videos of podcast channels that pass the per-video rules except the title rule, ≤ 15 per channel, stratified by genre. Write `~/Developer/pk-data/sb66/picks.json`. Do not fetch audio in this step.
5. Cost before starting a fetch: sb65 took about 18 h for 1,717 episodes (fetch and transcription). Ask the user before a multi-day fetch.
6. Captions route: stopped. YouTube returned HTTP 429 on the first subtitle request (`build/p66/corpus-captions/result.md`). One file, `subs/MvHacUOd4Ss.en.json3`, arrived on a later attempt and was not analysed. Do not build on captions unless a paced test of 5 videos succeeds.
7. SPoRC pairs: `build/p66/corpus-captions/rejects.pkl` holds every match with its reason, the chosen clock shift and the sentences. Read at least 15 of the "sponsor segment over plain show talk" rejects and 10 others (`pickle.load`; fields `why`, `segs`, `sents`, `shift`). Relax a rule only behind a flag and only if the hand-checked sample supports it. The current yield is 38 pairs: even a full recovery of the 292 adds few episodes next to step 4.
8. Gate for any new corpus: stage 1 pretraining on it, then the recipe, then step A against the current stage 1 (`reader_run.sh … pre sx13 sx17 stepa`), then gate B of section 2.

## 6. App audit and release check (Stage 4)

No audit ran. Do it directly, one area at a time. For each finding write: file and line, the user action that triggers it, the fix, and a test. Fix what is found.

| # | Area | Files | Check |
|---|---|---|---|
| 1 | Drive import | `Services/ExternalModelLibrary.swift`, `Views/ExternalModelLibraryView.swift` | Security-scoped access is stopped on every path. Drive removed during a copy: partial file deleted, row shows a plain error. Stop during a copy. Two imports at once |
| 2 | Downloads and preparation | `Services/CoreAIModelDownload.swift`, `Services/ModelStorage.swift`, `Services/LocalModel/ModelStore.swift`, the CPU model files (`CPUModel…`, `CPUReading.swift` if present) | Cancelled task writes no state. Temp files removed. No continuation resumed twice |
| 3 | Pipeline | `Services/ProcessingPipeline.swift`, `Services/TranscriptionService.swift`, `Services/HeavyWorkCoordinator.swift` | Lease released on every return and throw. Cancelled job writes no result. Checkpoint not reused across a new `AdDetector.version` (now 66) or reader identity. No whole-library fetch on the main actor |
| 4 | Compare Models | `Services/OnDeviceReading.swift`, `Services/ModelComparisonLab.swift`, `ModelBench`, `Services/PodTest/PodTestRunner.swift` | Late callbacks after Stop are dropped (run tokens). Start pressed twice. Results for the right model when the list changes |
| 5 | Playback | `Services/AudioPlayerService.swift`, chapter and skip code | No double skip at a boundary, at the end of the episode, with overlapping cuts, when scrubbing back into a cut. Observers removed. Background tasks always complete |
| 6 | Four Readers on the phone | `Services/SentenceTagger.swift` (`ReaderCache`, `probabilities`) | About 220 MB of weights while reading. Check that a read beside transcription or a Core AI read stays inside the memory budget. This is new in batch 1 |
| 7 | Largest text | `Views/` | UI tests use `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`. Look for fixed frames around text and `lineLimit(1)` on buttons |

Release gates, in order:

1. `./Scripts/unit-test.sh` — full suite, 0 failures (last full run: 693 tests before the credits rule).
2. `./Scripts/uitest.sh` for `testAccessibleModelsAndSound`, `testPass65ImportFromDrive`, `testAccessibleImportFromDrive`, `testPass62PodTestStopped`, `testPass60PodTestResults`; look at the screenshots.
3. `./Scripts/device-build.sh` succeeds with no new warnings.
4. Confirm the GitHub run for `d2d20b4` produced the IPA: `curl -s "https://api.github.com/repos/Throckmorton69420/podskipper/actions/runs?per_page=3"` (it was `in_progress` when this file was written).
5. Update `TASKS.md`, `claude/HANDOFF.md`, `claude/FINISH-PLAN.md`, `claude/REQUEST-CATALOG.md`, `claude/PHONE-CHECKLIST.md`. Push code alone, then docs.

## 7. Suggested order

1. Release gates 1–4 of section 6 for batch 1 (about 30 minutes). This closes the gaps listed in section 0.
2. Section 4.2 (quick mode), because sections 3 and 4 depend on it.
3. Section 2 (one pair), in the background while 4 and 5 proceed.
4. Section 5 steps 1–4.
5. Section 6 audit.
6. Section 3 after a teacher passes.

## Appendix — the 27B teacher's wrong sentences by label (60 fold episodes, from `build/p66/teacher/diagnose-qwen38-27b.json`)

| Label the teacher gave | Wrong seconds | Wrong sentences | Right seconds |
|---|---|---|---|
| INTRO | 1,239 | 655 | 317 |
| HOST_READ_AD | 985 | 564 | 7,847 |
| GUEST_PLUG | 566 | 309 | 1,134 |
| SELF_PROMO | 509 | 286 | 1,763 |
| OUTRO | 444 | 206 | 632 |
| NETWORK_PROMO | 6 | 2 | 49 |
| PAID_AD | 0 | 0 | 3,707 |
| CREDITS | 0 | 0 | 223 |
| **Total** | 3,748 | 2,022 | 15,672 |

These counts use the inner sentences of each part (the first and last sentence are left out), parts of confidence ≥ 70 only, as `silver_veto_check.py` does.
