# ChatGPT → Claude Opus 5.5 forensic handoff — 4 October 2026

> **Read this before touching code.** This file exists to prevent Claude from inheriting ChatGPT/Codex mistakes, stale status labels, or unverified success claims. It is a transition record, not acceptance evidence.

## 1. Repository state that must be reconciled first

Remote repository: `Throckmorton69420/podskipper`  
Active recovery branch: `codex/complete-project-recovery`  
Draft PR: #22, still open/draft/unmerged  
Remote PR head at handoff audit: `252be96ae41ba1cdd93b8cca4304938905cdecee`  
Implementation checkpoint inside that head: `8698c0ab984a653a45df16bbe5c713a0db8cbd3e`

GitHub Actions run **37100498970 / Build #303** completed successfully on exact head `252be96`. That proves unsigned compilation/verification/packaging for that revision. It does **not** prove simulator acceptance or physical-phone behavior.

The PR body states that there is a **local documentation-only commit**
`59c3afd0557d298137d26408e25b4a3e6d9c21c9`
after the pushed head. GitHub cannot resolve this SHA. Therefore the actual engineering checkout may be ahead of GitHub.

Before changing anything, inspect the real checkout, expected at:

`/Users/shashankpandya/Developer/podskipper-recovery`

Record:
- current branch and HEAD;
- upstream and PR;
- `git status --short --branch`;
- unpublished commits relative to origin;
- every dirty and untracked path;
- worktrees;
- stashes;
- ignored rollback/build artifacts named by the current handoff;
- whether local `59c3afd...` exists and exactly what it contains.

**Do not reset, clean, rebase, force-push, pop/apply a stash, overwrite local docs, or pull over unpublished work merely to obtain a clean tree.**

Preserve the user's Feather-installed app/data/signing identity, downloaded model caches, rollback IPAs, ignored evidence, local commits and stashes.

## 2. Conversation provenance and its limits

The user supplied these conversation references for the ChatGPT/Codex phase:

- `codex://threads/01a0ff9e-deb9-7280-bb15-a18fb838b9c7`
- `codex://threads/01a10069-5c82-7171-950b-f1686fceec0f`
- `https://chatgpt.com/share/6ac1e892-be98-83ea-9edf-43c696d1dac9`

The current ChatGPT tool environment could not resolve the two `codex://` URIs and the public share page did not expose the transcript here. Claude should open them if its client can.

Because those transcripts were not readable here, **do not treat model authorship of every commit as proven**. The transition window below is reconstructed from Git history, project-indexed source documents, the current PR and the repository's own evidence files.

## 3. Reconstructed transition window

Last audited delivered baseline before the current transition work:

- remote/document head: `ad592214ad6b5d56691f8a2792ac0cbe9e2990be`
- app source represented by that delivery: `24c03da`
- user-installed Build 301: physical-phone regressions reported; no overall phone acceptance.

Remote commits after `ad592214` and before/current `252be96`:

1. `63fd19916c782fccfedd2b6e79668e859e63f435` — Preserve unfinished catalog conflict and prioritize phone regressions
2. `aadde549fb32cb986fdc1db54f2a174767242afd` — Preserve unfinished phone-regression evidence before documentation integration
3. `146a3dedfd271077eacf050f78ee29fec2424a1e` — Reconcile product intent, acceptance evidence and historical provenance
4. `577c5f215ae0a9a05fa0cea7753bd9fa743d552d` — Integrate reconciled specification without overwriting regression work
5. `8698c0ab984a653a45df16bbe5c713a0db8cbd3e` — Repair Build 301 model flows, benchmark lifecycle and shared controls
6. `252be96ae41ba1cdd93b8cca4304938905cdecee` — Record Build 301 regression evidence and remaining device gates

Use `claude/CHATGPT-TRANSITION-FILE-MANIFEST-2026-10-04.md` for the exact file list.

## 4. What ChatGPT/Codex attempted to implement

### Model settings, libraries and comparison
The transition work attempted to:
- open the real Core AI and MLX libraries directly instead of through redundant landing pages;
- show selected downloaded model name/readiness in Settings;
- make Core AI and MLX section ordering/descriptions/controls consistent;
- prevent selection of missing, disabled, incomplete or incompatible models;
- provide one shared comparison destination;
- display four visible engine rows: Apple Intelligence, Reader, Core AI selected model and MLX selected model;
- keep Basic/Hard controls next to the corresponding engine;
- keep Core AI/MLX catalogues collapsed by default within comparison;
- preserve benchmark histories and exact engine/model/revision/variant/sample/policy identity;
- show only the requested benchmark as active;
- expose queued/loading/running/stopping/error state and real Stop behavior;
- avoid assigning a success score to incomplete/failed output.

### Core AI / MLX runtime and download work
The transition work added or changed:
- an app-owned Core AI benchmark classifier session using the public tokenizer/runtime for supported Qwen/Nemotron families;
- non-thinking chat templating and constrained JSON for the benchmark path;
- cancellation intended to keep shared heavy-work ownership until engine work unwinds;
- Core AI staged/resumable downloads and atomic installation;
- readiness validation and guarded model selection;
- MLX readiness checks for manifest/required files/JSON;
- more complete benchmark failure measurements.

The episode cutting path was deliberately **not** switched to the new guided Core AI benchmark path because local guided outputs completed but made wrong classifications.

### UI regressions
The transition work attempted to repair:
- oversized Speed & Audio plot;
- inconsistent Simple/Detailed plot geometry;
- inaccessible landscape/large-text sound controls;
- material/detent behavior;
- unequal/truncated Activity Pause/Stop and Resume/Stop actions;
- player action sizing and accessibility scrolling.

### Documentation/reconciliation
The transition also introduced the compact authority stack:
- `PodSkipper — Product Specification & Decisions.md`
- `claude/REQUEST-CATALOG.md`
- `IMPLEMENTATION-PLAN.md`
- `claude/HANDOFF.md`

and a large provenance/archive/reconciliation set so historical Claude/assistant “done” labels no longer automatically count as current acceptance.

## 5. ChatGPT/Codex mistakes, failed approaches and claims to distrust

These are not theoretical. They are preserved in the repository and must be treated as lessons/known failure modes.

### A. Wrong comparison design was implemented first
An unpublished/local draft replaced the required four visible engine rows with a **single-engine selector / one-runner** UI. That contradicted the user's later explicit Build 301 requirement.

The repository itself marks that draft as superseded in:
`claude/evidence/2026-10-02-phone-regressions.md`.

Commit `8698c0a` later restored the four-row design. **Do not resurrect the one-selector design.**

### B. Earlier simulator/chart “success” was invalidated by later failures
The evidence records multiple failed/intermediate UI attempts. In particular, a later landscape gutter/gesture check failed after an earlier chart-control pass. The repo explicitly says not to claim acceptance from the earlier pass.

Only the specifically named later passing bundles in:
`claude/evidence/2026-10-03-build301-device-regressions.md`
count as the current local simulator evidence for that revision.

### C. Physical-phone success was never established for the new fixes
The user physically tested Build 301 and reported failures. The later fixes at `8698c0a/252be96` have local build/unit/simulator evidence but **not physical-iPhone acceptance**.

Never convert:
- compile success,
- unit success,
- simulator UI success,
- CI IPA packaging

into “works on phone.”

### D. Nemotron Core AI startup root cause remains unresolved
The supplied Build 301 diagnostic export establishes five Nemotron load failures with:
`CoreAIDelegates.AIModelError error 0`.

ChatGPT/Codex did not prove the OS/runtime root cause and did not prove the new revision loads successfully on the phone.

### E. Core AI Qwen and MLX Qwen3.5 phone behavior remains unresolved
The supplied export had three incomplete Core AI Qwen Basic answers. It had **no MLX run**. The user's MLX startup/failure report remains valid user acceptance evidence, but the export does not reproduce it.

Same-model iPhone Basic/Hard/load/Stop/history must be retested on the new artifact.

### F. Local guided Core AI output completed but quality was poor
Mac probes for Qwen completed with the new guided path but made incorrect cuts/classifications. Do not promote that runtime to the episode path merely because it returns syntactically complete JSON.

### G. Catalogue transaction repair is unfinished and parked
A separate unpublished catalogue transaction draft reached 252 tests with one confirmed failure:
`CataloguePersistenceTests.testSuccessfulPrivateMergePreservesPendingMainEditsAndCompletionOnLaterSave`.

A later pending main-context save can erase the completion marker and collapse 52 relationships back to 1. That is a real unresolved data-integrity issue.

Preserve:
- named stash `stash@{0}` if still present;
- `build/catalogue-transaction-final-working.tar.gz`;
- its patch/checksum/evidence.

Do not blindly pop the stash.

### H. Detection quality remains failed
The current authoritative docs still say **16 of 17 strict quality fixtures fail**. UI/model-benchmark work does not close detection quality.

### I. Background capability/signing mismatch remains unresolved
The diagnostic export shows the Feather-resigned runtime bundle identity does not match declared continued-processing task identifiers and background GPU/inference capabilities were missing in that installed copy.

Do not change app identity or signing configuration casually. Diagnose the actual resigned entitlements/capabilities without destroying the user's installed app data.

### J. Remote/local documentation is not fully synchronized
Two concrete warning signs:
- PR #22 body refers to local-only `59c3afd...`, absent from GitHub.
- active `README.md` still describes `ad592214/Build 301` as the latest audited baseline even though the remote PR head is `252be96`.

Treat docs as inputs to reconcile against the live checkout, not unquestionable truth.

## 6. Things the user was trying to get ChatGPT to finish that remain incomplete

Claude should pick these up instead of assuming the transition batch completed them.

### Immediate Batch 1 acceptance
1. Reconcile the actual live checkout with remote `252be96` and local `59c3afd...`.
2. Verify the four-row comparison UX is exactly the user's required design.
3. Verify Core AI and MLX library routes, selected model/readiness, download/enable/select/delete/cellular controls.
4. Diagnose and fix actual physical-device model behavior:
   - Apple Intelligence Basic/Hard;
   - Reader Basic/Hard;
   - Nemotron 3 Nano 4B Core AI Basic/Hard/load;
   - Qwen3 4B Core AI Basic/Hard/load;
   - Qwen3.5 4B MLX Basic/Hard/load;
   - Stop during queued/loading/generating;
   - leave/revisit screen and preserved history.
5. Export fresh phone diagnostics for any failure and use the exact new source/artifact identity.
6. Physically verify the repaired Speed & Audio sheet, plot size, glass, EQ/speech/repair controls, landscape/large text.
7. Physically verify Activity and player equal full-label controls.

### After Batch 1
8. Batch 2: processing observers/queue/recovery/resources/background/thermal/routes.
9. Batch 3: repair the parked catalogue/main-context conflict before bulk history/import work.
10. Batch 4: detection/class/boundary/correction intelligence and the failed 17-fixture quality gate.
11. Batch 5: full destination/player/editor/audio/video parity and phone routes.
12. Batch 6: backup/history/publishing/signed capabilities/end-to-end integration.

Do not skip ahead in a way that makes a lower dependency unsafe.

## 7. Evidence that can be reused, but only at its stated level

At `8698c0a/252be96`, repository evidence records:
- 242 local unit tests passed;
- unsigned Release iphoneos build passed;
- named simulator Activity/sound/model/accessibility flows passed;
- Build #303 / run 37100498970 successfully compiled/verified/packaged the exact pushed head.

These are valuable and should not be needlessly repeated, but they are **not phone acceptance**.

## 8. Files added by the transition that deserve explicit review

Do not merely trust their existence. Read them and verify behavior:

Implementation:
- `Services/CoreAIClassifierSession.swift`
- `Services/CoreAIModelDownload.swift`
- `Services/LocalModel/ModelAnswerFailure.swift`
- `Views/ModelComparisonView.swift`

Tests:
- `Tests/CoreAIModelDownloadTests.swift`
- `Tests/ModelReadinessTests.swift`

Major modified implementation files:
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
- `.github/workflows/build-ipa.yml`

Evidence/docs:
- `claude/evidence/2026-10-02-phone-regressions.md`
- `claude/evidence/2026-10-02-catalogue-transactions.md`
- `claude/evidence/2026-10-03-build301-device-regressions.md`
- all files under `claude/reconciliation/`
- all files under `claude/archive/2026-10-02-reconciliation/`

The archive is intentional provenance. **Do not delete it as “duplicate docs.”**

## 9. Known stale or synchronization-sensitive files

### `README.md`
Its baseline paragraph is stale relative to remote head `252be96`. Update only after reconciling the actual local checkout and local-only documentation commit.

### `claude/HANDOFF.md`, `claude/REQUEST-CATALOG.md`, `IMPLEMENTATION-PLAN.md`
Remote versions reflect the 3 October pushed checkpoint, but the PR body says a later local docs-only commit exists. Prefer the live checkout versions if newer and reconcile rather than overwrite.

### `CLAUDE.md`
Keep its repository-first/evidence-level rules. Amend only if necessary after reading the live checkout and current user instruction. Do not restore the archived cloud-only restrictions.

## 10. Handoff discipline Claude must follow from here

Use the user's latest explicit requirements as product intent. Use current code and exact evidence as implementation state. Later physical-device failure overrides earlier success.

For every meaningful batch, keep separate:
- source implementation;
- compilation;
- unit/integration tests;
- simulator interaction with inspected screens;
- physical-phone acceptance.

Before ending a session:
1. finish the coherent requested batch unless genuinely blocked;
2. update the request catalog status/evidence;
3. update the handoff with exact revision and unresolved failures;
4. record dirty/untracked/local-only work;
5. do not call a batch done because a plan or progress report was written;
6. do not fabricate access to the user's Feather container/device;
7. leave a precise next executable action, not a vague “continue testing.”

Use the relevant Apple/SwiftUI/iOS and Figma/build skills available in Claude's environment. Verify APIs rather than guessing.

## 11. Deletion instructions

**No existing tracked project file should be deleted merely for this handoff.**

The archive/reconciliation copies were intentionally retained as provenance. The known bad one-selector implementation is historical evidence, not a separate active file that must be deleted; the active implementation must simply remain aligned to the four-row design.

Any later deletion should be based on live code/dependency review, not on this handoff document.
