# Cloud task 12 — Apple-style "New" episodes and counts per show

Branch: `cloud/new-counts`. Read `CLAUDE.md` first. Branch from current `main`. Don't touch `Services/LocalModel/`, `ModelFinder.swift`, `VideoSync.swift`, or the job logic in `ProcessingPipeline.swift`.

His words (30 Sep): a subscribed show's episode is New until he's heard it, regardless of ad processing; show the count on each show, like Apple Podcasts.

## What to build
- Reproduce Apple Podcasts' behaviour (reference: `ApplePodcastsReference/ios27.2b2/DISTILLED/` — read only the parts about Library, show badges and "New"; never copy Apple code or assets):
  - An episode is **New** when it arrived in a followed show and he hasn't played it (not started, not marked played). Starting playback or marking played clears it; "Mark as Unplayed" doesn't make it New again unless Apple does.
  - Ad processing state has no effect on New.
  - Episodes that were in the back catalogue when he followed a show are not New (only ones published after following, or the latest one at follow time — match Apple).
- A count badge on each show in Library (grid and list) and a "New" marker on episode rows; the show page shows "N New". Library can filter/sort by shows with new episodes if Apple does.
- Counts come from `CountsCache` (extend it) — never a whole-library fetch on the main thread; invalidate where playback state changes.
- A migration for existing episodes that's cheap and runs once (don't mark his whole existing library New).

## Done means
PR from `cloud/new-counts`, CI green, zero warnings, a unit test for the New rules, simulator screenshots of Library with badges and a show page. Phone test in the description: refresh feeds → a new episode shows a badge → play 5 seconds → badge count drops by one.
