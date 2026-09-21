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

## One last honest thought

Skipper on the App Store is $9.99 once and works today. This is a project. You'll spend a few evenings on it and you'll hit snags I haven't predicted.

The reasons to do it anyway are real: you own it, nothing about your listening leaves your phone, you can tune the ad detection yourself, and you get the Apple Podcasts feed that no app on the store will give you. Just go in knowing which one you're buying.
