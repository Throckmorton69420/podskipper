# Cloud task 04 — Download Bonsai and run it on the phone (engine only)

Branch: `cloud/on-device-model`. Read `CLAUDE.md` first. **This task may edit `project.yml`** (to add Swift packages) and add one navigation row in `Views/SettingsViews.swift`; everything else in the do-not-edit list still applies. The Mac session wires your engine into ad finding afterwards — do not touch `Services/ProcessingPipeline.swift`.

## Why

Ads are to be found by an open-source language model that runs **inside PodSkipper on his iPhone 16 Pro (A18 Pro, 8 GB RAM, iOS 27)**, reading the episode's transcript in context. The chosen model is **PrismML Bonsai 27B, 1-bit** (Qwen 3.6 27B base, Apache 2.0): Hugging Face `prism-ml/Bonsai-27B-mlx-1bit`, ~3.9 GB deployed, 262K context. It needs PrismML's forks: `github.com/PrismML-Eng/mlx-swift` (custom 1-bit kernels, iOS/macOS). Published numbers (iPhone 17 Pro Max, 12 GB): ~111 tokens/s reading, ~11 tokens/s writing; peak memory at 100K context 11.6–12.2 GB without KV-cache compression — so on an 8 GB phone the transcript **must be read in chunks**. A smaller fallback, `prism-ml/Bonsai-8B` in its MLX 1-bit form (find the exact repo name), must be selectable with a one-line change.

The model is too big to ship inside the IPA (GitHub release files are capped at 2 GB), so the app downloads it itself once.

## Update (29 Sep, after his phone test) — the default model is Ternary Bonsai 8B

Locally AI on his iPhone 16 Pro doesn't even offer Bonsai 27B; it offers **Ternary Bonsai 8B (2.1 GB)** and **Bonsai 8B 1-bit (1.2 GB)**. He ran Ternary Bonsai 8B there: it loaded and answered a small ad question instantly and correctly. So:
- **Default model: Ternary Bonsai 8B** (find its exact MLX repo under `huggingface.co/prism-ml`, and whether it needs PrismML's forks too).
- Picker choices: Ternary Bonsai 8B (default), Bonsai 8B 1-bit (smaller/faster), Bonsai 27B 1-bit marked "Experimental — may not fit in this iPhone's memory", which checks `os_proc_available_memory()` before downloading and before loading, and refuses with a plain message if it won't fit.
- Chunk size can be larger for 8B (try ~12,000 tokens per window, overlap ~1,000); keep both as constants.

## Build

All new code in `Services/LocalModel/` and `Views/LocalModelView.swift`.

1. **Packages.** Add PrismML's `mlx-swift` fork and whatever LLM-loading layer it needs (their docs / README say which: `mlx-swift-lm` or their fork of it) to `project.yml`, pinned to a tag or commit. Read their README and example app first and follow them exactly; don't guess. Confirm the 1-bit Bonsai format loads with that stack.
2. **`ModelStore`** (download manager).
   - Lists the repo's files through the Hugging Face API (`https://huggingface.co/api/models/<repo>` → `siblings`) and downloads only what text generation needs (skip the vision tower if the model loads without it — check).
   - Background `URLSession` (continues while locked or suspended), resumable, one file at a time, **Wi-Fi only** unless he turns on "Allow cellular"; verifies each file's size; stores in Application Support/Models/<repo>/ with `isExcludedFromBackup = true`.
   - Starts automatically on first launch after this update when on Wi-Fi, and when he taps Download.
   - Publishes state for the UI: not downloaded / downloading (bytes done, total, speed) / paused (no Wi-Fi) / ready (size on disk) / failed (plain reason).
   - Delete removes the files and frees the space.
3. **`LocalJudge`** (inference), an actor with roughly:
   `func judge(lines: [TimedLine], show: String, title: String, notes: String, evidence: [EvidenceSpan], only ranges: [Range<Int>]?, progress: @Sendable (Double) -> Void) async throws -> [JudgedPart]`
   - `TimedLine` is the app's existing transcript line type. `EvidenceSpan` = (start, end, kind: `.inserted` / `.repeated`), and `JudgedPart` = first line, last line, label, sponsor, funny, confidence, why — define them to match.
   - **Prompt and output:** port the `RULES` text, the label list (`KIND`), the JSON schema (including `first_words` / `last_words`), the line format (numbered lines, a time on every 15th line, «I»/«R» evidence marks) and the `anchor()` edge-snapping from `Tools/DetectionLab/gemini_bench.py`. Keep the wording identical; it's what was benchmarked.
   - **Chunking:** windows of ~6,000 tokens with ~800 tokens of overlap (both constants), each window prompted separately; parts from overlapping windows merged (same label and overlapping lines → one part). `only ranges` limits reading to those line ranges plus 40 lines of context either side (used for the fast "check the suspicious stretches" mode).
   - **Output:** constrained/structured JSON if the stack supports it, otherwise parse the first `{…}` block leniently; a window whose answer can't be parsed is retried once, then reported as failed (don't invent parts). Turn reasoning off or cap it; the answer must be short.
   - **Memory:** load the model only for a job and unload it straight after; set MLX's GPU cache limit low; before loading, check `os_proc_available_memory()` and throw a clear `.notEnoughMemory(available:needed:)` instead of letting iOS kill the app.
   - **Locked phone:** with the app in the background, iOS gives a sideloaded app no GPU. Find out whether PrismML's fork runs its 1-bit kernels on the CPU. If yes, run on the CPU when `UIApplication.shared.applicationState != .active` (and switch back to the GPU when the app is active). If no, throw `.needsForeground` so the app can tell him. **State plainly in the PR which it is and how you know.**
   - Reports progress (fraction of windows done) and timing (tokens read per second), and exposes those numbers for Diagnostics.
4. **`LocalModelView`**: Settings row "On-device ad model" → a screen with state, size, progress, speed, Download / Pause / Delete, the "Allow cellular" switch, and a model picker (Bonsai 27B / Bonsai 8B) that says the sizes. Plain wording. Add one `NavigationLink` to it in `SettingsViews.swift`.
5. A small **self-test** button on that screen, hidden behind a long press on the title: runs `judge` on a built-in 40-line sample transcript containing one obvious host-read ad and shows the parts it found and the reading speed. This is how he'll check it on the phone.

## Out of scope

Wiring into Find Ads, notifications, Activity, the reader — the Mac session does those.

## Done means

PR open from `cloud/on-device-model`, CI green with zero warnings (MLX packages must build on the CI's Xcode; if they can't, say exactly why in the PR). The PR states: package versions used; files downloaded and their total size; CPU-when-locked: yes/no and the evidence; anything unconfirmed; and exact phone test steps (download on Wi-Fi, then the self-test, reporting the speed shown).
