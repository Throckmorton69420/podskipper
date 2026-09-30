# Cloud task 08 — Scrolling that feels smooth everywhere

Branch: `cloud/scrolling`. Read `CLAUDE.md` first. Branch from current `main` (tasks 01–07 are merged). **Don't edit** `Services/ProcessingPipeline.swift`, `Services/ModelFinder.swift`, `Services/LocalModel/`, `Services/PlayerEngine.swift`, `Services/StreamEngine.swift` or the `CLAUDE.md` list — those are waiting on phone tests. Your files: `Views/` (all except `ActivityView.swift`, `DiagnosticsView.swift`, `PlayerViews.swift`), `Services/LibraryIndex.swift`, `Services/ArtworkStore.swift`, `Services/EpisodeCatalogue.swift`, `Models/Models.swift` (only computed helpers, no stored-property changes).

## What he reports (repeatedly, his words condensed)

"Scrolling is choppy and doesn't feel buttery smooth"; "stuttering up and down effect when scrolled/swiped up to the top of the page on the library and up next page"; artwork disappearing randomly while a job runs; the library/episode lists freezing for a moment while ads are being found. Catalog: Smooth scrolling — PARTIAL; quick swipe-to-top — OPEN.

## What to do

You can't run Instruments here, so this is a careful code audit plus fixes. Use the `guide-swiftui-performance-audit` approach (Apple skills) if available.

1. Audit every scrolling screen: Library (grid and two-column), a show's episode list, Up Next, Search/Discover shelves, Downloads, Activity's list is out of scope. For each, look for: work in `body` (sorting, filtering, date formatting, string building, `FetchDescriptor`s, file-system checks such as `FileManager.fileExists`, JSON decoding) → move to cached/computed-once values or `LibraryIndex`; `@Query` over the whole library feeding a list → limited fetches; views observing an object that changes often (the pipeline's progress, the player's time) → isolate that read in a tiny subview; images decoded on the main thread or at full size → downsample to the displayed size off the main thread and cache (`ArtworkStore`); missing stable `id`s; `AnyView`; heavy `.shadow`/`.blur`/materials inside rows; `GeometryReader` in rows.
2. The "stutter at the top" on Library and Up Next: find what changes size when the scroll reaches the top (a header, the tab bar's bottom accessory / mini player, a safe-area inset, a `.searchable` or large title) and stop the layout loop.
3. Artwork disappearing during a job: find why rows lose their image (cache eviction, view identity changing when the episode's processing state changes, a reload triggered by pipeline updates) and fix it.
4. Swipe-to-top (tapping the status bar / tapping the current tab): make it land cleanly without the bounce stutter.
5. Keep every change behaviour-neutral apart from speed. List each change in the PR with the file and the reason ("row computed its date string on every scroll frame — now cached").

## PR rules
Branch from the latest `main` (a lot changed since this brief was written). Rebase before opening the PR; open it ready for review, not draft; one CI check-in at most.

## Done means

PR from `cloud/scrolling`, CI green with zero warnings from PodSkipper's code, and a PR description with a table of issues found → fix → file, plus phone tests (fast-scroll Library, a long show like Legion of Skanks, and Up Next while an episode is being processed; swipe to top; watch for stutter and missing artwork).
