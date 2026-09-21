# Apple Podcasts (iOS 27) — Bundle Findings

Evidence only. No interpretation, no design advice.

**Source:** `/mnt/user-data/uploads/Podcasts_3.9_1789369323.ipa` → `/tmp/podcasts-ipa/Payload/Podcasts.app`.
**Tools:** `unzip`, `python3` (`plistlib`/`json`), `strings`, `grep`. No macOS tooling.
**Provenance:** `CFBundleShortVersionString 3.9`, `CFBundleVersion 4027.110.2`,
`DTSDKName iphoneos27.0.internal`, `DTXcodeBuild 27A200c`, `BuildMachineOSBuild 23A344017`.

---

## 1. Info.plist

| Key | Value |
|---|---|
| `CFBundleIdentifier` | `com.apple.podcasts` |
| `CFBundleName` / `CFBundleDisplayName` | `Podcasts` / `Podcasts` |
| `MinimumOSVersion` / `DTPlatformVersion` | `27.0` / `27.0` |
| `UIDeviceFamily` | `[1, 2]` (iPhone + iPad) |
| `UIRequiredDeviceCapabilities` | `["armv7"]` |
| `CFBundleDevelopmentRegion` / `CFBundleAllowMixedLocalizations` | `en` / `true` |
| `LSApplicationCategoryType` | `""` (empty) |
| `NSAccentColorName` | `AccentColor` |
| `UILaunchScreen` | `{"UIColorName": "systemBackground"}` |
| `UIStatusBarStyle` | `UIStatusBarStyleDefault` |
| `UIRequiresPersistentWiFi` | `false` |

**Orientations** — all four, with **no `~ipad` variant key present**:
`UIInterfaceOrientationPortrait`, `PortraitUpsideDown`, `LandscapeLeft`, `LandscapeRight`.

**UIBackgroundModes** — `audio`, `fetch`, `notif`, `remote-notification`.
(`notif` is not a documented public value and appears alongside `remote-notification`.)

**UIApplicationSceneManifest** — `UIApplicationSupportsMultipleScenes` is **false**:

```json
{ "UIApplicationSupportsMultipleScenes": false,
  "UISceneConfigurations": {
    "UIWindowSceneSessionRoleApplication": [
      {"UISceneConfigurationName":"Default Configuration",
       "UISceneDelegateClassName":"Podcasts.SceneDelegate"}],
    "CPTemplateApplicationSceneSessionRoleApplication": [
      {"UISceneClassName":"CPTemplateApplicationScene",
       "UISceneConfigurationName":"Podcasts-Car",
       "UISceneDelegateClassName":"CarPlaySceneDelegate"}] } }
```

**CFBundleURLTypes** — two entries, both `CFBundleTypeRole: "Editor"`:

```
"Podcast Feed":      podcast, pcast, itms-pcast, itms-pcasts, itms-podcast, itms-podcasts
"Podcast Spotlight": podcasts
```

**Audio / NowPlaying keys**

| Key | Value |
|---|---|
| `MPSupportsExternallyPlayableContent` | `true` |
| `SupportsSharedQueue` | `true` |
| `UIBrowsableContentSupportsSectionedBrowsing` | `true` |
| `INIntentsSupported` | `["INPlayMediaIntent"]` |
| `INAlternativeAppNames` | `[{"INAlternativeAppName": "Podcast"}]` |
| `BGTaskSchedulerPermittedIdentifiers` | `["com.apple.podcasts.feed-update"]` |
| `CoreSpotlightContinuation` | `true` |

`NSUserActivityTypes` — playback continuation decomposed per entry point:

```
com.apple.podcasts.playback.podcast      .episodeList   .playlist   .unplayed
com.apple.podcasts.playback.episode      .store         .listenNow  .NetworkMedia
com.apple.corespotlightitem              com.apple.corespotlightquerycontinuation
```

`UTExportedTypeDeclarations` — three types, each conforming to `public.data` + `public.content`:
`com.apple.podcasts.episode` ("Episode"), `.show` ("Show"), `.station` ("Station").

`UIApplicationShortcutItems` — exactly two:

```
kMTShortcutItemTypeSearchStore       icon "magnifyingglass"  title key QUICK_ACTION_SEARCH
kMTShortcutItemTypeCheckNewEpisodes  icon "arrow.clockwise"  title key QUICK_ACTION_REFRESH
```

Also present: `SBMatchingApplicationGenres` = `["Entertainment","Education","Lifestyle"]`;
`MDItemKeywords` = `"Podcast, Podcasts"`; `LSCounterpartIdentifiers` = `["com.apple.podcasts"]`.

### PlugIns/ — all six declare `MinimumOSVersion 27.0`

| Bundle | `CFBundleIdentifier` | `NSExtensionPointIdentifier` |
|---|---|---|
| `PodcastsAnnouncementsNotificationExtension.appex` | `com.apple.podcasts.PodcastsAnnouncementsNotificationExtension` | `com.apple.usernotifications.content-extension` |
| `PodcastsClassKitExtension.appex` | `com.apple.podcasts.PodcastsClassKitExtension` | `com.apple.classkit.context-provider` |
| `PodcastsNotificationExtension.appex` | `com.apple.podcasts.PodcastsNotificationExtension` | `com.apple.usernotifications.content-extension` |
| `PodcastsWidget.appex` | `com.apple.podcasts.widget` | `com.apple.widgetkit-extension` |
| `com.apple.podcasts.DiagnosticExtension.appex` | `com.apple.podcasts.DiagnosticExtension` | `com.apple.diagnosticextensions-service` |
| `com.apple.podcasts.SpotlightIndexExtension.appex` | `com.apple.podcasts.SpotlightIndexExtension` | `com.apple.spotlight.index` |

Principal classes / notable attributes:
- Announcements: `MTAnnouncementNotificationViewController`; category `com.apple.podcasts.announcement`,
  `UNNotificationExtensionInitialContentSizeRatio` **0.1**, default content hidden, interaction enabled.
- Notification: `NotificationViewController`; category `com.apple.podcasts.newEpisodesAvailable`,
  ratio **0.6**, default content hidden, interaction enabled.
- ClassKit: `PodcastsClassKitExtension.ContextRequestHandler`.
- Diagnostic: `com_apple_podcasts_DiagnosticExtension.PodcastsDiagnosticExtension`;
  `DEAttachmentsName "Podcasts Logs"`.
- Spotlight: `IndexRequestHandler`; `CoreSpotlightDontRunDuringMigration true`.
- Widget: no principal class, empty `NSExtensionAttributes`.

---

## 3. Localizable.loctable (`en` — 2157 strings, 58 locales)

### 3a. Compound metadata formats — exact separator codepoints

**The show-row metadata separator is a middle dot flanked by U+2004 THREE-PER-EM SPACE, not U+0020.**
Verified codepoint-by-codepoint:

```
NEW_EPISODES_AND_LAST_UPDATED_DATE_FORMAT   one/other: '%%@ · %d new'
     U+0025 U+0025 U+0040 | U+2004 U+00B7 U+2004 | U+0025 U+0064 ' new'
MORE_EPISODES_AND_LAST_UPDATED_DATE_FORMAT  one/other: '%%@ · %d more'
NEW_TRAILERS_AND_LAST_UPDATED_DATE_FORMAT   one: '%%@ · %d trailer'
                                            other: '%%@ · %d trailers'
```

A different string uses a plain-spaced interpunct, and three distinct dashes are each used in their
own context:

```
NMT_TRACKLIST_SUBTITLE                     '%1$@ · %2$@'    U+0020 U+00B7 U+0020
NOWPLAYING_PODCAST_ARTIST_FORMAT           '%@ — %@'        em dash    U+2014
REMOVE_DOWNLOADS_TIP_MESSAGE_FORMAT        'Save %@ — %@'   em dash    U+2014
UPDATED_DATE_AND_NEW_EPISODE_COUNT_FORMAT  '%@ – %@'        en dash    U+2013
UPDATED_DATE_AT_TIME_AND_NEW_EPISODE_COUNT_FORMAT  '%@ at %@ – %@'
DATE_DURATION                              '%@ - %@'        hyphen-minus U+002D
```

Other multi-specifier layout formats:

```
'%@, %@' -> '%1$@, %2$@'        '%@ %@' -> '%1$@ %2$@'        '%@%@%@' -> '%1$@%2$@%3$@'
'%@ %@ (%@)' -> '%1$@ %2$@ (%3$@)'                            '%@ of %@' -> '%1$@ of %2$@'
'‎%@\xa0%@' -> '‎%1$@\xa0%2$@'   (LTR mark + NBSP; U+200F RTL variant also present)
DATE_AT_TIME -> '%@ at %@'                 DURATION_PLAYED_FORMAT -> '%@ (%@)'
EPISODE_DURATION_SIZE_FORMAT -> '%1$@ (%2$@)'     EPISODE_SIZE_FORMAT -> '%@ (%@)'
EPISODE_SIZE_ALT_FORMAT -> '%1$@, %2$@'           Downloading_Progress -> '%@, %@'
Downloading_Size_X_Of_Y -> '%@ %@ of %@ %@'
EPISODE_DOWNLOADING_SIZE_X_Of_Y_SIZE_REMAINING -> '%@ %@ of %@ %@, %@ remaining'
FROM_SHOW_EP -> 'From %@: %@'              FROM_SHOW_EP_DATE -> 'From %@: %@, %@'
EPISODE_OR_PODCAST_SHARE_NOTES -> '%@ by %@'      STATIONS_COUNT_EPISODES_FORMAT -> '%@ Episodes, %@'
LAST_REFRESH_FORMAT -> 'Last Refresh: %@ at %@'   DOWNLOAD_PROGRESS_PERCENTAGE_FORMAT_%@ -> '%1$@ Downloaded'
EPISODE_AND_SEASON_NUMBER_FORMAT_SHORT -> 'Season %1$d, Ep %2$d'
EPISODE_AND_SEASON_NUMBER_TRAILER -> 'Season %1$d, Episode %2$d Trailer'
EPISODE_AND_SEASON_NUMBER_BONUS   -> 'Season %1$d, Episode %2$d Bonus'
EPISODE_AND_SEASON_NUMBER_COMMA_COMBINATOR_SHORT -> '%@, %@'
EPISODE_AND_SEASON_NUMBER_WHITE_SPACE_COMBINATOR -> '%@ %@'
```

**Inline SF Symbol tokens.** Exactly 2 keys (3 occurrences) embed a `{{symbol:...}}` placeholder;
the only symbol used is `line.3.horizontal.decrease`:

```
EPISODE_FILTER_COUNT_COMPOUND_FORMAT  one:   '%d Episode ({{symbol:line.3.horizontal.decrease}} Filtered by: %@)'
                                      other: '%d Episodes ({{symbol:line.3.horizontal.decrease}} Filtered by: %@)'
```

### 3b. Date, duration, relative-date

```
DURATION_FORMAT_HOURS -> '%@:%@:%@'       DURATION_FORMAT_MINUTES -> '%@:%@'
LESS_THAN_1_MINUTE -> '< 1m'              LESS_THAN_1_MINUTE_ACCESSIBILITY_LABEL -> 'Less than one minute'
PLAYBACK_SPEED_CHANGE_NOTICE -> '%.2fx'
```

Relative dates are terse, no-space, single-letter units:

```
TIME_AGO_JUST_NOW -> 'Just now'           TIME_AGO_EDITED_JUST_NOW -> 'edited just now'
TIME_AGO_MINUTES_AGO -> one/other '%dm ago'
TIME_AGO_HOUR_AGO -> '%dh ago'            TIME_AGO_HOURS_AGO -> one/other '%dh ago'
TIME_AGO_DAYS_AGO -> one/other '%dd ago'
'Yesterday' -> 'Yesterday'                'Today' / TODAY_TITLE / NEW_EPISODES_TODAY -> 'Today'
EPISODE_PLAYED_TODAY -> 'Played Today'
```

"Updated" family — note the device-specific split in wording *and* capitalisation:

```
SHOW_UPDATED_AT_FORMAT -> 'Updated %@'    'Updated %@ at %@' -> 'Updated %@ at %@'
'Updated just now' -> 'Updated just now'  RECENTLY_UPDATED -> 'Recently Updated'
DETAIL_HEADER_UPDATED_PHONE -> 'Last updated %@'
DETAIL_HEADER_UPDATED_PAD   -> 'Last Updated on %@'
'Last Updated'              -> 'Last Updated on %@'
```

### 3c. Up Next / queue / insertion

```
UP_NEXT / UP_NEXT_CELL_STRING / WIDGET_UP_NEXT_HEADER / PODCASTS_ADD_WIDGET_SUBTITLE -> 'Up Next'
QUEUE_TITLE -> 'Playing Next'             QUEUE_SECTION_TITLE_NOW_PLAYING -> 'Now Playing'
'Play Next' -> 'Play Next'                'Play Last' -> 'Play Last'
'Add to Queue' / ADDED_TO_QUEUE -> 'Add to Queue' / 'Added to Queue'
HUD_ADD_TO_UP_NEXT -> 'Added'             HUD_PLAY_NEXT -> 'Playing Next'
REMOVE_FROM_QUEUE -> 'Remove from Queue'  REMOVE_FROM_UP_NEXT -> 'Remove from Up Next'
QUEUE_BACK_TO -> 'Resume: %@'             QUEUE_FROM -> 'Queue: From %@'
QUEUE_EPISODE -> one 'Queue: %lld episode' / other 'Queue: %lld episodes'
'Queue Insertion Location' -> (identity)  'Clear Queue' -> 'Clear Queue'
QUEUE_CLEAR_CONFIRM -> 'Clear Episodes'   QUEUE_KEEP_CONFIRM -> 'Keep Listening'
CLEAR_QUEUE_PROMPT_TITLE -> 'Keep Listening?'
CLEAR_QUEUE_PROMPT_MESSAGE -> other '... to the %lu episodes you’ve selected to play next?'
CLEAR_HARD_QUEUE_PROMPT -> one 'Clearing will remove %d episode from your queue.'
PODCASTS_EMPTY_UPCOMING / 'Your Queue is Empty' -> 'Your Queue is Empty'
QUEUE_TIP_TITLE -> 'See Your Queue'
CONTINUOUS_PLAYBACK_FOOTER -> 'The next episode in Up Next will automatically start playing after
                               an episode ends.'
UP_NEXT_FOOTER_STRING -> 'Your iPhone will try to add one episode from each of the top 10 shows
                          in Up Next.'
STATIONS_UP_NEXT -> '%@'   STATIONS_UP_NEXT_AND_MORE -> 'and %d more'   ...AND_ONE_MORE -> 'and 1 more'
SMART_PLAY_BUTTON_PLAY_NEXT_EPISODE -> 'Play Next Episode'    AX_QUEUE_BUTTON_LABEL -> 'Queue'
```

Two queue tiers are named in the binaries: `NowPlayingHardQueue` / `NowPlayingSoftQueue`, with
`HardQueueHeaderView` / `SoftQueueHeaderView` (§2).

### 3d. Tabs, library lists, sort/filter

Tab and page titles:

```
TAB_HOME / TITLE_HOME -> 'Home'       TAB_LIBRARY / TITLE_LIBRARY -> 'Library'
TITLE_CATALOG -> 'New'                TITLE_SEARCH -> 'Search'
TITLE_SHOWS -> 'Shows'                TITLE_CHANNELS -> 'Channels'
TITLE_SAVED -> 'Saved'                TITLE_DOWNLOADED -> 'Downloaded'
TITLE_LATEST_EPISODES -> 'Latest Episodes'    TITLE_TOP_CHARTS -> 'Top Charts'
TITLE_CATEGORIES -> 'Categories'      TITLE_LISTEN -> 'Listen Now'
TITLE_PROVIDERS -> 'Providers'        TITLE_SUGGESTIONS -> 'Suggestions'
```

Library lists and empty states:

```
LIBRARY_SHOWS -> 'Shows'              LIBRARY_SAVED_EPISODES -> 'Saved'
LIBRARY_LATEST_EPISODES / LATEST_EPISODES -> 'Latest Episodes'
DOWNLOADED / DOWNLOADED_EPISODES -> 'Downloaded'     CARPLAY_TAB_STATIONS -> 'Stations'
LIBRARY_HEADER_MAC -> 'Library:'      LIBRARY_EMPTY_TITLE -> 'Start Your Library'
LIBRARY_IS_EMPTY_CONTENT_UNAVAILABLE_TITLE -> 'Library is Empty'
LIBRARY_EMPTY_SUBTITLE -> 'Followed shows, saved episodes, and channel subscriptions will show up here.'
LIBRARY_EMTPTY_ADD_PODCAST_BUTTON -> 'Follow a Show by URL'   [sic: EMTPTY]
LIBRARY_EMTPTY_SEARCH_BUTTON      -> 'Search For a Podcast'   [sic]
LATEST_EPISODES_EMPTY_TITLE -> 'No Latest Episodes'
DOWNLOADED_EPISODES_EMPTY_TITLE -> 'No Downloaded Episodes'
EMPTY_LIBRARY_CHANNELS_TITLE -> 'No Channels'   EMPTY_LIBRARY_CATEGORIES_TITLE -> 'No Categories'
'Empty Grid' -> 'Follow a podcast or download episodes to add them to My Podcasts.'
'10 / 5 / 3 / 2 Latest Episodes' (identity values)
```

**Grid-vs-list display-mode strings: not determinable from the bundle.** No `VIEW_AS`, "Show as Grid"
or "Show as List" key exists in `en`. The only `Grid` keys are `'Empty Grid'` (an empty-state message)
and `PODCASTS_WIDGET_OPTION_LIBRARY_LIST_ITEM -> 'A list in your library'`. Grid/list distinctions
appear only as *type names* in the binaries (§2).

Sort / filter vocabulary:

```
SORT_BUTTON / EPISODES_SORT_BUTTON -> 'Sort'    SORT_BY / EPISODES_SORT_BY -> 'Sort By'
EPISODES_FILTER_BUTTON -> 'Filter'              ACTION_FILTERS / SEARCH_FILTERS -> 'Filters'
SORT_BY_TITLE -> 'Title'          SORT_BY_DATE_ADDED -> 'Date Added'
SORT_BY_DATE_FOLLOWED -> 'Date Followed'        SORT_BY_DATE_UPDATED -> 'Date Updated'
SORT_BY_SAVED -> 'Date Saved'                   SORT_BY_UPDATED -> 'Recently Updated'
SORT_MANUAL / EPISODES_SORT_BY_MANUAL -> 'Manual'
SORT_MENU_OPTION_BY_DATE_DOWNLOADED -> 'Date Downloaded'
SORT_MENU_OPTION_BY_DATE_PUBLISHED  -> 'Date Published'
SORT_MENU_OPTION_BY_SHOW -> 'Group By Show'     SORT_MENU_OPTION_SHOWS -> 'Shows'
SORT_NEWEST_TO_OLDEST -> 'Sort Newest to Oldest'
SORT_OLDEST_TO_NEWEST_TOGGLE -> 'Sort Oldest to Newest'
SORT_SUBTITLE_NEWEST_TO_OLDEST -> 'Newest to Oldest'   ...OLDEST_TO_NEWEST -> 'Oldest to Newest'
STATION_SORT_BY_LIBRARY -> 'Manual Library Order'      STATION_SORT_BY_SHOW_TITLE -> 'Show Title'
STATION_SORT_BY_NEWEST_TO_OLDEST -> 'Newest To Oldest' [note title-case "To", unlike SORT_SUBTITLE_*]
EPISODE_FILTER_TITLE_DOWNLOADED -> 'Downloaded'        EPISODE_FILTER_TITLE_BOOKMARKED -> 'Saved'
EPISODE_FILTER_SEE_ALL_DOWNLOADED_FORMAT -> 'See All Downloaded (%d)'
EPISODE_FILTER_SEE_ALL_SEASON_FORMAT     -> 'See All Season %d (%d)'
EPISODE_FILTER_COUNT_DOWNLOADED_FORMAT   -> one '%d Downloaded Episode' / other '...Episodes'
EPISODE_FILTER_COUNT_SEASON_FORMAT       -> '%#@episode_count@ %#@season_number@'
```

### 3e. Accessibility labels for transport controls

Apple distinguishes **interval skip** from **track change** by label:

```
AX_JUMP_FORWARD -> 'Skip'         AX_JUMP_BACKWARD -> 'Rewind'
AX_SKIP_FORWARD -> 'Next'         AX_SKIP_BACKWARD -> 'Previous'
AX_PLAY -> 'Play'                 AX_PAUSE -> 'Pause'
AX_PLAY_BUTTON_PLAY / _PAUSE / _PLAYING / _REPLAY / _OPEN -> 'Play' / 'Pause' / 'Playing' / 'Replay' / 'Open'
AX_VOLUME -> 'Volume'   AX_MUTE_BUTTON -> 'Mute'   AX_MAXIMUM_VOLUME_BUTTON -> 'Full Volume'
AX_NEXT_PAGE_BUTTON -> 'Next page'   AX_PREV_PAGE_BUTTON -> 'Previous page'
AX_DOWNLOAD_BUTTON / _DOWNLOADING_ / _DOWNLOADED_ -> 'Download' / 'Downloading' / 'Downloaded'
AX_FOLLOW_BUTTON_LABEL -> 'Follow'      AX_CONTEXT_MENU_BUTTON_LABEL -> 'More'
AX_TRANSCRIPT_BUTTON_LABEL -> 'Transcript'    AX_QUEUE_BUTTON_LABEL -> 'Queue'
AX_SUGGEST_LESS_BUTTON_LABEL -> 'Suggest Less'    AX_EPISODE_CAPTION_VIDEO_ICON -> 'Video'
AX_CLOSE_BUTTON -> 'Close'       AX_ACCOUNT_SETTINGS_BUTTON -> 'Account Settings'
```

The play button's AX label carries remaining time in four duration shapes, prefixed by state:

```
AX_PLAY_BUTTON_PLAYING_REMAINING_TIME -> 'Playing, Remaining Time:'
AX_PLAY_BUTTON_PLAY_REMAINING_TIME    -> 'Play, Remaining Time:'
..._HOURS_MINUTES   -> '%1$#@hours@, %2$#@minutes@'
                       hours one 'Playing, Remaining Time: %d hour'; minutes one '%d minute'
..._MINUTES_SECONDS -> '%1$#@minutes@, %2$#@seconds@'
..._MINUTES -> one 'Playing, Remaining Time: %d Minute'
..._SECONDS -> one 'Playing, Remaining Time: %d Second'
```

Note the inconsistent casing: `_MINUTES` / `_SECONDS` capitalise the unit ("%d Minute"); the compound
`_HOURS_MINUTES` / `_MINUTES_SECONDS` variants do not.

```
ACCESSIBILITY_BOOKMARK_LABEL -> 'Save Episode'   ACCESSIBILITY_FAVORITE_LABEL -> 'Favorite'
ACCESSIBILITY_BOOKMARK_VALUE_ON / _OFF -> 'On' / 'Off'
ACCESSIBILITY_STAR_RATING_LABEL -> 'Star Rating'
ACCESSIBILITY_STAR_RATING_HINT  -> 'Use custom actions to set rating'
ACCESSIBILITY_STAR_COUNT_FORMAT -> one '%d Star' / other '%d Stars'
TRANSCRIPT_ACCESSIBILITY_ACTION_SHOW_CONTROLS / _HIDE_CONTROLS -> 'Show/Hide Playback Controls'
TRANSCRIPT_ACCESSIBILITY_ACTION_SHOW_MENU -> 'Show Transcript Menu'
TRANSCRIPT_ACCESSIBILITY_LABEL_SILENCE -> 'Silence'   ..._VALUE_ACTIVE -> 'Active'
```

Skip-interval settings vocabulary:

```
SKIP_BUTTONS / SKIP_BUTTONS_TITLE -> 'Skip Buttons'
SKIP_BUTTON_FORWARD / SKIP_FORWARD -> 'Forward'   SKIP_BUTTON_BACK / SKIP_BACKWARDS -> 'Back'
SKIP_FORWARD_INTERVAL -> 'Skip Forward Interval'  SKIP_BACKWARD_INTERVAL -> 'Skip Backward Interval'
SKIP_FORWARD_BACKWARD -> 'Skip Forward/Back'      FORWARD_BACK -> 'Forward/Back'
SKIP_BUTTON_SECONDS -> one '%d Second' / other '%d Seconds'
SKIP_BUTTONS_FOOTER -> 'Set the number of seconds to skip when you tap the skip button.'
'Speed and Audio Adjustments' / 'Sleep Timer' / 'Sleep Timer %@' / 'Sleep Timer Remaining' (identity)
```

### 3f. Editorial / shelf section titles

```
SHOWS_YOU_MIGHT_LIKE -> 'Shows You Might Like'
EPISODES_YOU_MIGHT_LIKE -> 'Episodes You Might Like'
TITLE_TOP_CHARTS -> 'Top Charts'      SEARCH_RESULTS_TOP_RESULTS -> 'Top Results'
'Featured' -> 'Featured'              'Recommended' -> 'Recommended'
RECENTLY_UPDATED -> 'Recently Updated'
LISTEN_NOW_SAVED -> 'Saved'           LISTEN_NOW_RECENTLY_SAVED -> 'Recently Saved'
TOP_SHELF_HOME -> 'Home'              TOP_SHELF_LISTEN_NOW -> 'Listen Now'
TOP_SHELF_NOW_PLAYING -> 'Now Playing'   TOP_SHELF_RESUME -> 'Continue'
TOP_SHELF_TOP_CHARTS -> 'Top Charts'
HOME_NO_SHOWS_BUTTON -> 'Show Featured Podcasts'
MY_PODCASTS_NO_PODCASTS_BUTTON -> 'See Featured Podcasts'
BOOKMARKS_EMPTY_BROWSE_BUTTON -> 'Browse Apple Podcasts'
FAILED_TO_LOAD_TOP_CHARTS -> 'Failed to Load Top Charts'
'Gathering Data for Top Stations.' -> 'Gathering Data for Top Charts.'  [key/value mismatch]
TODAY_NO_PLAY_NOW_PODCASTS -> 'You’re all caught up!'
```

**"New & Noteworthy", "Essentials", "Because You Listened": not determinable from the bundle.**
No key or value matching those phrases exists in `en` — editorial shelf titles appear server-supplied
(cf. `EditorialCard`, `FetchShelfIntent`, `RecommendationsShelvesIntent` in §2).

Smart play-button labels (the show-page primary action, varying by state):

```
SMART_PLAY_BUTTON_PLAY -> 'Play'             _RESUME -> 'Resume'        _PLAY_AGAIN -> 'Play Again'
_LATEST_EPISODE -> 'Latest Episode'          _FIRST_EPISODE -> 'First Episode'
_NEXT_EPISODE -> 'Next Episode'              _TRAILER -> 'Trailer'      _PLAY_TRAILER -> 'Play Trailer'
_RECENTLY_PLAYED -> 'Recently Played'        _PLAY_FROM_TIMESTAMP -> 'Play from %@'
```

Episode-row captions (the eyebrow/badge line):

```
EPISODE_CAPTION_SAVED -> 'Saved'      EPISODE_CAPTION_VIDEO -> 'Video'
EPISODE_CAPTION_DOCUMENT -> 'Document'    EPISODE_CAPTION_PDF_DOCUMENT -> 'PDF Document'
EPISODE_DOWNLOADED -> 'Downloaded'
```

### 3g. Marquee / scrolling titles

**No marquee strings exist.** Case-insensitive search of `en` for `marquee` and `ticker` returns zero
hits. The only "scrolling" strings concern the Now Playing sheet's vertical swipe:

```
NOW_PLAYING_SCROLLING_TIP_TITLE -> 'Swipe Up For More'
NOW_PLAYING_SCROLLING_TIP_DESCRIPTION -> 'See episode notes and chapters, or check out what’s
                                          playing next.'
NOW_PLAYING_SCROLLING_TIP_DONE_BUTTON_TITLE -> 'Got It'
```

A `NOW_PLAYING_FONT_SIZE -> '12'` key exists — a localizable numeric value.

---

## 2. Type names from `strings`

Method: `strings -n 4` over the main binary (35,306 lines) and each of 15 framework binaries. Swift
symbols are mangled; names below are plain-text identifiers recovered after filtering out mangled
fragments (rejecting tokens containing a digit or underscore, or lacking a lowercase letter) —
6,966 clean tokens. No demangler was available, so this is a lower bound on what exists.

Frameworks present: `IMDebug`, `NowPlayingUI`, `PodcastsActions`, `PodcastsAppEntities`,
`PodcastsAppIntents`, `PodcastsPlayback`, `PodcastsPlaybackUI`, `PodcastsSiriDonation`,
`PodcastsSuggestedDonations`, `PodcastsTestAutomationAppIntents`, `PodcastsTranscripts`,
`PodcastsWidgetKit`, `SWAIPodcastsAppIntents`, `ShelfKit`, `ShelfKitCollectionViews`.
`ShelfKit` (34,841 strings) and `ShelfKitCollectionViews` (33,613) are the two largest.

**Shelf** (57) — cell customisation is split three ways (list / horizontal grid / vertical grid),
each its own type, plus a dedicated single-item vertical case:

```
Shelf  ShelfItem  ShelfCell  ShelfCVCell  ShelfContentType  ShelfAttributes  ShelfError  ShelfLoad
ModernShelf  ModernShelfItem  ModernShelfCell  ModernShelfListBuilder  LoadingShelf
ShelfHeaderStyle  ShelfHeaderView  ShelfBackgroundView  ShelfPageControl  ShelfSpacer
ShelfScrollPosition  ShelfArtworkPosition  ShelfCellHeight  ShelfCellShape  ShelfCellRowSpacing
ShelfCellListCustomizations  ShelfCellListSeparatorMode  ShelfCellGridCustomizations
ShelfCellHorizontalGridCustomizations  ShelfCellVerticalGridCustomizations
ShelfCellVerticalGridSingleItemCustomization  ShelfCellEnvironment  ShelfItemSubcomponentID
ShelfSwiftUICell  ShelfUIKitCell  TypedShelfUIKitCell  AnySwiftUIShelfCell  UIShelfCell
DeletableShelfUIKitCell  MultiSelectableShelfUIKitCell  SourceProvidingShelfCell
ExpandableShelfItem  HeaderFooterShelves  ShelfImpressionMetricsEnvironmentKey
FetchShelfIntent  RecommendationsShelvesIntent  SharedWithYouShelfIntent  EpisodeUpsellShelfIntent
NewsFromYourShowsShelfIntent  CategoryPageFromYourShowsShelfIntent  ShowPageHeaderAndFooterShelvesIntent
```

**Lockup** (42) — the artwork+text unit; parallel Legacy and modern hierarchies, plus a Circle variant:

```
Lockup  LockupRow  LockupAndIndex  LockupStyleOptions  ShowLockupStyle  ShowLockupStyleType
ShowLockup  EpisodeLockup  ChannelLockup  LibraryShowLockup  LibraryEpisodeLockup
LegacyLockup  LegacyCategoryLockup  LegacyChannelLockup  LegacyEpisodeLockup  LegacyEditorialItemLockup
LargeLockupView  LargeLockupCollectionViewCell  LargeChartLockupCollectionViewCell
CircleLockupView  MultipleSubscriptionChannelLockupView  SearchLockupCache
ContextMenuLockupPreviewProvider  MTEpisodeLockup [both Podcasts]
FetchChannelLockupsIntent  FetchSearch{Show,Episode,Channel,EditorialItem}LockupsIntent
```

**Cell** (162; selected) — note the size/shape families **Hero**, **Uber**, **Brick**, **Showcase**,
each with its own cell type, and per-cell environment keys for size, selection and display state:

```
CVCell  ViewCell  UIKitCell  SwiftUICell  UICellConfigurationState
CellSizeEnvironmentKey  CellSelectionStateEnvironmentKey  CellConfigurationStateEnvironmentKey
IsDisplayingCellEnvironmentKey  IsDisplayingCellTrait
EpisodeCellState  EpisodeCellLayoutGuide  SingleShowEpisodeCell  MultiShowEpisodeCell
ChartEpisodeCell  ChartEpisodeEyebrowView  AccessibilityChartEpisodeCell  AccessibilityEpisodeCell
ShowHeroCell  AccessibilityShowHeroCell  UberCell  ShowUberCollectionViewCell
ChannelUberCollectionViewCell  RoomUberCollectionViewCell  ShowcaseCollectionViewCell
BrickCollectionViewCell  CategoryBrickCell  ChannelBrickCell
CategoryListCell  ChannelListCell  LinkListCell  SubscriptionLinkCell  LabelCell
LabelWithoutTopSeparatorCell  ParagraphCell  ToggleCell  HighlightCell  EmptyItemCell
ErrorCell  LoadingCell  BubbleTipCell  DoubleColumnEndMarkerCell  PowerSwooshCell
Search{Result,Show,Episode,Channel,Category,EditorialItem,Hint,Landing}Cell  NoLocalResultsCell
TopResultCell  TopResultShowCell  TopResultChannelCell  RecentlySearchedHeaderCell
ReviewCardCell  ReviewCardOverflowCell  ProductRatingCollectionViewCell
ProductTapToRateCollectionViewCell  TranscriptSnippetCell  UpsellBannerCell  EpisodeUpsellBannerCell
```

**Header** (82; selected) — note `EpisodePaletteHeaderView` (palette-derived header background) and
`ForcePortraitHeadersTrait`:

```
Header  HeaderView  HeaderModel  HeaderContext  HeaderStyleO  HeaderFactoryC
HeaderButton  HeaderButtonItem  HeaderButtonState  FollowHeaderButton
PageHeader  PageHeaderConfiguring  FlowDestinationPageHeader  HeaderFooterShelves
ShowHeader (+View, +Factory, +ContentView, +DescriptionView, +ButtonAreaView, +LegacyView)
HorizontalShowHeaderCell (+LegacyCell, +Style, +TextContentView, +Delegate)
EpisodeHeader (+Cell, +ContentView, +ButtonAreaView)  EpisodeEdgeToEdgeHeaderCell
EpisodeCollectionHeader  EpisodePaletteHeaderView
EpisodeHeaderEntitlementDisplay{,Presenter,Style,View}
ChannelHeader (+View, +ViewProtocol)  HorizontalPaidChannelHeaderView
CategoryHeaderCollectionViewCell  CatagoryHeaderCollectionViewCell [sic: Catagory]
ShowEpisodeCountHeader (+Cell, +Data)  HardQueueHeaderView  SoftQueueHeaderView [NowPlayingUI]
ShelfHeaderStyle  ShelfHeaderView  RecentlySearchedHeader  NoLocalResultsHeader
LargeMacHeader  CollectionControllerLargeMacHeader  ForcePortraitHeadersTrait
Upsell{Artwork,Editorial,LogoFallback,SquareFallback}Header (+ …CompactHeader variants)
EpisodeListWidgetLargeHeader  PodcastsWidgetFullHeader [PodcastsWidgetKit]
```

**Section** (24) — `NSCollectionLayoutSection` confirms compositional layout under the surface:

```
Section  SectionLayout  NSCollectionLayoutSection  HorizontalSectionInfo  CategorySection
NewEpisodeSection  NowPlayingTrackSection  QueueModelSection [PodcastsPlayback]
JetPackSection  JetPackLoadOrderSection  MTPodcastDetailEpisodeSection
MTPodcastDetailUnplayedEpisodeSection  AllowNotificationsSection  NoSubscriptionsSection
```

**Grid** (17):

```
GridSpec  GridSpecType  StandardGridSpec  MacGridSpec  GridCustomizations
CellVerticalGridCustomizations  CellHorizontalGridCustomizations
CellVerticalGridSingleItemCustomization  ShelfCell{,Vertical,Horizontal}GridCustomizations
CategorySelectionGrid  CategorySelectionGridLayout  UpsellShowGridView
```

**NowPlaying** (92; selected) — four distinct presentations are named (`NowPlayingPresentation`,
`…Landscape`, `…Queue`, `…QueueLandscape`):

```
[NowPlayingUI]
NowPlayingTransportController  NowPlayingPlaybackControlsController (+ViewModel, +Wrapper,
  +HoverEffect)  NowPlayingPreciseControlSlider
NowPlayingArtwork (+View, +ViewModel, +Controller)  NowPlayingItemState  NowPlayingPodcastItem
NowPlayingDataProvider  NowPlayingMediaPlayerController
NowPlayingHardQueue  NowPlayingSoftQueue  NowPlayingQueueController  NowPlayingQueuePlaceholderIfEmpty
NowPlayingTrackSection  TrackSectionMenuItems  NowPlayingChapterMenuItems
NowPlayingAdvancedControlsView  NowPlayingAdvancedControlsMenu  NowPlayingAdvancedSpeedControls
NowPlayingSpeedPresetPicker  NowPlayingSpeedPresetView  NowPlayingSpeedControlsAnimationViewModel
NowPlayingAXSpeedStepper  NowPlayingSleepTimerRemaining (+Text, +ForegroundStyle)
NowPlayingVideoToggleButton (+StateMachine, +ViewModel, +Wrapper)  NowPlayingVideoPreferenceProvider
NowPlayingBannerView (+Controller, +Delegate)  NowPlayingTabController  NowPlayingMenuController
NowPlayingFooterButtonController  NowPlayingContextMenuProvider  NowPlayingTip (+Controller, +Variant)
[Podcasts] NowPlayingPresentation{,Landscape,Queue,QueueLandscape}  MTNowPlayingIndicatorView
  MTNowPlayingArtworkProvider  MPNowPlayingInfoCenter  MPNowPlayingPlaybackQueueDataSource
  CPNowPlayingTemplate  CPNowPlayingButton  CarPlayNowPlayingController
[ShelfKit] NowPlayingLiveActivityController  PresentNowPlayingAction
[PodcastsPlayback] NowPlayingItemPlayheadSynchronizer
[PodcastsTranscripts] NowPlayingAlignmentCoordinator  ExternalNowPlayingEnvironmentTracker
```

**MiniPlayer** (11) — the second line is a distinct "subline" component with its own controller and
view model; three separate hint views:

```
MiniPlayer [Podcasts]  MiniPlayerSublineView  MiniPlayerHintLabelStyle
MiniPlayerUpsellHintView  MiniPlayerVideoAvailableHintView  MiniPlayerVideoOfflineHintView
NowPlayingMiniPlayerAccessoryController  NowPlayingMiniPlayerSublineController (+ViewModel)
```

**Transport / Scrub / Ticker / Marquee**

```
Transport (7): NowPlayingTransportController [NowPlayingUI]
               TransportCommand [PodcastsPlayback]   TransportCommandTracking [PodcastsTranscripts]
               MPNowPlayingInfoTransportableSessionRequest/Response [Podcasts]
Scrub (4):     ScrubPositionProvider  DummyScrubPositionProvider  Scrubbing [PodcastsTranscripts]
Ticker (3):    TickerSlider  TickerSliderStyle  TickerSliderAnimationViewModel [NowPlayingUI]
Marquee (0):   no matches in any binary, case-insensitive
```

`TickerSlider` is the only "ticker"-named construct, in `NowPlayingUI` alongside
`NowPlayingPreciseControlSlider`. Scrub-position types live in `PodcastsTranscripts` — transcript
scrubbing is modelled separately from playback transport.

**Sort / Filter / Selection / Editing**

```
Sort (5):      StationSortOrder [ShelfKit]  MTPlaylistSortOrder  ExplicitSortOrderKey
               SortAscendingFlag  NSSortDescriptor [Podcasts]
Filter (17):   Filter  FilterStatus  FilterAction  SearchFacetFilter  EpisodeUserFilter
               FilterablePresenter (+Filter, +Style, +Helper, +Redirect, +RedirectContainer)
               NavigationItemFilterablePresenterHelper  FilterInformationCell  FilterLinkCell
Selection(23): Selection  CellSelectionStateEnvironmentKey
               CategorySelection{,Cell,CompactCell,Chip,Grid,GridLayout,Background,BodyContent,
                 CloseButton,ContainerModifier,FavoritedCategoriesObserver}
               SelectionBackground  SelectionAndHoverBackgroundView [PodcastsTranscripts]
               {Copy,Play}TranscriptSelectionContextAction  ShowSelectionView  ShowSelectionRowView
Editing (1):   no meaningful matches (only unrelated `GisEditing`). Editing-mode types are named
               `Deletable…` / `MultiSelectable…` instead: DeletableShelfUIKitCell,
               MultiSelectableShelfUIKitCell [ShelfKit]
```

**Category / Browse / Chart / Editorial / Recommend / Card**

```
Category (39): Category  CategoryView  CategorySection  CategoryHeader  CategoryListItem
               CategoryListPresenter  CategoryPagePresenter  CategoryBrickCell  CategoryListCell
               LibraryCategoryPlayAction  LegacyCategoryLockup  MTCategory  MTFeedCategory
               CategoryIngester  SearchCategoryCell  SearchCategoryView
Browse (1):    Browse [Podcasts, ShelfKit] — no other Browse-prefixed types exist
Chart (5):     ChartEpisodeCell  ChartEpisodeEyebrowView  AccessibilityChartEpisodeCell
               LargeChartLockupCollectionViewCell  ModernTopChartsUrl
Editorial (9): EditorialCard  EditorialCardCollectionViewCell  LegacyEditorialItemLockup
               SearchEditorialItemCell  SearchEditorialItemView  UpsellEditorialHeader
               EditorialItemContextActionConfiguration  FetchSearchEditorialItemLockupsIntent
Recommend(11): RecommendationsShelvesIntent  RecommendationsMetadata (+Provider)
               RefreshRecommendationsAction [ShelfKit]
               Accept/DeclineEpisodeLimitRecommendationAction  Recommending [PodcastsActions]
Card (9):      EditorialCard  ReviewCardCell  ReviewCardOverflowCell  CardRim
               CardPresentationController  CardPresentationAnimator  CardDismissalAnimator
               CardTransitioningDelegate
```

---

## 4. Metadata.appintents

A directory of three JSON files (`extract.actionsdata`, `extract.packagedata`, `version.json`).
Eight such directories exist. `version.json` = `{"toolsVersion":"27A200c","version":"3.0"}`.

The app-level `extract.actionsdata` is **empty** (`"actions":{}`, `shortcutTileColor: 14`); it only
declares includes of `PodcastsAppEntities`, `PodcastsAppIntents`, `SWAIPodcastsAppIntents`,
`PodcastsWidgetKit` packages. 18 intents total across five framework packages.

**PodcastsAppIntents (6)** — the Apple Intelligence `audio` domain surface.
`AudioEntity` below = one-of `AudioEntityCases` {`ShowEntity`, `EpisodeEntity`,
`PodcastCollectionEntity`, `NewsBriefEntity`}.

- `PlayAudioIntent` — title **"Play Episode"**; desc "Play the provided episode immediately, clearing
  the playback queue"; schema `audio/PlayAudioIntent v1.0.0`. Params: `audioEntity` (AudioEntity);
  `queueLocation` (optional enum) — "The position in the playback queue to play the audio (e.g., start
  immediately, play next, or add to the end of the queue)"; `playbackAttributes` (array) — "…(e.g.,
  shuffle, repeat mode)"; `warmupAudioQueueResult` (optional) — "Optional pre loaded and warmed up
  queue"; `requestIdentifierOverride` (optional).
- `WarmupAudioQueueIntent` — "Warmup Audio Queue"; "Warmup a specific audio item to the queue";
  schema `audio/WarmupAudioQueueIntent v1.0.0`. **A pre-warm verb distinct from play.**
- `AddAudioToLibraryIntent` — "Add Audio to Library"; schema `audio/AddAudioToLibraryIntent v1.0.0`;
  `isDiscoverable: false`, `visibilityMetadata.assistantOnly: true`.
- `OpenAudioAppIntent` — "Open Audio Intent"; schema `audio/OpenAudioIntent v1.0.0`; `openAppWhenRun: true`.
- `OpenAppLocationAppIntent` — "Open App Location"; `openAppWhenRun: true`; param `target` (`AppLocation`).
- `SearchPodcastsAppIntent` — "Search Podcasts"; schema `system/ShowInAppSearchResultsIntent v1.0.0`;
  `openAppWhenRun: true`; param `criteria` — "Phrase to search for".

**PodcastsPlayback (2)** — `PlayPauseStationAppIntent` ("Play or Pause Station"; "Start playback of a
station or pause playback if the station is currently playing"; params `station`, `firstEpisode`
optional — "controlling where in the station list playback will start"); `PlayPauseWidgetIntent`
("Play or Pause Episode"; params `episode`, `episodePlaylist`, `playbackAccountDSID` optional).

**SWAIPodcastsAppIntents (4)** — `FollowShowAppIntent` ("Follow the provided show, adding it to you
library" [sic]); `OpenShowAppIntent` / `OpenEpisodeAppIntent` / `OpenChannelAppIntent`, all
`openAppWhenRun: true`; `OpenShowAppIntent` also takes `notice` (optional `ShowNoticeType`).

**PodcastsWidgetKit (2)** — `SelectLibraryListAppIntent`, `SelectWidgetShowAppIntent`.

**PodcastsTestAutomationAppIntents (4)** — station CRUD, shipped in the production bundle:
`CreateStationAppIntent`, `DeleteStationAppIntent`, `AddShowsToStationAppIntent`, and
`RemoveAudioFromLibraryAppIntent` ("Unfollows a show or unbookmarks an episode from the user's library").

### Entities (11, all in PodcastsAppEntities) — `?` = optional, `[s:…]` = spotlightAttributeKey

```
EpisodeEntity   title [s:title]; showName? [s:contentCatalog]; show?→ShowEntity; contextualMetadata?;
                releaseDate? [s:releasedDate]; duration? [s:duration]; description?; creator?; isSaved?
                exports: public.url, public.utf8-plain-text
ShowEntity      title [s:title]; contextualMetadata?; showDescription? [s:contentDescription];
                explicit?; description?; provider?; followed?
                exports: public.url, public.utf8-plain-text
ChannelEntity   name; subscribed                  StationEntity  title; contextualMetadata?
PodcastCollectionEntity  title [s:title]; contextualMetadata?
NewsBriefEntity title [s:title]; providerName? [s:publishers]; date? [s:releasedDate];
                provider?→NewsProviderEntity
NewsProviderEntity  title [s:title]; topicID?     ArtistEntity  name [s:artist]
LibraryList     listType? (enum); station?→StationEntity      WarmupAudioQueueResult  entityID?
ContextualMetadata  invocationSource? (enum); associatedActivities (array); suggestedListOrder?
```

Queries (12): `{Show,Episode,Channel,Station,Artist,NewsBrief,NewsProvider,PodcastCollection}EntityQuery`;
`DefaultLibraryListQuery`, `WarmupAudioQueueResultQuery`, `AudioEntityIntentValueQuery`,
`SingleShowWidgetShowQuery`.

### Enums

```
QueueInsertionLocation   next = "Next";  tail = "Later"
```

Only **two** insertion positions are modelled in App Intents; note "Later", where the in-app menu
string is `'Play Last' -> 'Play Last'`.

```
AudioEntityCases   podcastShow="Podcast Show"; podcastEpisode="Podcast Episode";
                   podcastCollection="Podcast Collection"; podcastNewsBrief="Podcast News Brief"
RemovableAudioEntityCases  show="Show"; episode="Episode"
PlaybackAttributes shuffle="On Shuffle"; repeat="On Repeat"
InvocationSource   userInitiated="User Initiated"; suggestedByApp="Suggested By App"
ShowNoticeType     follow = FOLLOWED_NOTICE ("Followed")
LibraryListType    saved / downloaded / latest → "Saved" / "Downloaded" / "Latest"
WidgetEpisodePlayList  listenNow, saved, downloaded, latestEpisodes
                   (display values are untranslated placeholders ending "  Translation Not Needed")
```

`AppLocation` — the 12 deep-linkable destinations, titles resolved against the loctable.
**The enum case is `browse` but its user-facing title is "New".**

```
home 'Home'   browse 'New'   shows 'Shows'   channels 'Channels'   saved 'Saved'
latestEpisodes 'Latest Episodes'   library 'Library'   search 'Search'
topCharts 'Top Charts'   downloaded 'Downloaded'   recentlyUpdated 'Recently Updated'
nowPlaying 'Now Playing'
```

`AudioActivity` — 31 cases for contextual playback suggestions: `barbecuing, beachDay, cleaning,
commuting, cooking, cycling, dance, dining, driving, focusing, gaming, gardening, hiit,
indoorActivity, meditating, outdoorActivity, partying, reading, relaxing, roadTrip, rowing, running,
showering, sleeping, strength, studying, traveling, walking, working, workoutHighIntensity
("High Intensity Workout"), workoutLowIntensity`.

---

## 5. Assets.car

`Payload/Podcasts.app/Assets.car` — **2,053,240 bytes (2.0 MB)**. Not decoded; no trivial reader
available without `assetutil`. Contents not determinable from this environment. The only loose image
in the bundle root is `AppIcon60x60@2x.png` (19,404 bytes).

---

## Explicitly not determinable from the bundle

- **Marquee / scrolling-title behaviour** — no `Marquee` type in any binary, no marquee string in `en`.
  `TickerSlider` exists but is a slider, not a text marquee.
- **Grid-vs-list library display toggle strings** — no `VIEW_AS` / "Show as Grid" / "Show as List" key.
- **"New & Noteworthy", "Essentials", "Because You Listened"** — absent from `en`; editorial shelf
  titles appear server-supplied.
- **Assets.car contents** — colours, symbol variants, image sets.
- **Numeric layout values** — spacings, corner radii, font sizes, artwork sizes are not in plists or
  strings; would require decoding compiled code or measuring screenshots.
- **Default skip-forward/backward interval values** — only labels and the `'%d Second(s)'` plural
  exist; the default numbers are not in the strings or plists.
- **Complete type inventory** — no Swift demangler was available, so §2 lists only names recoverable
  as plain text; mangled-only symbols are missed.

---

## 6. iOS 27.2 beta 2 (Podcasts 3.9, build 4027.200.26, platform 24B5088s) — what changed from 27.0

Extracted from the bundle Shashank pulled out of the 27.2 beta 2 IPSW. Strings are in
`ApplePodcastsReference/ios27.2b2/DISTILLED/en-strings.tsv` (2,169, against 27.0's 2,157). The
comparison was of every English string and of the plain-text symbols in the main binary, ShelfKit,
NowPlayingUI and PodcastsWidgetKit.

**The tabs did not change.** `TAB_HOME` "Home", `TITLE_CATALOG` "New", `TAB_LIBRARY` "Library",
`TITLE_SEARCH` "Search" are all present in 27.0 too, and `AppLocation.browse` was already titled
"New". What the listener sees as "the New tab has the discovery shelves; Search is only the
categories" is the layout Apple serves from its own servers (the shelves are server-built — see
"Explicitly not determinable"), not something the app bundle defines. PodSkipper had been folding
both into one "Discover" tab; pass 9 splits them to match.

Added in 27.2:
- `CREATE_STATION_BUTTON` "Create Station" replaces `NEW_STATION_BUTTON`; symbol
  `badge.plus.radiowaves.right` added to ShelfKit.
- `MARK_FILTERED_AS_PLAYED_CONFIRMATION` "This will mark all filtered episodes of this show as
  played." and the `…UNPLAYED…` twin — a show page acts on exactly what its filter shows.
- `AX_SHOW_METADATA_STAR_RATING_FORMAT` "%.1f star(s)" — the show header's rating is read aloud.
- "Recent Episodes" as an Apple Watch sync source (`RECENT_EPISODES_*`,
  `SYNC_SETTINGS_…_RECENT_EPISODES`) and as the widget: `PODCASTS_RECENT_EPISODES_WIDGET_DESCRIPTION`
  "Continue playing or see what's new." / "Play recent episode" replaces "Play Up Next episode".
- `SNIPPET_SHOW_SUBTITLE` "Show", `SNIPPET_STATION_SUBTITLE` "Station" (Siri / Spotlight snippets).
- ShelfKit: an `insightsBanner` shelf (`com.apple.podcasts.shelf.insights-banner`, new
  `PodcastsInsights` framework) on Home; `carPlayListenNowFooter`; `hidesUnentitledContent`.
- Separators: `NEW_EPISODES_AND_LAST_UPDATED_DATE_FORMAT` and its siblings now put U+2004 (three-per-em
  space) either side of the "·" instead of a normal space.
- `AUTO_DOWNLOADS_PAUSED` gained a second line, "Automatic Downloads are paused."

Removed in 27.2:
- `SEARCH_PLACEHOLDER_LONG` "Shows, Episodes, and More" (the short `SEARCH_PLACEHOLDER`, same text,
  remains).
- The "What's New" sheet pages about video (`WELCOME_TITLE_B/C/D`, `WELCOME_DESCRIPTION_B/C/D`).
- NowPlayingUI's `isChapterListExpanded` — the chapter list no longer remembers being expanded.

Episode-row vocabulary relevant to pass 9 (present in both versions): `RATING_EXPLICIT` "Explicit",
`BONUS_EPISODE` "Bonus", `EPISODE_NUMBER_BONUS_SHORT` "E%d Bonus", `TRAILER` "Trailer",
`EPISODE_CAPTION_VIDEO` / `AX_EPISODE_CAPTION_VIDEO_ICON` "Video", "Show Video" / "Hide Video",
`EPISODE_DATE_FORMAT` "MMM dd, yyyy".
