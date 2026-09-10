# Building the IPA, and publishing a feed from your phone

Two separate things. The build is straightforward. The feed needs one design change from what you described, and it's worth understanding why.

---

## Part 1 — Building the IPA without a Mac

I can't compile it here; there's no macOS in this container. But you don't need a Mac either. GitHub's `macos-26` runners are generally available and ship Xcode 26.5/26.6, which is exactly the SDK this app needs.

`.github/workflows/build-ipa.yml` builds with `CODE_SIGNING_ALLOWED=NO`, packages the `.app` into `Payload/` and zips it as `PodSkipper.ipa`. Ksign applies your own certificate on the phone, so CI never touches an Apple account, a `.p12`, or a provisioning profile.

`project.yml` is an XcodeGen spec. The runner generates the `.xcodeproj` from it, which means there is no Xcode project in the repo and you never need to open Xcode. Bundle ID, version, and background modes all live in that one file.

**Setup, all from Safari on your phone:**

1. Create a repo (private is fine) and upload this folder. GitHub's web editor handles this, or push from a Working Copy-style client.
2. Edit `project.yml`: change `com.yourname` to your own reverse-domain prefix in both `bundleIdPrefix` and `PRODUCT_BUNDLE_IDENTIFIER`.
3. Edit `BGTaskSchedulerPermittedIdentifiers` in the same file and `ProcessingPipeline.backgroundTaskID` in the Swift so they match exactly. Mismatched, background processing silently never runs.
4. Actions tab → **Build unsigned IPA** → **Run workflow**.
5. When it's green, go to Releases → `latest` → tap `PodSkipper.ipa`. It downloads straight into Files.
6. Ksign → Files → import the IPA → sign with your certificate → install.

**One budget note:** macOS runners bill at a 10x multiplier, so a free private repo's 2,000 minutes is really about 200 macOS minutes a month. A build is a few minutes, so you get maybe 20–40 builds. Public repos don't consume the quota at all — and there's nothing secret in this code.

**On the certificate:** you already know this territory from your DNS work, so briefly — a shared enterprise cert goes down for everyone when Apple revokes it, which is why the anti-revoke DNS profiles exist. Your own paid developer cert is the only version that doesn't randomly die. Your call.

---

## Part 2 — Why the feed can't live on the phone

Your instinct is right, but one piece has to move.

The problem is *when* Apple Podcasts fetches. It refreshes feeds on its own schedule, frequently while your phone is asleep and PodSkipper is suspended. An HTTP server inside a sideloaded app only exists while that app is running, and iOS suspends background apps within seconds unless they're actively playing audio. Apple Podcasts would follow the show, then quietly fail every refresh and download from then on. On top of that, plain `http://` feed URLs fail silently in Apple Podcasts — tapping Follow just closes the sheet — and getting a trusted certificate for a localhost server is its own project.

So: **your phone becomes the worker, and Cloudflare R2 becomes the server.**

```
Phone (PodSkipper)                          R2 bucket (always up)
─────────────────────                       ─────────────────────
subscribe to feeds
download episode
transcribe on-device      ──── nothing leaves the phone ────
detect ads on-device
cut the audio (AVFoundation)
upload cut .m4a          ─────────────────▶  audio/show/xxx.m4a
generate RSS
upload feed.xml          ─────────────────▶  feeds/show.xml
                                                     │
                                    Apple Podcasts ◀──┘
                                    (CarPlay, Watch, HomePod, iPad)
```

That's still your VPS plan — you've just replaced the rented server's *compute* with your phone, and kept a dumb static host for the *serving* part. The transcription and ad detection never leave the device, which was the point.

**Cost: $0.** R2's free tier is 10 GB of storage with no egress charge, and you already have the Cloudflare account and the domain.

**Worth asking yourself once:** if PodSkipper can already play episodes ad-free, why publish a feed at all? The honest answer is CarPlay, Apple Watch, HomePod, iPad, and cross-device position sync — none of which a sideloaded app gives you. If you only ever listen on your phone, skip Part 2 entirely and save yourself the upload bandwidth.

---

## Part 3 — Setting up R2

1. `dash.cloudflare.com` → **R2** → **Create bucket**. Name it `podcasts`. Location hint: North America East.
2. Bucket → **Settings** → **Public access** → **Connect Domain** → `pods.ha50e76.win`. Cloudflare creates the DNS record and the TLS certificate. This is the one place you *want* the orange cloud, because it's R2's own integration rather than a proxy in front of your origin.
3. R2 overview → **Manage API Tokens** → **Create API Token** → permission **Object Read & Write**, scoped to that bucket. Copy the Access Key ID, the Secret Access Key, and your Account ID. The secret is shown once.
4. In PodSkipper → Settings → R2, paste all four plus `https://pods.ha50e76.win`. They go into the Keychain, not into UserDefaults or the database.
5. Process one episode, tap **Publish**, then open `https://pods.ha50e76.win/feeds/<slug>.xml` in Safari. Raw XML means it worked.
6. Apple Podcasts → **Library** → **⋯** → **Follow a Show by URL** → paste that feed URL.

The feed carries `<itunes:block>Yes</itunes:block>` so it stays out of Apple's directory if it's ever crawled. It's your private copy, not a republication.

---

## Part 4 — Automation, and what iOS will actually let you do

This is the part where I'd rather be accurate than encouraging.

**iOS will not let a headless Shortcut transcribe an hour of audio.** A background App Intent gets a short execution budget and then gets killed. So the app exposes two intents that do different jobs:

| Intent | Opens the app? | What it does |
|---|---|---|
| **Refresh feeds** | No | Checks shows for new episodes, queues them, asks iOS to schedule processing. Light enough to run headless. |
| **Process and publish** | Yes | The real work. Needs foreground runtime. |

**The engine is `BGProcessingTask`, not Shortcuts.** The app registers a background processing task that iOS runs opportunistically — in practice, overnight while charging on Wi-Fi, which is exactly when you want an hour of transcription happening. That runs whether or not you set up any automation.

**The automations actually worth building:**

*Nightly refresh (reliable, headless):*
Shortcuts → Automation → **Time of Day**, 2:00 AM, **Run Immediately** with Ask Before Running off → Action: **Refresh feeds**. Queues new episodes and nudges the scheduler.

*Process on plug-in (reliable, gets real runtime):*
Shortcuts → Automation → **Charger** → **Is Connected** → **Run Immediately** → Action: **Process and publish**. The app opens, works while you're not using the phone, and publishes. This is the one that consistently completes.

*Manual (most reliable of all):*
Put **Process and publish** on your Home Screen. Tap it while you're making coffee.

**Set expectations honestly:** an hour-long episode is a download, a full on-device transcription, dozens of language-model calls, an audio re-export, and a ~50 MB upload. That's a plugged-in, overnight activity, not something that finishes while you wait. If you subscribe to six daily shows, your phone will be doing this every night and you'll feel it in battery and thermals. Two or three weekly shows is comfortable.

---

## What's new in the code

| File | What it does |
|---|---|
| `project.yml` | XcodeGen spec — no `.xcodeproj` needed, no Xcode needed |
| `.github/workflows/build-ipa.yml` | Builds the unsigned IPA on `macos-26`, publishes it as a release |
| `Services/AudioCutter.swift` | Physically removes ad ranges with `AVMutableComposition`. No ffmpeg — AVFoundation stitches time ranges natively, which is why this is feasible on a phone at all. |
| `Services/R2Uploader.swift` | S3 SigV4 signing in CryptoKit, streaming file uploads, Keychain credential storage |
| `Services/FeedPublisher.swift` | Cuts, uploads, generates RSS, only re-uploads when the detected ads actually changed |
| `Services/Intents.swift` | The two App Intents above, plus a per-show publish intent |

`Models.swift` gained `publishedURL`, `publishedByteCount`, `publishedDuration`, and `publishedAdVersion` on `Episode`, plus `publishedFeedURL` and `lastPublished` on `Podcast`.

**Still not compiled.** Same caveat as before, plus two new soft spots: the exact `AVAssetExportSession.export(to:as:)` signature, and whether R2 is happy with how I'm ordering canonical headers in SigV4. If uploads come back 403 with `SignatureDoesNotMatch`, that's the function to stare at — `signedRequest` in `R2Uploader.swift`. Everything else is ordinary Swift.

**One piece I didn't write:** the Settings UI for entering R2 credentials. `R2Credentials.save(_:)` and `.load()` are ready; you need a form with five text fields wired to them. Twenty minutes, and I left it out rather than guess at how you'd want it laid out.
