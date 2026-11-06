# PodSkipper — one phone pass (Pass 58, 6 November 2026, for IPA 48aab59)

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

16. Settings › MLX models › Reading in the Background: download the CPU copy (2.6 GB). **Expect:** download finishes and checks out. *(X58-02)*
17. Queue Find Ads on 3 long episodes with an MLX model selected; lock the phone while listening to something else for 15 min. **Expect:** progress continues; Diagnostics › Background shows "reads … on the CPU while PodSkipper isn't on screen"; no "iOS ended PodSkipper". *(X58-02, P06)*
17b. With an MLX model as the finder, Find Ads Again on an episode with an outro. **Expect:** the outro is skipped even if the model didn't mark it, and banter that only names a brand is not cut. *(X58-15)*
18. Leave the phone on a charger overnight with work queued. **Expect:** next morning the reads are done; "finished off screen … rested N s" lines. *(X58-02, P10, P16)*
19. Activity: Pause, Resume, Stop, Restart one job; relaunch the app. **Expect:** states stay as you left them; stopped stays stopped. *(P02, P03, P17, P18)*
20. Tap a "finished"/"failed" notification. **Expect:** opens that episode's job. *(P15)*
21. Compare models: run Basic on Apple Intelligence, the Reader and one MLX model; leave and come back mid-run. **Expect:** progress kept; Stop works; "On Your Episodes" shown beside. *(M03, M11, M12, X54-04, X58-04)*
22. Core AI Qwen3.5 2B and Qwen3 4B (if you still use them): Find Ads on one long episode. **Expect:** no closure; if it closes, note the time. *(X54-01, X55-04, X56-03, M19)*
23. Mark a found ad "not an ad", move an edge, add a missed one in the editor. **Expect:** saved, shown as edited with the original behind; Find Ads Again keeps your edits. *(D04, D12, D13, A19, A20)*
24. A funny host-read ad with "Keep Ads Played for Laughs" on. **Expect:** it plays; straight reads skip. *(X56-04)*

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
