# Claude Opus 5.5 resume prompt — PodSkipper

## Recommended effort setting

For this takeover, use **Opus 5.5 at High effort** while reconstructing the two local checkouts and resolving the cross-cutting recovery state. After the state is understood, use **Medium** for bounded implementation/test batches. Escalate to **Extra High/xhigh** only for genuinely difficult problems where the added reasoning is worth the usage cost — for example the SwiftData catalogue conflict, Core AI/MLX runtime/cancellation/recovery, or a stubborn cross-cutting regression. Do not default to Max.

The goal is not to spend the most tokens. The goal is to preserve state, diagnose before retrying, and finish coherent batches.

## Copy/paste takeover prompt

You are taking over the PodSkipper iOS project from ChatGPT/Codex after its usage limit interrupted unfinished local work.

This is a continuation of an existing recovery project, not a fresh implementation. Do not restart from assumptions, do not trust assistant summaries as implementation truth, and do not overwrite unpublished work to obtain a clean repository.

Keep working until the coherent task is actually implemented and checked. Only stop to ask the user when a necessary product decision cannot be established from current context or immediately before a genuinely risky/irreversible action. A plan, progress report, green compile, simulator screenshot or partial patch is not completion.

### 1. Recover BOTH local checkouts before editing

#### A. Active UX4 engineering checkout

Expected path:

`/Users/shashankpandya/Developer/podskipper-recovery`

Last transcript-grounded state:

- branch `codex/complete-project-recovery`;
- local HEAD `59c3afd0557d298137d26408e25b4a3e6d9c21c9`;
- 14 modified files + 5 untracked files;
- parked catalogue stash preserved;
- work deliberately held before a coherent final commit/push.

Remote PR #22 head was:

`252be96ae41ba1cdd93b8cca4304938905cdecee`

GitHub cannot resolve `59c3afd...`, so the local checkout may contain the newest source/docs.

#### B. Acceptance-enforcement checkout

Expected path:

`/Users/shashankpandya/Desktop/2026-10-02/referenced-chatgpt-conversation-this-is-an/work/podskipper-acceptance`

Expected branch:

`codex/acceptance-gates`

Transcript references local commits:

- `6f30ce0`
- `cfebe4d`

GitHub currently has neither.

The transcript shows a final command attempting:

`git commit -m 'Repair acceptance gates and preserve bounded UX4 integration handoff'`

immediately before the usage-limit failure. Do **not** assume that commit succeeded.

#### For both checkouts, report before editing

- actual path;
- branch and exact HEAD;
- upstream/remotes;
- local commits absent from origin;
- remote commits absent locally;
- `git status --short --branch`;
- every modified and untracked path;
- worktrees;
- stashes;
- ignored rollback/evidence artifacts relevant to the handoff;
- whether the named local commits actually exist;
- any post-transcript changes.

Create recoverable snapshots before integrating overlapping work.

Do **not** reset, clean, rebase, force-push, blindly pull, pop/apply stashes, overwrite docs, delete model caches, or discard local files simply to make either checkout clean.

Preserve:

- Feather-installed app/data;
- signing identity and runtime bundle behavior;
- downloaded model caches;
- rollback IPAs/artifacts;
- local commits;
- local stashes;
- ignored test/evidence artifacts.

### 2. Read the transition package in this order

After Git-state recovery, read:

1. `claude/CHATGPT-TRANSCRIPT-AUDIT-2026-10-04.md`
2. `claude/CHATGPT-TO-CLAUDE-HANDOFF-2026-10-04.md`
3. `claude/CHATGPT-TRANSITION-FILE-MANIFEST-2026-10-04.md`
4. this prompt
5. current live versions from the UX4 checkout of:
   - `PodSkipper — Product Specification & Decisions.md`
   - `claude/REQUEST-CATALOG.md`
   - `IMPLEMENTATION-PLAN.md`
   - `claude/HANDOFF.md`
   - `CLAUDE.md`
6. current evidence/reconciliation files needed for the active batch.

The raw uploaded ChatGPT/Codex transcript is provenance, not implementation authority.

Authority order:

1. latest explicit user requirement/correction;
2. current live source/dirty diff;
3. exact build/test/result evidence tied to that source/config;
4. physical-device evidence for device-only behavior;
5. historical assistant/chat claims only as provenance.

Later physical-device failure overrides earlier simulator success.

### 3. Thoroughly review the project folder, not only handoff files

Inspect every new/modified remote transition file listed by the manifest and then the newer local-only dirty paths from the UX4 checkout.

Do not assume new files are correct because they compile or because an older UI test passed.

Pay particular attention to:

- model runtime ownership/cancellation;
- Core AI and MLX package/readiness semantics;
- download state/progress/resume;
- processing recovery/checkpoints;
- SwiftData save/merge ownership;
- player/video routes;
- audio DSP versus explanatory UI;
- navigation;
- Dynamic Type/accessibility;
- state persistence;
- simulator-only demo paths versus real runtime paths.

Do not delete reconciliation/archive files merely because they look duplicated. They are deliberate provenance.

### 4. Latest explicit product corrections — use these, not superseded designs

#### Player / video

The user physically reported that Build #303 regressed the player.

Restore/verify the known-good player behavior before layering cosmetic changes.

Video requirements:

- video occupies the full available width like Apple Podcasts;
- resolve RSS/feed video first;
- if RSS has no video, resolve the embedded video link from the Apple Podcasts web page;
- Stavvy's World episode #200 is a concrete regression case;
- trace the historical implementation before replacing the resolver architecture.

#### Speed & Audio

The latest user correction supersedes prior chart designs:

- real dynamic Liquid Glass/transparency must be visible in the interactive sheet;
- **remove the Simple chart entirely**;
- keep and improve **Detailed only**;
- use the **same EQ bands in portrait and landscape**;
- reflow/scroll if needed rather than deleting portrait bands;
- labels/effect explanations must be readable and truthful;
- do not draw invented frequency curves for features that are not frequency-response transforms;
- all EQ/speech/repair controls remain reachable at landscape and accessibility sizes.

Do not reintroduce:
- Simple/Detailed paired charts;
- equal Simple/Detailed geometry work;
- Warmth/Words/Edge Simple-chart concepts;
- Simple bar charts.

#### Activity

- expanded Activity supports natural swipe collapse/minimize;
- preserve readability and coherent spacing;
- fix “See All”, Open Episode row/alignment, separator consistency and full action labels;
- verify both popup and expanded page, not one presentation only.

#### Model UX

Keep the explicitly required four visible comparison rows:

1. Apple Intelligence
2. Reader
3. selected Core AI model
4. selected MLX model

For each:
- correctly proportioned Basic/Hard controls;
- play affordance/icon;
- sole active-run identity;
- clear queue/loading/generating/stopping/error state;
- persistent history across navigation;
- incomplete/failed answers cannot score as success.

Libraries/settings:
- no recursive Core AI ↔ MLX navigation;
- direct coherent libraries;
- selected downloaded model/readiness visible;
- download controls must not jump size between states;
- progress must be meaningful, not visually stuck at 0%;
- model name/size/status/download/enable layout must be coherent;
- missing/incomplete/incompatible models cannot be selected.

Core AI versus MLX:
- determine whether artifacts are actually compatible before sharing storage;
- if runtimes require separate packages, make that explicit instead of making the UI look broken;
- keep canonical model naming consistent.

### 5. Actual runtime/performance work remains open

Do not treat Reader simulator runs as proof of Core AI/MLX.

Re-establish actual runtime behavior for:

- Apple Intelligence Basic/Hard;
- Reader Basic/Hard;
- Nemotron 3 Nano 4B Core AI load/Basic/Hard;
- Qwen3 4B Core AI load/Basic/Hard;
- Qwen3.5 4B MLX load/Basic/Hard;
- Stop during queued/loading/generating;
- leave/re-enter while work is active;
- retained benchmark history.

User's physical Qwen3.5 4B MLX episode-processing report remains a blocker:

- ~11 min to ~30%;
- severe heat;
- app sluggishness;
- background/reopen restarted progress from zero.

Fix recoverable interruption/checkpoint behavior before claiming this area done. Measure performance/thermal behavior honestly; do not simply increase token limits and call it fixed.

Fresh phone failures must produce fresh diagnostics tied to the exact tested source/artifact.

### 6. Salvage local UX4 work; do not blindly preserve or discard it

The dirty UX4 tree includes attempts at:

- player/video geometry;
- Activity swipe/layout;
- model download progress/layout;
- Core AI token/context handling;
- transfer cancellation/resume;
- processing recovery;
- Basic/Hard play icons/geometry;
- sound glass/chart work;
- focused/accessibility UI tests.

Some of this is useful. Some is superseded by the user's latest corrections.

Review diff-by-diff. Preserve valid implementation, remove only proven superseded/broken portions, and keep rollback evidence.

### 7. Acceptance-enforcement checkout: audit adversarially before integration

The first validator implementation was unsafe even though its own tests passed. Later review reproduced five false passes:

1. nonexistent evidence paths;
2. incomplete required-engine coverage;
3. `working-tree` revision bypass;
4. stale/unbound external review;
5. unresolved blocking finding.

Continuation work attempted:
- evidence file/hash validation;
- engine/scenario/config/source binding;
- real xcresult parsing;
- reject zero-test/wrong-test results;
- source/app fingerprints;
- cross-checkout simulator lease;
- launch/restart receipts;
- diagnostic vs release modes;
- current-source IPA delivery gate;
- workflow-audit provenance;
- adversarial tests.

Reported 29 targeted tests passed, but:
- dedicated simulator smoke never produced a completed test receipt;
- independent reviewer hit usage limit;
- final commit is uncertain.

Therefore:
- inspect the live acceptance checkout;
- rerun the adversarial validator tests first;
- verify the simulator lease against the UX4 checkout;
- prove the smoke-test receipt end-to-end;
- integrate only verified pieces into the active project;
- do not let validator infrastructure become a new source of false confidence.

### 8. Mandatory simulator efficiency policy

The user explicitly objected to usage-heavy, confused simulator behavior.

For every simulator batch:

1. One simulator owner at a time across **all** checkouts/processes.
2. Build/generate once when possible; reuse a valid product.
3. Diagnose with one focused test or small coherent shard.
4. Prefer accessibility identifiers / semantic interaction.
5. Coordinate taps are fallback only and must be documented.
6. After a failure, inspect `.xcresult`, logs, screenshots and app state **before retrying**.
7. Restart/erase only for a demonstrated simulator problem.
8. Record simulator boot/reboot separately from app/XCTest launches.
9. Keep clean-fixture and persistent-inspection modes explicit.
10. Actual Core AI/MLX acceptance must exercise the actual engine/model/path.
11. Reader is never a substitute for Core AI/MLX inference.
12. Do not accept based only on exit code, file existence or a screenshot from the wrong state.

Do not spawn unnecessary subagents, worker threads or parallel processes. They consume usage and complicate simulator/repository ownership.

### 9. Skills/design review policy

For iOS work, always use the relevant:

- **apple-skills**
- **Figma guidance**
- **Build iOS Apps**

and verify actual Apple SDK/HIG/toolchain behavior.

Current user direction:
- Apple skills + actual SDK/HIG + product specification are authority;
- bounded read-only `workflow-audit` may be used if useful;
- **Design Director is not required**;
- do not reinstall/run Design Director automatically;
- do not block delivery on Design Director;
- do not call external reviewers/subagents without a clear bounded benefit.

### 10. Known unresolved non-UX work

Do not let the project get trapped in another endless UX loop.

After the coherent UX4/runtime batch:

#### Processing/resources/background/routes
Continue observer ownership, queue/recovery, resources/thermal/background and route acceptance.

#### Catalogue data integrity
The parked transaction draft reached 252 tests with one confirmed failure:

`CataloguePersistenceTests.testSuccessfulPrivateMergePreservesPendingMainEditsAndCompletionOnLaterSave`

A later main-context save can erase the completion marker and collapse 52 relationships to 1.

Preserve the stash/evidence. Do not blindly pop it over current UX4 work. Reproduce and resolve this in its dependency batch.

#### Detection intelligence/quality
Historical strict fixture state remains **16 of 17 failing**. Model benchmark completion does not close actual ad/fluff detection quality.

#### Full parity/integration
Continue destination/player/editor/audio/video parity, backup/history/publishing, signed capabilities and end-to-end integration.

The user explicitly required the **entire project** to be completed, not only the latest visible defects.

### 11. Evidence discipline

For every batch keep separate:

- source implementation;
- compile result;
- automated unit/integration tests;
- simulator interaction and inspected screenshots;
- physical-iPhone acceptance.

Never infer physical phone success.

Reuse valid evidence; rerun only what the current diff invalidates.

Do not merge PR #22 while current required gates remain open.

Do not modify signing identity or erase/overwrite the user's Feather app data.

### 12. Documentation discipline

After a coherent completed batch:

- update `claude/REQUEST-CATALOG.md` when acceptance/evidence changed;
- update `claude/HANDOFF.md`;
- update `IMPLEMENTATION-PLAN.md` only when dependency/exit-gate state changed;
- update stale `README.md` only after local/remote source state is reconciled;
- record exact revision and dirty/untracked state;
- preserve unfinished work explicitly.

Do not call a batch complete because you wrote documentation.

### 13. First response to the user

Do not begin with a new architecture proposal.

First provide a concise forensic state report:

- UX4 checkout path/branch/HEAD;
- exact modified/untracked paths;
- local-only commits;
- stashes/worktrees;
- acceptance checkout path/branch/HEAD;
- whether `6f30ce0`, `cfebe4d`, and the attempted final acceptance commit exist;
- remote PR #22 head;
- mismatches between docs and real source;
- exact recovery/snapshot action performed;
- exact unfinished checkpoint you are resuming.

Then continue the work without waiting for another confirmation unless a real unresolved decision or risky action requires one.

### 14. Definition of a successful takeover

A successful takeover is not “Claude understands the project.”

It is:

- both local states preserved and reconciled;
- latest user corrections applied;
- valid ChatGPT work salvaged without carrying forward known mistakes;
- acceptance tooling itself proven not to false-pass;
- affected source built/tested efficiently;
- affected simulator UI actually inspected;
- physical-only gates clearly left for the user's device;
- durable request-catalog/handoff state updated;
- the next dependency batch ready without lost context.
