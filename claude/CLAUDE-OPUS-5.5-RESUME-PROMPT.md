# Claude Opus 5.5 resume prompt — PodSkipper

## Recommended model setting

Use **Claude Opus 5.5 — Extra High (xhigh)** for this takeover and the first difficult recovery batch. This is a long-horizon, multi-file, agentic coding task with significant data-integrity and device-evidence risk. Do not use Max by default. If usage pressure becomes material after the takeover is understood, High is the reasonable step-down for well-scoped implementation work.

Opus 5.5 uses adaptive thinking; do not try to disable thinking. Keep enough output/context budget for a complete agentic loop.

## Copy/paste prompt

You are taking over the PodSkipper iOS project from ChatGPT/Codex.

This is a continuation of an existing recovery project, not a fresh implementation. Do not restart from assumptions, do not trust assistant summaries as implementation truth, and do not overwrite unpublished work to make the repository look clean.

Keep working until the coherent task I asked for is actually implemented and checked. Only stop to ask me when you genuinely cannot proceed without a user decision or immediately before a risky/irreversible action. A progress report, plan, partial patch, green compile, or simulator screenshot is not completion.

### 1. Recover the actual engineering state before doing anything else

Locate the real checkout, expected at:

`/Users/shashankpandya/Developer/podskipper-recovery`

Before editing, report:

- current branch and exact HEAD;
- upstream and current PR;
- `git status --short --branch`;
- commits not on origin;
- remote commits not local;
- every dirty and untracked path;
- worktrees;
- stashes;
- ignored rollback/evidence artifacts named by the handoff;
- whether local commit `59c3afd0557d298137d26408e25b4a3e6d9c21c9` exists and exactly what it contains.

Remote PR #22 head was `252be96ae41ba1cdd93b8cca4304938905cdecee` at the ChatGPT handoff audit. The PR body says local `59c3afd...` exists but GitHub cannot resolve it. The local checkout therefore takes precedence if it is newer.

Do **not** reset, clean, force-push, rebase, pop/apply a stash, overwrite local docs, delete caches, or pull over unpublished work just to make the tree clean.

Preserve:
- installed Feather app/data;
- signing identity and bundle behavior;
- downloaded model caches;
- rollback IPAs/artifacts;
- local commits;
- local stashes;
- ignored evidence.

### 2. Read the handoff and authority stack

After inspecting Git state, read these from the **actual checkout**, not uploaded/stale copies:

1. `claude/CHATGPT-TO-CLAUDE-HANDOFF-2026-10-04.md` if present locally; otherwise read it from branch `handoff/chatgpt-to-claude-2026-10-04`.
2. `claude/CHATGPT-TRANSITION-FILE-MANIFEST-2026-10-04.md`.
3. `PodSkipper — Product Specification & Decisions.md`.
4. `claude/REQUEST-CATALOG.md`.
5. `IMPLEMENTATION-PLAN.md`.
6. `claude/HANDOFF.md`.
7. `CLAUDE.md`.
8. `claude/evidence/2026-10-02-phone-regressions.md`.
9. `claude/evidence/2026-10-02-catalogue-transactions.md`.
10. `claude/evidence/2026-10-03-build301-device-regressions.md`.
11. relevant files under `claude/reconciliation/`.

Also open these conversation references if your environment can resolve them:

- `codex://threads/01a0ff9e-deb9-7280-bb15-a18fb838b9c7`
- `codex://threads/01a10069-5c82-7171-950b-f1686fceec0f`
- `https://chatgpt.com/share/6ac1e892-be98-83ea-9edf-43c696d1dac9`

Use them as provenance only. Latest explicit user requirements govern intent. Current code and exact test/build/device evidence establish implementation status. Later physical-device failures override older success labels.

### 3. Thoroughly audit the project folder and the transition files

Do not limit the review to handoff documents.

Use the transition manifest to inspect every changed/new path from `ad592214` to `252be96`, especially:

- `Services/CoreAIClassifierSession.swift`
- `Services/CoreAIModelDownload.swift`
- `Services/LocalModel/ModelAnswerFailure.swift`
- `Views/ModelComparisonView.swift`
- `Tests/CoreAIModelDownloadTests.swift`
- `Tests/ModelReadinessTests.swift`
- `Tests/ModelBenchTests.swift`
- `Services/CoreAIAdJudge.swift`
- `Services/CoreAIModelLibrary.swift`
- `Services/LocalModel/JudgePrompt.swift`
- `Services/LocalModel/LocalJudge.swift`
- `Services/LocalModel/LocalModelSpec.swift`
- `Services/LocalModel/ModelBench.swift`
- `Services/LocalModel/ModelStore.swift`
- `Services/ProcessingPipeline.swift`
- `Views/LocalModelView.swift`
- `Views/SettingsViews.swift`
- `Views/AudioControls.swift`
- `Views/ActivityNow.swift`
- `Views/PlayerViews.swift`
- `Views/Theme.swift`
- `Views/WorkDetailView.swift`
- `UITests/ScreenshotTests.swift`
- `Models/Models.swift`
- `.github/workflows/build-ipa.yml`.

Do not assume new files are correct because tests compile. Verify how they interact with existing ownership, cancellation, model caches, SwiftData, settings, navigation, accessibility, and the episode processing path.

The archive/reconciliation directories are intentional provenance. Do not delete them as duplicates.

### 4. Known ChatGPT/Codex mistakes that you must not inherit

- A wrong **single-engine selector** comparison UI was implemented first. The required design is four visible rows: Apple Intelligence, Reader, selected Core AI, selected MLX, each with Basic/Hard controls. Do not resurrect the one-selector design.
- Earlier chart/UI passes were later invalidated by landscape/gesture failures. Do not cite superseded intermediate runs as current acceptance.
- The new source has **no physical-iPhone acceptance**. Build/unit/simulator/CI success are separate evidence levels.
- Nemotron Core AI load failure root cause was not solved.
- Core AI Qwen incomplete answers were not proven fixed on the phone.
- The supplied diagnostics contained no MLX run, so MLX failure/root cause is not established.
- Guided Core AI output completed locally but made bad cuts/classifications. Do not promote it to the episode path merely because JSON completes.
- The catalogue transaction draft still has a real main-context overwrite/data-integrity failure.
- Detection quality still fails 16 of 17 strict fixtures.
- Feather-resigned background task/capability identity mismatch remains unresolved.
- Remote documentation is not guaranteed synchronized with local state. `README.md` is known stale relative to remote head, and `59c3afd...` is local-only according to the PR body.

### 5. What I need you to pick up and finish

First finish/reconcile Batch 1 rather than assuming ChatGPT completed it.

You need to establish the actual state of, fix where necessary, and validate:

1. Four-row model comparison UX and active-run identity.
2. Direct Core AI/MLX library routes.
3. Selected downloaded model name/readiness.
4. Download, resume, enable, select, delete and cellular behavior.
5. Selection guards for missing/incomplete/incompatible models.
6. Apple Intelligence Basic/Hard.
7. Reader Basic/Hard.
8. Nemotron 3 Nano 4B Core AI Basic/Hard/load.
9. Qwen3 4B Core AI Basic/Hard/load.
10. Qwen3.5 4B MLX Basic/Hard/load.
11. Stop during queued/loading/generating.
12. Leaving/re-entering comparison while work is active and retained history.
13. Speed & Audio medium/large sheet, compact Simple/Detailed plots, glass appearance, EQ/speech/repair reachability, landscape and accessibility sizes.
14. Activity and player equal complete action labels/buttons.
15. Fresh diagnostics tied to the exact tested artifact when any model run fails.

You cannot infer phone acceptance yourself. Prepare one coherent exact-head unsigned artifact and one consolidated phone checklist only when local gates are ready. Do not make me repeatedly install tiny incremental builds.

Then continue the dependency plan:
- Batch 2 processing/resources/observers/recovery/background/thermal/routes;
- Batch 3 catalogue context/data-integrity repair before bulk history/import;
- Batch 4 detection intelligence and 17-fixture quality gate;
- Batch 5 complete destination/player/editor/audio/video parity;
- Batch 6 backup/history/publishing/signed capabilities/end-to-end integration.

### 6. Engineering rules

Always use the relevant **Apple skills, Figma guidance, and Build iOS Apps skills** available in your environment for iOS work. Verify actual Apple APIs/toolchain behavior instead of guessing.

Use local Xcode and simulator interaction with inspected screens. Distinguish:

- implementation/source presence;
- compilation;
- automated tests;
- simulator interaction;
- physical-phone acceptance.

Reuse valid evidence rather than rerunning everything. Rerun only what the current change can invalidate.

Do not alter signing identity or install over/erase the user's Feather data.

Do not merge PR #22 while required gates remain open.

Do not start unrelated refactors or feature additions.

### 7. Session completion discipline

Maintain a short persistent checklist for the active batch and keep it updated as work proceeds.

Before you stop:
- finish the coherent requested batch unless genuinely blocked;
- run the relevant build/tests;
- interact with the simulator and inspect actual screenshots for affected UI;
- record exact revision and exact evidence;
- explicitly list what was not tested;
- update `claude/REQUEST-CATALOG.md` if evidence/status changed;
- update `claude/HANDOFF.md`;
- update `IMPLEMENTATION-PLAN.md` only if dependency/exit-gate state changed;
- update stale `README.md` only after local/remote state is reconciled;
- preserve dirty/untracked/local-only work;
- leave an exact next executable action.

Never end with only “here is what I would do next” when you can perform the work yourself.

### 8. First response to me

Do not start by proposing a new architecture.

Start by giving me a concise forensic state report containing:

- actual checkout path;
- branch/HEAD/upstream;
- remote PR head;
- local-only commits;
- dirty/untracked files;
- stashes/worktrees;
- whether `59c3afd...` exists;
- any mismatch between the current handoff docs and the actual tree;
- the exact unfinished Batch 1 checkpoint you are resuming.

Then continue the work without waiting for another confirmation unless a real decision or risky action requires it.
