# Public discovery request failures — 2 October 2026

This source batch follows pushed `a25f301`; the successful older `04224e9` CI and the local `ead23f1` IPA do not validate or contain it.

`DiscoverService` uses one checked transport for show charts, ranked show lookup, episode charts and episode search. Non-HTTP and unsuccessful HTTP responses are rejected before parsing; transport and malformed-response errors propagate. Cancellation is checked before and after each network await, so a late response cannot start the next lookup chunk or return a cancelled result. An HTTP failure with a valid empty-shaped body cannot become "no shows."

Lookup deduplicates requested IDs before batching, preserves their first ranking, and emits each returned ID once. The old unique-key rank dictionary could crash for duplicate requested IDs. Any failed chunk fails the whole new snapshot; the existing `CatalogLoader` retains its previous successful data and exposes retry. Genuine successful empty results remain empty, and a blank episode search makes no request.

All **224 combined unit tests pass**, zero failures, in `build/unit-20261002-175213.xcresult`; matching console preserved. Twelve new request/loader cases cover batching/order/duplicates, genuine empty, first/later transport failure, HTTP 401/429/503, malformed JSON, invalid IDs/non-HTTP, cancellation after response, retained snapshot/retry, and shared chart/search transport. The earlier lookup-only 221-test run is also preserved at `build/unit-20261002-174943.xcresult`; the shared transport is validated by the later run. Network payloads are injected; no live catalog requests or downloads are needed for these regressions.

CategoryView already presents CatalogLoader failure/empty/retry states; this source change makes failures reach those states. This is not a new screenshot/navigation tour or full editorial parity claim. Top-level cached chart fallbacks, real offline requests, all shelf/people/preview destinations, pagination, accessibility and glass contrast remain acceptance work.

Separate persistence finding remains: EpisodeCatalogue/LibraryIndex save failures can still be swallowed and completion markers/counts reported prematurely. That needs a complete background-context transaction and caller error-propagation batch across follow/import/cloud/refresh. Preserve partial durable batches and user data; avoid replacing these errors with another silent fallback.

## Preview caller follow-up

The service checkpoint is `121143365ae015467741115f455450609f4e0d25`. Its unsigned device Release and verified IPA are preserved in `build/delivery-1211433` (69212752 bytes; SHA-256 `ba4caf39b7c54bd09ba5bce0808435fbfb052fdc056648e28814adbe3f69aeba`). It has no preview caller changes.

The following source batch removes `try?` from both show and episode preview feed resolution. One shared resolver propagates directory errors to the existing error/retry view, returns unavailable only for a genuinely absent entry, requires the requested show ID rather than choosing an arbitrary first result, preserves explicit private feed addresses, and rejects late cancelled results. All **230 combined units pass**, zero failures, at `build/unit-20261002-180321.xcresult`, console preserved alongside. Six resolver cases cover known feed/no request, absent identity/entry, blank feed resolution, exact/mismatched directory identity, transport failure and cancellation. These source tests do not replace the still-required complete preview/people/offline screenshot tour.
