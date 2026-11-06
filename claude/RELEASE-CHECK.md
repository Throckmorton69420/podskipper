# PodSkipper — release check (Pass 58, 6 November 2026)

What publishing PodSkipper would run into, checked against the code as it is now. **Fixed** means changed in this pass; **Needs you** means a decision or an account only you have; **Risk** means App Review or the law could object, with what would avoid it.

## Required before any App Store upload

| Item | State |
|---|---|
| Privacy manifest | **Fixed.** `Resources/Privacy/App/PrivacyInfo.xcprivacy` (app) and `…/Extension/…` (widget/Lock Screen): no tracking, no data collected by the developer; reasons for settings storage (CA92.1), file dates (C617.1, incl. llama.cpp's `stat`/`fstat` on the model file), free space (E174.1, 85F4.1), time since restart shown in Diagnostics (3D61.1). |
| Microphone purpose string | **Fixed.** It said "Not used…", which App Review rejects; now says plainly that PodSkipper never records and why iOS asks for the line. |
| Bundle identifier | **Needs you.** `com.yourname.podskipper` (+ `.nowplaying`) is a placeholder; the App Store needs IDs under your own developer team. The extra background-task names for your sideloaded installs (`com.worksin.two.*`, `app.ivory2951.coral5096.*`) are harmless but would be removed from a store build. |
| Developer account, signing, App Store Connect record, privacy policy URL, support URL | **Needs you.** |
| Data-collection answers in App Store Connect | "Data Not Collected" matches the code: iCloud sync uses your own iCloud, the relay and publishing use your own Cloudflare account, Diagnostics files are shared only by hand. |

## Entitlements

| Entitlement | For | Store status |
|---|---|---|
| CarPlay audio | the car's player | **Needs Apple's approval** (CarPlay request form). Without it the CarPlay scene is inert; nothing breaks. |
| iCloud key-value store, App Groups | sync, widgets | Standard capabilities. |
| Increased memory limit, extended virtual addressing | MLX / Core AI models | Standard capabilities. |
| Background GPU Access (`continued-processing.gpu`) | a started job continuing on the GPU | Standard capability, but **iPhone doesn't grant the GPU in the background** (Apple: iPad only; measured in Pass 58) — which is why the CPU reader exists. |
| Background inference (`continued-processing.inference`) | Neural Engine work in a continued task | Standard capability. |

## Risks App Review (or the law) could raise

1. **Publishing ad-free copies (feature "Publishing").** PodSkipper uploads edited episode audio to a public URL on your Cloudflare storage and serves it as a feed. That is redistributing other people's copyrighted audio. Guideline 5.2.1/5.2.2 (intellectual property) and ordinary copyright law both apply. **Avoid:** in a store build, either remove publishing or keep the copies private to the person (no public feed). For your own sideloaded builds it is your call.
2. **Looking like Apple Podcasts.** Guideline 5.2.5 forbids apps "confusingly similar" to Apple's own apps. PodSkipper copies Apple Podcasts' layout, strings and flows on purpose (your parity requirement). **Avoid:** a distinct name and icon (already), own accent colours and artwork style; keep native components, which are allowed.
3. **Skipping ads in other people's shows.** Not forbidden by a guideline (Overcast, Pocket Casts skip intros/silence), but publishers object; describe it as skipping, never as removing ads for others.
4. **Reader trained on SponsorBlock data (if the Pass 58 Reader ships).** SponsorBlock's database is CC BY-NC-SA 4.0 (attribution, non-commercial, share-alike), and the training audio came from YouTube. Fine for your own builds. For a store release: free app with attribution, or the Reader trained only on your own episodes (the one shipped today).
5. **Downloading models after install.** Allowed (data, not code — guideline 2.5.2). The app already asks before large downloads and shows sizes.
6. **YouTube video.** Opens in YouTube's own player ("Watch on YouTube"); no stream extraction. Allowed.

## Quality gates (Mac)

| Gate | State |
|---|---|
| Unit tests | 580 run / 0 failures / 1 skipped on b2bb998 |
| Accessibility audit on every main screen | **Added** (`testPass58AccessibilityAudit`); results below |
| Plain words | 1,029 on-screen strings scanned for technical terms: none in everyday screens ("API token" appears only in the Cloudflare publishing setup, Cloudflare's own term) |
| Save failures | **Fixed** (L21): 92 silent saves now logged and shown; catalogue merges roll back and retry |

## Accessibility audit results

Xcode's audit (`performAccessibilityAudit`, all checks) on 18 screens of the demo library, iPhone 16 Pro simulator, iOS 27.2.

| Run | Issues | What changed before it |
|---|---|---|
| 1 | 240 on 15 screens | — (133 text-size, 57 contrast, 42 cut-short, 6 unlabelled, 1 small target) |
| 2 | 105 on 18 screens | Match iPhone Text Size; "Nothing playing" contrast; separators hidden; Play All target; test reaches episode, player, Speed and Audio |
| 3 | 91 on 18 screens | show header darker; brighter secondary text on colour/glass/player; Publish label white; VoiceOver labels for the meta line; mini player art and banner chevron hidden; player grabber target |
| 4 | stopped part-way (a transient popup vanished while the audit read it); the 8 screens it covered matched run 3 | header author/stats/summary and people roles brighter; ad-free count white on the header; Search tiles shaded |

What remains after run 3 is mostly text measured on the mini player's Liquid Glass (its contrast depends on whatever scrolls under it — Apple's own glass behaves the same) and transport buttons in the collapsed mini player below 44 pt (as Apple's). Titles cut short with "…" in shelves are reported separately (4–5 per run), not counted: their full text is in VoiceOver's label, as in Apple Podcasts.
