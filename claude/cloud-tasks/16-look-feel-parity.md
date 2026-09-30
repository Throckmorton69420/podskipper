# Cloud task 16 — Look and feel: consistency and Apple Podcasts parity

Branch: `cloud/look-feel`. Read `CLAUDE.md` first. Branch from the **latest** `main` (after task 08 is merged). Don't touch `Services/LocalModel/`, `ModelFinder.swift`, the job logic in `ProcessingPipeline.swift`, or `VideoSync.swift`.

His standing complaints: polish has been the weak point; two design languages side by side; the same information drawn different ways on different screens; sloppy details (e.g. glass buttons whose label sits off-centre because an invisible icon takes space — fixed on the ad-model screen in 2d26bb6; look for the same pattern elsewhere).

## 1. Audit first (write it into the PR description)
Walk every screen in code: Library (grid/list, show page), episode page, Up Next, player (mini + full, transcript, chapters, sound), Search/Discover, Activity, Settings and its sub-screens, Storage, Diagnostics, onboarding. For each, list what differs from Apple Podcasts (reference: `ApplePodcastsReference/ios27.2b2/DISTILLED/` — read only the parts you need; never copy Apple code or assets) and what is inconsistent inside PodSkipper (fonts, spacing, corner radii, artwork sizes, button styles, row layouts, empty states, section headers, toolbars).

## 2. Fix, in this order
1. **Consistency:** one component per kind of information (episode row, show row, section header, glass buttons, empty state). Use `Views/Theme.swift` Metrics (artwork sizes, radii, gutters, readableMax, bottomInset), `AdaptiveRow`, `CoverStrip`, `AdaptiveGrid`, `BottomClearance`, `contentCard`, `Feel.swift` haptics. Replace one-off literals.
2. **Buttons:** every glass/glassProminent button sized to its label, label centred; icon + text only where the icon actually shows (check the tint on `.glassProminent`).
3. **Apple Podcasts parity that affects normal use:** swipe actions and context menus on rows, pull to refresh, the show page header, episode page layout, "Up Next" behaviour, played/unplayed indicators, Dynamic Type (the catalog's open "Dynamic type effect" item: text must scale without clipping; check at the largest accessibility sizes).
4. **Motion:** Liquid Glass via the system APIs, symbol effects on state changes, Reduce Motion respected. No `.blur`/`.saturation`/`.drawingGroup` in anything that redraws every frame.

## Rules
- SwiftUI rules in `CLAUDE.md` (small views for fast-changing values; one `.sheet` per view with an enum; no whole-library work on the main thread).
- Accessibility identifiers stay as they are (UI tests use them).
- Rebase on `main` before opening the PR; open it **ready for review, not draft**; one CI check-in at most.

## Done means
PR from `cloud/look-feel`, CI green, zero warnings from PodSkipper's code. Description: the audit table (screen → what changed), and the phone test: tap through Library, a show, an episode, the player, Up Next, Settings and Storage at normal and the largest text size; note anything that still looks off.
