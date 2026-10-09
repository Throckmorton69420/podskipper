# Pass 33 evidence — his 9 October 2026 phone run on build 3ba90ff

Sources: `PodSkipper-diagnostics-1791520088.json` (exported 2026-10-09 04:28Z) and `PodSkipper-results-1791520104.json`, the Library Recovery screenshot (12:27 local) and the Compare Models screen recording (10-08 01:08). Raw exports are his data and are not committed; scratch copies were used read-only.

## 1. Revision

`3ba90ff` is the single child of the Pass 32 app commit `110406d` (ancestry checked). `git diff 110406d..3ba90ff` touches only `Scripts/watch-ci.sh`, `claude/HANDOFF.md` and `claude/REQUEST-CATALOG.md`: the installed build runs exactly the Pass 32 app code.

## 2. Crashes (MetricKit), symbolicated

No dSYM is archived by CI. A Release `iphoneos` build of `3ba90ff` with CI's flags and the same Xcode 27.0 (27A266a) was made in a temporary worktree and `atos` was run against it (UUID differs from the CI binary; only call chains that are coherent are reported).

| Delivered (UTC) | Signal | Where | PodSkipper frames (symbolicated) |
|---|---|---|---|
| 10-09 00:48:47, 00:49:28 (Core AI Qwen3 4B, both "part 1 of 1 · ~1,952 prompt tokens") | SIGABRT | abort raised inside **Metal**, under MetalPerformanceShadersGraph → CoreAIDelegates → CoreAIRuntime | `CoreAIAdJudge.judgeReport` (closure, line 318) → `CoreAIClassifierSession.respondDirectly` → coreai-models `StaticShapeEngine` graph run (innermost two frames shifted; not relied on) |
| 10-05 04:34:38 | SIGABRT | **identical** Metal/MPSGraph/CoreAIDelegates stack | older build (not symbolicated) |
| 10-07 02:45, 02:48, 02:49 | SIGTRAP | Swift trap inside CoreAIRuntime | build 77b904d — not symbolicated here |
| 10-05 02:10 | SIGTRAP | SwiftData trap from a SwiftUI view body | older build — not symbolicated here |
| 10-08 18:49, earlier | SIGKILL 0x8BADF00D | scene-update / process-exit watchdog | — |

Conclusions: (a) Pass 32's suspect, prompt-prefix reuse, is **refuted as the cause** — reuse is off on iPhone in 3ba90ff and the same abort still happens, and the same stack occurred on 5 Oct. (b) The abort is inside Apple's Metal stack while Core AI's GPU delegate runs a static-shape graph of the Qwen3 4B Neural Engine bundle (`ios/qwen3_4b_mixed_4bit_8bit_static.aimodel`, max context 4,096; graphs for context 256/512/1,024/2,048/4,096 × query 8/16/64 — read from the bundle's file on Hugging Face without downloading the weights). (c) Whether it happens while the prompt is read or the answer is written, and at which position, was not recorded — Pass 33 records it. (d) A 5 Oct build read ~3,500-token parts across the 2,048 boundary without crashing, so "crossing a context bucket" is not shown to be the trigger. Gemma 4 E2B (three times) and MiniCPM5 2B (once) closed the app **while loading**, with no crash report: consistent with iOS ending the app for memory (the Gemma "portable" bundle is the 4.9 GB macOS build), not proven.

## 3. Disk writes and storage

- MetricKit disk-write exceptions: 17,180 MB (10-09, pid 47999, build 3ba90ff), 68,719 MB (10-07), 17,180 MB (10-07), 4,300 MB (10-08).
- The 10-09 one, symbolicated: the dominant writer (≈⅔ of samples) is **MPSGraph under coreai-models' GPU-pipelined `EngineImpl.init`** — Core AI compiling a model on the phone when it loads. The session loaded ~10 Core AI/MLX models.
- MetricKit daily disk: app data 37.5 GB; app **Caches 2.6 → 14.1 → 0 → 2.6 GB** over 4–8 Oct; phone 236 of 256 GB used (≈20 GB free) on 8 Oct.
- Code: CoreAIKit's `ModelStore.delete` removes only `<repo>/<revision>/<variant>`; other revisions, the iPhone build Pass 32 replaced with the portable one, and `.staging-*` folders were never removed. Core AI's compiled copies live in `Library/Caches/com.apple.e5rt.e5bundlecache` (hash-named, not attributable to a model) and are freed only when iOS purges Caches — the "frees up later" he saw. PodSkipper's Storage page counted only episodes.

## 4. Library Recovery ("SwiftDataError error 1")

- The screenshot (12:27 local, EDT) is the 04:27:58Z launch whose log reads "first screen in 120370 ms" with "library opened in 15 ms": the first open failed, the recovery screen waited ~2 min, Try Again opened it at once. The 120 s is the recovery screen, not a slow launch. "first screen in 3750328 ms" (03:08Z) is a process iOS started in the background and that was opened an hour later — `LaunchTiming` measured from process start.
- "error 1" carries no information: a Swift struct error always bridges to NSError code 1, and the app showed only `localizedDescription`.
- **Proven hazard (disposable store, simulator):** `AppLibrary.resolvedContext()` opened the same default store with only Podcast/Episode/AdSegment when an App Intent or entity query ran before the app had published its context. Opening a store with that smaller schema deleted every Bookmark, ListeningSession and SmartFilter (Core Data: "entities being removed") — `Pass33StoreTests.testOpeningTheStoreWithASmallerSchemaLosesTheOtherTables`. Whether this ever ran on his phone, or caused the 04:27 failure, cannot be told from the exports. Low free space (§3) is another candidate; the new report records it.

## 5. Audio

- Session: `.playback` / `.spokenAudio`, no options; no `playAndRecord`, input node, tap, recorder or capture anywhere in the app. `NSMicrophoneUsageDescription` exists only because the Speech framework declares it. coreai-kit links `MicRecorder`/`MeetingTranscriber` but PodSkipper never calls them. PodSkipper does not reserve the microphone.
- Route log: the same headset reported at very different delays within seconds (Bose 129 → 377 → 392 ms; AirPods 119 → 281 → 285 ms) — profile/sample-rate changes. Any change of the output format makes iOS stop `AVAudioEngine` and post `AVAudioEngineConfigurationChange`, which nothing observed. The silence watchdog then marked playback "interrupted" and waited for an interruption-ended that a format change never sends. Consistent with "another app's microphone briefly pauses PodSkipper" and with silent playback; not proven on the phone — the new playback trace will show it.
- iOS 27 deprecates `AVAudioSession.InterruptionType`/`InterruptionOptions` in favour of `AVAudioSessionDidBecomeInactiveNotification` + `ResumptionRecommendation`; the old notifications are still used (open).

## 6. "Started (automatic)"

All three (03:46:21, 04:22:16, 04:28:02 — the last 4 s after launch) are **Prepare Ahead** jobs (the "get the next 2 episodes ready" setting, default on) started while the app was **on screen**, each stopped by him within ~30 s, during model testing. They are configuration-driven continuation, not new background work, so P21 as written is not breached. They did hold the heavy-work slot so a Compare test queued behind them ("Waiting for background work to finish"); Pass 33 makes a tapped test pre-empt them.

## 7. Reader learning (D04/D07/D12/X32-07)

- New Results export: the correction ledger still holds **one** episode (LoS YN Airlines, lock, 410 s, grade A/94) — the same Pass 32 harvested.
- His 5 Oct review of LoS "Pete Lee & Jeremiah Watkins" (6 confirmed, 1 not an ad, 4 locked per the Diagnostics edit counts) predates the ledger: it reached the **on-device** learning (that show's lessons are dated 5 Oct) but not the Mac harvest. `harvest_corrections.py` now also takes stretch verdicts he gave and locks he set (never an edge the reader moved itself). Result: **2 episodes, 1 show, 8 labels, 1,146 s** settled — in `build/lab/corrections-p33/` (local only; contains transcript text).
- No host ad-free copies (adFree false on all 37 episodes); no publisher transcripts (X31-15). Truth used: only his verdicts and locks. Model agreement is not used as truth.
- Correction-aware measurement on those episodes (detector as it ran then): an ad end 226 s late (YN Airlines), a plug end 44 s late, an ad start 10 s early (show cut), one false 5 s plug. D07's gate (reliable corrections across diverse held-out shows) is **not met**: retraining stays deferred. The Basic/Hard samples say nothing about show-specific lessons.

## 8. Thermal (P09/X31-12/X28-03)

All 9 Oct model tests began at thermal state 2 (serious) or reached it. Avoidable work found: (1) GPU-pipelined Core AI loads compile on the phone (§3) — each new model tried costs a compile; (2) MLX answers written to the 320-token cap and then asked again freely (up to ~640 tokens per part) — now forced completion, whitespace suppression and loop stops; (3) speculative preparation overlapping test sessions — now pre-empted; (4) per-run Core AI sessions are created and released (no resident leak found); MLX GPU cache is capped at 64 MB and cleared after each read. Cooldown was not lengthened. No phone measurement yet.

## 9. Model results matrix (9 Oct, build 3ba90ff; Basic/Hard samples, policy as recorded)

Category from the error and the saved answer text. "valid but wrong" = parsed, low score: a quality limit, not a format failure.

| Date (UTC) | Model | Exact identity | Sample | Policy | Thermal | Time | Read/write tok/s | Result | Category |
|---|---|---|---|---|---|---|---|---|---|
| 10-09T03:55 | Bonsai 8B 1-bit | `prism-ml/Bonsai-8B-mlx-1bit @ 019934f87a61a654e3960ea22f53688e0d2c49ba` | hard | 3 | serious→serious | 154 s | 58/16 | — | hit answer cap |
| 10-09T03:56 | Bonsai 8B 1-bit | `prism-ml/Bonsai-8B-mlx-1bit @ 019934f87a61a654e3960ea22f53688e0d2c49ba` | basic | 3 | serious→serious | 81 s | 84/19 | 31 % | valid but wrong — restates whole stretch |
| 10-09T00:52 | Core AI · Gemma 4 E2B | `coreai.model:gemma-4-e2b` | hard | 3 | unknown→unknown | 0 s | 0/0 | — | process closed (crash or iOS) |
| 10-09T04:00 | Core AI · Granite 4.0-H 1B | `mlboydaisuke/granite-4.0-h-CoreAI @ e0c884d19ecb9f90407904adcf629732fc8e6e38 / gpu-pipelined/granite_4_0_h_1b_decode_int8hu_block32_sym` | hard | 3 | serious→serious | 192 s | 18/16 | — | malformed / schema mismatch |
| 10-09T04:03 | Core AI · Granite 4.0-H 1B | `mlboydaisuke/granite-4.0-h-CoreAI @ e0c884d19ecb9f90407904adcf629732fc8e6e38 / gpu-pipelined/granite_4_0_h_1b_decode_int8hu_block32_sym` | basic | 3 | serious→serious | 182 s | 19/21 | 28 % | valid but wrong |
| 10-09T04:07 | Core AI · LFM2.5 1.2B | `mlboydaisuke/LFM2.5-1.2B-CoreAI @ 8dc37422e5ace08e7c6ae56048c129813e4e0a56 / gpu-pipelined/lfm2_5_1_2b_instruct_decode_int8hu_block32_sym` | hard | 3 | serious→serious | 222 s | 26/27 | — | hit answer cap |
| 10-09T04:10 | Core AI · LFM2.5 1.2B | `mlboydaisuke/LFM2.5-1.2B-CoreAI @ 8dc37422e5ace08e7c6ae56048c129813e4e0a56 / gpu-pipelined/lfm2_5_1_2b_instruct_decode_int8hu_block32_sym` | basic | 3 | serious→serious | 156 s | 27/27 | — | malformed / schema mismatch |
| 10-09T04:12 | Core AI · MiniCPM5 1B | `mlboydaisuke/MiniCPM5-1B-CoreAI @ b8a6ac397ccd5fb815f97336f8a8b1800b110da1 / int8` | hard | 3 | serious→serious | 110 s | 42/36 | 0 % | valid but wrong |
| 10-09T04:14 | Core AI · MiniCPM5 1B | `mlboydaisuke/MiniCPM5-1B-CoreAI @ b8a6ac397ccd5fb815f97336f8a8b1800b110da1 / int8` | basic | 3 | serious→serious | 100 s | 47/36 | 27 % | valid but wrong |
| 10-09T03:12 | Dolphin 3.0 Llama 3.2 3B | `mlx-community/dolphin3.0-llama3.2-3B-4Bit @ cdc777b578ff86a69f1b05c9bc00df0cdc2f52d1` | hard | 3 | fair→fair | 12 s | 240/22 | 0 % | valid but wrong |
| 10-09T03:12 | Dolphin 3.0 Llama 3.2 3B | `mlx-community/dolphin3.0-llama3.2-3B-4Bit @ cdc777b578ff86a69f1b05c9bc00df0cdc2f52d1` | basic | 3 | fair→fair | 15 s | 172/21 | 0 % | valid but wrong |
| 10-09T03:16 | Gemma 3 4B | `mlx-community/gemma-3-4b-it-qat-4bit @ 3d9ef289111449933c22761961f16a5df237ce2a` | hard | 3 | fair→serious | 115 s | 131/16 | 45 % | valid but wrong — fenced |
| 10-09T03:21 | Gemma 3 4B | `mlx-community/gemma-3-4b-it-qat-4bit @ 3d9ef289111449933c22761961f16a5df237ce2a` | basic | 3 | serious→serious | 139 s | 102/13 | 48 % | valid but wrong — fenced |
| 10-08T05:28 | Gemma 4 E4B | `mlx-community/gemma-4-e4b-it-4bit @ 475b9088d29754a3379866cf5aeb6b41acd313c2` | hard | 3 | serious→serious | 92 s | 110/13 | 39 % | valid but wrong |
| 10-08T05:30 | Gemma 4 E4B | `mlx-community/gemma-4-e4b-it-4bit @ 475b9088d29754a3379866cf5aeb6b41acd313c2` | basic | 3 | serious→serious | 70 s | 123/12 | 0 % | valid but wrong |
| 10-09T03:34 | Granite 4.0 H 1B | `mlx-community/granite-4.0-h-1b-4bit @ a5a21e23f01a461f501dcd2b7a34c9efc6fba6a6` | hard | 3 | serious→serious | 85 s | 297/51 | — | malformed / schema mismatch — prose / not JSON |
| 10-09T03:35 | Granite 4.0 H 1B | `mlx-community/granite-4.0-h-1b-4bit @ a5a21e23f01a461f501dcd2b7a34c9efc6fba6a6` | basic | 3 | serious→serious | 80 s | 373/50 | — | malformed / schema mismatch — prose / not JSON |
| 10-09T03:18 | Granite 4.0 H Micro | `mlx-community/granite-4.0-h-micro-4bit @ 0a29e17503da7de371af61a0a532853810637627` | hard | 3 | serious→serious | 104 s | 183/25 | — | malformed / schema mismatch — prose / not JSON |
| 10-09T03:32 | Granite 4.0 H Micro | `mlx-community/granite-4.0-h-micro-4bit @ 0a29e17503da7de371af61a0a532853810637627` | basic | 3 | nominal→serious | 41 s | 177/24 | — | malformed / schema mismatch — prose / not JSON |
| 10-09T03:37 | LFM2.5 2.6B | `LiquidAI/LFM2.5-2.6B-MLX-4bit @ 04efa23776ce61ec34ec95ec34c859854c89542b` | hard | 3 | serious→serious | 108 s | 191/23 | — | hit answer cap — empty text |
| 10-09T03:40 | LFM2.5 2.6B | `LiquidAI/LFM2.5-2.6B-MLX-4bit @ 04efa23776ce61ec34ec95ec34c859854c89542b` | basic | 3 | serious→fair | 53 s | 306/28 | 25 % | valid but wrong |
| 10-09T03:39 | LFM2.5 350M | `LiquidAI/LFM2.5-350M-MLX-4bit @ f6cb4e006bb7a2d8a6afa14ec0a53e0586f65a5b` | basic | 3 | serious→serious | 69 s | 1786/169 | — | malformed / schema mismatch — text in line fields |
| 10-09T03:40 | LFM2.5 350M | `LiquidAI/LFM2.5-350M-MLX-4bit @ f6cb4e006bb7a2d8a6afa14ec0a53e0586f65a5b` | hard | 3 | fair→fair | 7 s | 1976/164 | — | hit answer cap — text in line fields |
| 10-09T03:11 | Llama 3.2 3B | `mlx-community/Llama-3.2-3B-Instruct-4bit @ 7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` | hard | 3 | fair→fair | 60 s | 148/18 | — | hit answer cap — restates whole stretch |
| 10-09T03:12 | Llama 3.2 3B | `mlx-community/Llama-3.2-3B-Instruct-4bit @ 7f0dc925e0d0afb0322d96f9255cfddf2ba5636e` | basic | 3 | fair→fair | 17 s | 151/15 | 0 % | valid but wrong |
| 10-09T01:05 | MiniCPM5 1B | `openbmb/MiniCPM5-1B-MLX @ 9879b18bf2928355fcdf4287635388a3665a40cb` | hard | 3 | serious→fair | 22 s | 980/75 | — | malformed / schema mismatch — label case |
| 10-09T01:06 | MiniCPM5 1B | `openbmb/MiniCPM5-1B-MLX @ 9879b18bf2928355fcdf4287635388a3665a40cb` | basic | 3 | fair→fair | 13 s | 917/75 | — | hit answer cap — label case |
| 10-09T01:08 | MiniCPM5 2B | `openbmb/MiniCPM5-2B-MLX @ 8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3` | hard | 3 | serious→serious | 48 s | 352/28 | 0 % | valid but wrong |
| 10-09T01:09 | MiniCPM5 2B | `openbmb/MiniCPM5-2B-MLX @ 8a9ad7539ac86281d0ac2b017ba04a5de53fe9a3` | basic | 3 | fair→fair | 7 s | 343/33 | 0 % | valid but wrong |
| 10-09T01:13 | Ministral 3 3B | `mlx-community/Ministral-3-3B-Instruct-2512-4bit @ a962dcb09eee4169c890e544c9eb938f1113fdee` | hard | 3 | fair→serious | 77 s | 171/20 | — | hit answer cap — fenced |
| 10-09T01:15 | Ministral 3 3B | `mlx-community/Ministral-3-3B-Instruct-2512-4bit @ a962dcb09eee4169c890e544c9eb938f1113fdee` | basic | 3 | serious→serious | 85 s | 205/20 | — | malformed / schema mismatch — fenced, label case |
| 10-09T03:09 | Nemotron 3 Nano 4B | `mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit @ c4d79ba1901d99806ef757642a552acebb851a35` | hard | 3 | nominal→nominal | 22 s | 116/12 | 0 % | valid but wrong |
| 10-09T03:10 | Nemotron 3 Nano 4B | `mlx-community/NVIDIA-Nemotron-3-Nano-4B-4bit @ c4d79ba1901d99806ef757642a552acebb851a35` | basic | 3 | nominal→fair | 70 s | 73/15 | 0 % | valid but wrong |
| 10-09T01:25 | Phi-3 mini 3.8B | `mlx-community/Phi-3-mini-4k-instruct-4bit @ 5b3819ed6317784fb20eddeae9bed984f778d0d0` | hard | 3 | serious→serious | 55 s | 198/5 | 0 % | valid but wrong |
| 10-09T01:28 | Phi-3 mini 3.8B | `mlx-community/Phi-3-mini-4k-instruct-4bit @ 5b3819ed6317784fb20eddeae9bed984f778d0d0` | basic | 3 | fair→serious | 100 s | 124/13 | — | hit answer cap |
| 10-09T01:18 | Phi-4 mini 3.8B | `mlx-community/Phi-4-mini-instruct-4bit @ ac1c269cb4222a4e136a3d09edad301056c1f36a` | basic | 3 | serious→serious | 56 s | 184/15 | 0 % | valid but wrong |
| 10-09T01:19 | Phi-4 mini 3.8B | `mlx-community/Phi-4-mini-instruct-4bit @ ac1c269cb4222a4e136a3d09edad301056c1f36a` | hard | 3 | serious→serious | 78 s | 131/19 | — | malformed / schema mismatch — fenced |
| 10-09T01:20 | Phi-4 mini 3.8B | `mlx-community/Phi-4-mini-instruct-4bit @ ac1c269cb4222a4e136a3d09edad301056c1f36a` | basic | 3 | serious→serious | 55 s | 210/18 | 0 % | valid but wrong |
| 10-09T01:21 | Phi-4 mini 3.8B | `mlx-community/Phi-4-mini-instruct-4bit @ ac1c269cb4222a4e136a3d09edad301056c1f36a` | basic | 3 | serious→serious | 55 s | 208/19 | 0 % | valid but wrong |
| 10-08T18:44 | Qwen3.5 2B | `mlx-community/Qwen3.5-2B-MLX-4bit @ 93760be4f1f69842a46bc13dbdc0f19e291392a3` | hard | 3 | nominal→nominal | 14 s | 201/27 | 0 % | valid but wrong |
| 10-08T18:44 | Qwen3.5 2B | `mlx-community/Qwen3.5-2B-MLX-4bit @ 93760be4f1f69842a46bc13dbdc0f19e291392a3` | basic | 3 | nominal→nominal | 27 s | 295/35 | 91 % | useful |
| 10-08T05:22 | Qwen3.5 4B | `mlx-community/Qwen3.5-4B-MLX-4bit @ 32f3e8ecf65426fc3306969496342d504bfa13f3` | hard | 3 | serious→serious | 136 s | 120/15 | 74 % | partly right |
| 10-08T05:25 | Qwen3.5 4B | `mlx-community/Qwen3.5-4B-MLX-4bit @ 32f3e8ecf65426fc3306969496342d504bfa13f3` | basic | 3 | serious→serious | 126 s | 92/12 | 91 % | useful |
| 10-08T05:18 | Qwen3.5 4B Instruct (6-bit) | `ALTICDEV/Qwen3.5-4B-Instruct-MLX-Q6 @ 00a036421c2f892d998408e53a38cbb332d56d7a` | hard | 3 | serious→serious | 224 s | 48/7 | 68 % | partly right |
| 10-08T05:20 | Qwen3.5 4B Instruct (6-bit) | `ALTICDEV/Qwen3.5-4B-Instruct-MLX-Q6 @ 00a036421c2f892d998408e53a38cbb332d56d7a` | basic | 3 | serious→serious | 107 s | 50/2 | 100 % | useful |
| 10-09T00:59 | SmolLM3 3B | `mlx-community/SmolLM3-3B-4bit @ d3a7e0594d6642dbcfb7d149bed8b0bdf49f95ce` | hard | 3 | fair→serious | 49 s | 226/21 | — | hit answer cap — character loop |
| 10-09T01:01 | SmolLM3 3B | `mlx-community/SmolLM3-3B-4bit @ d3a7e0594d6642dbcfb7d149bed8b0bdf49f95ce` | basic | 3 | serious→serious | 116 s | 157/20 | — | hit answer cap |
| 10-09T03:45 | Ternary Bonsai 1.7B | `prism-ml/Ternary-Bonsai-1.7B-mlx-2bit @ 5f3e306330f636cfc6c6241b4850fae6711c5985` | hard | 3 | serious→serious | 81 s | 498/66 | — | hit answer cap — restates whole stretch |
| 10-09T03:46 | Ternary Bonsai 1.7B | `prism-ml/Ternary-Bonsai-1.7B-mlx-2bit @ 5f3e306330f636cfc6c6241b4850fae6711c5985` | basic | 3 | serious→fair | 61 s | 443/60 | — | hit answer cap — restates whole stretch |
| 10-09T03:41 | Ternary Bonsai 4B | `prism-ml/Ternary-Bonsai-4B-mlx-2bit @ e1374ad6bf9b1b56afd743936b8faa33c409a75f` | hard | 3 | fair→serious | 86 s | 113/18 | — | hit answer cap |
| 10-09T03:43 | Ternary Bonsai 4B | `prism-ml/Ternary-Bonsai-4B-mlx-2bit @ e1374ad6bf9b1b56afd743936b8faa33c409a75f` | basic | 3 | serious→serious | 107 s | 116/24 | 37 % | valid but wrong |
| 10-09T03:49 | Ternary Bonsai 8B | `prism-ml/Ternary-Bonsai-8B-mlx-2bit @ 9260b24298e4211e804663e9f519962cf59f34be` | hard | 3 | serious→serious | 163 s | 71/10 | — | hit answer cap |
| 10-09T03:52 | Ternary Bonsai 8B | `prism-ml/Ternary-Bonsai-8B-mlx-2bit @ 9260b24298e4211e804663e9f519962cf59f34be` | basic | 3 | serious→serious | 146 s | 67/12 | 61 % | partly right |

