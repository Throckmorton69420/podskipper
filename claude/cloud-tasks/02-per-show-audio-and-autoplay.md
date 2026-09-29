# Cloud task 02 — Per-show EQ and per-show autoplay

Branch: `cloud/per-show`. Read `CLAUDE.md` first. **Start only after task 01 (`cloud/audio-controls`) is merged into `main`**, and branch from the new `main`.

## What Shashank asked for

Catalog rows (OPEN): **Per-show EQ** and **Per-show autoplay**. There is already a global "Continue playing after an episode ends" (`AppSettings.continuousPlayback`; autoplay in `Services/PlayerEngine.swift`) and a global EQ/audio setup (task 01's combined model).

## What to build

1. **Per-show audio.** On a show's page (its settings / "…" menu), an "Audio for this show" screen: *Use my default* (default) or a custom preset + repairs for this show, using exactly the same controls and the same combined-gains function as task 01. When an episode of that show plays, its settings apply; switching to another show's episode switches them. `Podcast` already has a per-show `voiceBoostOverride` (`Models/Models.swift`) — fold it into the new per-show settings and migrate it.
2. **Per-show autoplay.** On the same show settings: "Continue playing" — *Use my default* / *On* / *Off*. When an episode of that show ends, this decides whether autoplay continues (keep the show's existing ordering rules; don't change the ordering or the "play without ads?" prompt).
3. Store both on `Podcast` as optional fields (nil = use default) so SwiftData migrates lightly, and include them in backup/restore (`Services/BackupService.swift`) so a restore keeps them.

## Out of scope

Autoplay ordering, the play-without-ads prompt, detection, and the files listed in `CLAUDE.md`.

## Done means

PR open from `cloud/per-show`, CI green with zero warnings, PR description with phone test steps (e.g. "Open Bad Friends → … → Audio for this show → Warm Speech. Play a Bad Friends episode, then a YMH episode: the EQ goes back to your default").
