# PodSkipper

An iOS 27 podcast player with on-device transcription/ad detection, richer listening controls, public-source video and safe backup/import/publishing workflows. The recovery branch is under active acceptance testing; compilation and individual tests do not mean the product is finished.

## Current documentation

- [Product Specification & Decisions](PodSkipper%20%E2%80%94%20Product%20Specification%20%26%20Decisions.md): authoritative product intent and settled scope.
- [Request Catalog](claude/REQUEST-CATALOG.md): individual acceptance/status/evidence and user provenance.
- [Implementation Plan](IMPLEMENTATION-PLAN.md): current dependencies and exit gates.
- [Handoff](claude/HANDOFF.md): exact delivered baseline, unpublished work, regressions and next action.
- [Reconciliation Report](claude/reconciliation/RECONCILIATION-REPORT.md): gaps, coverage, source index, supersessions and evidence audit.

The latest audited app baseline is draft [PR #22](https://github.com/Throckmorton69420/podskipper/pull/22), ad592214/Build 301. Its build/regression workflow succeeds, while the user reports phone model/UI failures and detection/device/integration gates remain open. See the handoff before coding or delivering.

Local Mac/Xcode performs builds, tests and actual simulator inspection. GitHub packages the unsigned IPA; the user signs/installs with Feather. Preserve installed data/signing identity and don't infer container/debug/capability access. Use the actual current project.yml/toolchain rather than obsolete original skeleton setup directions.

`PLAIN-ENGLISH-GUIDE.md`, `PUBLISHING.md`, older cloud tasks and evidence reports are descriptive/dated relative references; the four current documents above govern scope/status. The original README and replaced plan/catalog/instructions are [archived](claude/archive/2026-10-02-reconciliation/README.md). Raw Claude history is non-authoritative provenance, never an active backlog or verified completion list.
