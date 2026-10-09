# PodSkipper — Handoff (Pass 34, 9 October 2026)

Read first: [Request Catalog](REQUEST-CATALOG.md) — the **Pass 34 overlay** at its top, then Pass 33, then the Pass 28–32 overlay, then the 178 base rows — and [Pass 34 evidence](evidence/2026-10-09-pass34-defaults-coreai-evalset.md) (Pass 33's is [here](evidence/2026-10-09-pass33-phone-evidence.md)). Then the [Specification](../PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md) and [Implementation Plan](../IMPLEMENTATION-PLAN.md). His Pass 34 request is tracked as X34-01…04.

## 1. Where the code is

- **`main` is canonical.** Work in `~/Developer/podskipper` only. `~/Developer/pk-app` is a second worktree at 77b904d (detached) for building an older main while the lab runs.
- `stash@{0}` (catalogue transaction WIP, 252 tests / one cross-context regression) is untouched; also tag `archive/backup-catalogue-stash-2026-10-02` (15a29af). Do not pop it casually (Batch 3).
- Archive tags from Pass 32 are intact (`archive/*`, six). Branches: `main`, PR #23's two branches, the `feather-*` branches.
- Git with credentials: `~/Developer/pk-tools/gitauth.sh <git args>` (ORIGIN → token URL, output redacted). `gh` is not installed.
- **Simulators.** PS-Unit (F51033BC-3FEA-4D44-BF85-06F492C6933F, iPhone 16 Pro, iOS 27.0): `./Scripts/unit-test.sh F51033BC-…` and `./Scripts/uitest.sh <Test[,Test]> <tag> PS-Unit`. The live simulator panel needs his "Let Claude use it" grant (not given this pass); headless tests work without it.
- **Symbolicating his crashes:** CI archives no dSYM. Build the exact commit in a temporary worktree with CI's flags (`xcodebuild … -configuration Release -sdk iphoneos … ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO`, same Xcode 27.0) into `build/DeviceDerivedData`, then `atos -o …/PodSkipper.app.dSYM/Contents/Resources/DWARF/PodSkipper -l 0x100000000 <0x100000000+offset>`. Only coherent call chains are trustworthy (UUIDs differ).
- MetricKit/report helpers used this pass: scratch scripts only (matrix and MetricKit stack printers); the matrix table is in the evidence file.

## 2. What Pass 34 changed

| Area | Files | Evidence level |
|---|---|---|
| Speed & Audio neutral baseline: registered defaults neutral (Volume Normalization and Reduce Rumble were on); one-time step keeps an existing install's sound; Reset text | `Models/Models.swift`, `Models/SoundModel.swift` (`SoundSettingsMigration.keepPreviousDefaults`), `Views/PlayerViews.swift` | Unit · phone OPEN |
| Core AI static-shape prompt read in 8-token steps (avoids the 64-wide prefill graphs where every Qwen3 4B abort happened; apple/coreai-models #201); crash note names it | `Services/CoreAIClassifierSession.swift` (`StaticPrefill`, `respondDirectly`) | Unit (step plan) + Release iphoneos compile · phone OPEN |
| Offline Reader evaluation set: tiers user / claude / sponsorblock, fixtures carried onto the phone clock by word alignment, YouTube upload matching from channel feeds, SponsorBlock + caption alignment, per-show dev/held-out scoring | `Tools/DetectionLab/evalset.py` (new) | Run on his 5 exports; output in `build/evalset/` (ignored) |
| Tests | `Tests/Pass33Tests.swift` (baseline asserted field by field; fresh install; update), `Tests/Pass34Tests.swift` | see §4 |

## 3. Findings to keep

Proven: Reset restored registered defaults that weren't neutral. All three 8bbe5dd Qwen3 4B closures were while reading the prompt (~1,952 tokens), never writing; the same test passed in between (intermittent). The abort is Apple's (MPSGraph under CoreAIDelegates). His own reviewed labels: 2 episodes, 1 show; the rest of the "accumulated results" are predictions or Claude/lab labels. A merged/locked stretch's stored detected edges are rewritten — score detection from the attempt's `savedCuts`. LoS 957's GLD fixture anchor doesn't match the phone's wording.

Hypotheses, not proven: that 8-wide prefill avoids the abort (phone decides); Pass 33's open ones (04:27 store failure cause, headset format-change → silent playback, Gemma/MiniCPM load closures = memory).

## 4. Verification this pass

- **Unit (PS-Unit):** 335 run, 0 failures, 1 skipped. New/changed: `Pass33Tests` sound tests (19/19 in the class), `Pass34Tests` (1).
- **Device compile:** Release iphoneos succeeds (`./Scripts/device-build.sh`); warnings pre-existing (iOS 27 interruption API etc.).
- **Not re-run (no relevant change):** UI tours; Speed & Audio UI tests (only the confirmation text changed); model tests.
- **evalset.py:** run on all five Results exports; caption parsing/alignment checked on synthetic input, including refusal across a stitched gap; SponsorBlock queried for 2 matched uploads.
- **Only the phone can show:** the sound after updating and after Reset; whether Qwen3 4B still closes the app.

## 5. Mac disk

≈22 GB free at the end of the pass (`build/DeviceDerivedData` ≈ 1.4 GB, simulator DerivedData rebuilt). The temporary 3ba90ff worktree used for symbolication was removed. Nothing else deleted.

## 6. Delivery and next steps

- **Pass 34 app commit:** see `git log` on `main` (the commit titled "Pass 34: …"); this pass does not trigger CI on its own — push when he wants an IPA (Pass 33's IPA, 8bbe5dd, is the last delivered build).
- Pass 33 delivery for reference: `8bbe5dd`, CI run 37905713822, artifact `PodSkipper-ipa` 11604479652.
- `AGENTS.md` (untracked, written by another tool) left untouched.
- Next: his phone on the Pass 34 build — (1) sound unchanged after update, then Reset → neutral; (2) one Core AI Qwen3 4B Basic + Hard. If Qwen3 4B still aborts with the "8-token steps" note, record it as an Apple runtime limit (apple/coreai-models #201) and steer that job to MLX Qwen3.5 4B / Apple Intelligence. Reader: each new Results export → `evalset.py build` → `evaluate`; detector changes only when held-out shows don't get worse; then the base plan batches (catalogue stash repair, parity, data/publishing).
