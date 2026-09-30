> Parked for the Mac session (pipeline-heavy; needs phone checks). Don't run in the cloud for now.

# Cloud task 14 — Pause and Resume in Activity

Branch: `cloud/activity-pause`. Read `CLAUDE.md` first. Branch from current `main`. This one does touch `ProcessingPipeline.swift` — keep changes small and read `claude/HANDOFF.md` §1 and HANDOFF's background notes first. Don't touch `Services/LocalModel/` except to call it.

His request: the Activity screen and the Activity pop-up (shared `Views/ActivityNow.swift`, task 10) need Pause next to Stop. The pipeline has no pause today.

## What to build
- `pause` on the running job: finish or checkpoint the current step, keep everything done so far (download, transcript — "a finished transcript is never redone" — `DetectionCheckpoint`, resumable transcription from task 03), keep its place in the line, release the model/GPU memory, and end any `BGContinuedProcessingTask` and `KeepAwake` silent audio cleanly (a `beginBackgroundTask` is ended in its expiration handler).
- `resume` picks it up from where it stopped, same place in the line. Paused jobs survive an app relaunch (persist the paused state) and are shown as "Paused" in Activity with Resume and Stop.
- While paused, nothing else starts automatically ahead of it unless he taps something else; if he starts another episode, the paused one waits behind it.
- The step that can't be interrupted mid-way (a model window, a transcription chunk) finishes first; the button shows "Pausing…" until then, with the same 4-second honesty rule Stop uses (say so in the log if the step didn't end by itself).
- Activity page and pop-up show the same Pause/Resume (shared view).

## Done means
PR from `cloud/activity-pause`, CI green, zero warnings, a unit test for pause/resume state. Simulator screenshots of Activity running, pausing, paused. Phone test in the description: Find Ads on a long episode → Pause during transcription → close and reopen the app → Resume → it continues from the same percentage, transcript not redone.
