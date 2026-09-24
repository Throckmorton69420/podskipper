# PodSkipper — the plain-English guide

No jargon. Every tap spelled out. Read the first section before you start, then follow the parts in order.

---

## First: what I can and can't hand you

I wrote all the code for this app. I could not run it, because building an iPhone app requires a Mac and I don't have one. **So nobody has ever pressed "build" on this code yet.**

That is normal and it is fixable. Here is what happens:

You put the code on GitHub. GitHub has free Mac computers that build apps for you. When you press the button, one of those Macs tries to build your app. One of two things happens:

- **It works.** You get a finished `.ipa` file. Done.
- **It fails.** You get a page of red text saying which line of code it didn't like.

If it fails, **copy the red text and paste it back to me. I fix it, you press the button again.** Expect to do this once or twice. That is not a sign anything is broken — that's just how writing software works, and the build robot is doing the checking that I couldn't.

So: what you're getting today is code plus a build button, not a guaranteed-finished file. I'd rather tell you that now than let you find out at step 14.

---

## The two confusing sentences, translated

You asked what I meant. Here it is in normal words:

> "the exact `AVAssetExportSession.export(to:as:)` signature"

There's a built-in Apple tool for chopping up audio files. I told the app to use it. There are a couple of slightly different ways to call that tool depending on the iOS version, and I picked one from memory. If I picked wrong, the build will say so and it's a one-line fix.

> "whether R2 is happy with how I'm ordering canonical headers in SigV4"

When your phone uploads a file to Cloudflare, it has to prove it's really you. It does that with a maths puzzle — the phone scrambles some information with your secret password, and Cloudflare unscrambles it. The scrambling has to be done in an exact order. I wrote that ordering from memory. If I got it wrong, uploads will fail with a message containing the words `SignatureDoesNotMatch`, and again it's a small fix.

> "the Settings UI for entering R2 credentials"

A screen with five boxes to type your Cloudflare details into. **I've now written it.** It's in the app under Settings → Cloudflare storage, and it has a "Save and test" button that uploads a tiny test file to check everything works before you rely on it.

---

## What you'll end up with

An app on your phone that:

- Holds your podcast subscriptions
- Downloads episodes and finds the ads using AI that runs on your phone — nothing is sent to any company
- Plays episodes with the ads skipped
- Optionally, uploads ad-free copies to your own Cloudflare storage and gives you a link you can paste into the real Apple Podcasts app, so it works on CarPlay and your Watch too

The last part is optional. If you only listen on your phone, skip Part 4 and Part 5 entirely.

---

## Reading the timeline, and arguing with it

The bar under the artwork is a map of the episode, not just a progress bar.

- A **coloured block** is something the app found. Orange is a paid ad, pink is
  the show selling its own things, blue-ish purple is another show, green is the
  intro, light blue is the outro. A block drawn faint is something it found but
  is *not* removing, because you have that kind switched off.
- A **small downward arrow** sits over every cut. A forty-second intro in a
  ninety-minute episode is three pixels wide, which is honest and invisible —
  the arrow is always the same size, so you can see at a glance that something
  was taken out there.
- **Touch and hold** anywhere on the bar and it names what is under your finger
  and crops the scale in around that spot, so you can scrub a few seconds at a
  time instead of half a minute. **Pinch** to zoom, **double-tap** to go back to
  the whole episode.
- Pauses inside the show are deliberately **not** drawn. They used to be, and a
  clean episode looked like a barcode.

### "What was skipped"

The ⋯ button in the player opens a list of everything the app decided to cut.
Open any one of them and you get:

- A **trimmer**, like cropping a video in Photos: two handles you drag to change
  where the cut starts and stops, over a texture showing where the talking is.
- **Hear what was cut** — plays that stretch and only that stretch, then puts
  you back where you were. You do not have to turn Skip Ads off first; the app
  suspends every kind of skipping for the length of the preview by itself.
- The **words that were spoken**, big enough to read, following along as it
  plays. If there were no words it says so — "music, a sting or silence".
- **Thumbs up** and **thumbs down**.

### How it finds ads, and why it got better

The app writes out everything said in the episode, on the phone, and then asks
Apple's on-device AI about it in short pieces. Three problems made it bad, and
all three were found by running the app's own ad finder on real episodes on the
Mac — a SmartLess episode and a Legion of Skanks episode — rather than guessing:

- It **stopped listening after the first few minutes.** Everything it read went
  into one long conversation with the AI, which filled up, and every question
  after that failed without saying so. On the SmartLess episode it found one ad
  break out of four.
- **Apple's safety filter refused comedy.** About half of the Legion of Skanks
  episode — including the sponsor reads — was turned away as "unsafe content",
  and those parts were skipped. It now uses the setting Apple provides for
  judging text you already have, which does not refuse.
- **It had no real sense of context.** It now asks, for each stretch: is this a
  break *away* from the conversation, and is the listener being asked to buy or
  sign up for something? Talk about "promoting awareness" or praising someone is
  not selling, and nothing is cut as a promotion unless it also has the words an
  ad has — a web address, a code, a sponsor's name.

It also now **checks the edges** of every cut piece by piece, so a cut starts at
"let's take a moment to thank Ridge" instead of thirty seconds early, and it
looks for the show's **opening** (network announcement, theme song) after any
ads at the start, and its **closing** before any at the end. It reads the
episode's **show notes**, which often list that week's sponsors by name.

It was tuned on a SmartLess and a Legion of Skanks episode and then checked on
two Conan O'Brien episodes it had not seen. On all four it found every ad break
the transcript shows, the guests' plugs and the Patreon plug, and most edges
land on the right sentence. It also found the openings: the network
announcement and theme on Legion of Skanks, the guest's recorded hello and the
"Smart… Less" theme on SmartLess, and the guest clip and theme song on Conan.

What it still gets wrong, from those same runs:

- On SmartLess it cuts about fifty seconds of the guest talking about buying
  another comedian's T-shirts and naming his website. A thumbs-down on that fixes
  it for good (see below).
- A cut can start or end a few seconds into the conversation, and a closing cut
  can take the last joke before the goodbyes.
- A theme song with no words at all cannot be found from the words — the app has
  nothing to read there except the silence it measures.

### What the thumbs actually do

A thumb does three things now.

1. It changes **this episode** straight away — a thumbs-down stops that stretch
   being skipped.
2. It is **filed against the show** and handed to the AI as a worked example the
   next time it looks at an episode of that show.
3. It goes into a **memory that does not depend on the AI agreeing.** The phone
   turns the words of that stretch into a kind of fingerprint. Next time, any cut
   whose words closely match something you gave a thumbs-down is not made, and any
   that matches something you gave a thumbs-up is kept without being second-guessed.
   This memory is shared across all your shows, so teaching it once on one show
   helps on the others.

The fingerprint match was tested on real episodes: the same Progressive ad
played twice scored 0.96 out of 1, two different SkinnyPop reads 0.82, and no
two unrelated stretches scored above 0.77. The line is drawn at 0.81. That is
why it works best for things that repeat — the same ad script every week, the
same recurring bit — and does nothing for a one-off conversation.

It is still not "learning" in the sense of retraining the AI, which cannot be
done on a phone. It is remembering precisely what you told it.

---

## What changed in the third pass

### The progress bar

It now separates **looking** from **moving**, so you can inspect a short ad in a
two-hour episode without ever losing your place.

- **Touch the bar** and a glass **loupe** rises above it: 90 seconds around your
  finger, with the segments drawn wide, ticks every 10 seconds, and the name of
  the segment you are in ("Ad · 0:45 left").
- **Drag** to look. Along the bar you move at the whole episode's scale; **slide
  your finger up onto the loupe** and you move at the loupe's scale, fine enough
  for single seconds; higher still is a quarter of that.
- Near the start or end of a segment the dot **catches** on the edge with a soft
  click — the easy way to land exactly where an ad ends.
- **Let go** and it springs back: dragging on its own never changes what you
  hear. A thin line shows how far you have stretched from where you were.
- **Hold still for about half a second** and it breaks with a firm click:
  playback jumps there. A ring stays where you were for five seconds — **tap the
  ring** to go back.
- A **tap** just shows the time at that spot. **Pinch** still zooms the bar;
  double-tap to zoom back out.

### Tenth pass

- **New and Search now show Apple's own pages.**
  - Last time I compared the app's files, and that was the wrong place to
    look. Apple doesn't build the New page into the app: its servers send
    the page (which rows, in what order, what's featured), and the app draws
    it. That's why the files never showed it.
  - Apple's website gets the same page, so PodSkipper now reads it from
    there.
  - **New** is Apple's actual New tab, in Apple's order:
    - the big banners at the top;
    - Top Shows;
    - New Shows;
    - Newly Added Video;
    - Top Series;
    - Trending Episodes;
    - The Moment;
    - Worth the Watch;
    - New Seasons;
    - the category charts;
    - New Trailers;
    - Essentials;
    - More to Discover.
    - Your own "For You" and "Because You Listen to" rows come after
      Apple's.
  - **Search** opens on Apple's 36 category tiles, with Apple's pictures.
  - Tapping a tile, a banner or a row title opens that page, laid out the
    same way. Tapping a show opens its page in PodSkipper, where you can
    follow it.
  - Pages are kept for six hours, so opening the tab doesn't download them
    every time.
  - If Apple changes its website, these tabs go back to PodSkipper's own
    shelves until I update the app.
- **Video: where everyone gets it, and what PodSkipper can do.**
  - **Apple:** each show's hosting company sends Apple the video privately.
    It's never in the public feed, and Apple doesn't let other apps read
    it.
  - **Spotify:** the same, through Spotify's own private system.
  - **YouTube:** the show uploads full episodes to its own channel. This is
    the only place the video is public.
  - So: in a show's settings, paste its YouTube channel link (for Stavvy's
    World, youtube.com/@stavvysworld). The player then shows **Watch on
    YouTube** on recent episodes that are on the channel.
  - It plays in YouTube's own player. That's the only way YouTube allows
    another app to play its videos, which means:
    - YouTube's ads play and can't be skipped.
    - Smart Speed, Voice Boost and ad skipping don't apply while watching.
  - When you close it, PodSkipper's ad-free audio carries on from the same
    moment. It allows for the ads the audio has and the video doesn't, as
    far as they were found, so the moment is approximate.
  - Only the channel's latest 15 uploads can be searched without a Google
    account key, so older episodes won't have the button.
- **Pressing play before ads are found:** swiping the question away now
  cancels. Nothing plays, and autoplay stops there. Leave it alone and it
  still plays when the countdown ends. A Settings switch brings back the
  old behaviour (a swipe plays it).
- **Skipping forward at the end** now moves on to the next episode instead
  of starting the same one again. It follows Up Next first, then the show
  in its page's order, skipping ones you've played.
  - Why it happened: the skip stopped just short of the end, and the audio
    player treats "play from the very end" as "start again".
  - Skipping an outro that runs to the end now finishes the episode too.
- **From Apple Podcasts:**
  - **Hide Played Episodes** and a **season picker**, both in a show's
    episode menu.
  - **Share from Here…** in the player's ⋯ menu shares an Apple Podcasts
    link that opens at that moment (when Apple lists the episode).
  - A **Recently Played** list in the Library.
- **Battery and data:**
  - Show artwork used to be downloaded and stored at full size, often 3000
    pixels and several megabytes each. It's now stored at 1200 pixels, and
    Apple's image server is asked for the size that's actually drawn, which
    is what Apple's app does.
  - The Library's lists (Starred, Latest, Downloaded) ask the library for
    just their own episodes instead of loading every episode first.

### Ninth pass

- **Why Stavvy's World #198 has no Video button.** Its public feed only
  lists the audio file. Apple's public directory lists that episode as audio
  as well. The video you see in Apple Podcasts reaches Apple through its own
  private system, which other apps can't read. The Video button only appears
  on an episode whose feed actually includes a video.
- **The player shows the date.** The line above the title now reads "Show ·
  Sep 14", with the year added for anything older than this year.
- **Lock Screen card:** the play, back and forward buttons are gone. The
  system's own Now Playing box directly above it already has them. The
  Dynamic Island keeps them, because nothing sits above it.
- **Transcript and the scrubber work together.** Tap a line in the transcript
  (or play a search result) and a ring stays on the scrubber where you were,
  for about ten seconds. Tap the ring to go back. It's the same ring a drag
  leaves. A hop of only a line or two doesn't leave one. A line inside a
  removed ad is skipped past, like any other part of an ad.
- **Stutter at the top of Library and Up Next.** The activity bar (finding
  ads, publishing) was pinned between the big page title and the list. That
  is a known cause of a big title juddering when you scroll back to the top.
  It's now the first row of the list and scrolls with it. The bar also no
  longer grows from two lines to three when a publishing message appears.
  This couldn't be reproduced on the simulator, so it needs checking on your
  phone.
- **New episodes arriving.**
  - Until now, feeds were only checked when you pulled down on the Library.
    Nothing checked them overnight.
  - Now they're checked when you open the app, if it's been half an hour.
  - They're also checked in the background every couple of hours, whenever
    iOS lets the app run.
  - The overnight processing checks them first, so it can process what just
    came out.
  - **Pull down on a show's page** to check just that show.
  - A check that's already running is joined rather than started twice. A
    check only adds episodes and fills in details, so finding ads and
    publishing carry on untouched.
- **Episode rows, like Apple's:**
  - an **E** badge for explicit episodes;
  - **Bonus** or **Trailer** where the feed says so;
  - a TV icon and **Video** for video episodes.
  - On a show's page, a **year heading** (2025, 2024…) appears where the list
    crosses into an earlier year, so Dec 26 under Jan 1 isn't read as the
    same year.
  - Lists that mix shows (Up Next, Latest) put the year in the date instead.
- **New and Search are two tabs now, as in Apple Podcasts.**
  - **New** has the shelves: For You, favourite categories, "Because You
    Listen to", Top Shows and Top Episodes.
  - **Search** opens on the categories only, and searching works as before.
  - Touch and hold a category to add it to your favourites; its shelf then
    appears in New.
- **What changed in Apple Podcasts 27.2 beta 2** (from the copy you
  extracted):
  - The tab names are the same as 27.0. The New and Search layout you noticed
    comes from Apple's servers, not the app, which is why it wasn't in the
    earlier copy either.
  - "New Station" became **"Create Station"** (done here too).
  - A show's filter menu gained **"Mark Filtered as Played / Unplayed"**,
    which asks before acting (done here, with Apple's wording).
  - Apple added a "Recent Episodes" option for Apple Watch syncing and the
    widget. It doesn't apply to PodSkipper.
  - Apple added a new listening-insights banner on its Home tab. What it
    shows comes from Apple's servers, so it can't be copied.
  - The full list is in the research notes.

### Eighth pass

- **Video, properly this time, and why you haven't seen any.**
  - None of the 19 shows you follow put video in their public feeds. I
    checked every one. The video Apple Podcasts shows for big shows is sent to
    Apple privately through Apple's own system, not published in the feed, so
    no other app can get it, PodSkipper included.
  - What PodSkipper can play is video that a feed does publish: either a video
    file as the episode itself, or the newer "alternate video" tag some hosts
    (Transistor, Omny, Podbean, RSS.com, Captivate and others) add for HLS
    video. Both are read now.
  - When there is video, the sound is played by the same audio player as
    every other episode, so **Smart Speed, Voice Boost, the equaliser and
    volume levelling all work**, and the picture follows the sound. It's
    checked four times a second and nudged back if it drifts; after an ad
    skip or a seek it jumps with the sound.
  - Switching to Audio only hides the picture; the sound never stops.
  - A separately streamed video whose ad breaks don't match the audio can't
    be kept in step. In that case the app says so and plays audio only,
    rather than showing a picture minutes out of step with the sound.
- **The false cut on Legion of Skanks 955 (4:48–5:30).**
  - The hosts were joking about doing an ad ("have him do the ad
    shirtless", a brand name in a joke) and then welcomed everyone to the
    show.
  - The first pass saw a brand and called it an ad. The second check
    correctly said "nothing is being sold" but also "could be removed", and
    "could be removed" was all it took to keep the cut.
  - Now a cut is dropped when nothing is being sold and there is none of an
    ad's own wording (a code, a web address, an offer). A cut containing the
    show welcoming you by name, with no ad wording, is dropped too.
  - Re-run on all six test episodes: that false cut is gone and every real ad
    is still found. On one SmartLess episode, the guest's recorded hello is no
    longer called an ad; it's now part of the intro, which is what it is.
- **Lock Screen card**
  - It now looks like the app's mini player: the episode's cover, show and
    release date, the title on two lines, and a progress bar and countdown
    that move by themselves.
  - It shows how much ad time was removed, and has back 15 / play-pause /
    forward 30 buttons.
  - A preview of it is in Settings under the switch.
  - The title can't scroll there: iOS doesn't allow moving text in Lock
    Screen cards.
- **Search the transcript in the player.** Open the transcript and use the
  search box at the top. It shows "3 of 12", has arrows to step through the
  matches, and highlights the words. Tap a line to play from it.
- **Episode page:** the hosts and guests the feed names, "More from" the show,
  and "You Might Also Like".
- **Searching a person's name** ("Tom Segura") now shows the shows they host,
  and your episodes that name them.
- **Discover:** "Because You Listen to <your most-played shows>" shelves. Apple's
  own editors' picks aren't available to other apps, so these are built from
  what you play.
- **Stations** (was Playlists), with Apple's "newest 1, 3, 5 or 10 per show"
  option, and each station showing "Next: <episode> and N more". Stations no
  longer read your whole library to count themselves.
- **Publish automatically:** turn it on for a show (on its publishing page or
  in its settings) and each new episode goes into the ad-free feed as soon as
  its ads are found.
- **Found while testing:** while something played, the app saved your
  position to the library every five seconds, which made every list refresh
  that often and closed a touch-and-hold menu on Up Next by itself. It now
  keeps a quick safety copy every five seconds and updates the library once a
  minute (and whenever you pause, skip or leave), which also saves battery.
- **Not done, and why:**
  - **iCloud sync, CarPlay and Home Screen widgets** each need a permission
    Apple grants to a paid developer account (iCloud, the CarPlay audio
    permission, or the shared storage a widget reads the app's data from).
  - A KSign-signed app can't carry those permissions, and adding them could
    stop it installing.
  - They become buildable once the app goes through TestFlight on a paid
    developer account.

### Seventh pass

- **Library scrolling.** The grid of show covers used to be one enormous row
  that had to be drawn in full at once, which is what stuttered on a quick
  flick. It is now one row per line of covers, drawn only as they come on
  screen. Each cover's "2d ago · 3 new" line now updates on its own instead of
  redrawing every cover whenever any show's numbers change.
- **Battery and heat.**
  - While playing with the screen off, the app used to wake five times a
    second for hours. Now it sleeps until just before the next ad or silence
    it has to jump over, at most a second at a time. Jumps land more exactly
    too.
  - Getting episodes ready ahead of time (the heaviest thing the app does)
    now waits in Low Power Mode and when iOS says the phone is hot. Find Ads
    pressed by hand is never held back.
  - Video episodes stop decoding the picture when nobody can see it (audio
    mode, or the app in the background without Picture in Picture).
  - Discover no longer adds up your whole listening history on screen to
    build "For You".
- **Publish from an episode.** On a show page, touch and hold an episode and
  choose **Publish…**, or select episodes and press **Publish** in the bar at
  the bottom. Either opens the same publishing view as the Publish button next
  to Play, with those episodes already ticked.
- **Show page title.** The show's name no longer appears in the bar when you
  scroll down.
- **Up Next**
  - The activity bar at the top is the same one as in the Library, and opens
    into the full card.
  - Under your list, **Then from <show>** shows where autoplay will carry on
    once Up Next runs out: the next episodes of the show that's playing, in
    that show's order, skipping played ones. They aren't added to Up Next
    behind your back; swipe one right to add it.
  - The "next 2" card is one line now ("Next 2: 1 ad-free" and what it's doing
    right now). Each episode's own row says "Getting ready next" until it's
    done, so the card no longer repeats the list below it.
  - Episodes you haven't heard are prepared before ones queued to hear again.
  - If getting ready ever sits without starting for two minutes, it restarts
    itself. It also checks once a minute whenever the app is open, not only
    while something plays. That's the fix for the two Legion of Skanks
    episodes that said "Waiting" and never started.
- **Lock Screen card** (when turned on) is there whenever PodSkipper has an
  episode loaded, playing or paused, and goes away when you swipe the app
  away. One limit: if the app has been paused in the background long enough
  for iOS to put it to sleep, iOS doesn't tell it when it's swiped away. In
  that case the card goes the next time you open PodSkipper.
- **Zoomed strip** is a bit more see-through again, still dark glass.
- **Video or Audio.** A video episode has a **Video | Audio** switch above the
  picture. Both come from the same player, so switching is instant and can't
  drift out of sync; ads are skipped in both, because skipping is just moving
  the playhead. Your choice is remembered.
- **Search**
  - Searching now also shows **Your Episodes** (titles in your library).
  - **Said in Your Episodes** finds the words inside episodes PodSkipper has
    transcribed, with the sentence and "Play from 12:34". Tapping it plays
    from just before that moment.
- **Favourite categories.** In Discover, touch and hold a category and choose
  Add to Favourites. Its top shows become a shelf near the top of Discover.

### Sixth pass — speed, battery and tidying up

- **Faster, cooler, fewer freezes.** The last build did its heaviest work on
  the part of the app that draws the screen: filling in every show's back
  catalogue (tens of thousands of episodes) and counting things like "unplayed"
  by reading every episode, over and over. That is what froze it, made
  scrolling choppy, warmed the phone and — when memory ran out — crashed it,
  and after a crash it started the whole job again. All of that now happens in
  the background, a few hundred episodes at a time, and picks up where it left
  off. Screens only read the finished numbers. The show page also stopped
  re-sorting its whole episode list on every frame of scrolling.
- **Getting every episode, with progress.** While the back catalogues come in
  you'll see a line at the top of the Library ("Getting every episode · 12 of 40
  shows"), and the same line in Settings above the history import. It only runs
  while the app is open, one show at a time, and pauses in Low Power Mode or with
  no connection, carrying on by itself later. When it says **Ready to import**,
  run the Apple Podcasts history import again. If you start the import earlier,
  it waits for this to finish first, so everything you've played can be matched.
- **The import's summary** now says what the leftovers actually are: episodes
  from shows you don't follow here, and episodes that are no longer in a show's
  feed at all (publishers drop old ones) — rather than blaming a "newest 50"
  limit that no longer exists.
- **No Publish tab.** Four tabs now: Library, Up Next, Settings, Search. Your
  ad-free feeds are **Library → Ad-Free Feeds**, and shows that have a feed wear a
  small green broadcast badge on their cover. On a show page, Publish works as
  before, with a new **Ready to Publish** filter (ad-free, not yet in the feed)
  and **In Feed**. Select only episodes already in the feed and the button
  becomes **Remove from Feed**. Pick some that haven't been processed and it asks
  "Find ads in N episodes and publish?" first. Touch and hold any episode for
  **Publish to Feed** / **Remove from Feed** (shown once Cloudflare is set up) and
  **Episode Details**.
- **Up Next**
  - What plays next is now always **Up Next first, then the rest of the show**,
    like Apple Podcasts. That's why the card showed Foley and Mark Normand and
    not the two you'd added: it was going through the show before your list. Jun
    5 was left out because it's marked played — the card now says it skips
    played episodes.
  - The card shows each episode's date and why it's there ("Up Next" or "Next in
    <show>"); tap the title line for the explanation, tap an episode to open it.
  - Up Next rows are now the full rows from a show page — date, description,
    cover — with the show's name above.
- **Episode page.** Tapping an episode in the card, or Episode Details on any
  episode, opens a page with the cover, date, length, what was cut and the full
  description.
- **Lock Screen card is off unless you turn it on** (Settings → Playback → Lock
  Screen Shortcut). When on, it only appears while something is playing,
  disappears when you pause, and is removed when you swipe the app away. It no
  longer updates itself every 30 seconds.
- **Star** fills the instant you tap it, and is white like the bookmark next to
  it. Apple Podcasts doesn't have a star at all — its version is "Save
  Episode" — and every control on its Now Playing screen is one colour, with
  on/off shown by the filled shape rather than a colour.
- **Loupe** (the zoomed strip above the progress bar) is now nearly solid dark
  glass, so the title behind it no longer shows through.
- **Mini player** shows the cover when it's shrunk beside the tab bar, with the
  release date under the title; the full-width one shows the date before the
  time left.
- **No signal.** If you lose connection, publishing and downloads now wait and
  carry on by themselves ("Waiting for a connection") instead of failing. When
  a job does fail, the bar says so plainly — "Couldn't publish" or "Finished
  with problems" — rather than "finished" and "failed" at once.
- **Intro on Legion of Skanks.** Intros now run through the theme song to where
  the talking starts: the app spots the few seconds of music with no words
  after the theme. On episode 955 that moves the end of the intro from 0:47 to
  1:10.
- **Battery:** the moving background behind the player draws two-thirds as many
  frames and stops in Low Power Mode, and working out how each ad was read (for
  the keep-host-read and keep-funny-ads settings) only happens when one of those
  settings is on. If you turn one on later, episodes processed before it won't
  have that information until you run Find Ads on them again.

### Fifth pass

- **Glass like Apple Podcasts:** no more hard-edged band under the top and
  bottom bars; the show page's colour fades into the list instead of ending on
  a line.
- **Every episode:** shows now keep every episode their feed lists, not the
  newest 50. The first launch of this build fills in your existing shows in the
  background. (A few publishers only put their latest few hundred episodes in
  the feed; older ones aren't anywhere an app can read.) Re-run the Apple
  Podcasts history import afterwards and far more will match.
- **Publishing lives on the show page.** Press Publish (or Feed) on any show —
  or open a show from the Publish tab — and the same page switches to
  publishing: the feed link where the description was, filters for Not in Feed /
  In Feed / Needs Ads, ticks on the rows, and Find Ads / Publish at the bottom.
  Episodes already in your feed show a small broadcast mark.
- **Activity** opens in place: tap the bar at the top and it grows into the full
  card; tap the chevron (or swipe up) to shrink it back. It stays after
  publishing finishes, so you can see what failed, until you clear it.
- **Find Ads in the player** works immediately: it pauses the "get the next
  episodes ready" job and starts on what you're listening to, and skipping
  begins as soon as it's done.
- **Speed & Audio and What was skipped** stay glass when dragged up. At truly
  full height iOS deliberately makes a sheet opaque, so they stop just short.
- **Bookmark badge** sits on top of the button.
- **Up Next** shows played episodes you add, with Unplayed and Played filters.
- **Autoplay:** start an episode from a show and it continues in that show's
  sort order; start one from Up Next and it continues through Up Next.
- **Lock Screen:** a PodSkipper card appears beside Now Playing; tap it to open
  the player (Settings → Playback → Lock Screen Shortcut). Why the system Now
  Playing tap does nothing: iOS picks the app to open from the signature of the
  app playing audio, and a KSign re-signature doesn't name PodSkipper correctly
  — that part can't be fixed from inside the app.

### Fourth pass

- **Size:** Settings → Display → Text and Icon Size. Six steps from Smallest to
  Largest; text, icons, covers and buttons all scale together. The new Default
  is a little smaller than before (the old size is "Large").
- **Touch and hold** any episode row for the same menu as its ⋯ — Play Next,
  Add to Up Next, Download, Mark Played, Star, Find Ads, and on a show's page,
  Select.
- **Selecting episodes** now happens on the show's page itself, with the full
  rows — cover and notes — and a tick beside each. Tap rows to tick them.
- **The bottom bar** now behaves like Apple Podcasts: scroll down and the tab
  bar shrinks, with the now-playing bar sitting beside it; scroll back up and
  it returns.
- **Play Next / Add to Up Next** now always lands in Up Next. It was being
  added, but hidden: Up Next only lists unplayed episodes, and the history
  import had wrongly marked hundreds played. Queuing a played episode now
  makes it unplayed.
- **The history import is fixed.** The export was counting Apple's "back
  catalogue" entries as played — 590 Cum Town episodes Apple shows as
  unplayed. Now only episodes with a real play, or that you marked played,
  count: 3,266 instead of 11,963 (36 of Cum Town's 627). Each episode is also
  matched only within its own show. I've re-run the export into iCloud Drive →
  PodSkipper; **import it again** and it will put the wrongly-marked episodes
  back to unplayed — except any you actually listened to in PodSkipper.
- **Autoplay order** within Up Next was backwards for shows of the same
  priority; it now plays top to bottom.
- **Sheets** (Audio, Bookmarks, Activity) grow out of the button you tapped,
  and the ones that were black pages are glass.
- **Background** moves about a quarter faster than the original, not twice as
  fast.

### Star and bookmark

- The **star fills in yellow** when an episode is starred.
- The **bookmark** is the same size as the buttons beside it, fills in, and
  shows a small number — how many bookmarks this
  episode has. **Tap** it to save the moment and type a label. **Hold** it to
  open this episode's bookmarks: tap a time to jump there, edit any label in
  place, swipe to delete, or add a new one with a label at the top.

### Sheets over the player

Audio settings and What was skipped now open at half height as glass, like the
rest of iOS. Drag them up for the full screen.

### Getting the next episodes ready

Up Next now shows a card: **"Getting the next 2 ready"** with each episode and
whether it is Waiting, being worked on, or Ad-free. It starts on its own —
when you open the app, when Up Next changes, when a job finishes, and every
minute while you listen — and **Prepare Now** does it straight away. The number
is the one in Settings → Prepare N episodes ahead.

### Publishing several episodes

- Select as many as you like and press **Publish**. They go into a queue and are
  published one after another without pressing anything again. Episodes whose
  ads haven't been found yet get that done first, automatically.
- The bar at the top now shows a line of what's happening as it happens. **Tap
  the bar** to open **Activity**: the steps of the current episode ticked off as
  they pass, the list of what's waiting (drag to change the order, swipe to
  remove), and the full running commentary.
- The step count is now per episode: an episode already on your phone skips
  "fetching the audio", so it says 1 of 3, not 2 of 4.

### Automatic downloads

Settings → Processing → **Automatic Downloads**, and each show's own settings.
The same choices as Apple Podcasts — Off, Only New, All Unplayed; keep the most
recent 1, 2, 3, 5 or 10, or the last 24 hours, 7, 14 or 30 days — plus:

- **Find Ads Right Away**, so an episode is ad-free before you press play.
- **Only on Wi-Fi.**
- Per show: **Skip Shorter Than** (keeps trailers and bonus clips off your
  phone) and **Skip titles containing** (for example `trailer, rerun`).
- A show's page lists exactly what its rule would download right now.

Only downloads a rule made are ever removed by a rule — never ones you
downloaded yourself, starred, or put in Up Next.

### Your Apple Podcasts listening history

Apple Podcasts has no export button, and an iPhone app is not allowed to read
another app's data, so this can't happen on the phone alone. But your Mac,
signed in to the same Apple Account, keeps a synced copy of everything —
including what you played on your iPhone. So:

1. On the Mac, run `Tools/ApplePodcastsExport/export-history.sh` (I've already
   run it once for you). It saves **Apple Podcasts History.json** to
   **iCloud Drive → PodSkipper**. Yours has 20 followed shows, 11,963 played
   episodes and 179 in progress.
2. On the iPhone: PodSkipper → **Settings** → **Import Apple Podcasts History**
   → **Browse** → **iCloud Drive** → **PodSkipper** → tap the file → **Open**.
3. It follows any shows you're missing, marks played episodes as played,
   restores where you stopped, and tells you how many it matched.

Only episodes already in PodSkipper's list for a show can be marked (it keeps
the newest 50 per show), so very old played episodes are counted, not marked.

### Keeping host-read ads, or the funny ones

Settings → What to skip has two new switches:

- **Keep Host-Read Ads** — skip produced commercials, hear the hosts' own reads.
- **Keep Ads Played for Laughs** — when the hosts turn an ad into a bit (the
  Cum Town kind), it's kept.

After finding ads, the AI is asked one extra short question about each ad: did
the host read it, and was it a bit? What was skipped shows the answer
("host-read", "produced spot", "played for laughs"). This works on episodes
whose ads are found from this version on.

How well it does, tested on three real episodes on the Mac: on Legion of Skanks
it called the Progressive commercials produced, the Ridge read a straight host
read, and the GLD read (the one with the Spain story) played for laughs. On
SmartLess all four breaks were produced, correctly. On Conan it marked one
stretch as a bit that was really the end credits with a joke in them, running
into a movie trailer. So treat **Keep Ads Played for Laughs** as experimental:
it is deliberately cautious, but when it is wrong you hear an ad. Both switches
start off.

### About Apple's "safety filter" and comedy

It isn't a label on comedy, and it doesn't read a show's genre. It is a filter
on the words in each piece of text the AI is shown. Profanity, sexual or
violent jokes — normal for a comedy podcast — trip it, and the AI refuses.
That's why about half of a Legion of Skanks episode was refused before.

It can't be switched off completely, but Apple provides a looser setting meant
for exactly this — rewording or classifying text you already have — and
PodSkipper has used it since the last pass. In the lab it took Legion of Skanks
from about half refused to every ad break found. If a stretch is still refused,
that one stretch is skipped over rather than the episode failing.

### The other ideas you asked about

- **Apple's bigger AI in iOS 27 (Private Cloud Compute).** Real, and apps can
  use it, but Apple requires each app to apply and be approved, and it needs the
  iOS 27 developer tools. The build robot on GitHub doesn't have those yet. Worth
  revisiting; not possible today for a sideloaded app.
- **SponsorBlock.** Gemini was half right. SponsorBlock is a real, free database,
  but its times are for **YouTube videos**. A podcast's audio file has different
  ads inserted at different places for different listeners, so YouTube timings
  don't line up with what you hear. It could help only for shows that are
  identical on YouTube, which is rare with inserted ads.
- **Podcasting 2.0.** Real. Some feeds include a transcript and chapter file.
  There's no standard tag that marks ads, but a publisher's own transcript would
  save the phone transcribing — a good future addition.
- **Chapters inside the audio file.** Real — PodSkipper already reads them.
  Some shows name a chapter "Sponsor" or "Ad"; most don't.

### Working in the background

No location trick — you're right that it would drain the battery, and Apple
treats an app holding a permission it doesn't need as a reason to cut its
background time. iOS 26 added the proper way: when a job you started (finding
ads, publishing) is running and you leave the app, PodSkipper asks iOS to let it
carry on, and iOS shows its progress on the Lock Screen. iOS can still stop it
if the phone is short on memory or battery. **This has not been tested on a
phone yet**, and a sideloaded install may not be granted it.

### Tapping Now Playing on the Lock Screen

Still not something the app can fix. With a sideloaded app, iOS opens the app
that installed it (KSign) instead. Through TestFlight or a normal install it
opens PodSkipper.

---

# Part 1 — Put the code on GitHub

You need a free GitHub account. Everything below works in Safari on your phone.

1. Go to **github.com** and sign in (or sign up — it's free).
2. Tap the **+** in the top right → **New repository**.
3. Under **Repository name**, type `podskipper`.
4. Choose **Public**. (Public repos get unlimited free build time. Private ones give you about 20 builds a month. There's nothing secret in this code — your Cloudflare passwords are typed into the app on your phone, never into the code.)
5. Tick **Add a README file**.
6. Tap **Create repository**.

Now upload the files. The folder I gave you has this shape:

```
project.yml
README.md
PUBLISHING.md
PLAIN-ENGLISH-GUIDE.md
.github/workflows/build-ipa.yml
PodSkipper/Models/Models.swift
PodSkipper/Services/  (9 files)
PodSkipper/Views/     (2 files)
```

**The folder structure matters.** A file in the wrong folder means the build fails.

7. On your repository page, tap **Add file** → **Upload files**.
8. Tap **choose your files** and select everything. On iPhone, the Files app lets you select multiple files at once — tap **Select**, then tap each file.
9. Scroll down, tap **Commit changes**.

If uploading nested folders through Safari proves painful, an app called **Working Copy** handles this properly and is free for this purpose. That is the smoother path if you hit friction.

---

# Part 2 — Change two names

Two lines need your own name in them, and they must match each other exactly.

1. In your repository, tap **project.yml**.
2. Tap the **pencil icon** (top right) to edit.
3. Find the line `bundleIdPrefix: com.yourname`. Change `yourname` to something that's yours — no spaces, letters only. For example `com.spandya`.
4. Find `PRODUCT_BUNDLE_IDENTIFIER: com.yourname.podskipper`. Change it the same way: `com.spandya.podskipper`.
5. Find `- com.yourname.podskipper.process`. Change it: `- com.spandya.podskipper.process`.
6. Tap **Commit changes** → **Commit changes**.

Now the matching line in the code:

7. Go to **PodSkipper** → **Services** → **ProcessingPipeline.swift**.
8. Tap the pencil icon.
9. Near the top find: `static let backgroundTaskID = "com.yourname.podskipper.process"`
10. Change it to exactly what you used in step 5: `"com.spandya.podskipper.process"`
11. Tap **Commit changes** → **Commit changes**.

**These two must be identical, character for character.** If they don't match, the app builds fine but the overnight processing silently never runs, and that's a miserable thing to debug later.

---

# Part 3 — Build the app

1. In your repository, tap the **Actions** tab.
2. If it asks you to enable workflows, tap the green **I understand my workflows, go ahead and enable them**.
3. On the left, tap **Build unsigned IPA**.
4. Tap **Run workflow** → **Run workflow**.
5. Wait. It takes about 5–10 minutes. Pull down to refresh.

**If you get a green tick:**

6. Go back to your repository's main page.
7. On the right side, find **Releases** and tap **latest**.
8. Under Assets, tap **PodSkipper.ipa**. It downloads into your Files app.
9. Skip to Part 6.

**If you get a red X:**

6. Tap the failed run, then tap the **build** job.
7. Look for the step with a red X and tap it to expand.
8. Screenshot it, or select and copy the text near the word `error:`.
9. Send it to me. I'll fix the code and tell you to press Run workflow again.

This is expected. Don't take it as a sign the whole thing won't work.

---

# Part 4 — Cloudflare storage (optional)

**Skip this whole part if you only listen on your phone.** Do it if you want the ad-free versions to appear in the real Apple Podcasts app, CarPlay, Apple Watch, or HomePod.

Why this is needed: Apple Podcasts checks for new episodes on its own schedule, often at 3am while your phone is asleep and the app is closed. So the finished audio has to live somewhere that's always awake. Your phone does the thinking; Cloudflare just holds the files. It's free — 10 GB of storage with no charges for people downloading from it.

1. Go to **dash.cloudflare.com** and sign in.
2. In the left sidebar, tap **R2**. (You may need to add a payment card even though you won't be charged, because Cloudflare requires one to enable R2.)
3. Tap **Create bucket**.
4. Name it `podcasts`. Leave everything else alone. Tap **Create bucket**.
5. You're now inside the bucket. Tap **Settings**.
6. Find **Public access** → **Custom Domains** → **Connect Domain**.
7. Type a subdomain on a domain you already own, for example `pods.ha50e76.win`. Tap **Continue** → **Connect domain**.
8. Wait a minute or two for it to say **Active**.

Now get your four values. **Write these down somewhere as you go** — one of them is shown only once.

9. Tap **R2** in the sidebar again (to leave the bucket).
10. On the right, find and copy your **Account ID**. It's a long string of letters and numbers. That's **value 1**.
11. Tap **Manage R2 API Tokens** → **Create API Token**.
12. Name it `PodSkipper`.
13. Under Permissions, choose **Object Read & Write**.
14. Under Specify bucket, choose **Apply to specific buckets only** and pick `podcasts`.
15. Tap **Create API Token**.
16. The next screen shows **Access Key ID** (**value 2**) and **Secret Access Key** (**value 3**). **Copy both now.** The secret is never shown again — if you lose it you have to make a new token.

Your four values are:

| | What | Example |
|---|---|---|
| 1 | Account ID | `8f4c2a91b...` |
| 2 | Access Key ID | `a1b2c3...` |
| 3 | Secret Access Key | `9x8y7z...` |
| 4 | Public address | `https://pods.ha50e76.win` |

Plus the bucket name: `podcasts`.

---

# Part 5 — Installing the app with Ksign

1. Open **Ksign** on your phone.
2. Make sure you have a certificate loaded — Ksign → certificates section → your `.p12` and `.mobileprovision` imported and set as active. You already do this for other apps.
3. Go to the **Files** section in Ksign and tap the **+** in the top right.
4. Tap **Import From Files**, and pick the `PodSkipper.ipa` you downloaded in Part 3.
5. Tap the imported file → **Sign** → choose your certificate.
6. When signing finishes, tap **Install**.
7. Tap **Install** again if iOS asks.
8. PodSkipper appears on your Home Screen.

**First launch:**

9. Open PodSkipper. Go to the **Settings** tab.
10. Check **On-device AI** says **Ready** in green. If it says unavailable, your iPhone doesn't have Apple Intelligence turned on — go to iPhone Settings → Apple Intelligence & Siri and enable it. It needs an iPhone 15 Pro or newer.
11. If you did Part 4: tap **Cloudflare storage**, paste your five values, tap **Save and test**. It uploads a tiny test file and deletes it. Green means it works; red tells you what's wrong.

---

# Part 6 — Using it

**Find and add a show:**

1. Tap the **magnifying glass** tab at the bottom right.
2. Without typing anything you get: **For You** (shows like the ones you listen to), **Top Shows**, **Top Episodes**, and **Browse by Category** — tap a colour tile to see that category's top shows.
3. Or type in the search box. Results come in three groups: shows already in **Your Library**, **Shows**, and **Episodes**. Recent searches appear under the box when you tap into it.
4. Tapping any show opens a **preview**: its artwork, description and recent episodes. Nothing is added yet.
5. Tap **Follow** on the preview to add it to your library. If you already follow it, the button says **Following · Open** and takes you to its page.

You can still add a show by its RSS address: **Library** tab → **+** → paste the address → **Add**.

**Process an episode:**

4. Tap the show, then tap **Find ads** on an episode.
5. Leave the app open. The first episode is slow — your phone downloads a speech model of a few hundred megabytes first. Later episodes are much faster.
6. When it says something like "3 ads, 4 min cut", it's done.

**Listen:**

7. Tap **Play**. The orange bars on the timeline are the ads. The app jumps over them.
8. If it cuts something it shouldn't have, tap **Undo skip**.

**Do something to lots of episodes at once:**

9. On a show's page, tap the **•••** next to Play and Publish, then **Select Episodes**.
10. Tap each episode you want. A tick appears beside it and the top of the screen counts them. **Select All** in the top left picks everything on screen.
11. Buttons appear just above the now-playing bar: **Played** (marks them played; it says **Unplayed** if they all already are), **Find Ads**, and a **•••** with Add to Up Next, Download, Remove Download, Star and Archive.
12. It only acts on what you can see. So to mark every unplayed episode as played: tap **All Episodes** above the list, choose **Unplayed**, then Select Episodes → Select All → Played.
13. Tap **Done** to leave without doing anything.

**Publish to Apple Podcasts (if you did Part 4):**

14. On the show's page, tap **Publish**. The page that opens is about the show's one ad-free link.
15. Tick the episodes you want in the feed and tap **Publish** at the bottom. This chops the ads out for real and uploads the result — it never looks for ads again. A 60-minute episode takes a few minutes, most of it uploading.
16. Once anything is published, the top of that page shows the show's link. Every episode you publish later goes into the same link, so you only ever add it to Apple Podcasts once.
17. Tap **Add to Podcasts**. If Apple Podcasts opens and offers to follow the show, tap **Follow** and you're done.
18. If nothing happens: tap the copy button beside it, open **Apple Podcasts** → **Library** → **•••** (top right) → **Follow a Show by URL** → paste → **Follow**.

Your ad-free version now behaves like any other podcast — CarPlay, Watch, HomePod, iPad, position syncing, all of it.

---

# Part 7 — Making it run by itself

Once things work manually, automate them.

**The main engine needs no setup.** The app already asks iOS to process queued episodes in the background. iOS decides when — usually overnight while your phone is charging on Wi-Fi. Plug your phone in at night and it happens.

**A nightly check for new episodes:**

1. Open **Shortcuts** → **Automation** tab → **+**.
2. Tap **Time of Day**.
3. Set it to **2:00 AM**, **Daily**.
4. Important: choose **Run Immediately** and turn **Notify When Run** off.
5. Tap **Next** → search for **Refresh feeds** → tap it.
6. Tap **Done**.

**Process and publish when you plug in:**

7. Shortcuts → Automation → **+** → **Charger**.
8. Choose **Is Connected**, **Run Immediately**.
9. Tap **Next** → search for **Process and publish** → tap it.
10. Tap **Done**.

This one opens the app, which is deliberate — iOS won't let an app transcribe an hour of audio while hidden in the background. It kills it. Opening the app gives it the time it needs.

**Set your expectations honestly:** one hour-long episode means a download, a full transcription, dozens of AI calls, an audio re-export and a 50 MB upload. This is a plugged-in, overnight job. Two or three weekly shows is comfortable. Six daily news shows will make your phone warm and your battery unhappy.

---

# When something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| Red X on the build | The code has a mistake | Copy the error text, send it to me |
| "On-device AI unavailable" | Apple Intelligence is off, or your iPhone is too old | iPhone Settings → Apple Intelligence & Siri. Needs iPhone 15 Pro or newer |
| Test upload fails with `SignatureDoesNotMatch` | The upload maths puzzle is wrong | Tell me — it's a fix in one file |
| Test upload fails with `403` or `401` | Wrong Cloudflare values | Re-check the four values. The Secret is shown once; make a new token if unsure |
| Episode stuck on "transcribing" | The speech model is still downloading | Keep the app open on Wi-Fi for a few minutes |
| App icon does nothing when tapped | Your Ksign certificate expired | Re-sign it in Ksign |
| Apple Podcasts follows the feed but won't play | The public address is wrong | Settings → Cloudflare storage. It must start with `https://` and be the custom domain |

---

### Eleventh pass

- **New icon.** It's a sound wave with the middle, the ad, faded out, and an
  arrow hopping over it. The outline also looks like a pair of headphones.
  There are three versions, and your phone picks one to match your Home
  Screen:
  - **light:** white on the pink-to-orange colour;
  - **dark:** the colour on near-black;
  - **tinted:** grey, for iOS to recolour.
- **The progress bar stays at the top of Library and Up Next**, as it does on
  a show's page. It goes away when the work is done. (It was a list row on
  those two pages, so it scrolled out of sight.)
- **Tapping a notification about a job takes you to that episode.**
  - A small sheet opens and says where the job stands *now*: still working
    (with the percentage), done (with how many breaks were found), or still
    stuck (with the reason and a **Try Again** button). There's also
    **Play**.
  - If iOS stops a job while you're out of the app, PodSkipper sends its own
    notice. The next time you open the app, it goes straight to that
    episode.
  - The grey "failed" notice iOS shows by itself can't be linked to
    anything, so the next-open behaviour is how that one gets you to the
    right place.
- **Less lag while ads are being found.**
  - The loudness-and-silence step read the whole audio file on the same
    thread that draws the screen. It now runs off it.
  - The progress bar used to redraw hundreds of times a second. It now
    redraws about four times a second.
  - Saving the transcript also moved off that thread.
- **YouTube: new ways to open the video somewhere else.** The YouTube sheet
  now has three more buttons:
  - **YouTube App** opens the video in whichever YouTube app you have
    installed, at the same moment.
  - **Safari** opens it in Safari, where AdGuard's "Block YouTube Ads"
    works.
  - **Share Link…** opens the share sheet with the link at that moment.
  - Opening it elsewhere pauses PodSkipper at the point the video had
    reached.

### Twelfth pass

- **Video from the podcast's own feed (the ChatGPT write-up was right).**
  - Some hosting companies put an HLS video stream in the normal podcast
    feed, next to the audio. PodSkipper has been able to read and play
    that since an earlier pass; my last answer only described the YouTube
    fallback, and that was wrong of me.
  - Hosts that do it today include Transistor, RSS.com, Fountain, Podbean,
    Captivate and a few others. Primary Technology is a real example.
  - It is **not** how Apple Podcasts gets video. Apple takes video from
    hosts through a private channel and doesn't read it from feeds. Shows
    whose host only does the Apple version (Acast, ART19, Omny in the
    examples I checked) still have no video PodSkipper can reach.
  - How it plays: the sound is still PodSkipper's own audio, so ad skipping,
    Smart Speed and Voice Boost all work, and the picture follows along.
    Skipping an ad moves the picture too. Use the **Video / Audio** switch
    at the top of the player. There is no "Watch on YouTube" button when
    the feed has its own video.
  - I measured real episodes: the video and the audio were the same length
    to within a second. That's what lets the picture follow the audio.
  - What changed this pass:
    - Feeds that name things slightly differently are read correctly.
    - When an episode offers several videos, the best one is chosen
      (streaming HLS, highest quality).
    - If a host adds ads to the audio but not the video, the picture skips
      over those ads instead of drifting.
    - If the video has ads of its own, PodSkipper plays audio only and
      says so on the player.
- **New and Search keep themselves current.**
  - They were already Apple's live pages. Now they refresh in the
    background every couple of hours and when you open the app, so they're
    current before you look.
  - If Apple adds a kind of row that PodSkipper doesn't know, it's shown in
    the closest familiar style (covers, episode rows or a list) instead of
    being left out. It won't be a perfect match for a brand-new design
    until I update the app, but nothing goes missing.
- **iCloud sync, CarPlay and widgets are built in and switched off.** They
  turn on by themselves once the app is signed by a paid Apple Developer
  account (US$99 a year). Until then nothing about today's app changes.
  Settings → More → **iCloud, CarPlay & Widgets** shows which ones are on,
  and previews the widgets.
  - **iCloud** syncs the shows you follow, where you are in each episode,
    what you've finished and what you've starred. Each device rebuilds
    episodes, transcripts and found ads from the feeds itself. A show you
    unfollow on one device stays on the others.
  - **CarPlay** has Up Next, Shows and Recent tabs and the standard Now
    Playing screen, with a speed button. Ads are skipped the same way as on
    the phone. An episode without its ads found plays straight away (no
    question on the car's screen).
  - **Widgets:** Up Next (small, medium, large and Lock Screen) and Now
    Playing with a play/pause button. You can add them now, but they'll
    only say "Open PodSkipper" until the paid account lets the app share its
    data with them.

#### Paid features: turning them on, step by step

1. Go to developer.apple.com/programs, click **Enroll**, sign in with your
   Apple Account and pay the yearly fee. Approval can take a day or two.
2. Tell me when you're enrolled. I'll change the app's identifier from the
   placeholder `com.yourname.podskipper` to one under your account.
3. Request CarPlay: go to developer.apple.com/contact/carplay, choose
   **CarPlay audio app**, and describe PodSkipper as a podcast player.
   Apple approves by hand.
4. In your developer account, open **Certificates, Identifiers & Profiles**
   → **Identifiers** → **+** and register the app with **iCloud**
   (key-value storage), **App Groups** (`group.<your id>.podskipper`) and,
   once approved, **CarPlay Audio**. Then register the widget
   (`<your id>.podskipper.nowplaying`) with the same App Group.
5. Make a development or ad hoc provisioning profile for each, and use it
   in KSign (or TestFlight, which I can set up instead).
6. The entitlement files are ready in `Support/PodSkipper-Paid.entitlements`
   and `Support/Widgets-Paid.entitlements`. Building with the environment
   variables `PODSKIPPER_ENTITLEMENTS` and `PODSKIPPER_WIDGET_ENTITLEMENTS`
   set to those paths includes them.
7. Open Settings → More → iCloud, CarPlay & Widgets. Each line should now
   say it's on.

### Thirteenth pass

- **A new way of finding ads.** The old version read the episode in 45-second chunks and guessed where
  each ad started and stopped. The new one reads it sentence by sentence, using the exact time of
  every word, and decides what each sentence is: conversation, an ad, the hosts' own plug, a plug for
  another show, the intro, or the outro.
- **What that fixes**, checked on the two episodes you labelled:
  - Matt and Shane 633: the old version failed 8 of 10 checks, the new one fails none.
  - Stavvy's World #199: the old version failed 9 of 9, the new one fails none.
  - In practice:
    - Two ads back to back are two separate cuts.
    - The hosts' tour dates aren't merged into the ad before them.
    - "Watch us on Spotify" stays separate from the ads after it.
    - Twisted Tea's cut starts at its lead-in line instead of halfway in.
    - Jokes about a product are left alone.
- **Where it's still weaker.** On two episodes I hadn't tuned it on:
  - A break of three back-to-back host-read ads came out as one long cut. It still skips them all,
    but you can't keep one and skip another.
  - A network intro was missed.
  - A produced ad break was found with a 20-second gap in it.
- **Slower.** On your Mac it takes 3–5 minutes per hour-long episode, against about 1 before. I don't
  know how long it takes on your phone. Tell me if it feels slow.
- **Transcripts you already have** still work. New transcripts keep every word's timing, so cuts can
  start mid-line.
- **Your changes are kept and teach it.**
  - Every cut remembers what was originally found. When you change it, it says **Edited**, and a faint
    dashed box on the strip shows the original. **Revert** puts it back.
  - Finding ads again never touches a cut you've confirmed, rejected, edited, added or locked.
  - Dragging an edge teaches the show. The words you cut away are remembered as "not part of it", and
    the words you pulled in as "part of it". The next episode's edges use both.
  - Changing a cut's type (ad, promo, other show, intro, outro) teaches too.
- **The editor in What Was Skipped, rebuilt like trimming in Photos:**
  - **A playhead of its own.** Tap the strip or a line of transcript to put it there. Play starts from
    it and runs a few seconds past the cut, so you hear where it lands.
  - **Precise edges.**
    - Drag a handle, and slide your finger down while dragging to move it more finely.
    - Pinch the strip, or tap the magnifier, to zoom in up to 8×.
    - Nudge buttons move the chosen edge by a tenth of a second or a whole second.
    - Dragged edges snap to the nearest word.
  - **Undo**, **Lock** (nothing can change it, including finding ads again) and a **type** menu.
  - **+ (top left)** adds a cut the detector missed.
  - For video episodes, the picture shows above the strip.
- **More video.**
  - When the feed has no video, PodSkipper now also checks Apple's public page for the episode. Some
    hosts (Stavvy's World's is one) link their own open video stream there. PodSkipper uses it only
    when it's exactly as long as the audio, so skipping stays in step. The player then says "From the
    show's host". It never uses Apple's own streams.
  - YouTube stopped serving its channel feeds this month, so "Watch on YouTube" had quietly stopped
    finding anything. It now reads the channel's Videos page instead.
- **SponsorBlock as a hint.** For a show with a YouTube upload, the ad finder asks SponsorBlock where
  viewers marked sponsors, and reads those places more closely. It never cuts anything just because
  SponsorBlock said so.
- **Only your phone can test:**
  - whether edits change the next episode, since the simulator has no ad-finding model;
  - the fine-drag and pinch feel;
  - the Stavvy's World video from Apple's page (I checked the link, its length and that it has no
    extra ads with a separate tool on your Mac; the app fetching it itself hasn't run anywhere yet);
  - SponsorBlock on a real show.

### Fourteenth pass

- **Why it was worse on some shows, and what I fixed.** I read the traces for the two episodes it did
  badly on.
  - It only reads a stretch closely when a keyword tells it to, so a network intro with no keyword
    was never considered. Openings are now kept when they name the show or a network — Legion of
    Skanks' "You are listening to the Gas Digital Network" is found.
  - A break of three ads in a row goes quiet in the middle — no web address, no "brought to you by" —
    so the cut ended early. A hole between two ads less than 45 seconds apart is now filled after one
    check. Conan's three-minute break is one clean cut instead of two with a 24-second hole.
  - Both of your labelled episodes still come out perfect.
- **I tried a bigger rewrite and threw it away.** Instead of judging sentences, it asked "split this
  stretch of the episode into parts and say what each is" — which is what you described. It is three
  times faster and it is the right idea, but the model on the phone isn't good enough at it yet: it
  copied my example back at me, and called whole ad breaks "conversation". It got 5 of 10 wrong where
  the current one gets 0. The code is in the repo for when the on-device model improves.
- **Every cut now shows why.** "a web address; a discount code; small print" — and when it isn't sure
  it says **Worth a look** instead of pretending. The top of What Was Skipped counts those.
- **Heat and battery.** Finding ads is the hottest thing the app does. It now spaces out its thinking
  when the phone says it is warm, or when Low Power Mode is on. Slower, but it won't cook the phone.
- **Video like Apple Podcasts.** The picture is the full width of the player, and tapping it goes
  full screen with the app's own controls (tap again to show or hide them). The picture also follows
  the sound more gently: it corrects half as often, never jumps while the stream is buffering, and
  ignores anything under a tenth of a second — that is what the stutter was.
- **What Was Skipped is easier to handle.**
  - The playhead has its own bar under the strip, so you can scrub without grabbing a trim handle by
    accident. The strip ignores taps right next to a handle.
  - **-5s** and **+5s** buttons beside play.
  - Haptics on the nudges, the steps, scrubbing, locking, changing a type, and when an edge snaps
    onto a word — and on the player's own play, back and forward buttons.
- **Still not right, and I am not going to pretend otherwise:**
  - Legion of Skanks' three ads in a row come out as one long cut rather than three.
  - Conan's closing credits are labelled an advertisement.
  - Speed on your phone is unmeasured. On my Mac an hour-long episode takes two to three minutes.

### Fifteenth pass

- **AirPods fixed again, and why it broke.** When episodes started getting video, the picture was set
  to follow the sound. Taking AirPods out or putting them back makes iOS pause the video by itself,
  and PodSkipper took that as *you* pressing pause, so it paused the sound right after your AirPods
  had resumed it. Now it only listens to the video's own buttons while Picture in Picture is showing.
  I can't use real AirPods in the simulator, so the test fakes what iOS does (pauses the video behind
  the app's back) and checks the audio keeps playing.
- **Video is the full width of the screen**, on every phone size. The last build fitted it into the
  height left over, and on your phone that made it narrower. It looked right on my bigger simulator,
  and I didn't check a phone your size. The test now checks the width matches the screen. **Tapping
  the cover** in Audio mode switches to video, like Apple Podcasts.
- **Cooler and lighter.** I had the code checked against Apple's performance guidance and fixed what
  it found:
  - The transcript view was redrawing every line five times a second.
  - The scrolling title in the mini player ran thirty times a second even while paused.
  - The cut editor was rebuilding itself while a cut played.
  - Playback was re-sorting chapters and scanning every ad and silence five times a second.
  - Transcripts were being decoded on the screen's own thread (the one that draws the app).
  - The player's background kept animating while paused.

  All of that is gone.
- **Finding ads is faster** — it asks the on-device model up to three questions at once, with exactly
  the same answers. On my Mac a half-hour episode went from 3:39 to 2:30.
- **Something I tried for older transcripts and took back out.** Episodes transcribed before word
  timings were kept only know the time of each line, not each word. I tried splitting those lines into
  sentences with estimated times. On the two test episodes like that it made things worse (it lost
  most of two ads on Legion of Skanks and a pre-roll on Conan), so it isn't in this build. What would
  actually help those episodes is transcribing them again, which takes a few minutes each; I've left
  that for you to decide.
- **What I tried and threw away:** asking the model fewer questions. Every version I measured lost
  two or three correct cuts on your labelled episodes, so the only speed change is the parallel one.

## What changed in pass 16

- **The two round buttons at the top of the player are no longer cut off.** Your screenshot
  showed the real cause: the player's page was about 90 points taller than the screen on your
  iPhone 16 Pro, and it was centred, so the top of it (those buttons) went off the top edge. Every
  earlier "fix" added space above the buttons, which made the page taller still. Now the cover or
  video takes whatever room is left, nothing else can grow, and if anything ever does overflow it
  goes off the bottom, not the top. The Video / Audio switch moved up between the two buttons, which
  frees a row so the video stays the full width of the screen. A test now checks, in video and audio
  mode, playing and paused, that the buttons sit inside the screen.
- **Swipe down to leave full-screen video.** The picture follows your finger, shrinks a little and
  the black fades; let go past about an inch, or flick, and you're back in the player with a light
  tap. A small pull springs back. The down-arrow still works.
- **Settings → Diagnostics.** This is how the phone can tell us things without you having to
  describe them. It shows, for every episode the app processes, how long transcribing and finding ads
  took, how hot the phone was, and whether it was plugged in — and a "typical speed" line. iOS also
  sends the app its own reports (battery use, heat, hangs and crashes); those appear here about a day
  after you install. **Share diagnostics** makes one file: AirDrop it to the Mac and I can read the
  numbers directly.
- **Smoother animation on your phone.** The iPhone 16 Pro's screen can draw 120 times a second, but
  apps have to ask for that for their own animations. PodSkipper now asks.
- **Research, no code change: where ads come from.** A report in `.research/ad-detection-research.md`.
  The short version: on Stavvy's World, MSSP and Conan most ads — even the ones Stavros reads himself —
  are stitched into the file when you download it, and the podcast host also serves a copy without
  them. Comparing the two finds every stitched-in ad to within a fortieth of a second, with no AI. Legion
  of Skanks records its ads into the episode, so the AI is still needed there. None of this is in the
  app yet; it is the plan for a later pass, and it needs one test from your phone first.
- **Housekeeping.** The "Screenshots" job on GitHub had been timing out on every push for days; it
  now only runs when asked. The helper scripts I use are saved in the project instead of a scratch
  folder.

## What changed in pass 17 (the ad-finder pass)

This pass was about finding ads better and faster, and proving it with numbers before anything
reached the app.

- **Six test episodes instead of two.** Legion of Skanks 952 and 956, Conan "Joel McHale Returns"
  and MSSP 636 joined MSSP 633 and Stavvy's World #199. I labelled the four new ones by reading
  their transcripts line by line; they are marked "Claude-labelled" until your own corrections
  replace them (see "Export detection report" below). Every ad and plug in all six is now labelled,
  so the lab can say how many ads were found, how many were missed, how far off each edge was, and
  how many seconds of ads you'd still hear per hour.
- **The ad-free copy, now in the app.** Some hosts keep each episode as it was uploaded, without the
  ads they stitch in when you download it. From your home connection this works for Stavvy's World,
  Conan and Matt and Shane (not Legion of Skanks, whose host keeps no such copy). The app now
  compares about a hundred small pieces of that copy with your download — under 1 MB, a few
  seconds — and knows every stitched-in ad to a fortieth of a second, including the ones the hosts
  read themselves. It then doesn't bother the AI with those parts at all. On Stavvy's World that
  halved the AI's work and took the ads you'd hear from 17 seconds an hour to none. Settings →
  **Compare with the Ad-Free Copy** (on). Diagnostics shows, per episode, what it found.
- **Conan's end credits are credits now,** not an ad. They're skipped with the outro switch, as you
  asked; the SiriusXM offer at the very end goes with them.
- **Legion of Skanks' back-to-back reads are separate cuts** (PrizePicks, Brunt, IndiCloud), and a
  host read now starts where the host hands off ("let's take a quick moment and thank Ridge
  Wallet"), not a minute later at the promo code. On LoS 952 that cut the ads you'd hear from about
  three and a half minutes an hour to under a minute.
- **Funny reads are kept by default** (your 23 Sep decision). Straight reads are still skipped. Turning
  a keep switch on now takes effect on episodes already processed, not only new ones.
- **What Was Skipped says more:** "tour dates", "Patreon", "credits", "trailer", "inserted at download".
  And a new share button there, **Export detection report**, makes one file with the transcript,
  what the app cut and what you changed. AirDrop it to the Mac after you've fixed an episode by ear
  and it becomes a test episode labelled by you.
- **Diagnostics → Your corrections** counts how often you had to fix a cut: that's the measure of
  "rarely needs manual edits".
- **Older episodes catch up.** Each episode remembers which version of the ad finder processed it.
  When a newer one arrives, the app re-labels older episodes from their saved transcripts while the
  phone is plugged in — no re-downloading, no re-transcribing, and never touching a cut you edited.
- **Small fixes:** the speed buttons in the player are now full-size (44 points) and "Volume
  Normalization" no longer wraps in the ⋯ menu ("Normalize Volume").
- **Not done, on purpose:** the publisher's own transcript (Conan's Spreaker feed has one) was tried
  and isn't used yet — its edges were good but it lost the credits. Details are in
  `claude/DETECTION-AUDIT.md` §13.

## What changed in pass 18

- **Tested on your shows only.** The ad finder is now measured on eleven episodes of eight shows you
  follow: Stavvy's World, MSSP, Legion of Skanks, Your Mom's House, 2 Bears 1 Cave, Bad Friends, Theo
  Von and Whiskey Ginger, plus The Adam Friedland Show. Conan is gone; you don't follow it.
- **The app now recognises audio it has heard before.** A show's theme song, its closing music, a
  network promo, a produced ad that runs every week, a read recorded once and used twice: all of them
  are the *same recording* each time, and conversation never is. The app keeps a compact
  "fingerprint" of each show's last few episodes and finds those recordings to a fraction of a
  second, with no AI. It costs about five seconds of work per hour of audio.
- **Plugs and post-rolls.** Stretches where the hosts ask you to do several things (buy tickets, go
  to a website, come see a show, subscribe) are cut as self-promotion even when the AI thinks it's
  just talk. After a show's closing music, the ads tacked on at the very end are cut as a block.
- **Result on your shows:** ads you'd still hear went from about 73 seconds an hour to about 18;
  show accidentally skipped went from about 13 to 10 seconds an hour. Bad Friends, Theo, MSSP and
  Stavvy's are now under 10 seconds an hour. The worst left is 2 Bears (a commercial the hosts made
  themselves and play in the episode). Details: `claude/DETECTION-AUDIT.md` §14.
- **More ad-free copies:** Bad Friends and Theo Von have one too, so their added ads are cut exactly.
- **Tapping an episode opens its page,** as in Apple Podcasts: from a show, Up Next, search, charts
  and the store shelves. The play button still just plays. The episode's ⋯ menu has Share Episode…,
  Copy Link and Go to Show; a show's ⋯ has Share Show…, Copy Link, Remove Downloads and Unfollow
  Show; show pages list Hosts & Guests; the Library can sort by Recently Updated; episode notes keep
  their links.
- **Video for every episode that has one.** Apple's catalog lists the host's own video stream for each
  episode (Stavvy's #198 has one; the feed doesn't say so). The app now reads it on every refresh, so
  the Video label shows up without playing first, and pulling to refresh a show checks again. Apple's
  own copy of the stream is encrypted audio, so the app uses the host's, as Apple's website does.
- **Older episodes.** The same catalog lists episodes the feed has dropped; they're added to the show,
  as far back as Apple has them.
- **Processing when the screen locks.** Apple requires the app's "keep working in the background"
  request to be named a particular way, and the app's wasn't — the likely reason iOS gave it only
  ~30 seconds. It's named Apple's way now, stays open across a queue of episodes, waits and retries
  when iOS slows the AI down in the background, and if iOS still stops it, the answers the AI already
  gave are saved so nothing is asked twice. Only your phone can confirm this one.

## What changed in pass 19

**A job you start keeps going when the screen locks, or picks up where it stopped.** Here is what went wrong before. When you locked the phone, the app asked iOS for a "processing window". iOS then ran a second job next to yours. The two shared one progress bar, which is why Find Ads Again sat at 0 % on step 3. Now:
- Only one job runs at a time.
- Only a job you started asks iOS to carry on and shows on the Lock Screen. Getting Up Next ready never starts while the app is in the background.
- If iOS pauses your job anyway, the answers so far are already saved. It carries on by itself when you open PodSkipper, even after a restart of the app. The status screen says "Paused" and has a **Resume** button.

**A stuck step says so.** If a job makes no progress for two minutes while the app is open, its row, the activity bar, the status screen and the ⋯ menus say "No progress for 2 min" and offer **Restart**. Restart keeps the transcript and the answers so far.

**Settings → Diagnostics → Working in the background** records what iOS did with each job: whether it let the job carry on (and if not, why), when it stopped it, and how often it made the ad finder wait. After you've locked the phone during a job once or twice, share that file with me. Only your phone can show whether the fix works.

**Opening the app after an update is smoother.** The catch-up work (new episodes, back catalogues, re-checking older episodes with the new ad finder) is spread over the first minute instead of all running in the first second.

**Every episode offers the same actions everywhere.** The player's ⋯ now has the same list as an episode's row and page: Find Ads Again, What Was Skipped, Go to Show and the rest. Go to Show from the player closes it and opens the show.

**Tap a coloured mark on the timeline** and a glass tag says what it is (Ad, Promo, Intro…), whose ad, how long, and whether it's skipped.

**The ad finder, measured on your shows:** ads heard fell from 17.9 to 7.0 seconds per hour, and show wrongly skipped from 10.3 to 7.1. The biggest fix was 2 Bears' Mountain Dew commercial, which was heard for almost two minutes. It also now remembers the sound of ads it is sure of, from any of your shows, so the same spot on another show is recognised instantly. When you mark a cut "not an ad", it remembers that too.

## What changed in pass 19b

- **Phone calls.** When a call ends, the episode carries on by itself (Settings → Playback → Resume After Calls, on by default). If the sound stops for any other reason, the player now shows Play instead of pretending to play, so your headphones' button works.
- **A real line of jobs.** Press Find Ads on as many episodes as you like: each joins the line in the order you pressed, and pressing again doesn't add it twice. Every waiting episode says Waiting; its status sheet says its place in line. The box at the top says "2 of 5" and how many more are waiting. Any episode's ⋯ has Remove from Line (waiting) or Stop Finding Ads (running).
- **Honest progress.** The percentage and time left now follow how long each step really takes on your phone: finding ads is the long part, so the bar no longer races to 60 % and then sits.
- **Library grid.** Tapping a cover opens that show, and Back comes straight back.
- **Cooler and steadier.** The moving background holds still while the phone is warm or working, and the app no longer keeps transcripts inside the episode list, which is what froze it once while you scrolled.
- **Results you can send.** Settings → Diagnostics → Prepare ad-finding results, then Share: one file with what was cut in each episode and why. Send it with the diagnostics file and the next pass checks accuracy from it instead of re-running episodes on the Mac.

## One last honest thought

Skipper on the App Store is $9.99 once and works today. This is a project. You'll spend a few evenings on it and you'll hit snags I haven't predicted.

The reasons to do it anyway are real: you own it, nothing about your listening leaves your phone, you can tune the ad detection yourself, and you get the Apple Podcasts feed that no app on the store will give you. Just go in knowing which one you're buying.
