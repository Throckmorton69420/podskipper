# Apple Podcasts, iOS 27.2 RC — distilled reference

**This is the reference from Pass 46** (it supersedes `../ios27.2b2/`). Podcasts 3.9, build 4027.210.1, minimum iOS 27.2.
Shashank supplied it as `Podcasts.app.zip`, `Podcasts.zip` and `Podcasts.ipa` (`~/Desktop/Podcasts app iOS 27.2 RC Reference/`, not in the repo):
the same app in each — the main binary's SHA-256 is `4f4bc25b21572bf036b384373b09a98437edf5316dbd228b9d523ea9a14d23cc` in all four copies.

| File | What it is |
|---|---|
| `en-strings.tsv` | Every English string in the app's `Localizable.loctable` files (key, text). |
| `Info.plist.json` | The app's Info.plist. |

Type names are as in `../ios27.2b2/DISTILLED/identifiers/` — the binaries' UI types are the same.

## What changed since 27.2 beta 2

- Strings: **Mark Season as Played / Mark Season as Unplayed** with "This will mark every episode of this season as played/unplayed.";
  the queue's **Coming Up** section (`QUEUE_SECTION_TITLE_COMING_UP`), and "Remove from Continue Playing" → **"Remove from Coming Up"**;
  the "Your favorite shows. Now with video." splash line.
- ShelfKitCollectionViews: `ClearAsCancelButtonVisibilityWhenEmpty` replaces `AutomaticallyShowsCancelButton` (search field); `ChartEpisodeEyebrowView` gone.

## Runtime behaviour

The package is device-only and the simulator has no Podcasts app. Runtime layout comes from Apple's own
**iOS 27 iPhone User Guide** (support.apple.com: "Play podcasts on iPhone", "Get started with Podcasts on iPhone") and its
Now Playing screenshot: grabber; artwork or video; date, title, show with ⋯; timeline; speed · Skip Back 15 · Pause ·
Skip Forward 30 · Sleep Timer; volume bar; View Transcript · AirPlay · Playing Next. Tabs: Home, New, Library, Search.

Reproduce Apple's behaviour in PodSkipper's own code. Never copy Apple's code or assets.
