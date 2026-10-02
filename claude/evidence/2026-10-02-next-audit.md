# Remaining scoped audit findings — 2 October 2026

Read-only audit against source `6b2d987`. This preserves the concrete failures identified at that revision. History import was addressed at `6394f68`, category cleanup/diagnostics at `2f841ea`, and exact destination/queue routing at `2073fde`. Station grouping/manual order is in the following validated batch. See `2026-10-02-data-stations-checkpoints.md` for current evidence and remaining verification boundaries. Live data and phone identity are preserved.

## Data cleanup

- `BackupService.stored` includes every Documents/.Trash and .Trashes item; stored-backup cleanup must retain unknown or unrelated trash and delete only owned backup/history artifacts.
- `FileStore.deleteAudio` accepts persisted path components and removes FileIndex/companions even when deletion fails. Require a direct-child basename boundary and track actual success for each file.
- `ProcessingPipeline.clearDownloads` and `DownloadManager.remove` clear filenames after failed file deletion. Preserve failed references and return/report real outcomes.
- `StorageView` omits inline-only transcripts and extracted-audio-only episodes in different selection/perform predicates. Use symmetric eligibility. Protect active player and processing/publishing work; explicit transcript cleanup must clear the corresponding resumable transcript/detection checkpoints so text cannot reappear.
- Diagnostics cleanup deletes files but leaves TimingLog.entries and BackgroundLog.events in memory; a subsequent log write resurrects old data. Prune/clear through the owning store and coordinate pending writes.

## History import

- `HistoryImport.normal` lowercases entire feed URLs, merging case-sensitive paths. Normalize only scheme/host and canonical URL components.
- `LibraryIndex.applyHistory` title fallback selects an arbitrary repeated title. Permit only a unique title within a matched feed; report ambiguity.
- Coalesce duplicate/conflicting rows by stable feed/GUID before mutation. Validate the archive's supported format/version before following feeds.
- `lastPlayedAt` must reflect genuine play/resume evidence. Apple source 6/default records must not become chronological New cutoffs. Preserve explicit local Mark Played instead of force-resetting it for imported default/unplayed records; any repair requires known import provenance.

## Destination and station parity

- FilterResultsView.playAll bypasses PlayCoordinator and picks first downloaded episode rather than the ordered first episode; use shared exact-episode/countdown routing.
- queueAll assigns 0…N without accounting for already queued episodes; prevent collisions and duplicates while preserving requested order.
- Station model lacks group-by-show preference and a manual episode-order schema; station-list order and sort-by-show alone do not satisfy this request.
- PersonView swallows errors and successful empty results remain 'Looking for…'. CategoryView also treats empty results as perpetual loading. Provide distinct loaded-empty/error/offline states with retry.
- Full category/shelf/See All/search-result/show-preview/people and populated station tours remain required. The prior 25-screen tour did not cover them.

## Access/verification

Installed re-signed phone identity remains `app.ivory2951.coral5096`; its exact source/signature capabilities are not proven. Do not replace the installed app or data to simplify testing. Real battery/charger background processing, heat/memory/scrolling, routes, public video/PiP and signed integration checks remain required.

## Current remaining source findings

- `VideoAudio` temporary-file cleanup still takes a stale snapshot and can race active preparation; it needs the same path/ownership/failure safeguards as download cleanup.
- `EpisodeCatalogue.fill`/`LibraryIndex.merge` do not report persistence failure to callers. `DiscoverService.lookup` suppresses per-chunk network/decode errors, which prevents views from distinguishing failure from genuine empty data.
- Full destination/editorial/pagination/preview parity, populated feature/accessibility tours, controlled phone background/thermal/routes, real import/backup/publishing and signed integrations remain open.
