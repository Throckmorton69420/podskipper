# PodSkipper: ad detection research (September 2026)

*Research only; no app code was changed. Written in pass 16 by a background research agent. The experiments ran on 22–23 Sep 2026 (UTC) from a cloud computer on a US Google Cloud address. The audio was deleted afterwards. Speech-to-text spot checks used Whisper `tiny.en`, so quoted words are approximate.*

---

## 1. Summary for Shashank

- **Many ads, including ones the host reads himself, are added to the file when it is downloaded.** For three of your shows there is a second copy of the same episode with no ads added. Comparing the two shows exactly where each ad was added, to about 1/40th of a second. No AI model is needed.
- **On Stavvy's World #199, every ad break came from this:** the BlueChew, Visible, Quo and Twisted Tea reads in Stavros's own voice, a movie trailer, and Lowe's and Ashley ads. Those are exactly the ads the test file for that episode labels.
- **Finding them costs about half a megabyte of download, not a second full copy.** The app can ask the server for small pieces of the ad-free copy (about 100 requests, roughly 0.6 MB).
- **The same ad plays on different shows.** A movie-trailer ad taken from Stavvy's World was found in MSSP with a strong match, in about 3 seconds of computer time. A "known ads" library would learn from every ad confirmed.
- **The AI is still needed for ads recorded as part of the episode.** Legion of Skanks records its ads live (PrizePicks, Brunt, IndiCloud and others), and MSSP #633 has a BlueChew read recorded the same way. The AI can now spend its time only on those parts.
- **Cheap sound clues are weak.** Silences and volume jumps appear throughout the conversation, so they only help tidy an edge once something else has found the ad.
- **None of your four shows publishes chapter markers.** Two feeds (Spreaker mirrors of Conan and MSSP) publish ready-made transcripts.

---

## 2. Findings per hypothesis

### H1: Inserted ads differ between downloads, and comparing copies isolates them at no model cost
**Verdict: supported, with one correction.** Comparing two copies that both contain ads finds only the spots that differ, often a fraction of each break. The reliable method is to compare against an **ad-free copy of the same episode**. One was found for Stavvy's World, MSSP and Conan, not for Legion of Skanks.

- **Stavvy #199 (Simplecast, served by AdsWizz "AIS Streaming Server").** Each ad-bearing fetch was a different stitch (97.41–98.14 MB), but two fetched a minute apart differed in only 4 spots of ~30 s. Requesting the stitcher URL **without the query string** returned an ad-free file of 90,927,571 bytes (also for a curl user agent and for `aid=manual_test`), matching the RSS `length` (90,927,998) and `itunes:duration` (1:34:42). Against it, the ad copy has **5 insertions at MP3-frame precision** (26 ms).
- **MSSP (Megaphone via `dcs-spotify.megaphone.fm`).** Four user agents got byte-identical files within minutes (cached per URL and/or IP). A dummy query parameter produced a new stitch with one 36 s spot moved. The show's **Spreaker mirror feed** is byte-identical outside the insertions, so it serves as the ad-free copy.
- **Conan.** The Simplecast mirror had no added ads from this address. The Spreaker copy was the same file plus a 60.29 s pre-roll of **Irish** ads — the ad server's choice depends on the requesting address.
- **Legion of Skanks (Art19).** Apple and Overcast user agents got copies differing only in the final 30 s spot; curl got fewer ads but still some. No ad-free URL found.

Caveats:
- **Stitching does not re-encode.** On all four hosts the ads were whole MP3 frames spliced in; show audio was byte-identical outside them (exactly 1 frame changed at each seam). A **frame-hash comparison is enough** for MP3. AAC/MP4 or a publisher re-upload needs an audio-level fallback (H2 fingerprint alignment).
- **Repeated ads.** A second stitched copy is a weak reference; the ad-free copy is the strong one.
- **Download statistics.** Ad servers count downloads by IP + user agent, drop bots and data-centre IPs, and count a download only when ≥60 s of audio is fetched ([Acast, IAB 2.2](https://learn.acast.com/en/articles/4231372-how-does-acast-measure-podcast-download-data-iab-2-2)). Small range requests probably do not count as downloads (inference, not verified).
- **The test address was a data centre.** A phone on home Wi-Fi or cellular may be served differently. Re-test first.
- **Ads recorded into the episode never differ between copies** (LoS live reads; MSSP #633 BlueChew). See H5.

Sources: [Sounds Profitable, how DAI works](https://soundsprofitable.com/article/how-dynamic-ad-insertion-actually-works/); [flavours of DAI](https://soundsprofitable.com/article/the-many-flavors-of-dynamic-ad-insertion/); [Megaphone ad locations](https://support.megaphone.fm/en/articles/70951-mark-ad-locations); [ART19 embedded ads](https://art19.zendesk.com/hc/en-us/articles/360056597471-Embedded-baked-in-ads); [Triton on caching](https://rainnews.com/triton-digital-politely-criticizes-stitcher-iheart-spotify-and-google-for-podcast-caching/); [MinusPod cross-fetch differential](https://github.com/ttlequals0/minuspod/blob/main/docs/how-it-works.md).

### H2: The same ad recurs, and fingerprinting finds it again cheaply and exactly
**Verdict: supported (measured).**
- **Recurrence.** The "Digger" movie trailer appears 3 times in one Stavvy download and again in MSSP #636 (different host, 320 vs 128 kbps, different show). Progressive boat insurance is both pre- and mid-roll in LoS.
- **Test.** A basic Shazam-style fingerprint (~60 lines numpy: 8 kHz mono, 64 ms FFT, 32 ms hop, peak picking, 5-peak fan-out, offset voting), query = 30 s Stavvy trailer. Self-match 2,766 votes; other Stavvy copies 882 and 119; MSSP #636 at 4584.16 s with 466 votes (transcript confirms). Largest false match anywhere 4–9 votes (10–500× margin). A host-read BlueChew spot matched the second stitched copy at 915.49 s (444 votes); the ad-free copy showed only noise (≤5).
- **Cost (one 2.1 GHz Xeon core, numpy):** 2.3 s CPU per hour of audio to fingerprint, ~79 hashes/s of audio, 25 ms to search one ad against one episode. Decoding MP3 to 8 kHz ~5–9 s/hour (PodSkipper already decodes for transcription).
- **iPhone 16 Pro estimate (not measured):** 1–3 s per hour of audio with Accelerate/vDSP.
- **Library size:** ~20 KB per 30 s ad; 1,000 ads ≈ 20 MB. Use one hash table for the whole library and pass each episode through it once.
- **Apple-native option:** ShazamKit custom catalogs (on-device, offline; `SHSignatureGenerator` from an `AVAsset`, [WWDC22 10028](https://developer.apple.com/videos/play/wwdc2022/10028/)). Offset precision, whole-episode speed and fit for many short references are **unknown** — test before choosing it over vDSP.

Sources: [Wang 2003](https://www.ee.columbia.edu/~dpwe/papers/Wang03-shazam.pdf); [Chromaprint](https://github.com/acoustid/chromaprint); Panako ([ISMIR 2014](https://archives.ismir.net/ismir2014/paper/000122.pdf)); [Nguyen, Tian & Xue 2010](https://link.springer.com/article/10.1155/2010/572571) (repeated podcast ads, 97.5 % detection); [Covell, Baluja & Fink 2006](https://research.google/pubs/advertisement-detection-and-replacement-using-acoustic-and-visual-repetition/) (TV ads by repetition, P > 99 %, R 95 %, edges ~11 ms).

### H3: Stitch points leave acoustic seams
**Verdict: mostly refuted as a detector; partly supported for snapping an edge something else found.**
- **Loudness** (median level 2.5 s either side of the 8 known seams in Stavvy #199): +1.5, −0.1, +2.5, +12.7, −7.9, +3.3, −46.4, +10.3 dB. Only 3 of 8 exceed 6 dB; the same measure exceeds 6 dB at 18,349 of 61,067 positions (100 ms apart).
- **Silence.** 288 runs of near-digital silence (< −90 dBFS, ≥100 ms), ~2.8 per minute of conversation. Silences ≥0.3 s below −45 dB: 888 in 102 minutes.
- **Recorded-in ads have no seam.** Between LoS's back-to-back live reads the level changed < 3.2 dB and no 20 ms frame fell below −60 dB.
- **Literature.** BIC/change-point segmentation (Chen & Gopalakrishnan 1998; [Zhou & Hansen 2000](https://www.isca-archive.org/icslp_2000/zhou00d_icslp.html)) detects speaker/channel changes — a host read has the same speaker and room. [Adblock Radio](https://www.adblockradio.com/blog/2018/11/15/designing-audio-ad-block-radio-podcast/index.html) calls native host reads the hard case.
- **Use:** snap a model-proposed edge to the nearest silence or word gap within ±1.5 s; record the evidence sharpness as edge confidence.

### H4: Publisher chapters mark ad breaks
**Verdict: refuted for these four shows.** None of 6 feeds carries `podcast:chapters` or `psc:chapter`; no MP3 has ID3 CHAP frames. Keep as a cheap optional first check for other shows.
- **Side finding:** the **Spreaker feeds carry `podcast:transcript`** (SRT/VTT/TXT) for Conan and MSSP, on the essentially ad-free timeline. Could replace on-device transcription for those shows; quality and word timing unknown.

### H5: Keep the language model only for host reads and promos, fed candidate regions by cheap signals
**Verdict: partly supported, with the wrong dividing line.** The line that matters is **added at download time vs recorded into the episode**, not host read vs produced ad.
- Host reads added at download time: Stavvy #199 BlueChew, Visible, Quo, Twisted Tea; MSSP #636 Rocket Money, Vuori.
- Recorded in: LoS PrizePicks, Brunt, IndiCloud, Blueprint, Body Brain Coffee, tour dates, Gas Digital plugs; MSSP #633 BlueChew (region B); Conan end credits closing with a SiriusXM offer ("three free months of SiriusXM … siriusxm.com/coney").
- Cheap signals cannot supply candidates for recorded-in reads. What changes: (a) spans already explained by the comparison or a fingerprint are removed from the model's input; (b) exact edges remove most edge-walk questions (~90 of 293 on Stavvy #199 per DETECTION-AUDIT §12); (c) a per-show profile could run a lighter cue-only pass on shows whose paid ads are all inserted (unmeasured).

---

## 3. Prior art

| Project / paper | Method | Reported numbers | What to borrow |
|---|---|---|---|
| [SponsorBlock](https://wiki.sponsor.ajay.app/w/API_Docs) ([categories](https://wiki.sponsor.ajay.app/w/Guidelines)) | Crowdsourced YouTube segments: `[start,end]`, `category` (sponsor, selfpromo, interaction, intro, outro/credits, preview, filler, music), `actionType`, `videoDuration` (staleness), votes, locked. SHA-256 prefix lookups. | None (crowd votes) | The category list (credits as its own kind); duration-based staleness (file bytes + ad-free length); a confirmed/locked flag. |
| [MinusPod](https://github.com/ttlequals0/minuspod) | Whisper; LLM over 10-min windows with 3-min overlap + verification pass; EBU R128 loudness, ≥12 dB jump as "DAI transition"; Chromaprint ad prints; cross-fetch differential (hold for review unless another stage agrees); MFCC jingle templates to snap edges; learns from corrections per show → network → global. | None published | Same staged idea (supports the plan). Borrow negative "not an ad" patterns, hold-for-review for single-signal spans, jingle templates, category model. Their differential is cruder than frame comparison against an ad-free copy. |
| [Podly](https://github.com/podly-pure-podcasts/podly_pure_podcasts), [podcast-ad-remover](https://github.com/jdcb4/podcast-ad-remover), [podcast-server](https://github.com/hemant6488/podcast-server), [PodWash](https://synodic.co/podwash/) | Whisper → LLM labels → ffmpeg cut, server-side | None | Confirms transcript + LLM is the norm; none on-device. |
| [Adblock Radio](https://www.adblockradio.com/blog/2018/11/15/designing-audio-ad-block-radio-podcast/index.html) | MFCC → LSTM (ad/talk/music) + fingerprint hotlist | ~95 % training accuracy | Fingerprint only hard cases. |
| [Reddy et al., EACL 2021 (Spotify)](https://arxiv.org/abs/2103.02585) | BERT sentence classifier on ASR transcripts; retention drops as silver labels | Transcript F1 0.769 (P 0.690, R 0.870); edges off 16 words (start) / 35 words (end) | Text-only tops out ~F1 0.77 with loose edges — the case for other signals. |
| [Nguyen, Tian & Xue 2010](https://link.springer.com/article/10.1155/2010/572571) | 1 s clip classification + repeat finding by fingerprint across 325 podcast files | 97.5 % detection; 20× faster than prior art | Known-ads library across episodes. |
| [Covell et al. 2006 (Google)](https://research.google/pubs/advertisement-detection-and-replacement-using-acoustic-and-visual-repetition/) | Repetition of 5 s snippets + Viterbi edge refinement | P > 99 %, R 95 %, edges ~11 ms | Edge refinement of repeat matches. |
| Commercial (Skipper, Podgy, Herd, PodSkip, ZeroAds, Podcast AdBlock) | Undisclosed | — | — |

---

## 4. The double-download experiment

### Method
1. Found feeds through the iTunes Search API; parsed the newest item's `<enclosure>`, `length`, `itunes:duration`, `podcast:chapters`, `podcast:transcript`.
2. Downloaded each episode several times with `curl -L`, varying user agent (AppleCoreMedia, Overcast, Spotify, curl, `PodSkipper/1.0 CFNetwork`, `Podcasts/1.0 CFNetwork`), timing (60 s pause) and query string.
3. Recorded final redirect host, `Content-Length`, `ffprobe` duration.
4. Parsed every MPEG-1 Layer III frame (skipping ID3), hashed each frame payload, compared hash lists with `difflib.SequenceMatcher` (~0.4 s for 230k frames).
5. Transcribed differing regions with `faster-whisper tiny.en`.
6. Tested range probing against the ad-free copy (§5, stage 1).

All files were CBR MP3, 44.1 kHz stereo: 128 kbps (Stavvy, Conan, LoS), 320 kbps (MSSP).

### Hosts seen
| Show | Redirect chain | Stitcher |
|---|---|---|
| Stavvy's World | `dts.podtrac.com` → `stitcher.simplecastaudio.com` (AIS Streaming Server, CloudFront) | AdsWizz for Simplecast |
| MSSP | `traffic.megaphone.fm` → `dcs-spotify.megaphone.fm`; mirror `api.spreaker.com` | Megaphone (Spotify) |
| LoS | `pdst.fm`, `pscrb.fm`, `clrtpod.com`, `mgln.ai` → `rss.art19.com` → `content.production.cdn.art19.com` | Art19 |
| Conan | `pdrl.fm`, podtrac, `arttrk.com`, `claritaspod.com` → Simplecast; mirror Spreaker | Simplecast; Spreaker |

### Stavvy's World #199 "Are You Garbage?" (same episode as fixture `stav199.json`)
| Copy | How fetched | Bytes | Duration |
|---|---|---|---|
| A | AppleCoreMedia UA, RSS URL | 97,707,700 | 6106.72 s |
| B | Overcast UA, 60 s later | 97,413,875 | 6088.36 s |
| C | Spotify UA, stitcher URL with `aid=manual_test` | **90,927,571** | **5682.96 s** (= RSS 1:34:42) |

Redirect-only probes: no query string → 90,927,571 (ad-free); curl UA with full query → ad-free; `PodSkipper/1.0 CFNetwork` UA → 98,136,526 (most ads); `Podcasts/1.0 CFNetwork` → 97,711,043.

Frame comparison, ad-free C vs A:

| Position in ad-free copy | Span in copy A | Length | Content |
|---|---|---|---|
| 0:00 (pre-roll) | 0:00.000–1:00.369 | 60.37 s | "Digger" trailer; Lowe's |
| 14:15.09 | 15:15.461–17:17.375 | 121.91 s | Host-read BlueChew ("promo code Stavvy"), host-read Visible |
| 41:08.78 | 44:11.037–45:33.636 | 82.60 s | Host-read Quo ("quo.com/stav"); Digger trailer |
| 70:48.76 | 75:13.593–76:55.131 | 101.54 s | Host-read Twisted Tea; Digger trailer |
| 94:42.97 (post-roll) | 100:49.306–101:46.723 | 57.42 s | Dancing with the Stars promo; Ashley |

- Total added 423.84 s = exactly the 6.78 MB difference at 128 kbps. Exactly one frame differs at each mid-roll seam.
- The ad-free transcript has no paid reads; only content plugs (Patreon joke, 2–3 s "sponsored by Visible" name-drops, sign-off plugs, ~10 s network bumper).
- Matches the fixture ("BlueChew + Visible 15:14–17:16", "Quo 44:10", "Twisted Tea 1:15:13"). SponsorBlock places Quo at 41:09 in the YouTube video; the ad-free copy puts the break at 41:08.8, so the ad-free timeline matches YouTube's.
- A vs B (both with ads): only `0:30–1:00`, `45:03–45:33`, `76:24–76:55`, `100:49–101:19` differ. **About 70 % of added time was identical in both.**

### MSSP Ep 636 (Megaphone vs Spreaker mirror)
Spreaker 4390.69 s (matches RSS length 175,683,525); Megaphone 4614.95 s.

| Position in ad-free copy | Added | Content |
|---|---|---|
| 6:41.16 | 60.16 s | Tremfya pharma spot |
| 32:26.07 | 103.94 s | Host-read Rocket Money ("rocketmoney.com/mssp"), host-read Vuori ("vuori.com/mssp") |
| 73:10.14 (post-roll) | 60.16 s | Wegovy; Digger trailer |

Four UAs gave byte-identical first 40 MB; `?t=<random>` changed the stitch (one 36 s spot reordered).

### MSSP Ep 633 (fixture)
Megaphone 4333.17 s; Spreaker 4043.28 s.

| Position in ad-free copy | Added | Fixture region |
|---|---|---|
| 11:25.14 | 96.16 s | Region A |
| 43:51.18 | 133.56 s | Audit's "45:04–47:55" break |
| 67:23.05 (post-roll) | 60.16 s | Region D's ads |

Region B (BlueChew host read), tour-date self-promo, Patreon sign-off and "Watch … on Spotify" are **in both copies** → recorded in.

### Legion of Skanks Ep 956 (Art19)
| Copy | Bytes | Duration |
|---|---|---|
| Apple UA | 113,760,976 | 7097.70 s |
| Overcast UA | 113,760,976 (different MD5) | 7097.70 s |
| curl UA | 112,801,342 | 7037.73 s |
| RSS `itunes:duration` | — | 6978 s |

Differences: Progressive pre-roll swapped, one extra 30 s BKFC mid-roll spot, one extra post-roll spot. Most LoS ads are **recorded in**: PrizePicks → Brunt → IndiCloud back to back (~28:25–31:54, ending "All right, let's get back into it"); Blueprint and Body Brain Coffee (~77–80 min); tour dates; Gas Digital plugs. Inserted: only Progressive and BKFC (~1–2 min).

### Conan "Joel McHale Returns"
Simplecast: 62,362,958 bytes, 3897.68 s, ad-free from this address with or without query. Spreaker: same file plus a 60.29 s Irish pre-roll. The ad-free transcript has no paid reads; the end is ~64 s of credits (from 3826 s) closing with a SiriusXM offer and "please subscribe" — the source of the "credits labelled as an ad" bug (the last 10 s really is a promo).

### Conclusion
- For Stavvy, MSSP and Conan an **ad-free copy exists and matches the ad copy frame for frame**. Comparing against it gives every inserted ad with 26 ms edges, including host reads, at no model cost.
- Comparing two ad-bearing copies catches only ~30 % of inserted time on Stavvy.
- LoS gains little: its ads are recorded in.
- **Not observed:** what an iPhone on residential or cellular gets.

---

## 5. Proposed detection plan

Key design change: store every cut, correction and fingerprint hit in **ad-free ("clean") timeline coordinates**, with a per-file map to the downloaded file's time. Cuts then survive re-downloads and line up with YouTube/SponsorBlock timelines.

| # | Stage | Catches | On-device cost | Risks | How to measure |
|---|---|---|---|---|---|
| 0 | **Feed metadata**: chapters, ID3 CHAP, `podcast:transcript`; RSS `length` vs downloaded bytes → seconds of inserted ads | Chapters: nothing on these shows. Length: Stavvy exact (6.78 MB ≈ 424 s); LoS roughly; Megaphone gives `length="0"` | Negligible | Stale publisher lengths | Log estimate vs stage 1 |
| 1 | **Inserted-ad map from an ad-free copy.** Reference URL by host: Simplecast/AdsWizz → stitcher URL without query; Megaphone → Spreaker mirror; Spreaker → Simplecast mirror; else a second stitched fetch (partial). **Range-probe** the reference: 6 KB windows, match 3-frame hashes against the local frame index, bisect where the byte offset jumps. | Every inserted ad, **including host reads**, 26 ms edges. Stavvy #199: all 3 mid-rolls + pre-roll; post-roll by subtraction. | Measured **98 requests, 588 KB (0.65 % of file)**; CPU trivial | (a) phone may be served differently; (b) undocumented host behaviour can change; (c) re-uploads / AAC break byte matching → fingerprint fallback; (d) App Review / publisher-terms question (open); (e) lost probe → retries + consistency check (ad-free size + inserts = local size) | Lab builds the map per fixture and scores vs labels; record requests, bytes, seams |
| 2 | **Known-ads fingerprint library** (vDSP landmarks or ShazamKit after a test), seeded from stage 1 spans, confirmed ads, jingles; plus **negative** prints (theme, bumpers = keep) | Repeated ads with no ad-free copy (LoS Progressive, BKFC; cross-show trailers); network promos; jingle edges. Not fresh live reads. | 2.3 s CPU/hour measured on a cloud core; iPhone est. 1–3 s; ~20 KB/ad | Theme music inside promos → require ≥60 % reference coverage, ≥5× background votes, minimum length; cap library per show/network | Hit and false-hit rate per fixture; offset error vs stage 1; ms/hour on phone |
| 3 | **Edge snapping**: silences, word gaps, level steps within ±1.5 s of a stage-4 edge | Tidier edges for recorded-in reads | Negligible | Weak as a detector; never creates cuts | Median / p90 edge error before vs after |
| 4 | **Language model on what remains**: regions outside stage 1–2 spans; skip edge walk where edges come from 1–2; split back-to-back reads on sponsor/call-to-action change; new kinds **credits** (default keep) and **self/network promo**; per-show cue-only profile | Recorded-in host reads, self-promos, cross-promos, credits | Today 2–3 min/hour on Mac; est. 30–50 % saving on Stavvy-like shows, ~0 % on LoS (unmeasured) | No saving on LoS-like shows; profile could miss a new recorded-in read | Questions and seconds/hour; fixtures must not regress |
| 5 | **Corrections feed back**: confirmed cut → positive prints + text lessons; "not an ad" → negative prints; all in clean-timeline coordinates | Stages 2 and 4 improve over time | Negligible | Poisoned prints → keep source, allow undo | Repeat-miss rate over time |

Stage 1 implementer notes: index the local file as `(hash(frame i), hash(i+1), hash(i+2)) → byte offset`. `delta(x)` = local offset of the 3-frame run at reference byte x, minus x. Probe a 64-point grid, bisect every interval where `delta` changes down to 2 frames; each change is one inserted block of that many bytes. Pre-roll = `delta(0)`; post-roll = local size − ad-free size − sum of inserts. Probe the **final** host URL so analytics prefixes are not hit repeatedly.

---

## 6. Measurable targets

| Metric | Definition | Target (proposal) |
|---|---|---|
| Per-cut precision / recall | One-to-one greedy IoU matching, match at **IoU ≥ 0.5**, per kind (ad, promo, credits) | Paid ads P ≥ 0.95, R ≥ 0.95; promos P ≥ 0.85 |
| Boundary error | Absolute start/end error (s) for matched cuts; share within 0.5 s and 3 s | Inserted edges median ≤ 0.05 s; recorded-in median ≤ 1 s, p90 ≤ 3 s |
| Time-weighted errors | **Ad seconds heard** and **content seconds skipped** per hour of audio | ≤ 10 s heard, ≤ 5 s skipped per hour |
| Compute | Model seconds, questions, CPU seconds for stages 0–3, network bytes, per hour of audio | iPhone 16 Pro ≤ 60 s per hour of audio for detection (excl. transcription) |
| Battery | Energy per processed episode | ≤ 2 % battery per hour-long episode incl. transcription (to confirm) |

How to measure:
- **Lab:** add `lab.sh dai <fixture>` storing the stage 1 map in the fixture JSON; extend `score.py` with IoU matching, edge errors, time-weighted errors and a compute summary. Every stage 1 span is a free exact label, so any Simplecast/Megaphone/Spreaker episode becomes a partial fixture automatically.
- **Fixtures to add:** LoS 952 and 956 (recorded-in back-to-back reads); Conan "Joel McHale Returns" (credits + promo); one Conan episode fetched **from the phone**; MSSP 636; a second Stavvy episode.
- **Phone:** in-app **"Export detection report"** JSON: app version, feed/enclosure URL, final host, UA; downloaded bytes, RSS length, SHA-256, duration; DAI map; fingerprint hits; cuts (detected and edited, kind, edges, per-edge confidence, evidence source); transcript (word-timed or hash + sentence times); timings (per-stage wall/CPU, questions, thermal samples, Low Power Mode); battery (MetricKit). He exports after checking an episode by ear; his edits are the labels.

---

## 7. Open questions and next experiments

1. **Repeat the double download from the iPhone** (home Wi-Fi and cellular, PodSkipper's real UA) for all four shows. Does the no-query Simplecast URL stay ad-free? Does Megaphone's cache follow the IP?
2. **Is the ad-free URL stable over time?** Re-probe weekly; check other Simplecast shows.
3. **Art19 (LoS):** try URL/parameter variants; else rely on fingerprints for Progressive and BKFC.
4. **Spreaker mirrors:** permanent? Will Spreaker add its own ads (Conan already has a pre-roll)?
5. **ShazamKit vs vDSP landmarks on iPhone 16 Pro:** speed per hour, offset precision, behaviour with 1,000 references.
6. **Spreaker `podcast:transcript` quality** vs SpeechTranscriber for MSSP and Conan.
7. **Policy:** is contacting an ad-free reference URL (~0.6 MB of range requests) acceptable under App Review and publisher terms? Decide before shipping stage 1.
8. **Splitting LoS back-to-back reads** by sponsor/call-to-action change; measure once LoS fixtures exist.
9. **Stage 4 saving:** model questions on Stavvy #199 and MSSP #633 with stage 1 spans removed, vs today's 293 and 203.

---

### Appendix: frame-hash comparison (Python, for the lab)

```python
from hashlib import md5
BR=[0,32,40,48,56,64,80,96,112,128,160,192,224,256,320]; SR=[44100,48000,32000]
def frames(b):                       # MPEG-1 Layer III only
    i = 10+((b[6]<<21)|(b[7]<<14)|(b[8]<<7)|b[9]) if b[:3]==b'ID3' else 0
    out=[]
    while i+4<=len(b):
        h=b[i:i+4]
        if h[0]==0xFF and h[1]&0xE0==0xE0 and (h[1]>>3)&3==3 and (h[1]>>1)&3==1 \
           and 0<(h[2]>>4)&15<15 and (h[2]>>2)&3<3:
            n=144*BR[(h[2]>>4)&15]*1000//SR[(h[2]>>2)&3]+((h[2]>>1)&1)
            out.append((i, md5(b[i+4:i+n]).hexdigest()[:12])); i+=n
        else: i+=1
    return out
# difflib.SequenceMatcher(None, clean_hashes, ad_hashes, autojunk=False).get_opcodes()
# 'insert'/'replace' runs = inserted ads; frame = 1152/44100 s
```
