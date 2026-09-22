# Detection, review and video: audit (pass 13, before any rewrite)

Written 22 September 2026, at commit 8b338bf. Everything below was checked in the code or measured
in the detection lab (`Tools/DetectionLab`) on real downloads. Nothing here is from memory.

## 0. The regression episode, measured

Matt and Shane's Secret Podcast, Ep 633 "Submerged in Silence" (Megaphone feed, index 3). Lab copy:
4,318 s, transcribed into 1,885 lines (about 2.3 s each). Shashank's copy is about 125 s shorter.
Happy Scribe's copy has no stitched-in ads at all and ends at 1:07:17. **Megaphone inserts different
ads into every download**, so no timestamp is portable between copies, and the regression file
anchors every region to words instead (`Tools/DetectionLab/regression/mssp633.json`).

What the transcript shows (lab copy times):

| Region | Lab copy | Shashank's copy | What it actually is |
|---|---|---|---|
| A | 11:04–11:23 | 11:03–11:23 | conversation (Call of Duty, "Durka Durkistan") |
| A | 11:25–13:00 | 11:24–11:44 | **stitched-in ad break**: Tremfaya 60 s + host-read Vuori 35 s here; one 20 s ad in his copy |
| A | 13:02– | 11:45– | conversation ("What's he doing back there?") |
| B | –30:46 | –29:26 | conversation (the French, "They fucking do") |
| B | 30:47–30:49 | ~29:27 | "Here we go." — the lead-in |
| B | 30:49–32:00 | 29:27– | **host-read BlueChew** ad, ending on the legal line |
| B | 32:01–32:27 | –31:05 | the hosts riffing on BlueChew (Shashank counts this as part of the ad) |
| B | 32:28–33:39 | 31:06–32:30 | **self-promotion**: Matt's tour dates, a Gaffigan aside, Shane's dates, "Enjoy the show" |
| C | 1:10:53–1:11:02 | 1:07:38–1:08:14 | "I've rotted my brain…", "Well, I think we've done it. **Let's do the Patreon. Goodbye everybody.**" — the sign-off |
| D | 1:11:03–1:11:13 | 1:08:17– | "Watch new episodes of Matt and Shane's Secret Podcast on Spotify. Do it." — a network plug |
| D | 1:11:14–1:11:57 | –1:09:53 | **stitched-in post-roll ads** (Grubhub, GEICO here) |

So two of Shashank's labels are finer than stated: A's "ad" is a whole insertion slot whose content varies,
and D's "outro" is a 10-second plug followed by stitched-in ads.

### What the current detector did on the lab copy

```
[ad] 0:11:23–0:13:16   Tremfaya + Vuori fused, end 16 s into conversation
[ad] 0:30:37–0:33:36   starts 12 s into the conversation; swallows the tour dates as an "ad"
[ad] 0:45:04–0:47:55   (not a reference case) starts 24 s into conversation
[outro] 1:10:50–1:10:59  conversation labelled outro
[ad] 1:10:59–1:11:57   "Let's do the Patreon. Goodbye everybody." + Spotify plug + ads as one ad
```

Regression score (`lab.sh score mssp633`): **8 of 10 regions fail.** These are the same mistakes
Shashank reported on his copy, with different timings.

### Second reference: Stavvy's World #199 (`regression/stav199.json`)

The current detector's cuts and what the transcript shows:

| Cut | What's there | Problem |
|---|---|---|
| 10:17–11:16 "ad (patreon)" | a joke: "that's a reality show I'd pay for… coming soon on Are You Garbage Patreon" | the word "patreon" alone |
| 14:35–17:28 | BlueChew + Visible host reads 15:14–17:16 | starts 37 s into conversation, ends 11 s into it |
| 44:10–45:49 | stitched-in Quo + Wonder 44:10–45:32 | ends 16 s into conversation |
| 1:15:20–1:17:07 | Twisted Tea host read 1:15:13–1:16:23, then a SiriusXM plug to 1:16:52, then a listener's hotline call | starts 7 s late; fuses the plug; ends 9 s into the call |
| 1:33:30–1:34:01 "ad (IDF)" | a joke: "That's Raytheon, folks. That's our new ad… Are you garbage sponsored by the IDF?" | the word "sponsor" |

Baseline: **9 of 9 regions fail.** The same causes as on MSSP 633.

**SponsorBlock versus the transcript.** For this episode's YouTube upload, SponsorBlock has two sponsor segments (0 votes):

- 41:09–41:56 in the video is the Quo read, at 44:10 in the feed audio (+181 s).
- 1:11:31–1:12:43 in the video is the Twisted Tea read, at 1:15:13 in the feed audio (+222 s).

The offset grows because the feed audio has stitched-in ads the video doesn't. SponsorBlock has nothing for BlueChew or Visible.

What separates the Twisted Tea read from the conversation next to it:

- **Before:** "Good luck, sister. Let us know if you…" is the hosts talking to each other and to a caller.
- **The read:** "Sometimes the best plan is having no plan at all. Get some friends together…" is generic second-person advice. The product name then repeats, followed by product attributes ("5% alcohol… real brewed tea… no carbonation"), a call to action ("Grab a refreshing Twisted Tea today"), and legal copy ("must be 21 plus. Please drink responsibly").
- **After:** the next voice is a different programme entirely (a SiriusXM plug), then the caller's voicemail.

The read has no URL, no code and no "sponsor", so today's keyword pre-filter only reached it by accident. Those features — a change of addressee, product-name repetition, attributes, call to action, legal copy, and the jump back — are what the sentence-level labeller should be told to look for.

## 1. Why: where each mistake comes from

| # | Cause | Where | Which example |
|---|---|---|---|
| R1 | **The unit of decision is a 45-second window, then a ≥12 s / ≥25-word "piece".** A window that holds a transition is labelled as a whole, and an edge can only land where a piece ends. | `TranscriptionService.windows(45, 10)`, `AdDetector.pieces` | A (16 s over), B (12 s early), D |
| R2 | **Word timings are thrown away.** SpeechTranscriber gives a time for every word (`audioTimeRange` on each run); only each result's first and last are kept. The finest possible boundary is a whole recognizer line. | `TranscriptionService` lines 85–95 | all edges |
| R3 | **Keywords override the model.** `strongCues` includes "patreon", "merch", ".com", "app store", "bonus episode". Any of them sets `asking = true`, which cancels both rules that would drop a window the model called conversation. | `AdDetector.detect` 270–285, 339 | C: "Let's do the Patreon" |
| R4 | **`anchorToCues` pulls a start up to 45 s earlier** to any line with a cue word, and pushes an end up to 30 s later. | `AdDetector.anchorToCues` | B early start |
| R5 | **The labels are too coarse and one-per-window.** The model is asked for advertisement / selfPromotion / crossPromotion / content per window. It has no labels for sign-off, lead-in, transition, riff-on-the-ad, network plug or tour dates, and it called Matt's tour dates `advertisement` with sponsor "mattmcusker". | `windowInstructions` | B self-promo; C |
| R6 | **Adjacent cuts of the same kind are fused** (gap ≤ 12 s, then ≤ 6 s). Two different ads become one; an ad and a mislabelled self-promo become one 3-minute ad. | `AdDetector.merge` | A, B |
| R7 | **Intro and outro are found by a separate walk** that starts where the promos stop, at piece granularity, trusting any piece with a closing word ("thank", "bye"). | `closing`, `walkBookend` | D |
| R8 | **Nothing uses the audio at an insertion point.** Stitched-in ads are mastered differently and usually start with a level jump and a hard cut; only silences (±2.5 s snapping) are used, after the fact. | `AudioAnalyzer`, `snap` | A, D |
| R9 | **Confidence is the model's own number** (it says 90–95 almost always), adjusted by fixed penalties. There is no boundary confidence. | `detect` | review UI can't say what to check |
| R10 | **Nothing is learnt from boundaries.** Corrections store only the passage text and a verdict; edits to start/end record nothing. | `Episode.apply`, `DetectionCorrection` | all |

The model is not the main problem, though it isn't blameless. It called Matt's tour dates
an advertisement, because "selfPromotion" as described didn't obviously cover tour dates
read inside the show. Most of the damage, though, comes from the pipeline around it. The pipeline
asks about the wrong unit (45 s), overrides the model with keywords, then fuses what the model
returned.

A limit worth stating plainly: Apple's on-device model is small (about 3 billion parameters,
4,096-token context). The open-source MinusPod benchmark found 7–8B models close to useless at
whole-window ad finding, and the best cloud models at about 0.8 F1. A small model can't be the whole
detector. It can be a good judge of one short, well-framed question at a time, which is what the lab
found in pass 8, and the structure has to come from the pipeline.

## 2. Review ("What Was Skipped"), audited

- **No original is kept.** `AdSegment` has start, end, sponsor, confidence, userVerdict, kindRaw,
  deliveryRaw, isComedyBit. Trimming overwrites `start`/`end` in place (`SkipReportView.commitEdges`).
  Coming back, an edited cut is indistinguishable from detector output. That is the bug Shashank saw.
- **Re-processing throws edits away.** The pipeline deletes every segment not thumbed down and writes
  fresh detector output (`ProcessingPipeline` 343–369). Confirmed and edited cuts are lost.
- **Thumbs-down is not required before editing.** The trimmer, play button, transcript and thumbs are
  all shown whenever a row is open.
- **Edits are not feedback.** Only the thumbs call `Episode.apply`. Trimming, and the things the UI
  can't do at all (delete a cut, change its type, add a missed one), record nothing. `kind` has a
  setter the UI never uses.
- **Trimming:** two handles over a window of the cut ± max(6 s, 35%). Precision is roughly span ÷ 350 pt
  (about a quarter of a second per point on a 90 s window). There is no zoom, no nudge and no snapping.
  The hold-to-commit path `beginTension` is defined and never called.
- **Audition always starts from the cut's start** (`startPreview` seeks to the lower bound) and ends
  itself if the playhead leaves the range. There is no independent playhead, no tap-to-seek on the
  strip, and no tap-to-seek in the transcript. The transcript highlights only while previewing.
- **Moving a handle while previewing breaks the preview:** `previewing` compares the range within
  0.5 s, so the playhead disappears and the button reads "play" while audio carries on.
- **No undo.** Every drag end and every thumb saves immediately.
- **Video:** the review uses the same episode timebase as the player, so it would work with video,
  but the picture is never shown on this page.

## 3. Player, timeline and transcript

- `PlayerEngine` owns one clock (`currentTime`, 200 ms tick), in seconds of the **downloaded audio file**.
  Transcript, silences, found ads and the video picture (`VideoSync`) all use that clock, so the shared
  timeline Shashank describes already exists in outline; it is the file's own timebase. What's missing:
  - word-level times (R2);
  - a way to express a moment *independently of a download*, which learning and SponsorBlock-style
    external labels need, because inserted ads move everything;
  - a second, independent cursor for auditioning (§2).
- Skipping is seeking: `adRanges` built from `AdSegment`s, per-kind toggles resolved episode → show → default.

## 4. Video

- Parsing, HLS playback and Audio/Video switching on one clock were built in earlier passes; pass 12
  added namespace-by-URI and best-alternate selection. `Episode.videoURL` is a single optional URL:
  there is no representation of *which* source it is (RSS HLS / file / YouTube / other).
- **Stavvy's World #199** (Simplecast, feed `feeds.simplecast.com/Fa0PP4fl`):
  1. The feed has 400 items, the Podcasting 2.0 namespace declared, and **no `alternateEnclosure` and no
     video enclosure** on any item. The #199 enclosure is `audio/mpeg`, 1:34:42.
  2. The iTunes lookup API also says `episodeContentType: audio`.
  3. **Apple's public episode page** (`podcasts.apple.com/…?i=1000790890075`) embeds, in its page data,
     `mediaKinds: ["video"]` and an HLS URL on **Simplecast's own CDN**:
     `siriusxmpartners.simplecastvideo.com/prod/media/video/transcoded/hls/…/apple/podcasts/…/main.m3u8?isSgai=true…`.
     It opens with no login and no encryption. The variant playlist totals **5,682.9 s against the feed audio's 5,682 s**,
     with no interstitial or cue markers today. So it lines up with the RSS audio second for second.
     A second URL on Apple's own domain (`play.itunes.apple.com/…/hls/playlist.m3u8`) is Apple's.
     It was not touched.
  4. YouTube has the full episode ("Stavvy's World #199 - Are You Garbage? | Full Episode", video
     `onhpg7I7vh4`).
  5. The relationship can be established reliably through Apple's episode id, which EpisodeLink already
     resolves from the feed guid/title.
  6. Caveats on (3): the path is marked for Apple Podcasts; `isSgai=true` means the host can add
     server-guided ad interstitials to it later (VideoSync would then refuse it as mismatched); reading it
     depends on Apple's web page, as New and Search already do. **Whether to use it is Shashank's call.**
- **YouTube fallback is broken today.** `youtube.com/feeds/videos.xml` returns 404 for every channel
  and playlist tried (22 Sep 2026), including Google's own. It has been intermittent before (RSS-Bridge
  #2113, n8n forum). The channel's public `/videos` page still lists uploads (and more than 15 of them,
  with durations), so it is a workable second source.

## 5. External evidence

- **SponsorBlock** (`sponsor.ajay.app`, hash-prefix API, CC BY-NC-SA 4.0): YouTube only. It has
  labels for Stavvy's World full episodes (#199: sponsor 41:09–41:56 and 1:11:31–1:12:43, video
  time; 0 votes). Its category definitions are the best-considered public taxonomy: *sponsor* = paid,
  unrelated to the creator; *selfpromo* = the creator's own things (merch, Patreon, own shows);
  *interaction* = like/subscribe reminders; *outro* = endcards/credits. Its boundary rule includes
  segues. Useful as (a) the taxonomy, (b) per-episode hints for shows with a YouTube upload, mapped to
  audio time with the inserted-ads mapping, and (c) offline validation. **Not** as training data
  shipped in the app (ShareAlike). There is no official dump download now.
- **No public podcast-ad dataset with transcripts is available.** Spotify's (TREC 2020) is withdrawn;
  its EACL 2021 paper remains the best benchmark (sentence-level BERT, F1 0.77; temporal smoothing
  +2 points).
- **Techniques with evidence:** sentence-level labelling followed by sequence smoothing; loudness jumps
  at insertion points; fingerprinting ads that repeat verbatim across episodes (97.5% in one study);
  per-show jingle snapping; diffing against a publisher transcript where one exists (Apple drops
  stitched-in portions from publisher transcripts, so the diff shows where inserted ads are).
- **Happy Scribe and Podscribe** hold transcripts and sponsor data for this show; neither is open data.

## 6. What this means for the architecture

The current architecture limits accuracy in three places, and patching thresholds won't fix them:

1. **Granularity.** 45 s windows and 12 s pieces can't produce 20 s ads with 1 s edges. The unit has
   to be the sentence, with word times kept.
2. **Classification is independent per window, then fused.** A sequence model is needed: each
   sentence gets a label in the context of its neighbours, and the labels are smoothed so that
   `conversation → lead-in → ad → riff → self-promo → conversation` comes out as that structure.
3. **Storage.** One mutable `AdSegment` per cut can't hold original, corrected and locked, and the
   pipeline's delete-and-replace destroys them. The data model needs to change before the UI can.

See §7 for the proposed changes.

## 7. Proposed changes (smallest set that does it properly)

**P1 — One timeline, with words.** Keep word times from SpeechTranscriber. Re-segment into sentences.
Store both. Everything below addresses moments as (seconds in this file) *and* (sentence index +
the sentence's words), so a correction can be re-found in another download.

**P2 — Detection as a pipeline of stages.**
1. *Candidates* (cheap, permissive): cue phrases, known sponsors and learnt sponsor text, show-notes
   sponsors, loudness jumps and hard cuts from `AudioAnalyzer`, long silences, publisher chapters titled
   Ad/Sponsor, SponsorBlock hints when the show has a YouTube upload, and repeats of audio seen in earlier
   episodes.
2. *Sentence labelling in context*: for each candidate region ± 60 s, the model labels numbered
   sentences in small batches with the fuller taxonomy (advertisement, self-promotion, membership/Patreon,
   merch, network/cross promotion, interaction, intro, outro/sign-off, credits, trailer, transition,
   content). Keywords become *features* the model is told about, never overrides. This format must be
   proven in the lab first: pass 8 found the model poor at pointing at a line number, and labelling is
   a different task.
3. *Sequence smoothing*: a small Viterbi pass over the sentence labels with transition costs, e.g. ad→ad
   cheap, content→ad expensive unless there is a cue, and ad→self-promo allowed without passing through
   content. This produces spans.
4. *Boundary refinement*: each span edge moves to the best word boundary within a few seconds, using
   word times, silences and level jumps. The result is a boundary with its own confidence.
5. *Confidence*: class confidence from the model's agreement across overlapping batches; start/end
   confidence from how sharp the boundary evidence is.

**P3 — Storage: original, corrected, locked.** A `SkipSegment` model:

- `detected`: kind, start/end, confidence, boundary confidences, evidence — never changed;
- `corrected`: optional kind and start/end;
- `status`: unreviewed / confirmed / corrected / rejected / added / locked;
- `effective` = corrected ?? detected.

Re-processing replaces only unreviewed segments. Locked and corrected ones are kept and win.
The existing `AdSegment` is migrated.

**P4 — Feedback from every action.** Thumbs, boundary edits, type changes, deletions and additions
each file a `Correction` holding the predicted span, the corrected span, the words at both edges and
the kinds. These feed (a) the show's worked examples, (b) the feedback memory, (c) learnt lead-in and
lead-out phrases per show ("Here we go", "Enjoy the show"), and (d) the regression set.

**P5 — Review editor, rebuilt.**

- A zoomed strip for the cut, with two edge handles and a separate playhead.
- Play and pause loop within the selection, starting from the playhead, not the start.
- Dragging a handle scrubs the audio at that edge. The strip zooms in as the finger slows, as in
  Photos and Voice Memos.
- Nudge buttons of ±0.1 s and ±1 s. Edges snap to word starts and ends.
- Tap a transcript line to move the playhead there. The line being played is highlighted.
- The original is drawn ghosted under the correction.
- Status is shown as Edited, Confirmed or Locked, and there is undo.
- The same view shows the picture for video episodes.

**P6 — Video source resolver.** `Episode.videoSources: [VideoSource]` with kind (rssHLS, rssFile,
publicHLS, youtube), URL, provider and alignment (same / mapped / unknown). The resolver tries them in
Shashank's order. YouTube discovery moves to the channel page, because the feed is down. The
Apple-page-linked host HLS is included only if Shashank decides so.

**P7 — Regression suite in the lab.** Word-anchored fixtures (`regression/*.json`), `lab.sh score`,
more episodes added from every correction worth keeping. Baseline recorded: MSSP 633, 8 of 10 failing.

Order: P1 → P2 in the lab against P7 until MSSP 633 passes and the older lab episodes don't regress →
P3 + P4 → P5 → P6. P2 is the uncertain part; the rest is known work.

## 8. What was built (pass 13, second half)

P1 and P2 are built and are what the app now runs. `Services/SegmentDetector.swift` replaces the
window detector in `ProcessingPipeline`. The old `AdDetector.detect` stays in the file for the lab's
`detect` command, which the new detector is compared against.

**Word times (P1).** `TranscriptSegment.words` keeps every word's own time from SpeechTranscriber,
and `TimedLine.words` stores them. A transcript made before this pass has no word times: it still
works, but it cuts at line edges.

**The stages (P2), in order:**

1. *Sentences*, rebuilt from the word times.
2. *Screening*: the old 45 s window question, used only to decide where to look. On both reference
   episodes it found every break; it was only ever wrong about edges and kinds.
3. *Look ranges*: every hit ± 60 s, every strong-cue sentence ± 30 s, the first 2 minutes and the
   last 3.
4. *Sentence labels*: numbered batches of 12 sentences, stepping by 6, so every sentence is labelled
   twice. The letters are C, A, S, N, I and O.
5. *Viterbi smoothing* with transition costs. Opening is only allowed before 4:00, and closing only
   in the last 6 minutes.
6. *Spans*: split wherever a new ad opens ("brought to you by…").
7. *Fragment grouping*: a tour-date list labels as one-second pieces of three different kinds. A
   stray line is never grouped into a full ad read.
8. *Verification*: each span is read whole with context, using the section question. That answer
   decides the kind unless the labels were near-unanimous.
9. *Joining*: two pieces of one kind within 50 s with no new sponsor are joined, if the joined
   stretch still reads as one.
10. *Screening fallback*: a window the screen flagged and the labels missed becomes a span, and is
    classified.
11. *Edge walk*: single-sentence inside/outside questions, needing two answers in a row to move an
    edge.
12. *What the words say*: rules that ask the model nothing.
    - Pieces of one read that the walk left a line or two apart are merged.
    - An ad reaches to lines that name what it sells, up to three lines away, and to the small print
      it closes on.
    - A read that opens by pointing back ("made for **that kind of** hang") reaches back to the
      set-up question.
    - A plug for the hosts' own dates reaches on to the web addresses read after the asides, and to
      the thanks that close it.
    - Two parts of one host-read up to two minutes apart are one read when the second names what
      the first sells (Ridge Wallet, with a riff about a velociraptor in the middle).
    - An edge never walks inward past a line that opens an ad or names its product ("Gentlemen,
      let's take a quick moment and talk about GLD" had been answered "outside").
    - An "ad" that offers nothing (no address, code, download or small print) and has no ad beside
      it is dropped as a joke about a product, at any length.
13. *Floors*: 10 s for an ad and 2.5 s for anything else. Then, in the app, the listener's padding,
    snapping to pauses, and bookends taken to the file's ends. Back-to-back ads are no longer fused.

**Result on the regression suite.**

| Episode | Old detector | New detector |
|---|---|---|
| MSSP 633 | 8 of 10 regions failing | **0 failing** |
| Stavvy's World #199 | 9 of 9 failing | **0 failing** |

On MSSP 633 the break at 11:25 now comes out as two separate ads, Tremfaya and Vuori. The
tour-date plug is its own self-promotion (32:28–33:39), not part of BlueChew. The Spotify plug is
kept apart from the post-roll ads. On Stavvy #199:

- the Patreon joke, the IDF joke and the hotline call are left alone;
- Twisted Tea runs from its set-up line (1:15:13) to "drink responsibly";
- the SiriusXM plug is separate from it;
- a false "ad" at 43:53 ("a girl from Sheets") is dropped.

**Caveats, stated plainly.**

- The step-12 rules were written while looking at these two episodes. That is where overfitting would
  show, so each new labelled episode goes into `regression/` before the next change. (Held-out check:
  see §9.)
- Speed: 3–5 minutes of model time per hour-long episode on the Mac, uncached, against about 1 for
  the old detector. The phone's speed is unmeasured.
- Detection quality on a phone is unmeasured. The lab uses macOS's copy of the same on-device model.

## 9. Held-out check (no labels, read by eye)

Two older lab episodes the rules were not written against.

**Legion of Skanks 952.**
- Pre-roll and post-roll Progressive ads: found, with exact edges.
- The 16:09–21:38 break: found as one cut. It holds three host-reads (Ridge, Ultra, Indacloud), so
  skipping is right, but it should have been three segments. The joining step links them through
  shared words.
- GLD and Body Brain Coffee: found, and separate.
- The Patreon plug and Gas Digital's subscribe plug: found. The subscribe plug is called an ad, not
  self-promotion.
- A minute of conversation at 1:09:40 was labelled as an ad, then dropped because it offers nothing.
- **Missed:** the Gas Digital network intro (0:28–1:09), which the old detector found.

**Conan (Needs a Fan, 29 min).**
- Apple Card and Coca-Cola pre-rolls: found.
- The 12:07–15:33 break: found in two pieces. It misses about 20 s of a movie trailer's start and
  leaves a 24 s gap.
- The closing credits: found 19 s late, and called an ad.

**Verdict.**
- Edges and separation are much better than the old detector's.
- Coverage of dense produced breaks and network intros is sometimes worse. The gap-filling between
  pieces of one break is the next thing to improve, and it needs a labelled episode of that kind to
  measure against.

## 10. P3–P6, built (pass 13, third part)

- **P3 (storage).** Built on the existing `AdSegment`, with new defaulted properties, so no migration
  is needed.
  - Original edges and kind: `detectedStart`, `detectedEnd`, `detectedKindRaw`.
  - `origin` (detected or added) and `isLocked`.
  - Derived: `isEdited`, `isReviewed` and `status`.
  - Re-processing replaces only cuts the listener hasn't reviewed.
- **P4 (feedback).**
  - `Episode.recordEdit` files boundary lessons: up to 12 words at the moved edge, marked outside or
    inside.
  - The edge walk answers a sentence that matches a lesson without asking, and quotes up to three of
    each in the edge prompt.
  - `FeedbackMemory` and the window detector's worked examples ignore boundary lessons.
  - Passages and lessons are capped separately: 24 passages and 16 lessons per show.
- **P5 (editor).** Described in the plan, row B122.
- **P6 (video).**
  - `VideoSourceResolver` finds the picture, and `SponsorBlockHints` supplies hints.
  - `YouTubeLink` reads the channel's Videos page, with the feed as fallback.

## 11. Why it was weaker on Legion of Skanks and Conan (pass 14)

Measured, not guessed, by reading the lab traces for both episodes.

**Cause 1 — nothing is read unless a keyword says so.** The screening stage asks the model about a
45-second window only when that window holds a cue phrase, a known sponsor, or sits in the first two
minutes or last three. Legion of Skanks' network intro ("You are listening to the Gas Digital
Network") sits at 0:28, inside the head, so it *was* read — and then the section question called it
conversation and it was dropped. Conan's movie-trailer ad contains no cue phrase at all for its first
twenty seconds.

**Cause 2 — a break is longer than the line that gives it away.** Both episodes hold breaks of three
host-reads back to back. The middle of such a break is riffing about the product with no address and
no opener, so the labels call it conversation and the span ends. Conan's 12:07–15:33 break came out
as two pieces with a 24-second hole; Legion of Skanks' 16:09–21:38 break came out in pieces with 80
seconds missing.

**Cause 3 — the section question judges a stretch on its own.** "Gentlemen, let's take a quick moment
and talk about GLD" was answered "outside the segment" because it reads as a lead-in.

### What was done about it

- **The opening is rescued**: a span in the first 150 s that the section question calls conversation
  is kept as the opening when it names the show or a network. Legion of Skanks' intro is now found
  (0:00:31–0:00:52).
- **Holes in a break are filled**: between two paid reads less than 45 s apart, the gap is offered to
  the section question, and kept when it says advertisement. Conan's break is now one cut,
  0:12:39–0:15:49, with no hole.
- **An edge never walks inward past a line that names the product or opens an ad** (pass 13's fix,
  kept).

### What was tried and reverted

- **Reading every window** (no cue filter). It covers everything, but it costs about 400 s an episode
  against 150 s, and — measured — it shifted the labelling downstream enough to lose two cuts on
  Matt and Shane 633 that the narrow filter gets right.
- **A whole-structure detector** (`Services/StructureDetector.swift`, kept in the repo, not wired
  in). One question per stretch of episode: "split this into consecutive parts and say what each
  is." It is the right shape for the problem and it is three times faster, but the on-device model
  is not reliable at it yet: given a worked example it copied the example's line numbers into every
  answer, and without one it returned "all conversation" for stretches holding a whole ad break.
  Best result: 5–6 of 10 regions failing on MSSP 633 against 0 for the shipped detector. Its
  evidence stage (`StructureDetector.evidence`) *is* used — it is what fills each cut's "why".

### Where it stands

| Episode | Before pass 14 | After |
|---|---|---|
| MSSP 633 (labelled) | 0 of 10 regions failing | **0** |
| Stavvy's World #199 (labelled) | 0 of 9 failing | **0** |
| Legion of Skanks 952 (held out) | network intro missed | **found** |
| Conan (held out) | 24 s hole in the 3-minute break | **no hole** |

Still wrong, and known: Legion of Skanks' three back-to-back reads come out as one 5½-minute cut
rather than three; Conan's credits are called an advertisement; both are visible in the lab traces.

## 12. Speed, measured (pass 15)

Where an episode's questions go, from the lab logs (Stavvy's World #199: 293 questions):

| Stage | Questions |
|---|---|
| Screening windows | 43 |
| Sentence labels (12 sentences, stepping 6) | 131 |
| Section checks (verify, classify, fill) | ~30 |
| Edge walks (a question per sentence at each unclear edge) | ~90 |

Tried and measured, on all four lab episodes:

| Setting | Questions (MSSP / Stav) | Regressions |
|---|---|---|
| As shipped | 203 / 293 | 0 / 0 failing |
| Walk only edges under 75% | 170 / 272 | **3 / 2 failing** |
| Labels stepping 9, walk under 75% | 126 / — | **3 failing** on MSSP |

Every reduction in the number of questions cost correct cuts on the labelled episodes, so none
shipped. What did ship changes *when* answers arrive, not *what* they are: screening windows and
sentence labels are independent, and are now asked three at a time (`AdDetector.askAll`).
Measured on Conan with fresh answers: 219 s one at a time, 150 s three at a time, identical cuts.
Every question still passes through `AdDetector.breathe`, so a warm phone slows it down.

Also tried and reverted: splitting word-less transcript chunks into sentences with times shared out
by length, so old transcripts get sentence-level edges. On the two lab episodes without word times it
lost most of two host-reads (Legion of Skanks: GLD 57:36 → 58:23, Body Brain 58:52 → 1:00:13), the
Conan pre-roll, and re-opened the hole in Conan's break. The labels are asked twelve sentences at a
time, and shorter sentences meant each question saw too little of the break. Re-transcribing such
episodes (which keeps word times) is the fix that would work, at a few minutes each.

The honest position: on the Mac an hour-long episode is two to three minutes; the phone is slower
and unmeasured. Making it much faster needs either a better on-device model (the structure
detector in §11 is the design that would then work) or labelled episodes of more shows, so that a
cheaper setting can be shown not to lose cuts.
