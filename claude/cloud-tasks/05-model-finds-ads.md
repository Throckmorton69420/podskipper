# Cloud task 05 — The on-device model finds the ads

Branch: `cloud/model-finds-ads`. Read `CLAUDE.md` first. **Start only after PR #4 (`cloud/on-device-model`) is merged into `main`**; branch from the new `main`.

**For this task only, you may edit** `Services/ProcessingPipeline.swift`, `Services/SegmentDetector.swift`, `Services/AdDetector.swift`, `Services/NotificationService.swift`, `Views/ActivityView.swift`, `Views/DiagnosticsView.swift`, `Services/DetectionReport.swift` and the results-export code (find it: Settings → Diagnostics → results export), plus `Models/Models.swift`. The Mac session will not touch these while you work. Still off-limits: `Tools/`, `Resources/Detection/`, `.github/`, `project.yml`.

## Background you need

- Today `detectAndSave(...)` in `ProcessingPipeline.swift` (~line 982) runs PodSkipper's small "reader" (`SentenceTagger`, a model trained on only 17 episodes) through `detector.detectSentences(...)` and saves `detection.segments` as `AdSegment`s. It runs in seconds, locked or not. It stays, but only as the **fallback** and as the **fast first pass**.
- PR #4 added `LocalJudge` (Ternary Bonsai 8B by default) with `judge(lines:show:title:notes:evidence:only:progress:)` → `[JudgedPart]` (first/last line, label, sponsor, funny, confidence, why), and `ModelStore` (download state).
- Shashank's rules for what gets cut (settled — do not ask him): paid ads, host-read ads, network promos → cut; self-promo and guest plugs (tour dates, specials, Patreon, Netflix/YouTube specials, even mid-conversation) → cut; intro/outro/credits follow the existing switches; a recurring bit, a joke/mock ad, or ordinary talk about a brand → keep. Funny host reads are kept by default (existing "keep funny reads" switch). On comedic shows (e.g. CumTown), only plain non-comedic reads are cut when the model is confident.

## What to build

1. **Setting** "Find ads with": *On-device model* (default once `ModelStore` says ready) / *PodSkipper reader*. If the model isn't downloaded, the reader is used and Activity says why.
2. **The flow in `detectAndSave`** (keep the function's other behaviour — kept reviewed cuts, sponsors memory, checkpoint, versioning):
   a. Run the reader exactly as now → `readerAds`. Save them on the episode as JSON (`readerSegmentsData`, new optional field) **always**, so both answers exist for comparison.
   b. If the model is the chosen finder and ready:
      - **App active (`UIApplication.shared.applicationState == .active`)** → full read: `judge(lines: all transcript lines, …)`.
      - **In the background / locked** → fast read: `only:` = line ranges covering each reader cut ±90 s, the first and last 180 s, every «I»/«R» evidence span ±30 s, and SponsorBlock `hints` ±60 s (already computed in `detectAndSave`). Mark the episode `needsFullModelRead = true` (new field).
      - Pass the show's past corrections (`episode.podcast?.corrections`, newest 20) as a short "This listener's past corrections on this show" block in the prompt (text excerpt + keep/cut + label). Keep the rules text itself unchanged.
   c. **Retries:** up to 3 attempts (`.notEnoughMemory`, parse failure, `.needsForeground`, any thrown error), with a short wait between. If all fail: save the **reader's** cuts, set `modelPending = true`, and send a notification: title "Ads found by the reader for now", body "<episode> — the on-device model couldn't run while the phone was locked. It will re-check when you open PodSkipper.", with two actions: **Keep reader's cuts** (clears `modelPending`) and **Re-check when I open the app** (default). Register the category and handle the actions in the app's existing `UNUserNotificationCenterDelegate` (find it).
   d. **Turning model parts into cuts:** map labels → kinds exactly like `KIND` in `Tools/DetectionLab/gemini_bench.py` (PAID_AD/HOST_READ_AD → ad, NETWORK_PROMO → crossPromo, SELF_PROMO/GUEST_PLUG → selfPromo, INTRO/OUTRO/CREDITS → their kinds, RECURRING_SEGMENT/MOCK_AD → keep). Start/end = the first line's start and last line's end (after the engine's quote anchoring), then the existing padding. `HOST_READ_AD` → delivery "host", `PAID_AD` → "produced"; `funny` → `isComedyBit`. Evidence text: "On-device model: <why>". Spans the ad-free comparison proved were inserted (`inserted`) are **always** cut even if the model missed them. Where the model says RECURRING_SEGMENT/MOCK_AD, no reader cut survives there. Otherwise the model's parts replace the reader's cuts.
3. **Catching up:** when the app becomes active, episodes with `needsFullModelRead` or `modelPending` are re-read in full by the model, one at a time, newest first, only while the app stays active; their unreviewed cuts are replaced. Show this in Activity ("Checking 2 episodes read while locked").
4. **Activity:** the current step says what's happening in plain words: "Reading with the on-device model — part 3 of 7 (82 words/s)", "Fast check of suspicious parts (phone locked)", "Retrying (2 of 3)", "Using the reader for now". No fake percentages; progress = windows done.
5. **Diagnostics timings** per episode: finder used, mode (full/fast), windows, seconds, tokens/s, attempts, failure reason; one background-log line per job ("Ads found in 94 s by the on-device model (full read)"). Results export: include both `segments` (final) and `readerSegments`.
6. Don't bump `AdDetector.version` in a way that makes every old episode re-run through the model. Add a separate `modelVersion`; old episodes are re-read by the model only when he taps Find Ads Again, or (at most 5 per day) while the app is active **and** charging.

## Done means

PR open from `cloud/model-finds-ads`, CI green with zero warnings. PR description with the exact phone test: (1) app open, Find Ads on one episode, watch Activity, note the time; (2) Find Ads on another, lock at once, wait; check the notification/log and the fast-read result; (3) open the app and see it catch up; (4) send Diagnostics + results export.
