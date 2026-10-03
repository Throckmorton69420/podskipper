> **Dated evidence/reference.** Findings and verification apply only to the named revision/inputs. Current specification, catalog and handoff govern scope/status; later user failures override earlier pass labels. Do not execute obsolete future-work directions from this report.

# Backup and restore recovery evidence — 2 October 2026

Simulator-hosted unit bundle: `build/unit-20261002-005713.xcresult`; 43 tests passed, including 10 new disposable-data archive/restore tests. No operation touched the installed iPhone library.

## Implemented behavior

- Each restore directory rename is journaled before it occurs. A failed or interrupted swap reverses completed moves, restores original defaults, retains its complete staged copy and retry marker, and does not open SwiftData until recovery succeeds.
- A committed restore retains one complete original rollback (library, checkpoints and settings). Current MLX and Core AI download caches survive the swap rather than being duplicated into backups.
- New archives include file sizes and streaming SHA-256 checksums. Staging validates integrity, settings and SQLite quick-check before replacing an existing pending restore. Old unversioned archives remain readable.
- Coordinated reads perform extraction inside the coordinated callback. Invalid files and insufficient-space errors leave both live and existing staged data intact.
- Backup names are unique even in the same minute. Retention uses creation dates and ownership records; corrupt records are preserved and cannot authorize deletion. Individual deletion is limited to the app's own Documents directory. External copies are untouched.
- Startup displays a recovery failure and retry action instead of force-crashing or opening partially swapped data.

## Tested

Round trip with audio, transcripts, checkpoints, settings, SQLite and preserved model caches; fault after every directory rename; repeated recovery after an interrupted swap; invalid settings; legacy archive; missing file; same-size corruption; corrupt archive; injected insufficient capacity; newest-N retention; same-minute uniqueness; external-copy preservation and scoped individual deletion; corrupt ownership record.

## Still required

Physical iCloud placeholder/download interruption, real storage exhaustion, recovery after a signed reinstall with preserved identity, and full-library throughput. The free-space preflight is conservative and based on archive size; compressed expansion can exceed it, in which case staging must fail without replacing originals. These tests establish disposable-data behavior, not phone verification.
