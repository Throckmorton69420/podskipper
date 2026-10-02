# Catalogue transaction investigation — unfinished

The requested save-failure propagation batch is parked for the user's newer phone regressions. It is not part of the delivered PR source. Base: `ad592214ad6b5d56691f8a2792ac0cbe9e2990be`, branch unchanged.

Preserved working state: local `stash@{0}` (message begins “Catalogue transaction WIP”), ignored `build/catalogue-transaction-final-working.tar.gz`, tracked diff `.patch`, and earlier checksum manifest `build/catalogue-transaction-working.json`. Restore the named stash only after reconciling any subsequent changes to the same files; do not blindly pop it over later UI work. Seventeen files, including new tests, are preserved.

Intermediate 250 units pass at `build/unit-20261002-184148.xcresult`. The final review adds two cases: 252 units execute with one failure at `build/unit-20261002-184606.xcresult`. Failed case: `CataloguePersistenceTests.testSuccessfulPrivateMergePreservesPendingMainEditsAndCompletionOnLaterSave`.

Focused reproduction `build/unit-catalogue-context-conflict.xcresult`/log confirms that the main context retains the old show snapshot. Before its save, main marker is nil/main episodes 1, while a fresh stored snapshot has a completion marker/52 relationships. After saving the pending main-context title edit, stored marker becomes nil and relationships return to 1. This is a genuine conflict, beyond the originally scoped error-reporting fix. Repair needs ownership/merge coordination preserving both user edits and newly linked episodes; do not weaken the assertion or push the draft as validated. The executor-affinity probe is separately inconclusive and remains preserved in ignored build evidence.

Other draft checks exercise private-context rollback, successful partial 50-row saves, permanent IDs, retry without duplication, cancellation, missing-show fetch safety, duplicate GUID ownership, conservative catalog title identity, initial-follow failure cleanup, and complete Apple catalog pagination. History missing-show network failures are now exposed in the draft. iCloud partial-follow failures allow independent existing-episode updates; no real signed iCloud verification is claimed.

Failure banner test passes in 26.531 s (`build/TR-recovery-catalogue-error.xcresult`); both whole-display portrait/landscape images were inspected and show a readable message and reachable Retry. It uses a demo-injected error, not genuine low-storage hardware. Landscape bottom glass still obscures unrelated rows; that remains open. These UI changes are also parked in the stash.
