# Apple Podcasts, iOS 27.2 beta 2 — distilled reference

**This is the reference.** Shashank's phone app is compared against iOS 27.2 beta 2, not the 27.0 RC in
`../ios27.0/`. The full app (Podcasts.app, .ipa, .zip) is on his Mac at
`~/Desktop/ApplePodcastsReferences/iOS27.2-Beta2/`; it is not in the repo.

| File | What it is |
|---|---|
| `en-strings.tsv` | Every English string in `Localizable.loctable` (key, text). Grep this first for labels, menus, empty states. |
| `Info.plist.json` | The app's Info.plist. |
| `identifiers/<binary>.txt` | Type, action and intent names found in each binary (`strings`, CamelCase only). They name what the app does: e.g. `OpenEpisodeContextAction`, `EpisodePageFooterShelvesIntent`, `LibraryEpisodePagePresenter`. |

Where things live in Apple's app:
- **ShelfKit / ShelfKitCollectionViews**: every page built from shelves (New, Search, show, episode, category pages) and the lockups on them.
- **Podcasts** (main binary): library, show detail (`MTPodcastDetail…`), up next, settings, context actions.
- **NowPlayingUI**: the player.
- **PodcastsTranscripts**: transcript view and search.
- **PodcastsWidgetKit / PodcastsWidget**: widgets and Live Activities.
- **PodcastsActions / PodcastsAppIntents / PodcastsAppEntities**: Shortcuts and Siri.

Reproduce Apple's behaviour in PodSkipper's own code. Never copy Apple's code or assets.
