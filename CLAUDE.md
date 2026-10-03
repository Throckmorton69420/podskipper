# PodSkipper — Repository Working Instructions

Read [Handoff](claude/HANDOFF.md), [Request Catalog](claude/REQUEST-CATALOG.md), [Product Specification](PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md), then [Implementation Plan](IMPLEMENTATION-PLAN.md). These replace old cloud-only/pass assumptions. Latest explicit user intent wins; historical source/archive/cloud briefs and pasted assistant reports are evidence only.

- Preserve other checkouts, local unpublished changes, rollback and installed phone app/data/actual signing identity. Isolate documentation or coding work; inspect current status before changing files. Do not assume direct access to Feather installation/container/capabilities or install over user data.
- Deployment target is iOS 27. Visual/functional reference is Apple Podcasts iOS 27.2 beta 2. Verify actual toolchain/SDK/capability availability, relevant Apple skills and official APIs before implementation; stale assistant framework/model claims are not authority.
- Work locally on Mac/Xcode/simulator. Latest workflow instruction uses GitHub for unsigned IPA compilation/delivery, local tools for tests/UI inspection. Keep atomic checkpoints and consolidated complete validated pushes/PRs; no broken or incomplete merge or force overwrite.
- Distinguish compilation, tests, inspected simulator behavior and actual phone acceptance. Name exact revision/artifact/evidence/remaining checks. Latest phone regressions override old pass labels; source presence is built/unverified until relevant gates pass.
- Keep one durable per-episode job owner, shared heavy-work coordinator, checkpoint/model/run identity and late-cancellation protections. No artificial silent processing audio, competing heavy inference or fabricated progress/telemetry.
- Avoid whole-library/main-thread work and frequent broad view updates; measure executor/performance behavior rather than trust comments. Catalogue transactions must preserve pending user edits/relationships and propagate save failure; no rollback of another context's listening work.
- Reuse transcript/model caches and existing focused tests/tours. Validate affected behavior and meaningful failure scenarios; no caffeinate, wasteful polling/review retries or repeated tiny phone-test requests.
- Shared typography/glass/spacing/targets and native navigation across all destinations, with accessibility/motion/contrast preferences. Plain concise user-facing strings; no implementation jargon in product flows.
- Use Episode.apply(_:to:) for correction verdicts, preserve original/corrected/locked history, and use existing AppSettings/per-show save patterns. Additive versioned migrations with defaults/optionals must be tested on disposable copied data.
- Never commit secrets/tokens/signing material, generated build/model/media files. Historical cloud delegation does not authorize new agents or tasks. Work only within the current user's task.
- Update catalog and handoff after each completed batch, retaining declines/supersessions and evidence limits. Do not call the whole product complete while required gates remain open.

The prior instructions are preserved in [Archive](claude/archive/2026-10-02-reconciliation/README.md). Their old SDK26 guards, Ksign/com.works identity, no-Mac/cloud file restrictions and direct-main assumptions do not govern the current local recovery environment.
