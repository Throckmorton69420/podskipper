# Cloud task 10 — Explain the sound chart, one Activity look everywhere, haptics and motion

Branch: `cloud/polish`. Read `CLAUDE.md` first. Branch from current `main`. Don't touch `Services/LocalModel/`, `ModelFinder.swift`, `ProcessingPipeline.swift` (logic), `VideoSync.swift` (task 09). You may edit views that *display* pipeline state (`Views/ActivityView.swift` and the Activity pop-up/card view — find it), `Views/AudioControls.swift`, `Views/PlayerViews.swift` (non-video parts), `Models/SoundModel.swift` (read-only helpers), and add small shared UI files. Use the Liquid Glass and SwiftUI skills; follow Apple's HIG.

## 1. The sound chart has to explain itself (his words, 30 Sep)

"The top shows a chart with speed and audio, but the way it is right now, it doesn't give all that much info and it's hard to make sense of it for a layperson — make it more visually intuitive and explanatory, or have some sort of labels that can be tapped for more info."

- Label the frequency axis in plain words under the numbers: **Rumble · Boom · Warmth · Mud · Body · Voice · Presence · Clarity · Sibilance · Air** (matched to the real band ranges in `SoundModel`).
- Draw 0 dB as a clear "unchanged" line; shade boosts and cuts differently; label the vertical axis "Louder / Quieter".
- Show each active fix's contribution in its own colour on the curve, with a small legend (e.g. "Warm Speech", "Reduce Muddiness −4 dB at 250 Hz"). Tapping a legend item, a band label or an ⓘ opens a short popover: what it does, when to use it, what you'll hear ("Mud: 200–400 Hz. Cutting it makes voices less boxy.").
- A one-line plain summary under the chart that updates live: "Voices a bit warmer, less boxy; sibilance softened; loudness levelled."
- If "speed" is shown in that header, label it plainly too ("Playback 1.2×, Smart Speed saving ~4 min/hour").

## 2. One Activity look everywhere

"The Activity pop-up window needs to look the same as the Activity section on the Activity page — include the same details."

- Find the compact Activity pop-up/card (the one that appears at the top / from the mini player / Settings) and make it use the **same row view** as the Activity page: artwork, show, episode, current step in plain words (e.g. "Reading with the on-device model — part 3 of 7"), step list done/current/waiting, elapsed and remaining time, which finder is used, "N more waiting", "2/20 processed", and the same actions (pause, stop, open). One shared SwiftUI view used in both places, not two copies.

## 3. Haptics and motion, consistently

From his earlier requests: subtle haptics everywhere a control changes state; smooth, physical motion; Liquid Glass effects (edge highlights, scroll-edge transitions, morphing between states, symbol effects, spring animations, parallax on artwork).

- Audit every interactive control (buttons, toggles, sliders, steppers, segmented pickers, swipe actions, long-press menus, trim handles, pull to refresh, tab switches). Add `.sensoryFeedback` where missing with a consistent vocabulary: selection → `.selection`, toggles → `.impact(weight: .light)`, destructive/confirm → `.success`/`.warning`, slider detents → `.selection` at snap points. One small helper so it's consistent.
- Use `.symbolEffect` for state changes (play/pause, download, processing done), matched-geometry / morphing transitions where one control becomes another, `.scrollTransition` for list rows and shelves (subtle scale/opacity), glass effects via the system APIs (`glassEffect`, `GlassEffectContainer`) rather than custom blurs.
- **Performance rule:** no `.blur`/`.saturation`/`.drawingGroup` in anything that animates every frame; keep effects on the GPU-cheap path; respect Reduce Motion (turn parallax and big springs off).
- List every place changed in the PR.

## Done means

PR from `cloud/polish`, CI green (zero warnings from PodSkipper's code), description with before/after notes per screen and phone tests (open the sound screen, tap each label; start Find Ads and compare the pop-up with the Activity page; tap through Library, player, settings and feel for haptics; turn on Reduce Motion and check).
