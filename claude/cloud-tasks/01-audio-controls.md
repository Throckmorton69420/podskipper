# Cloud task 01 — One set of audio controls; the EQ shows what they do

Branch: `cloud/audio-controls`. Read `CLAUDE.md` first.

## What Shashank asked for (his words, 24 Sep)

> the audio options right now seem to have a bunch of redundancies in the form of addressing different parts of speech and audio (e.g. de-esser and sibilance) and then having that same thing in the equalizer setting. It would be cool to have the equalizer reflect the changes made by the toggles. Also, if there are any preset in the equalizer that do the equivalent thing as what one of the toggles does then if that preset is selected then maybe have that toggle enabled and selecting the extent of the effect is reflected back on the equalizer. For example, if remove muddiness is selected then the equalizer would show the corresponding changes on the different bands on the equalizer; also, these bands would change in real time as the remove muddiness slider is adjusted to reflect that change. also when something like reduce muddiness preset is selected, it should toggle the reduce muddiness effect with the position of the slider in the corresponding place. also, if the equalizer is already on one of the other presets then it should start with that as a baseline and have the toggled effect reflect on top of it. for example, if warm speech is selected as the preset then start with the band settings for that as the baseline (done in the background) and then to that add any of the other toggle effects that are selected like reduce boom, reduce harshness, reduce sibilance, reduce muddiness, enhance dialogue, de-esser, rumble filter, voice boost, volume normalization, etc. as applicable. Use sound engineering principles and physics and all the available scientific and technical knowledge to make the necessary improvements.

Catalog rows (all OPEN): no duplicate controls · preset is the base state · other controls layer on top · the UI shows the combined result.

## Where the code is

- `Services/AudioEngine.swift` — the `AVAudioUnitEQ` graph: 10 ISO bands (`EQPreset.frequencies`) plus dedicated bands (`EQBand.rumble`, `EQBand.deEsser`, voice low-cut/presence, …) and `apply(settings:normalizationGain:)`.
- `Models/Models.swift` — `AppSettings` (voiceBoost, normalize, rumble, deEsser + strength, mudCut + amount, equalizer on/preset/gains, …) and `struct EQPreset` (Flat, Speech, Voice Clarity, Warm Speech, Reduce Harshness, …).
- `Views/AudioControls.swift` (`RepairRow`, …), and the audio/EQ parts of `Views/PlayerViews.swift` and `Views/SettingsViews.swift`.

Read all of these fully before designing.

## What to build

1. **One model of the sound.** What you hear = preset band gains (the base) + each enabled repair's band contribution scaled by its strength slider. Write this as one pure function (e.g. `EQMath.combinedGains(preset:repairs:) -> [Double]`) used by both the audio engine and the UI, so they can never disagree. Clamp to the EQ's range.
2. **No duplicates.** Merge controls that do the same thing (e.g. "De-esser" and "Reduce sibilance" become one control with one strength). Keep existing `UserDefaults` keys working: migrate old values on first launch so nobody loses their settings.
3. **Presets that equal a repair** (e.g. a "Reduce muddiness"-type preset): choosing it turns that repair on at the matching strength on top of Flat, instead of being a separate band shape.
4. **Repairs the 10 bands can't show** (rumble high-pass, narrow de-esser notch, normalization, voice boost gain) stay on their dedicated bands in the engine, but the EQ view still draws their effect (e.g. an overlay of the combined response), so the picture matches what you hear.
5. **Live update:** moving a repair's slider moves the drawn curve/bands immediately, without audio glitches (apply to the engine at most ~30 times a second).
6. Base the band shapes on speech sound-engineering practice (boom ≈ 80–150 Hz, muddiness ≈ 200–400 Hz, presence/dialogue ≈ 2–4 kHz lift, harshness ≈ 2.5–5 kHz, sibilance ≈ 5–9 kHz). Explain the choices briefly in comments.

## Out of scope

Per-show EQ (task 02 does it after this merges). Don't touch playback, detection, or the files listed in `CLAUDE.md`.

## Done means

PR open from `cloud/audio-controls`, CI build green with zero warnings, PR description per `CLAUDE.md` including exact phone test steps (e.g. "Settings → Audio → pick Warm Speech, turn on Reduce Muddiness, drag its slider: the EQ curve should dip around 250 Hz as you drag").
