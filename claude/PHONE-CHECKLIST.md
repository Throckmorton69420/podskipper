# PodSkipper — phone pass, hardware only (Pass 71, 26 November 2026, for the IPA built from the Pass 71 code commit — HANDOFF §1z7; list from Pass 70)

Personal sideload use is locked in: install the unsigned IPA from GitHub with your own signing, over your current install (your library stays).
This list now holds **only what needs the iPhone's own hardware**: on-device Core AI / MLX / CPU inference and the
Reader on your real library, the T9 over USB-C, audio routes (AirPods/Bose, speaker, CarPlay, calls, the Lock Screen and
Dynamic Island), two real devices, battery and heat, and one Diagnostics export. Everything that could be checked in the
iOS 27.2 simulator was moved to automated tests or Mac evidence — each removed item is mapped to its test in
`TASKS.md` (Pass 70, "Phone checklist audit"). Go in order; mark ✗ with a word or a screenshot where it differs.

## A. Audio routes and the Lock Screen (20 min, AirPods or Bose, then the speaker)

1. Play an episode with ads found, on AirPods. **Expect:** ads skipped with the skip notice; Speed and Audio changes (speed, a preset, Voice Boost) audible at once. Then stream one that isn't downloaded: plays at once, "Streaming · EQ and fixes start once downloaded", no gap when it moves to the file. *(A04, A05, A09, A10)*
2. Your shower-speaker show: on the speaker choose This Show and **Remember for Each Speaker**; switch to headphones mid-episode. **Expect:** your default sound within a second or two; back on the speaker, the show's own. *(X58-16)*
3. Lock the phone: Lock Screen card, play/pause, skip; tap the card; the Dynamic Island while Find Ads runs. **Expect:** right episode and state; the tap opens the player; the Live Activity shows real progress and ends when done. *(A03, A17, A18, C05)*
4. Take a call (or Siri) mid-episode. **Expect:** pauses; resumes afterwards when "Resume After Calls" is on. *(A16, P07)*
5. AirPods/Bose double-tap/press to pause and play; switch to the speaker. **Expect:** works; no other app's sound taken. *(A03, P07)*
6. CarPlay (if available). **Expect:** PodSkipper listed when the build carries CarPlay (it does: personal sideload keeps every capability); note what you see. *(C01)*
7. A video episode on AirPods, downloaded: Picture in Picture, then lock. **Expect:** picture in step with sound around a skipped ad; EQ audible on the video's sound. *(V01–V08, A23)*
8. Action button / Shortcuts on the phone: "Play next in queue", "Play episode", "Refresh feeds"; a Lock Screen widget. **Expect:** each works; the widget shows the current episode and opens it. *(C01, C03)*

## B. On-device reading (overnight + 45 min)

9. The new Reader (Pass 71: one pair, `finalv4`, replaces the four) on your library: Find Ads Again on two episodes you know well, then leave the phone on the charger so Reader-labelled episodes are labelled again (detector 67). **Expect:** the same breaks skipped or more, no new cuts in the talk (in the lab it cut less of the show on unseen shows: 6.3 → 3.9 s/h; on your 11 test episodes it heard about 6 s/h more ad than the four — a produced movie trailer and a host's hand-off read are the known misses); scrolling stays smooth. *(X58-07, X66-02, X66-05, X71-02)*
10. Compare models › Scores on This iPhone: Basic and Hard on the Reader. **Expect:** 93 and 96 (detector 67; Hard names one of 17 breaks wrong). Results saved by earlier builds now say "earlier policy" until you run them once (Pass 70: Reader results follow the detector version). *(X70-02)*
11. Basic and Hard on Apple Intelligence, one MLX, one CPU and one Core AI model; tap Stop once mid-read. **Expect:** progress moves within seconds ("part 1 of N · X% · N tokens a second"); Stop ends it at once ("Stopped by you"); each line leads with Alone, then Checked. *(X59-04, X63-05, X64-01, X64-03, X64-04)*
12. The PodSkipper Test with the CPU models and two Qwen3.5 4B switched on; leave the app once mid-run. **Expect:** "Paused: open PodSkipper to carry on", then it carries on; "About h:mm:ss left"; every CPU model finishes without "answer limit". *(X60-01, X62-A3, X62-B1, X64-07)*
13. Queue Find Ads on 3 long episodes with an MLX finder, lock the phone and listen to something else for 15 min; then leave work queued overnight on the charger. **Expect:** Diagnostics › Background shows "reads … on the CPU while PodSkipper isn't on screen", no "iOS ended PodSkipper"; next morning the reads are done. *(X58-02, P06, P10, P16, X62-B2)*
14. Core AI: Qwen3.5 2B or Gemma 3 4B with no compiled copy; any unprepared model with under 5 GB free; Find Ads with Qwen3 4B on one long episode. **Expect:** a plain message instead of closing; no compiler leftovers in Storage; no closure (note the time if it closes). *(X54-01, X63-06, X64-02, M19)*
15. Learned on This iPhone, a minute after opening the build: "In Use: Yes"; tap Update Learned Reader. **Expect:** it says what it is doing, then the decision; after saving a correction, "Last Learned" is now. *(X63-01)*

## C. The T9 over USB-C (20 min; on the Mac first: `"/Volumes/Samsung PSSD T9 Media/PodSkipper/ssd_models.sh"`)

16. With PodSkipper open on Compare Models, plug the T9 in (folder chosen once before). **Expect (Pass 70):** within a few seconds, without Read Again, the drive's models show "Ready · on your drive" (CPU, MLX, and Core AI models the Mac compiled for this iPhone) and **Import** beside **Download**. Unplug: they go back to "Not downloaded" within a few seconds; nothing closes when no model is reading. *(X64-06, X65-10, X70-01)*
17. **Core AI straight from the drive (Pass 70):** with the T9 in, choose a Core AI model the Mac compiled for this iPhone that isn't on the phone (it says "Reads the copy compiled on your Mac for this iPhone from your external drive"), run Basic. **Expect:** it loads without "Preparing…" and without closing, reading from the drive. *(X70-01)*
18. Import one model of each kind from the drive (for a Core AI build with both graphs, the dialog offers Compiled Copy or Portable Build); press Stop once. **Expect:** GB/GB · MB/s while it copies; Stop says "Import stopped; nothing was kept"; finished: "… is on this iPhone now", then Delete. *(X64-06, X65-10, X66-06, X66-08)*
19. **Import from Files (Pass 70):** T9 unplugged and nothing on it chosen, tap Import in a CPU model's row and pick its .gguf from iCloud Drive or On My iPhone; in another row pick the wrong file. **Expect:** the right file imports with progress; the wrong one says which model it is and what that row wants. *(X70-01)*

## D. Two devices and the network (20 min, iPhone + iPad)

20. iPhone: play to 12:00, star an episode, correct an ad. iPad after a minute. **Expect:** same position, star and correction; Settings names the sync used. *(X54-06, X55-06, C04, X53-06)*
21. Delete an episode's download on one device. **Expect:** not deleted on the other.
22. Publishing (only if you use it): 2 ad-free episodes, airplane mode mid-upload, back online; paste "Copy Feed Address" into Apple Podcasts (Library › Follow a Show by URL). **Expect:** resumes, each once, one feed; Apple Podcasts opens the ad-free feed (Apple Podcasts isn't in the simulator). *(F01–F06)*

## E. Over a day, then Diagnostics

23. Normal use for a day with Background App Refresh on. **Expect:** no heat warning in ordinary listening; battery use reasonable; new episodes appear; if the app ever closes or freezes, note the time. *(P09, X53-05, X56-01, X55-03)*
24. Tap a "finished" or "failed" Find Ads notification (a system notification tap can't be driven by a test). **Expect:** opens that episode's job. *(P15)*
25. **Share Diagnostics…** (Settings › Diagnostics, everything, last 7 days) and send it with this list.
