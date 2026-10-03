# Destination parity: first critical batch

Recorded 2026-10-02. Implemented at `2073fde`; 13 destination and seven decoded-video tests passed in the combined 163-unit run (`build/unit-20261002-115317.xcresult`). The rendered-video tour passed with nine inspected images. Remaining destination screenshots are acceptance work. The earlier chapter batch is committed at `6b2d987` and passed 106 unit tests plus its eight-screen UI walkthrough.

## Implemented behavior

- Preview routes from RSS show rows carry the resolved feed URL, GUID, enclosure and publication date. Library/feed matching uses unique GUID or exact enclosure. Ambiguous title-only matches are rejected; a publication date can disambiguate a directory entry. Unknown explicit identities never silently select a different same-title episode. A directory show ID must resolve before it can substitute a local same-title show.
- Feed aliases normalize HTTP/HTTPS and default ports while preserving path case, query and credentials. Media enclosure identity retains exact scheme/path/query. If duplicate alias records exist, the exact feed URL is preferred; ambiguous remaining matches fail safely.
- Show preview rows use enclosure identity instead of array indices. Duplicate enclosure rows are represented once. Preview playback retains the resolved ParsedItem's media type, video, people and chapter metadata rather than rebuilding only its headline fields.
- Station Queue All preserves the existing queue and appends unseen visible episodes. Play All puts the visible station order ahead of unrelated queued episodes, starts the visible first episode through PlayCoordinator, and honors normal prompting/download rules. Both produce unique compact queue positions. Save failures restore changed fields and produce an alert.
- Transcript search selection passes startingAt to PlayCoordinator. It does not mutate the saved playback position before a cancellable countdown.
- One CatalogLoader distinguishes loading, loaded-empty and failure, preserves a successful snapshot on refresh failure, and prevents replaced/cancelled requests from publishing stale results. Category and person pages show explicit empty/error states with Retry. Search retains library/transcript matches if online catalog requests fail and offers Retry. A failed search is no longer described as a completed search with no matches.
- Person library matches compare parsed people names after the indexed predicate, excluding archived episodes. A substring-only match no longer attributes another person's episode to the selected person.
- Both show and episode previews surface the initial Follow save failure and skip the success haptic. Episode preview reports a feed item that cannot be identified uniquely and offers Retry/open-show recovery.

## Disposable tests

NEW Tests/DestinationParityTests.swift has 13 tests: parsed-RSS repeated-title identity, resolved-feed propagation, exact enclosures, missing identities, date disambiguation, duplicate GUID/enclosure ambiguity, local show/episode matching, feed alias versus enclosure exactness, station queue persistence/dedup/collision compaction, visible-first station order, loaded-empty/no-results, network failure preserving snapshots/retry, request replacement, and cancellation. Derived queue notifications are disabled only for disposable test contexts so they do not start preparation through app singletons.

NEW Tests/DemoVideoTests.swift has seven tests. Generation is awaited, propagates stage errors, checks writer setup/each append/completion, bounds encoding waits, validates duration/decoded content, replaces corrupt or black fixtures, cleans interrupted writes and cancellation, reuses valid files, and rejects a same-path concurrent request for a different duration. Tests verify decoded changing, nonblack clock frames; navigation or AVPlayerItem readiness alone is insufficient evidence of rendered video.

## Focused UI checks for the parent

- Search a demo transcript term, tap its result, dismiss the unprocessed countdown, and confirm the saved position is unchanged. Accept a start and assert PlayerEpisodeTitle and numeric PlayerElapsedTime identify the requested episode/moment.
- Existing queue + overlapping station: Queue All repeatedly; confirm no duplicate entries/queue-order collisions. Play All with first episode unavailable and a later downloaded episode; confirm the first episode receives the prompt and later becomes the actual current title. Dismissing the prompt must not switch playback.
- Empty public category: category.empty appears and category.loading is absent after completion. On failure category.error/category.retry appear; retry retains a prior successful chart when offline.
- Empty person catalog with library matches: episodes remain; person.error/person.retry report an online failure. Genuine empty completion uses person.empty. There must be no permanent "Looking for" state.
- Search online failure keeps local results, catalog.search.error and catalog.search.retry. Genuine zero matches uses catalog.search.empty.
- Repeated-title feed fixture: choose the second item, inspect its GUID/enclosure identity, and play that item. A title-only chart entry with multiple candidates must offer show recovery, never play the first arbitrarily.
- Video: wait for the actual AVPlayerLayer frame-ready accessibility value before inline/fullscreen screenshots. Inspect the clock image and compare it with audio elapsed time. PlayerVideo container presence alone does not prove rendered frames.

## Remaining acceptance gaps

- EpisodeCatalogue.fill and LibraryIndex.merge do not return persistence failure evidence. The initial Follow save is handled here, but later episode indexing errors still need a throwing/result-bearing merge API and caller coverage. DiscoverService.lookup also suppresses per-chunk network/decode failures; view loading states cannot recover an error that the service has already converted to an empty list.
- Station manual order/grouping, store-aware membership refresh and consistent editor terminology are covered by the next batch; see `2026-10-02-data-stations-checkpoints.md` for its verification boundary.
- Full category/public editorial/From Your Shows organization, shelf See All pagination, public search pagination, person episode discovery outside the library, and persistent feed-preview caching remain incomplete. StorePage cache/unknown-shelf rendering already exists and should be reused.
- Unfollowed episode previews still need shared people/chapters/transcript/information/related sections when their metadata is available. No private Apple editorial/media data is fabricated.
- Accessibility text/landscape destination screenshots and real-phone queue, streaming, background, routes and video/PiP remain separate acceptance evidence.

## References and their limits

The visual target remains ApplePodcastsReference/ios27.2b2/DISTILLED. Its en-strings.tsv has From Your Shows, Group by Show, station Manual/Manual Library Order and explicit empty station states. ShelfKit identifiers include CategoryPageFromYourShowsShelfIntent, GroupedSearchResultsPage and SearchResultsPaginator. Identifiers and strings demonstrate named capabilities, not exact visual geometry.

Current public behavior references: [Apple podcast library organization](https://support.apple.com/guide/iphone/organize-your-podcast-library-iph4003ecb12/ios) and [Apple podcast search and playback](https://support.apple.com/guide/iphone/get-started-with-podcasts-on-iphone-iphaca38804e/27/ios/27). These support ordered playback, station settings and searching by show/episode/person/category; the local 27.2 beta 2 reference remains the requested visual source. [AVPlayerLayer.isReadyForDisplay](https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay) describes first-frame availability, unlike item/container existence.
