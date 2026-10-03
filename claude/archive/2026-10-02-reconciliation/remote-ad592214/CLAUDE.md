# PodSkipper — instructions for Claude Code sessions

## Local engineering takeover

The current Mac implementation is tracked in `claude/HANDOFF.md` and
`claude/REQUEST-CATALOG.md`. The cloud-only coordination restrictions below
do not apply to that isolated local worktree. Preserve other checkouts and the
installed app; use validated atomic commits and complete pull requests.
The current deployment target is iOS 27 and unsigned delivery uses Feather.

Read this whole file before touching code. It is written for **cloud sessions** (claude.ai/code), which work in parallel with the main session on Shashank's Mac.

## The app and the person

- PodSkipper is an iOS 26+ podcast app (SwiftUI + SwiftData, XcodeGen `project.yml`) that transcribes episodes on the phone and skips ads. Shashank (a physician, not a developer) uses it on an iPhone 16 Pro, iOS 27, sideloaded with KSign as `com.worksin.two`. The only way a build reaches his phone is the IPA that GitHub Actions (`.github/workflows/build-ipa.yml`) builds from `main`.
- He judges results on his phone. Never claim something works unless it was shown working; a green build only proves it compiles. Name everything that wasn't tested.
- Plain, short language in anything he reads (PR descriptions, UI text). No jargon in UI strings.

## What a cloud session can and cannot do

- There is **no Mac, no Xcode, no simulator** here. You cannot build or run the app. The pull-request build (GitHub Actions, `macos-26`) is your compiler: push, open the PR, and check its result (`gh pr checks` if `gh` works; otherwise say in the PR that the check still needs looking at).
- **Zero warnings** is the standard. The CI runner's Xcode is older than the Mac's: guard any API newer than iOS 26.0 SDK with `#if compiler(>=6.4)`.
- Look up Apple APIs in Apple's documentation; do not guess signatures. If an API can't be confirmed, choose the older, well-known one.

## Git rules

- Work on a branch named `cloud/<task-name>`. **Never push to `main`, never merge, never force-push someone else's branch.** Open a pull request to `main`; the Mac session reviews and merges it.
- Small, focused commits. Commit messages end with the `Co-Authored-By` line your environment gives you.
- Never commit secrets, keys, tokens, `build/`, audio or model files.

## Files you must NOT edit (the Mac session is changing them now)

`Services/ProcessingPipeline.swift`, `Services/SegmentDetector.swift`, `Services/SentenceTagger.swift`, `Services/AdDetector.swift`, `Services/FastReader.swift`, `Services/SegmentEvidence.swift`, `Services/AdFreeCopy.swift`, `Services/AdPrints.swift`, `Services/KeepAwake.swift`, `Services/BackgroundWork.swift`, `Views/ActivityView.swift`, `Views/DiagnosticsView.swift`, anything under `Tools/`, `Resources/Detection/`, `.github/`, and `project.yml`. If your task seems to need one of them, stop and describe the change you need in the PR instead of making it.

## SwiftUI / code rules that have cost the most

- A value that changes more than about once a second is read in its own small view. No `.blur`, `.saturation` or `.drawingGroup` in a frame loop.
- No whole-library work on the main thread (use `LibraryIndex` or a limited `FetchDescriptor`). `Task {}` from main-actor code stays on the main actor; use `Task.detached` for heavy work.
- One `.sheet` per view, driven by an enum item. Push value-link screens on the navigation stack's path. Hide a List row chevron with `.navigationLinkIndicatorVisibility(.hidden)`.
- Never assign `segment.userVerdict` directly: use `Episode.apply(_:to:)`.
- Settings live in `AppSettings` (`Models/Models.swift`), saved to `UserDefaults` through the `save(_:_:)` pattern with defaults registered in `init()`. Per-show values live on the `Podcast` model (see `voiceBoostOverride`). SwiftData model changes must stay lightweight-migratable: new stored properties need defaults or must be optional.
- Keep the existing file and naming style. Comments explain *why*, briefly.

## Pull request description (this is what the Mac session and Shashank read)

1. What changed, in plain lines.
2. Status of each requirement: BUILT / UNVERIFIED, PARTIAL, or not done — never "verified".
3. Exactly what Shashank should test on the phone, step by step.
4. Anything you were unsure of or couldn't confirm.

## Task briefs

The current tasks are in `claude/cloud-tasks/`. Do only the task you were given.
