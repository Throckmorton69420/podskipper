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

**Add a show:**

1. **Library** tab → **+**.
2. Paste the show's RSS feed address. To find one, search the web for `"<show name>" RSS feed`.
3. Tap **Add**.

**Process an episode:**

4. Tap the show, then tap **Find ads** on an episode.
5. Leave the app open. The first episode is slow — your phone downloads a speech model of a few hundred megabytes first. Later episodes are much faster.
6. When it says something like "3 ads, 4 min cut", it's done.

**Listen:**

7. Tap **Play**. The orange bars on the timeline are the ads. The app jumps over them.
8. If it cuts something it shouldn't have, tap **Undo skip**.

**Publish to Apple Podcasts (if you did Part 4):**

9. On the show's page, tap **Publish ad-free feed**. This chops the ads out for real and uploads the result. A 60-minute episode takes a few minutes.
10. When it finishes, tap **Copy address**.
11. Open the real **Apple Podcasts** app.
12. Tap **Library** at the bottom.
13. Tap the **•••** in the top right.
14. Tap **Follow a Show by URL**.
15. Paste, tap **Follow**.

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
