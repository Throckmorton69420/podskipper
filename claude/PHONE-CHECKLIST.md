# PodSkipper — one phone pass (Pass 63, 11 November 2026, for the IPA built from the Pass 63 code commit in HANDOFF)

Replaces the ~120 separate "phone acceptance open" items in the [Request Catalog](REQUEST-CATALOG.md). Install the IPA from the commit named in [HANDOFF](HANDOFF.md) over your current install (your library stays). Go in order; each line says what to do and what you should see. Mark ✗ with a word or a screenshot where it differs. **At the end, share Diagnostics once** (Settings › Diagnostics › Share Diagnostics…, everything, last 7 days) and send that file with this list — that file carries the timings, closures and background lines I need, so no separate test runs.

## A. First launch and the look (5 min)

1. Open PodSkipper. **Expect:** Home first (Continue Playing, New Episodes ›, Up Next ›); tabs Home · New · Library · Settings · Search. *(X58-05)*
2. Home Screen icon in Light, Dark and Tinted (long-press Home Screen › Edit › Customize). **Expect:** a clean icon in each. *(U17)*
3. iPhone Settings › Display & Brightness › Text Size: one step bigger, back to PodSkipper. **Expect:** PodSkipper's text and icons grow; at the standard size it looks as before. Settings › Display › "Match iPhone Text Size" off → the slider works again. *(Pass 58)*
4. Scroll Library, a show page, New and Search quickly. **Expect:** no stutter, no blank artwork, no jumping bars. *(U11, L18, P09)*
5. Long-press a Continue Playing card › "Remove from Continue Playing"; a New Episodes row › "Remove from New Episodes". **Expect:** each leaves its shelf and stays gone after relaunch. *(X58-05)*

## B. Listening (20 min, AirPods or Bose)

6. Play an episode with ads found. **Expect:** ads skipped with the skip notice; timeline shows the ad spans. *(A09, A10)*
7. Speed and Audio: change speed, a preset, Voice Boost; "This Show" vs "All Shows". **Expect:** audible each time; whichever you leave it on keeps playing after you close the page; Reset This Show returns to your default. *(A04, X55-05, X58-16)*
7b. Your shower-speaker show: on the shower speaker choose This Show, turn on **Remember for Each Speaker**; switch to headphones mid-episode. **Expect:** the sound changes to your default within a second or two; back on the speaker, the show's own again. Show Settings › Audio for This Show says "Custom · Some Speakers". *(X58-16)*
8. Lock the phone: Lock Screen card, play/pause, skip; tap the card. **Expect:** right episode and state; the tap opens PodSkipper's player. *(A03, A17, A18)*
9. Take a call (or Siri) mid-episode. **Expect:** pauses, resumes after if "Resume After Calls" is on. *(A16, P07)*
10. AirPods/Bose: double-tap/press to pause and play; switch to the speaker. **Expect:** works; no other app's sound stolen. *(A03, P07)*
11. CarPlay (if available). **Expect:** PodSkipper listed only if signed with CarPlay; otherwise not listed — either is fine, note which. *(C01)*
12. A video episode: Video/Audio switch, full screen, swipe down, Picture in Picture. **Expect:** picture in step with sound around a skipped ad; EQ audible on the video's sound once downloaded. *(V01–V08, A23)*
13. Stream an episode not downloaded. **Expect:** plays at once; "Streaming · EQ and fixes start once downloaded"; moves to the file without a gap. *(A05)*
14. Transcript: search a word, tap a line. **Expect:** jumps there; words light as said. *(A13, X50)*
15. Skip forward at an episode's end with autoplay on. **Expect:** the next queued/sorted episode, not a restart. *(A07, A08)*

## C. Finding ads (overnight + 30 min)

0. The new Reader: Find Ads Again on two episodes you know well. **Expect:** ads caught at least as well as before, less of the show cut; episodes the Reader alone had done get redone in the background on the charger. *(X58-07)*

16. *(changed in Pass 63)* Settings › Ad Skipping › **CPU model library**: download Qwen3.5 4B (CPU) (2.6 GB) if it isn't there already. **Expect:** all five CPU models are listed before any is downloaded; the download finishes and checks out; the row then has its own Basic and Hard. *(X58-02, X63-04)*
17. Queue Find Ads on 3 long episodes with an MLX model selected; lock the phone while listening to something else for 15 min. **Expect:** progress continues; Diagnostics › Background shows "reads … on the CPU while PodSkipper isn't on screen"; no "iOS ended PodSkipper". *(X58-02, P06)*
17b. With an MLX model as the finder, Find Ads Again on an episode with an outro. **Expect:** the outro is skipped even if the model didn't mark it, every ad the Reader found is still skipped, and banter that only names a brand is not cut. *(X58-15, X59-03)*
18. Leave the phone on a charger overnight with work queued. **Expect:** next morning the reads are done; "finished its read on the CPU … rested N s" lines. *(X58-02, P10, P16)*
19. Activity: Pause, Resume, Stop, Restart one job; relaunch the app. **Expect:** states stay as you left them; stopped stays stopped. *(P02, P03, P17, P18)*
20. Tap a "finished"/"failed" notification. **Expect:** opens that episode's job. *(P15)*
21. Compare models: run Basic on Apple Intelligence, the Reader and one MLX model; leave and come back mid-run. **Expect:** progress kept; Stop works; "On Your Episodes" shows each engine's score beside the Reader's on the same episodes. *(M03, M11, M12, X54-04, X59-05)*
21b. *(changed in Pass 63)* Compare models › **CPU Models (Processor)** › All CPU Models (after 16): run Basic and Hard on a downloaded CPU model. **Expect:** the bar moves within the first seconds and keeps moving; under it "Reading the sample on the CPU · part 1 of N · X% · N tokens a second", then "Writing its answer · N tokens"; the time left says "Measuring speed…" first, then a time; both finish. *(X59-04, X63-05)*
21c. Compare models › **The PodSkipper Test** › Run the Test (keep PodSkipper open; it can take an hour or more with Core AI). Leave the app once mid-run and come back. **Expect:** the screen stays on; "Paused: open PodSkipper to carry on" while away, then it carries on; at the end each finder's score beside the Reader's, and the episodes you listen with unchanged (no new cuts, no "Found by" change). If an episode says "a different version" or "not in your library", note which. *(X60-01)*
21d. *(Pass 62)* Compare models with last night's stopped run still there. **Expect:** your finished run's table shows; under it **Resume · Start Over · Keep Earlier Results**, each word centred in its button. Tap Keep Earlier Results: back to Run the Test, the table still there. *(X62-A1)*
21e. *(Pass 62; path changed in Pass 63)* Settings › Ad Skipping › CPU model library: download **Liquid LFM3 1.7B (CPU)** (new, 1.0 GB), **Qwen3.5 2B (CPU)** and **LFM2.5 1.2B (CPU)** (and the Instruct 6-bit CPU copy if you want it, 3.5 GB). Then The PodSkipper Test: switch on both Qwen3.5 4B models and the CPU models; Run the Test. **Expect:** each listed with its own switch; every CPU model finishes 264d9ec5 (no "320-token answer limit"); the CPU models' seconds per episode lower than last night's 266–2,382 s. *(X62-A3, X62-B1)*
21f. *(changed in Pass 63)* Basic and Hard (version 4) on the Reader, Apple Intelligence and a few models. **Expect:** the Reader above 90 on both (it was 80 and 0); every result shows Score, Ads cut, Show kept, Edges and Kinds; a model shows two scores, "Model alone" and "with PodSkipper's check"; no model answers with the whole sample as one ad or intro (an answer like that now scores as nothing found, not as everything cut); the scoreboard shows Score, Ads cut and Show kept for each. Hard is a 21-minute episode: it takes longer than before. *(X62-A2, X63-02, X63-03)*
21g. *(Pass 62; path changed in Pass 63)* Select a CPU model in the CPU model library, lock the phone with Find Ads queued and Apple Intelligence as your finder, on battery. **Expect:** Diagnostics › Background: "… reads N % of the transcript on the CPU", and the episode says "Found by <CPU model> for now: Apple Intelligence reads it again…". *(X62-B2)*
21h. *(Pass 63)* Settings › Ad Skipping › **Find Ads With**: five choices (PodSkipper Reader, Apple Intelligence, Open-source models (MLX, graphics chip), Core AI models, CPU models (processor)); under it **When Locked or in the Background** and one sentence saying who reads on screen and who reads off screen. Try each choice and both background settings. **Expect:** the sentence changes each time and matches what happens (Diagnostics › Background names who read). "Use It on Screen Too" is gone; if you had it on with an MLX or Core AI model chosen, Find Ads With now says CPU models. *(X63-04)*
21i. *(Pass 63)* Delete a CPU model you have tested (Compare models › All CPU Models, or the CPU model library). **Expect:** its row stays, with Download again, its latest Basic and Hard results and "All N runs, with details". *(X63-04)*
21j. *(Pass 63)* Settings › Ad Skipping › **Learned on This iPhone**, a minute after opening the new build. **Expect:** "In Use: Yes" and "Kept the new reader head…" dated today (your 10 Nov export said rolled back on 6 Nov and never tried again). Tap **Update Learned Reader**: a line says what it is doing ("Learning: reader 1 of 2…"), then the decision. Save a correction in What Was Skipped and look again within a minute: "Last Learned" is now. *(X63-01)*
21k. *(Pass 63)* Core AI model library. **Expect:** LFM3 1.7B, Qwen3.5 2B, Nanbeige4.2 3B and Mistral 7B can be downloaded (LFM3 and Mistral say which build is used); Qwen3.5 4B, GPT-OSS 20B and Muse Glimmer 30B are listed as too large for this iPhone, with their size; a line says Mixtral and Qwen3.5 4B Instruct aren't published for Core AI. Download one with little free space. **Expect:** it says how much space preparing it needs instead of closing; Settings › Storage shows no "NSIRD_PodSkipper…" leftovers after a failed preparation. *(X63-06)*
21l. *(Pass 64)* Compare models: start Basic on Qwen3.5 4B (MLX), then on a CPU model, and during the PodSkipper Test, tap **Stop** while it reads. **Expect:** the panel goes at once (no "Stopping…"), the result line says "Stopped by you"; starting another test straight away says "Waiting for the previous test to stop" for a few seconds at most, then runs. *(X64-01)*
21m. *(Pass 64)* Core AI library: try Gemma 3 4B or Qwen3.5 2B (Core AI) without a compiled copy, and any not-yet-prepared model with under 5 GB free. **Expect:** a plain message (needs a copy compiled on your Mac / not enough space) instead of PodSkipper closing; Settings › Storage shows no compiler leftovers after a Core AI test. *(X64-02)*
21n. *(Pass 64)* Basic and Hard (now version 5) on the Reader and a few models. **Expect:** each model's line leads with **Alone** (a model that finds nothing shows 0 %), then **Checked**; weak models' Checked no longer falls far below the Reader's (Ministral 3 3B was 48 % on Hard); Scores on This iPhone folds with its chevron and its cards show Alone · Checked · Ads cut · Show kept · tok/s. *(X64-03, X64-04)*
21o. *(Pass 64)* On the Mac, with the drive plugged in: `"/Volumes/Samsung PSSD T9 Media/PodSkipper/ssd_models.sh"` (downloads every model; Core AI compiles take ~17 min each). Then plug the drive into the iPhone: a model library › **External Drive** › Choose Folder → PodSkipper/Models. **Expect:** the drive's models listed; CPU and MLX ones "read from the drive" and test from it; **Import** shows X.XX GB / Y.YY GB and MB/s. *(X64-06)*
21p. *(Pass 64)* Import a Mac-compiled Core AI model (e.g. Gemma 3 4B) from the drive, then run Basic on it. **Expect:** it loads without "Preparing the model for this iPhone" and without closing. *(X64-02, X64-06)*
21q. *(Pass 64)* Compare models › The PodSkipper Test with last run stopped, after downloading another model. **Expect:** the new model's switch is listed with "Not in the last run yet"; buttons **Resume (+1) · Run Newly Added Models · Keep Earlier Results · Start Over**, one to a row, full width; Run Newly Added Models reads only the new one on the same episodes. *(X64-07)*
21r. *(Pass 64)* During a PodSkipper Test run. **Expect:** "About h:mm:ss left" from the models' own speeds (or "+ N finders not timed on this iPhone yet"), "Running … · this step m:ss" ticking even while a slow Core AI model reads its prompt; any download shows GB/GB · MB/s. *(X64-07)*
21s. *(Pass 65)* Settings › Accessibility › Display & Text Size › Larger Text, the largest size; open an episode's player, then Speed and Audio, then Settings › Ad Skipping › Core AI models. **Expect:** the four skip buttons one per line with whole words; the chart's zone names wrapping, none overlapping; the tone line whole; Delete/Download buttons with whole words. Set the size back afterwards. *(X65-02)*
22. Core AI Qwen3.5 2B and Qwen3 4B (if you still use them): Find Ads on one long episode. **Expect:** no closure; if it closes, note the time. *(X54-01, X55-04, X56-03, M19)*
23. Mark a found ad "not an ad", move an edge, add a missed one in the editor. **Expect:** saved, shown as edited with the original behind; Find Ads Again keeps your edits. *(D04, D12, D13, A19, A20)*
24. A funny host-read ad with "Keep Ads Played for Laughs" on. **Expect:** it plays; straight reads skip. *(X56-04)*

12b. *(Pass 62)* Legion of Skanks #963 (Colum Tyrrell) in **Video**, skips on or off. **Expect:** the video plays with its sound instead of "Video unavailable"; switch to Audio — it carries on at the same point with ads skipped. *(X62-A5)*

## D. Library and data (20 min)

25. Follow a new show from Search. **Expect:** all its episodes arrive (back catalogue), Library banner disappears when done; no "couldn't be saved" line. *(L08, L09, L21)*
26. Show page: sort/filter/season, then leave and return. **Expect:** your choices kept. *(L03)*
27. Stations: make one, Choose Shows…, reorder, Play All. **Expect:** plays in the shown order. *(L05, X58-05)*
28. Automatic Download Options: latest 3 for one show. **Expect:** only those download; Use Cellular Data respected. *(L06)*
29. Settings › Backup: Back Up Everything; Manage Backups; restore it. **Expect:** library, positions, corrections, settings back as they were. *(B01, B02, B08)*
30. Export OPML and listening history; import an OPML from Files. **Expect:** shows followed, nothing marked played that wasn't. *(B04–B07)*
31. Storage: clear downloaded audio for one show. **Expect:** sizes update; the playing episode kept. *(B03, B09, B10)*

## E. Two devices (iPad, 15 min)

32. iPhone: play to 12:00, star an episode, correct an ad. iPad: open after a minute. **Expect:** same position, star and correction; Settings shows which sync is used (iCloud or your relay). *(X54-06, X55-06, C04, X53-06)*
33. Delete an episode's download on one device. **Expect:** not deleted on the other (downloads are per device).

## F. Publishing (only if you use it, 15 min)

34. Publish 2 ad-free episodes of one show; airplane mode mid-upload; back online. **Expect:** resumes, finishes once each, one feed URL for the show; "Copy Feed Address" pasted into Apple Podcasts (Library › Follow a Show by URL) opens the ad-free feed. *(F01–F06)*

## G. System features (10 min)

35. Home Screen and Lock Screen widgets. **Expect:** current episode/queue, tap opens it. *(C01)*
36. Action button / Shortcuts: PodSkipper's "Play next in queue", "Play episode", "Refresh feeds". **Expect:** each works. *(C03)*
37. Live Activity during Find Ads. **Expect:** real progress and waits, ends when done. *(C05)*

## H. Over a day

38. Normal use for a day with Background App Refresh on. **Expect:** no heat warning in ordinary listening; battery use in iPhone Settings › Battery reasonable; new episodes appear. *(P09, X53-05)*
39. If the app ever closes or freezes: note the time. *(X56-01, X55-03)*
40. **Share Diagnostics…** (everything, 7 days) and send it with this list.
