# Apple Podcasts, iOS 27.3 beta 1 — distilled reference

**This is the reference from Pass 58** (it supersedes `../ios27.2rc/`). Podcasts 3.9, build 4027.300.19, minimum iOS 27.3
(iOS 27.3 beta 1, 24C5037i). Shashank supplied it on 5 Nov 2026 as `~/Desktop/Podcasts-iOS-27.3-24C5037i-Reference/`
(`Podcasts(iOS-27.3-24C5037i).ipa` and the `.app`; not in the repo). Main binary SHA-256
`e2390ffb92fe59cb4b6a6a627dd8e471551274fccd5d3625431d30dad21b0e7b`.

| File | What it is |
|---|---|
| `en-strings.tsv` | Every English string in the app's `Localizable.loctable` files (key, text; plural rules as JSON). |
| `Info.plist.json` | The app's Info.plist. |

Extracted with `build/p58/parity/distill.py` (git-ignored lab copy; read-only `plistlib` + `strings`). Type names are as in
`../ios27.2b2/DISTILLED/identifiers/` except the differences below.

## What changed since 27.2 RC

Strings (27.2 RC → 27.3 b1):
- Home's split shelves: **Remove from Continue Playing** (`REMOVE_FROM_CONTINUE_PLAYING_SHELF`) and **Remove from New
  Episodes** (`REMOVE_FROM_NEW_EPISODES`). Apple's support note for 27.2: "The Home tab … offers two separate sections for
  New Episodes and Continue Playing" (Up Next became New Episodes).
- Stations: **Choose Shows…** as a button and as its page's title (`STATION_SETTINGS_CHOOSE_SHOWS_BUTTON` / `_NAV_TITLE`;
  "Add Shows" is gone).
- Settings: **Automatic Downloads → Automatic Download Options**, **Downloads → Download Options**, **Video Streaming →
  Video Streaming Options**, **Allow Over Cellular → Use Cellular Data** (automatic downloads and video streaming).
- "Something Went Wrong" / "Please try again later." became keyed strings (same words); "%@ left" removed.

Types (27.2 b2 → 27.3 b1, CamelCase identifiers):
- Main binary: `RemoveFromUpNextSplitShelfContextAction`, `UpNextSplitShelfRemovalType`, `UnfollowEpisodeContextAction`,
  token-protected asset downloads (`TokenProtectedAssetsDownloader`, `AssetTokenDownloadPreflight`).
- ShelfKit: `RemovedFromUpNextSplitShelvesResetObserver` (`removedFromUpNextSplitShelvesDate`), hero cards
  (`HeroCardKind`, `HeroCardBackground`, `HeroCardColor…`, `HeroCardArtworkLayout`), `SaveEpisodeAction`.
- ShelfKitCollectionViews: `LibraryMenuLinkCell` with `prefersLibraryMenuGrid` / `libraryMenuGrid` / `libraryMenuList`
  beside size-class properties (the Library menu as a grid in regular width), `EpisodeHeroTextZone`, `HeroButtonStyle`,
  `ShowTitleAccessibility`, `DoubleColumnRefreshControl`.
- PodcastsTranscripts: alignment-driven highlighting (`TranscriptAlignment`, `AlignmentPath`, `ActiveInterval`).
- PodcastsWidgetKit: `EpisodeListWidgetLarge`.
- NowPlayingUI: the video toggle's state machine reworked (`VisibilityProvider`).

## Runtime behaviour

Device-only package; the simulator has no Podcasts app. Runtime layout is from Apple's iOS 27 user guide and support notes.
Reproduce Apple's behaviour in PodSkipper's own code. Never copy Apple's code or assets.
