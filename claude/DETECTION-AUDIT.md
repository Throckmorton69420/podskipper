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

## 13. Pass 17: six labelled episodes, the ad-free copy, and model fixes (measured)

### Fixtures and scoring

Four fixtures were added and the two old ones made complete, so every skippable span in all six is
labelled ("complete": true). New ones are **Claude-labelled** (read line by line around every
sponsor mention; how each cut was judged is in the fixture's notes) until his exported reports
replace them.

| Fixture | Length | Source of labels |
|---|---|---|
| `mssp633` | 1.20 h | Shashank (21–22 Sep) + the 45:27 inserted break from the comparison |
| `mssp636` | 1.28 h | Claude, pass 17 |
| `stav199` | 1.69 h | Claude (pass 13) + pre/post-roll and "inserted" from the comparison |
| `los952` | 1.45 h | Claude, pass 17 (replaces the word-less pass-14 copy) |
| `los956` | 1.96 h | Claude, pass 17 |
| `conanjm` | 1.25 h | Claude, pass 17 ("Joel McHale Returns") |

`score.py` now also reports, for complete fixtures: one-to-one IoU ≥ 0.5 matching per ad and per
break (back-to-back reads share a `group`), edge error for matched cuts, cuts that land on something
skippable at all ("on target"), and seconds of ads heard / show skipped per hour. `EITHER` marks
spans where cutting and keeping are both right (a funny riff he keeps by default, a two-second
name-drop). Inserted regions are scored against the frame-exact comparison. `Scripts/run-four.sh`
runs all six; `LAB_INSERTED=1` hands the detector the cheap evidence as the app hands it the
comparison.

### Cheap evidence, from his home connection (the Mac), 23 Sep

**The ad-free copy** (`Tools/DetectionLab/dai.py map|probe`, app port `Services/AdFreeCopy.swift`):

| Show | Ad-free source | Inserted in his download | Probe cost (Python / Swift) |
|---|---|---|---|
| Stavvy's World #199 | Simplecast stitcher path, no prefixes, no query → 90,927,571 B (= RSS) | 5 spans, 413.3 s | 90–125 requests, 0.55–0.76 MB, 7–8 s |
| Conan "Joel McHale Returns" | Simplecast, same trick → 62,362,958 B | 4 spans, **604.5 s** (the data centre got none) | 104 requests, 0.63 MB, 15 s (first answer slow) |
| MSSP 636 | Spreaker mirror = RSS length exactly | 3 spans, 230.2 s | 93 / 143 requests, 0.57 / 0.87 MB, 3–7 s |
| MSSP 633 | Spreaker mirror | 3 spans, 275.0 s | 93 requests, 0.57 MB, 6 s |
| LoS 952 / 956 | **none** (Art19 direct and plain URLs serve the same stitched bytes) | RSS length says ≈164 s / ≈104 s were added | — |

- Probe spans matched the full frame diff within 0.3 s at every seam (Swift port within 0.1 s).
- **Following the enclosure is wrong for Simplecast:** with a podcast user agent it asks the stitcher
  for a new stitch (and is slow; one request hung for minutes). The stored file is reached by
  taking `stitcher.simplecastaudio.com/…/default.mp3` out of the enclosure, without the query.
  Only a `curl` user agent got the ad-free file through the full enclosure — not used.
- Spreaker's copy of Conan carries its **own** 60.3 s pre-roll; Simplecast is the better reference.
- The first redirect of a Simplecast stitch carries `x-total-bytes=` — a free size check (unused yet).

**Repeated-ad fingerprints** (`dai.py prints`, landmark hashes, 15 s pieces, offset voting):
decode + print 6–11 s per episode on the Mac (≈5 s per hour, ffmpeg decode included); search 0.6 s
for 110 pieces. Found: the MSSP Vuori and Rocket Money/AG1 breaks shared between 633 and 636
(already known from the comparison); Conan's Digger trailer repeated inside its own breaks; and,
seeded by hand from LoS 952's Progressive/Hyundai/Mazda-BKFC spots, the Progressive pre-roll and
mid-roll in 952 and the pre- and post-roll in 956. No false match above threshold. **Not in the app:**
on these shows it adds nothing the comparison doesn't, except on LoS, and there it needs a seed
library of known ads, which should come from his confirmed cuts (pass 18+).

**The publisher's transcript** (`dai.py pubtx`): only Conan's Spreaker feed has one (SRT/VTT/TXT;
MSSP's has none). 1,412 cues, median 2.5 s, fetched in 1 s; no word times (words spread by length);
its clock leads the ad-free timeline by the Spreaker pre-roll, found from 1,149 shared phrases.
With the comparison's spans: 4/6 ads, edges median 0.57 s / p90 0.96 s (better than the on-device
transcript's 0.6 / 6.6), 52.5 s heard per hour (on-device: 30.6) — it **lost the credits**
(called ad + self-promo). It would save on-device transcription (≈63 s per hour of audio on the
Mac). Not wired: one show, and worse on the one thing D3 fixed.

### Model fixes (D3, D2, and what the new fixtures exposed)

Each measured on all six. Pass 17 detector = `AdDetector.version` 17.

- **D3 credits:** a span in the last five minutes with ≥ 2 credit lines ("produced by", "theme song
  by", "engineering"…) becomes the outro, class `credits`; a ≤ 20 s span right after it goes with it.
  Conan: credits PASS (were "ADVERTISEMENT").
- **D2 back-to-back:** a run of ad sentences splits where a new read opens, including after a
  greeting ("What's up, Skanks? I want to talk to you for a second about Brunt"). LoS 956: Brunt and
  IndiCloud now PASS separately.
- **Late host-read starts** (new): the labels agreed only from the offer, 40–80 s after the hand-off.
  A read now reaches back ≤ 90 s to a strong opener that names what it sells (or within 75 s: the
  recognizer spells brands its own way). LoS 952: Ridge and GLD PASS.
- **Plugs segments** (new): pieces of self-promotion ≤ 30 s apart with a cue between (≤ 100 s with
  three cues) join into one.
- **Network ident** at the top that offers nothing is the intro, not an ad.
- "details" alone no longer counts as small print ("and then give real details" kept a minute of
  Conan as an ad).
- **Tried and reverted:** kind-by-majority when grouping fragments (lost Ultra on LoS 952 and cut
  "Let's do the Patreon" on MSSP 633); reclassifying any < 10 s "ad" by the section question (cut
  "Let's do the Patreon").

### Results

Per fixture: regions failing | ads matched | ad P / R | break P / R | cuts on target | edge median / p90 (s) | ads heard | show skipped (s per hour) | model questions.

**Baseline (pass-16 detector, fresh answers):**

| Fixture | Fail | Matched | Ad P/R | Break P/R | On target | Edges | Heard | Skipped | Q |
|---|---|---|---|---|---|---|---|---|---|
| mssp633 | 1 | 5/6 (8 cuts) | 0.63/0.83 | 0.63/0.83 | 8/8 | 0.78/37.3 | 26.7 | 5.7 | 203 |
| mssp636 | 3 | 4/5 (9) | 0.44/0.80 | 0.44/0.80 | 6/9 | 0.90/66.6 | 2.6 | 47.7 | 318 |
| stav199 | 3 | 6/6 (10) | 0.60/1.00 | 0.50/1.00 | 10/10 | 0.82/31.1 | 17.4 | 1.9 | 293 |
| los952 | 10 | 5/11 (14) | 0.36/0.46 | 0.29/0.50 | 14/15 | 1.14/10.2 | 200.9 | 18.6 | 349 |
| los956 | 10 | 6/10 (12) | 0.50/0.60 | 0.25/0.43 | 10/12 | 0.76/16.9 | 106.8 | 14.6 | 437 |
| conanjm | 6 | 3/6 (6) | 0.50/0.50 | 0.50/0.50 | 5/6 | 2.06/12.9 | 132.7 | 27.9 | 266 |

**Pass 17, model only** (what LoS gets in the app — no ad-free copy):

| Fixture | Fail | Matched | Ad P/R | Break P/R | On target | Edges | Heard | Skipped | Q |
|---|---|---|---|---|---|---|---|---|---|
| mssp633 | 1 | 6/6 (7) | 0.86/1.00 | 0.86/1.00 | 7/7 | 1.09/27.6 | 25.8 | 6.5 | 203 |
| mssp636 | 3 | 4/5 (8) | 0.50/0.80 | 0.50/0.80 | 6/8 | 0.90/66.6 | 2.6 | 38.3 | 314 |
| stav199 | 3 | 6/6 (10) | 0.60/1.00 | 0.50/1.00 | 10/10 | 0.82/31.1 | 17.4 | 1.9 | 293 |
| los952 | 8 | 10/11 (12) | 0.83/0.91 | 0.50/0.75 | 12/13 | 1.00/10.2 | **45.5** | 19.8 | 351 |
| los956 | 7 | 7/10 (13) | 0.54/0.70 | 0.15/0.29 | 11/13 | 0.58/5.2 | 98.1 | 14.6 | 438 |
| conanjm | 5 | 3/6 (6) | 0.50/0.50 | 0.50/0.50 | 5/6 | 2.06/12.9 | 132.7 | 27.9 | 266 |

No region that passed at baseline fails here.

**Pass 17 with the ad-free comparison** (what MSSP, Stavvy's World and Conan get in the app; the
LoS rows use lab fingerprints the app does not have, shown for completeness):

| Fixture | Fail | Matched | Ad P/R | Break P/R | On target | Edges | Heard | Skipped | Q |
|---|---|---|---|---|---|---|---|---|---|
| mssp633 | 1 | 5/6 (5) | 1.00/0.83 | 1.00/0.83 | 5/5 | 0.77/27.6 | 31.7 | **1.9** | **134** |
| mssp636 | 1 | 5/5 (6) | 0.83/1.00 | 0.83/1.00 | 5/6 | 0.60/22.5 | **0.5** | **11.2** | **226** |
| stav199 | 2 | 5/6 (5) | 1.00/0.83 | 1.00/1.00 | 5/5 | **0.20**/31.2 | **0.0** | 3.4 | **141** |
| (los952) | 9 | 10/11 (14) | 0.71/0.91 | 0.43/0.75 | 12/15 | 1.14/17.9 | 42.2 | 34.4 | 340 |
| (los956) | 5 | 8/10 (12) | 0.67/0.80 | 0.25/0.43 | 12/13 | 0.74/2.3 | 87.1 | 7.7 | 402 |
| conanjm | 2 | 5/6 (5) | 1.00/0.83 | 1.00/0.83 | 5/5 | 0.60/6.6 | **30.6** | **2.4** | **151** |

**Work, fresh answers, on the Mac (seconds per hour of audio):** baseline mssp636 273, stav199 191,
los952 248, los956 249, conanjm 248 (mssp633 ran partly cached). With the comparison:
**stav199 102 (−47 %), conanjm 142 (−43 %)**; questions −34 % on MSSP 633 and −29 % on MSSP 636.
The comparison itself: 3–15 s of network and a second of hashing per episode. LoS: unchanged (no
ad-free copy). The phone is still unmeasured (D1).

**Regions that changed from pass to fail with the comparison, and why:**
- MSSP 633 `D-network-promo` — "Watch new episodes of Matt and Shane's secret podcast on Spotify.
  Do it." (4 s, before the post-roll). With the post-roll's words gone, the labels call the lines
  around it one short "ad", which the 10-second floor drops. The two fixes tried both also cut
  "Let's do the Patreon", which he labelled the sign-off. **Accepted as a known trade**: the same
  episode now gets its 45:27 break exactly (it failed at baseline), skips 3.8 s less show per hour
  and asks 34 % fewer questions. Carried to pass 18.
- Stavvy's `twisted-tea` / `siriusxm-plug` — both sit inside one inserted break, which is now cut
  whole and frame-exact; the region check wants two cuts. Break-level P/R 1.00/1.00, 0.0 s heard.
  A scoring artifact, not a miss.

**Still wrong, known:** LoS openings (the Gas Digital ident + theme) and outros ("You've been
listening to…") are missed on both LoS fixtures; the LoS plugs segment is found only in part; the
Conan cold open ("I feel blank about being Conan O'Brien's friend" + theme) is not called the
intro; MSSP 636's Spotify plug + riff after BlueChew are cut (both EITHER, not counted).

## 14. Pass 18: his shows, audio fingerprints, plugs and post-rolls (measured)

**The test set is now his library only.** Conan (`conanjm`) is gone: he doesn't follow it. Eleven episodes of eight shows he does follow, all labelled line by line (Claude-labelled, as before; `labelled_by` says so in each file):

| Key | Show | Ad-free copy | Previous episode for fingerprints |
|---|---|---|---|
| stav199 | Stavvy's World | Simplecast stored file | stav199p (#198) |
| mssp633, mssp636 | Matt and Shane's Secret Podcast | Spreaker mirror | each other |
| los952, los956 | Legion of Skanks | none (Art19) | each other |
| ymh1 | Your Mom's House 877 | none (Spreaker listing dead) | ymh1p |
| bears1 | 2 Bears, 1 Cave | none | bears1p |
| badf1 | Bad Friends | **Spreaker mirror (new)** | badf1p |
| theo1 | This Past Weekend #684 | **Spreaker mirror (new)** | theo1p |
| wg1 | Whiskey Ginger | none | wg1p |
| afs2 | The Adam Friedland Show | none | afs2p |

`dai.py` now finds Spreaker mirrors the way the app does (iTunes search by show name or publisher) and reads malformed Spreaker feeds by pattern; the app's `AdFreeCopy` got the same two fixes and now tries a mirror for any show, not only Megaphone-fed ones. Megaphone itself serves the same cached stitch to every variant tried from one address (11 URL/user-agent variants of YMH 877 → identical 213,643,663 bytes), so a second stitch is no reference.

Labels: wordless music after an intro or outro (a theme's instrumental tail, credits music) had no line to anchor to, so every cut that included it scored as "show skipped". `score.py` gained `start_at_end_of` / `end_until`, and those gaps are `EITHER` regions (`build/tails.py` added them where the gap has no words at all; a few by hand). Either-way regions no longer move the anchor search on.

### Where the seconds were lost (before)

`Tools/DetectionLab/why.py` reads the detector's own log and says, for every second of ad heard, which stage lost it. On the pass-17 detector, with these labels:

| Loss | Seconds (all fixtures) | Example |
|---|---|---|
| Intro/outro/theme songs dropped by the section question ("content") | ~260 | YMH theme at 18:54 and closing song; LoS, Bears, Theo, WG outros |
| Host reads never read (no ad words in the window) or dropped as "offers nothing" | ~360 | YMH Mountain Dew ×2, Bears Mountain Dew, Bad Friends NOCD ("no CD") |
| Plugs dropped by the section question | ~230 | LoS 956 plugs (130 s), YMH tour dates |
| Produced spots with no ad-free copy | ~80 | WG Liquid IV / Jets / Peacock |

### What changed

1. **Audio fingerprints (research stage 2), `Services/AdPrints.swift`.** Landmark hashes (8 kHz mono, 512-point FFT every 32 ms, peaks that are the loudest point within ±7 frames and ±7 bins, each paired with the next 6 peaks within 2 s; hash = f1·f2·Δt, 22 bits), decoded in 4-s chunks with AVAudioConverter, never the whole file in memory. A stretch that plays again — in the show's last two episodes, or twice in this one — at ≥2.5 agreeing hashes a second over ≥8 s is produced material. Measured on this Mac: **5.2 s of one core per hour of audio** to fingerprint (116–154 hashes/s), **0.15–1.0 s** to compare an episode with two others and itself. False repeats across 11 episodes and 7 previous episodes: **none**; true ones carry hundreds to thousands of agreeing hashes (LoS bumper 1,050; MSSP recorded BlueChew read reused in two episodes 3,637; WG Jets spot 1,915).
   - What it found: every intro bumper and theme (LoS, Stavvy's welcome, YMH, Bad Friends, AFS, WG), every outro (LoS, Theo, Bears, WG, AFS), the post-roll spots that run weekly (Porosos on YMH and Bears, Liquid IV on WG), the MSSP reads recorded once and used in two episodes, the Wegovi spot twice in one AFS episode, and YMH's second Mountain Dew read.
   - In the detector (`withProduced`): a repeat overlapping a cut widens it to the recording's exact edges; one found in another episode is cut, its kind from one section question or, failing that, from where it is (opening, closing, else an ad if ≥20 s); one repeated only within this episode is cut only if the question says it's promotional (a clip teased at the start and played later is the show — AFS's cold open is exactly that, and LoS 956 played a song twice mid-episode), except a chorus twice in the last five minutes (YMH's closing song). Repeats are also read closely, which is how YMH's *first* Mountain Dew read (next to the repeated second) was found.
   - In the app: fingerprinted alongside transcription, compared with the show's last two episodes (kept in Caches, ~1 MB per hour, three per show), stored per episode (`producedSpansData`) so a re-label uses it; older episodes are fingerprinted during the D22 re-label if their audio is still there.
2. **Plugs (`plugs`).** Where lines asking the listener to do something (tickets, a website, come see me, subscribe, go check out, tune in…) cluster — at least two different requests, lines within 35 s, lines inside a paid read not counted — that stretch is self-promotion. It fills gaps between pieces the model found. One request plus tour talk was too loose (it cut a Stavvy's joke about "asking for tickets… tour"); two requests is the rule.
3. **After the closing (`afterTheClosing`).** When the last produced recording in the final four minutes is followed by at most 150 s that already hold a cut or sell something, that tail is post-roll (WG: Peacock and Disney+ after the weekly Liquid IV).
4. **Smaller fixes, each from a `why.py` finding:** shop-shelf offers ("look for… in stores near you") and a brand named three times count as selling (Mountain Dew); a brand written as two words matches ("no CD" = nocd.com); back over lines naming the sponsor itself every ≤40 s (NOCD's testimonial read) — only the sponsor's name, since the read's other rare words turned up in the chat before a FanDuel read and grew it 97 s; a fragment beside a read is kept only if ≤15 s or it names that read's sponsor (23 s of gym-flooring talk after LoS's mid-roll was kept before); a screening window becomes an ad only if its own words sell something, not just the previous read's last line.
5. **Background-safe model calls:** a rate-limited question (screen locked) now waits and asks again instead of being lost; answers per episode are checkpointed (`DetectionCheckpoint`).

Tried and dropped: **reading every sentence once** ("sweep", 20 sentences a question, exceptions only). The on-device model flagged 1,177 of 2,119 sentences on YMH as not-conversation, so everything was read closely: 605 questions, 535 s of work per hour, and Mountain Dew still missed downstream. **A sentence-embedding ad score** (Apple's `NLEmbedding`, ridge regression, leave-one-show-out) was measured as a screening supplement: at the threshold that adds 6 % more windows it recovers 3 of the 5 regions the cue words miss — not needed once repeats are read closely; not shipped.

### Numbers (same labels for both columns; pass-17 detector re-run on today's fixtures)

Seconds of ads heard / seconds of the show skipped, per hour:

| Fixture | Pass 17 | Pass 18 |
|---|---|---|
| stav199 | 0.0 / 3.1 | 0.0 / 4.3 |
| mssp633 | 31.7 / 1.9 | **9.2** / 1.9 |
| mssp636 | 0.5 / 3.3 | 0.5 / 5.0 |
| los952 | 25.8 / 28.4 | **10.5 / 14.8** |
| los956 | 75.0 / 7.0 | **15.5** / 8.8 |
| ymh1 | 188.2 / 4.0 | **26.6** / 6.7 |
| bears1 | 205.6 / 51.0 | **99.3 / 25.1** |
| badf1 | 69.5 / 16.5 | **2.2** / 16.8 |
| theo1 | 20.8 / 0.2 | **2.7** / 0.9 |
| wg1 | 175.2 / 20.1 | **29.4** / 24.3 |
| afs2 | 28.1 / 8.9 | **8.5** / 10.0 |
| **All 14.8 hours** | **72.7 / 12.6** | **17.9 / 10.3** |

Targets (research §6): ≤10 s heard and ≤5 s skipped per hour. Met for heard on 7 of 11 episodes; overall not yet. What's left, by size:
- **bears1 Mountain Dew (114 s):** the hosts introduce and play a commercial they made for the sponsor ("our partners in business, Mountain Dew… we took your ideas"). It's a one-off recording (not in the previous episode), mostly dialogue, with no offer.
- **YMH (27 s/h):** the Hoop and Huddle network promo's first seconds, 12 s of the theme's start, 20 s of the fan closing song.
- **WG (29 s/h):** Santino's Chappelle plug and the end-of-show plugs, in part.
- **Show skipped:** the biggest are edges of LLM-found cuts that start or end 10–20 s off (LoS mid-roll neighbours, Bears DraftKings start), one Bad Friends bit read as self-promotion ("welcome to the Magic Johnson Theater… enjoy the film"), and WG's pre-roll cut 5 s into the theme.

**Work, fresh answers, on the Mac (seconds per hour of audio):** ymh1 150 (155 questions), wg1 220 (223), los952 216 (339; pass 17 measured 248 on the same episode, −13 %). None of the three has an ad-free copy, so this is the full cost. Results with fresh answers were identical to the cached run. The fingerprint stage adds ~5 s of one core per hour plus one model question per repeat that has words. The phone is still unmeasured (D1): expect it to be several times slower than the Mac.
