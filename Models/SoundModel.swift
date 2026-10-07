import Foundation

// MARK: - One model of the sound
//
// What you hear is: the preset's ten band gains (the base), plus every
// switched-on repair's own band shape scaled by its slider, plus the few
// things ten one-octave bands can't do (a rumble high-pass, a narrow
// sibilance notch, and the overall level). All of it is worked out here, in
// plain functions with no audio or UI in them, and both the audio engine and
// the equalizer view read the same answer — so what is drawn is what plays.

/// A speech repair: one problem, one switch, one strength.
///
/// The band shapes follow standard dialogue-mixing practice. Each is a set of
/// weights over the ten ISO bands, in dB per dB of strength, centred where the
/// problem actually lives rather than on whichever band is nearest a label:
///
/// - Rumble, below ~80 Hz: traffic, air conditioning, desk thumps. Below the
///   lowest voice fundamental (~85 Hz for a deep male voice), so a high-pass
///   removes it without touching speech.
/// - Boom, ~80–150 Hz: chest resonance and the proximity effect of a close
///   directional mic. Centred between the 64 and 125 bands, leaning to 125.
/// - Mud, ~200–400 Hz: small untreated rooms pile up reflections here and the
///   voice sounds boxy. Centred just above 250.
/// - Dialogue presence, ~2–4 kHz: consonants carry intelligibility here and
///   the ear is most sensitive here, so a lift makes words clearer without
///   making them much louder. A gentle trim below speech and a touch of air
///   at 8 kHz go with it, the classic "voice boost" shape.
/// - Harshness, ~2.5–5 kHz: the same region seen from the other side — too
///   much of it is glare and listening fatigue. Centred near 3.5 kHz, which
///   leans on the 4k band.
/// - Sibilance, ~5–9 kHz: S, SH and T. A one-octave band is too wide to cut
///   it without dulling the voice, so most of the cut is a narrow notch at
///   7 kHz on its own band, with only a little taken off the 8k band.
enum Repair: String, CaseIterable, Identifiable, Hashable, Codable {
    // Low to high. Nasal and Muffled added in pass 29 (his 5 Oct question:
    // is a fix missing?). Every other fix was a cut or the presence lift; a
    // dull, muffled guest needed a top-end lift, and a honky, nasal voice a
    // cut around 1 kHz, both standard dialogue repairs.
    case rumble, boom, mud, nasal, dialogue, harshness, sibilance, muffled

    var id: String { rawValue }

    /// Signed dB per dB of strength on each of the ten bands, low to high
    /// (32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k).
    var bandShape: [Double] {
        switch self {
        case .rumble:    return Array(repeating: 0, count: 10)
        case .boom:      return [-0.4, -0.8, -1.0, -0.3,  0,    0,   0,    0,    0,    0]
        case .mud:       return [ 0,    0,   -0.3, -1.0, -0.4,  0,   0,    0,    0,    0]
        case .nasal:     return [ 0,    0,    0,    0,   -0.35, -1.0, -0.3, 0,    0,    0]
        case .dialogue:  return [-0.5, -0.5, -0.3, -0.1,  0,  0.1, 0.8,  0.8,  0.3,  0]
        case .harshness: return [ 0,    0,    0,    0,    0,    0,  -0.45, -1.0, -0.2, 0]
        case .sibilance: return [ 0,    0,    0,    0,    0,    0,   0,    0,  -0.3,  0]
        case .muffled:   return [ 0,    0,    0,    0,    0,    0,   0.1,  0.35, 0.85, 0.7]
        }
    }

    /// The slider's range, in dB at the deepest point. nil for a plain switch.
    var range: ClosedRange<Double>? {
        switch self {
        case .rumble:    return nil
        case .boom:      return 2...12
        case .mud:       return 2...12
        case .nasal:     return 1...8
        case .dialogue:  return 1...8
        case .harshness: return 1...10
        case .sibilance: return 2...12
        case .muffled:   return 1...8
        }
    }

    var defaultStrength: Double {
        switch self {
        case .rumble:    return 1
        case .boom:      return 6
        case .mud:       return 5
        case .nasal:     return 4
        case .dialogue:  return 4
        case .harshness: return 4
        case .sibilance: return 6
        case .muffled:   return 3
        }
    }

    func clamped(_ strength: Double) -> Double {
        guard let range else { return 1 }
        return min(range.upperBound, max(range.lowerBound, strength))
    }

    // UserDefaults keys. These are the keys the separate controls always
    // used, so nobody's settings move.
    var enabledKey: String {
        switch self {
        case .rumble:    return "rumble"
        case .boom:      return "bassCut"
        case .mud:       return "mudCut"
        case .nasal:     return "nasalCut"
        case .dialogue:  return "voiceBoost"
        case .harshness: return "harshCut"
        case .sibilance: return "deEsser"
        case .muffled:   return "brighten"
        }
    }

    var strengthKey: String? {
        switch self {
        case .rumble:    return nil
        case .boom:      return "bassCutAmount"
        case .mud:       return "mudCutAmount"
        case .nasal:     return "nasalCutAmount"
        case .dialogue:  return "voiceBoostAmount"
        case .harshness: return "harshCutAmount"
        case .sibilance: return "deEsserAmount"
        case .muffled:   return "brightenAmount"
        }
    }

    // Words for the settings screen.
    var title: String {
        switch self {
        case .rumble:    return "Reduce Rumble"
        case .boom:      return "Reduce Boom"
        case .mud:       return "Reduce Muddiness"
        case .nasal:     return "Reduce Nasal Tone"
        case .dialogue:  return "Enhance Dialogue"
        case .harshness: return "Reduce Harshness"
        case .sibilance: return "Reduce Sibilance"
        case .muffled:   return "Brighten Muffled Voices"
        }
    }

    var plain: String {
        switch self {
        case .rumble:    return "Removes low hum and thumps: traffic, air conditioning, a bumped mic."
        case .boom:      return "For voices that sound boomy, chesty, or too bass-heavy."
        case .mud:       return "Clears up boxy speech that sounds like it was recorded in a cupboard."
        case .nasal:     return "For honky voices that sound pinched or stuffed-up, as if talking through the nose."
        case .dialogue:  return "Makes words clearer and lifts quiet or distant hosts."
        case .harshness: return "Takes the edge off bright, glaring voices. Easier over a long session."
        case .sibilance: return "Softens harsh S, SH and T sounds."
        case .muffled:   return "For dull, muffled voices: a cheap mic, a phone-in guest, or a thick windscreen."
        }
    }

    var technical: String {
        switch self {
        case .rumble:    return "High-pass at 80 Hz."
        case .boom:      return "Cut centred near 110 Hz."
        case .mud:       return "Cut centred near 280 Hz."
        case .nasal:     return "Cut centred near 1 kHz."
        case .dialogue:  return "Lift at 2–4 kHz, trim below 125 Hz, small level lift."
        case .harshness: return "Cut centred near 3.5 kHz."
        case .sibilance: return "Narrow cut at 7 kHz, plus a little at 8 kHz."
        case .muffled:   return "Lift above 4 kHz, most at 8–16 kHz."
        }
    }

    var symbol: String {
        switch self {
        case .rumble:    return "wind"
        case .boom:      return "speaker.wave.1"
        case .mud:       return "aqi.medium"
        case .nasal:     return "nose"
        case .dialogue:  return "person.wave.2"
        case .harshness: return "moon.zzz"
        case .sibilance: return "waveform.badge.minus"
        case .muffled:   return "sparkles"
        }
    }
}

/// One filter in the chain, described without AVFoundation so the view can
/// draw it and the engine can build it from the same numbers.
struct FilterSpec: Equatable {
    enum Kind { case lowShelf, highShelf, peak, highPass }
    var kind: Kind
    var frequency: Double
    /// Octaves, for a peak. Ignored by the others.
    var bandwidth: Double
    var gain: Double
    var isOn: Bool
}

/// Everything that shapes the sound, as one comparable value.
struct SoundSettings: Equatable {
    /// The preset's ten band gains in dB; zeros when the equalizer is off.
    var base: [Double]
    /// Only the repairs that are on, with their strengths.
    var repairs: [Repair: Double]
    /// Volume normalization for this episode, in dB. 0 when off.
    var normalizationDB: Double
}

/// What the engine should be set to. Built only by `EQMath.plan`.
struct SoundPlan: Equatable {
    /// The ten ISO bands, low shelf / peaks / high shelf, combined gains.
    var bands: [FilterSpec]
    var rumble: FilterSpec
    var sibilanceNotch: FilterSpec
    /// Broadband gain in dB: normalization + loudness match + dialogue lift.
    var levelDB: Double

    var combinedGains: [Double] { bands.map(\.gain) }
    var allFilters: [FilterSpec] { bands + [rumble, sibilanceNotch] }
}

enum EQMath {
    /// How far a band you hear may move: PodSkipper's own limit for speech
    /// (and for headroom), not the audio unit's — `AVAudioUnitEQ` accepts
    /// −96…+24 dB per band. Every band can always be dragged across all of
    /// it, fixes or not.
    static let gainRange: ClosedRange<Double> = -12...12
    /// Pass 32 (his 7 Oct report: with fixes on, 32 Hz–1 kHz stopped well
    /// short of the slider's ends). The preset part of a band used to be held
    /// to ±12 on its own, so with Reduce Muddiness taking 6 dB out of 250 Hz
    /// the band you hear could only reach +6. The preset part now goes as far
    /// as it must to put the band where the finger is; the band you hear is
    /// still held to `gainRange`, so nothing louder ever reaches the EQ.
    static let baseGainRange: ClosedRange<Double> = -36...36
    static let frequencies: [Double] = EQPreset.frequencies.map(Double.init)

    // MARK: Bands

    /// What the repairs alone add to each of the ten bands.
    static func repairContribution(_ repairs: [Repair: Double]) -> [Double] {
        var total = Array(repeating: 0.0, count: 10)
        for (repair, strength) in repairs {
            let s = repair.clamped(strength)
            for (index, weight) in repair.bandShape.enumerated() {
                total[index] += weight * s
            }
        }
        return total
    }

    /// Preset (base) plus every enabled repair, clamped to the EQ's range.
    /// The one function both the engine and the UI use for the ten bands.
    static func combinedGains(preset: [Double], repairs: [Repair: Double]) -> [Double] {
        let added = repairContribution(repairs)
        return (0..<10).map { index in
            let base = preset.indices.contains(index) ? preset[index] : 0
            return clamp(base + added[index])
        }
    }

    /// The base gain that makes a band land on `target` once the repairs are
    /// added — so dragging a band puts it where the finger is.
    static func baseGain(forTarget target: Double, band: Int, repairs: [Repair: Double]) -> Double {
        clampBase(clamp(target) - repairContribution(repairs)[band])
    }

    static func clamp(_ gain: Double) -> Double {
        min(gainRange.upperBound, max(gainRange.lowerBound, gain))
    }

    /// The preset part of a band (see `baseGainRange`).
    static func clampBase(_ gain: Double) -> Double {
        min(baseGainRange.upperBound, max(baseGainRange.lowerBound, gain))
    }

    // MARK: Plan

    static func plan(_ sound: SoundSettings) -> SoundPlan {
        let gains = combinedGains(preset: sound.base, repairs: sound.repairs)
        let bands = gains.enumerated().map { index, gain in
            FilterSpec(kind: index == 0 ? .lowShelf : (index == 9 ? .highShelf : .peak),
                       frequency: frequencies[index], bandwidth: 1.0, gain: gain, isOn: true)
        }

        // 80 Hz, 12 dB/octave: below the lowest voice fundamental.
        let rumble = FilterSpec(kind: .highPass, frequency: 80, bandwidth: 1.0, gain: 0,
                                isOn: sound.repairs[.rumble] != nil)

        // Three quarters of the sibilance cut goes on a narrow (0.6 octave)
        // notch at 7 kHz; the 8k band carries the rest (see `bandShape`).
        let sibilance = sound.repairs[.sibilance].map { Repair.sibilance.clamped($0) }
        let notch = FilterSpec(kind: .peak, frequency: 7000, bandwidth: 0.6,
                               gain: -0.75 * (sibilance ?? 0), isOn: sibilance != nil)

        var plan = SoundPlan(bands: bands, rumble: rumble, sibilanceNotch: notch, levelDB: 0)
        plan.levelDB = sound.normalizationDB + loudnessMatchDB(plan) + dialogueLiftDB(sound.repairs)
        return plan
    }

    /// Enhance Dialogue also raises the level a little, as Voice Boost did,
    /// for quiet hosts: +3 dB at strength 5. The loudness match takes back
    /// about 2 dB of that for the presence lift itself, so the net is ~+1 dB.
    static func dialogueLiftDB(_ repairs: [Repair: Double]) -> Double {
        guard let s = repairs[.dialogue] else { return 0 }
        return 0.6 * Repair.dialogue.clamped(s)
    }

    /// Keeps the tone changes from also changing how loud speech is.
    ///
    /// Cutting boom or mud takes energy out and the voice sounds quieter, so
    /// the difference is judged better or worse by loudness rather than tone.
    /// Mix engineers level-match for that reason. The weights are the long-term
    /// speech spectrum (most energy at 250 Hz–1 kHz) times the ear's
    /// sensitivity, so the result tracks how loud speech sounds. Capped at
    /// ±4 dB so an extreme curve can't swing the level wildly.
    static func loudnessMatchDB(_ plan: SoundPlan) -> Double {
        let weights: [Double] = [0, 0.02, 0.08, 0.18, 0.22, 0.20, 0.15, 0.10, 0.04, 0.01]
        var power = 0.0
        for (index, frequency) in frequencies.enumerated() {
            let db = toneResponseDB(at: frequency, plan: plan)
            power += weights[index] * pow(10, db / 10)
        }
        let change = 10 * log10(max(power, 1e-6) / weights.reduce(0, +))
        return min(4, max(-4, -change))
    }

    // MARK: Response, for drawing

    /// The whole chain's response at one frequency, level included.
    static func responseDB(at frequency: Double, plan: SoundPlan) -> Double {
        toneResponseDB(at: frequency, plan: plan) + plan.levelDB
    }

    static func toneResponseDB(at frequency: Double, plan: SoundPlan) -> Double {
        plan.allFilters.reduce(0) { sum, filter in
            filter.isOn ? sum + magnitudeDB(filter, at: frequency) : sum
        }
    }

    /// Standard biquad (RBJ "Audio EQ Cookbook") magnitude. `AVAudioUnitEQ`
    /// doesn't publish its exact filter maths, so this is the textbook
    /// version of each type; it matches in shape and centre, and may differ
    /// by a fraction of a dB at the edges.
    static func magnitudeDB(_ filter: FilterSpec, at frequency: Double,
                            sampleRate: Double = 44_100) -> Double {
        let f0 = min(filter.frequency, sampleRate * 0.49)
        let w0 = 2 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let a = pow(10, filter.gain / 40)
        let b0, b1, b2, a0, a1, a2: Double

        switch filter.kind {
        case .peak:
            guard filter.gain != 0 else { return 0 }
            let alpha = sinW0 * sinh(log(2) / 2 * filter.bandwidth * w0 / sinW0)
            b0 = 1 + alpha * a; b1 = -2 * cosW0; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW0; a2 = 1 - alpha / a
        case .lowShelf:
            guard filter.gain != 0 else { return 0 }
            let alpha = sinW0 / 2 * 2.0.squareRoot()
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW0 + root)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW0)
            b2 = a * ((a + 1) - (a - 1) * cosW0 - root)
            a0 = (a + 1) + (a - 1) * cosW0 + root
            a1 = -2 * ((a - 1) + (a + 1) * cosW0)
            a2 = (a + 1) + (a - 1) * cosW0 - root
        case .highShelf:
            guard filter.gain != 0 else { return 0 }
            let alpha = sinW0 / 2 * 2.0.squareRoot()
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW0 + root)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW0)
            b2 = a * ((a + 1) + (a - 1) * cosW0 - root)
            a0 = (a + 1) - (a - 1) * cosW0 + root
            a1 = 2 * ((a - 1) - (a + 1) * cosW0)
            a2 = (a + 1) - (a - 1) * cosW0 - root
        case .highPass:
            let alpha = sinW0 / (2 * 0.5.squareRoot())
            b0 = (1 + cosW0) / 2; b1 = -(1 + cosW0); b2 = (1 + cosW0) / 2
            a0 = 1 + alpha; a1 = -2 * cosW0; a2 = 1 - alpha
        }

        let w = 2 * Double.pi * frequency / sampleRate
        let numRe = b0 + b1 * cos(w) + b2 * cos(2 * w)
        let numIm = -(b1 * sin(w) + b2 * sin(2 * w))
        let denRe = a0 + a1 * cos(w) + a2 * cos(2 * w)
        let denIm = -(a1 * sin(w) + a2 * sin(2 * w))
        let num = numRe * numRe + numIm * numIm
        let den = max(denRe * denRe + denIm * denIm, 1e-12)
        return 10 * log10(max(num / den, 1e-12))
    }
}

// MARK: - The controls' state

/// Everything the sound controls set, as one value: the equalizer switch,
/// the preset and its bands, and which repairs are on at what strength.
///
/// The app default lives in `AppSettings` (one UserDefaults key per field, as
/// always) and a show's own sound is one of these stored on the `Podcast`.
/// The screens edit a `SoundState` either way, so the default and a show get
/// exactly the same controls and the same rules.
struct SoundState: Codable, Equatable {
    var equalizerOn = false
    var preset = EQPreset.flat.name
    var gains = EQPreset.flat.gains
    var enabled: Set<Repair> = []
    /// Every repair's slider, on or off, so switching one on again brings back
    /// where it was.
    var strengths: [Repair: Double] = [:]

    func isOn(_ repair: Repair) -> Bool { enabled.contains(repair) }

    func strength(_ repair: Repair) -> Double {
        repair.clamped(strengths[repair] ?? repair.defaultStrength)
    }

    /// Switch a repair. Turning off the repair a "fix one problem" preset
    /// stands for means that preset no longer describes the sound, so the
    /// picker goes back to Flat (its base is flat already).
    mutating func setRepair(_ repair: Repair, on: Bool) {
        if on { enabled.insert(repair) } else { enabled.remove(repair) }
        if !on, EQPreset.resolving(preset).repair == repair {
            preset = EQPreset.flat.name
        }
    }

    mutating func setStrength(_ repair: Repair, _ value: Double) {
        guard repair.range != nil else { return }
        strengths[repair] = repair.clamped(value)
    }

    var enabledRepairs: [Repair: Double] {
        var result: [Repair: Double] = [:]
        for repair in enabled { result[repair] = strength(repair) }
        return result
    }

    /// The preset's gains, or flat when the equalizer is switched off.
    var baseGains: [Double] {
        guard equalizerOn, gains.count == 10 else { return EQPreset.flat.gains }
        return gains
    }

    /// Choosing a preset. A tone preset replaces the base and leaves the
    /// repairs as they are, so they layer on top. A "fix one problem" preset
    /// is that repair on a flat base, at the strength it stands for.
    mutating func choosePreset(named name: String) {
        guard name != EQPreset.custom.name else { return }
        let chosen = EQPreset.resolving(name)
        gains = chosen.gains
        if let repair = chosen.repair {
            setStrength(repair, max(chosen.repairStrength, isOn(repair) ? strength(repair) : 0))
            setRepair(repair, on: true)
        }
        preset = chosen.name
    }

    /// Dragging a band makes the base the listener's own.
    mutating func setBaseGain(_ gain: Double, band: Int) {
        guard band >= 0, band < 10 else { return }
        if gains.count != 10 { gains = EQPreset.flat.gains }
        gains[band] = EQMath.clampBase(gain)
        preset = EQPreset.custom.name
    }

    /// Everything that shapes the sound. `normalizationDB` is 0 when volume
    /// normalization is off or there's no episode.
    func sound(normalizationDB: Double) -> SoundSettings {
        SoundSettings(base: baseGains, repairs: enabledRepairs, normalizationDB: normalizationDB)
    }

    static func normalizationDB(on: Bool, gain: Double?) -> Double {
        guard on, let gain, gain > 0 else { return 0 }
        return 20 * log10(gain)
    }
}

// MARK: - Settings glue

extension AppSettings {
    /// The app default, read from and written back to the individual
    /// settings. Writing only touches what changed, so a slider drag saves
    /// one value, not twenty.
    var soundState: SoundState {
        get {
            var state = SoundState(equalizerOn: equalizerEnabled,
                                   preset: equalizerPreset,
                                   gains: equalizerGains)
            for repair in Repair.allCases {
                if storedIsOn(repair) { state.enabled.insert(repair) }
                if repair.range != nil { state.strengths[repair] = storedStrength(repair) }
            }
            return state
        }
        set {
            if equalizerEnabled != newValue.equalizerOn { equalizerEnabled = newValue.equalizerOn }
            if equalizerPreset != newValue.preset { equalizerPreset = newValue.preset }
            if equalizerGains != newValue.gains { equalizerGains = newValue.gains }
            for repair in Repair.allCases {
                let on = newValue.isOn(repair)
                if storedIsOn(repair) != on { storeIsOn(repair, on) }
                if repair.range != nil {
                    let value = newValue.strength(repair)
                    if storedStrength(repair) != value { storeStrength(repair, value) }
                }
            }
        }
    }

    func isOn(_ repair: Repair) -> Bool { storedIsOn(repair) }
    func strength(_ repair: Repair) -> Double { soundState.strength(repair) }

    func setRepair(_ repair: Repair, on: Bool) {
        var state = soundState
        state.setRepair(repair, on: on)
        soundState = state
    }

    func setStrength(_ repair: Repair, _ value: Double) {
        var state = soundState
        state.setStrength(repair, value)
        soundState = state
    }

    var enabledRepairs: [Repair: Double] { soundState.enabledRepairs }
    var baseGains: [Double] { soundState.baseGains }

    func choosePreset(named name: String) {
        var state = soundState
        state.choosePreset(named: name)
        soundState = state
    }

    func setBaseGain(_ gain: Double, band: Int) {
        var state = soundState
        state.setBaseGain(gain, band: band)
        soundState = state
    }

    /// The app default's sound. `normalizationGain` is the episode's linear
    /// gain; pass nil when there is no episode.
    func sound(normalizationGain: Double?) -> SoundSettings {
        soundState.sound(normalizationDB: SoundState.normalizationDB(on: volumeNormalizationEnabled,
                                                                     gain: normalizationGain))
    }

    /// The sound for an episode of this show: the show's own if it has one,
    /// otherwise the app default. Switching to another show's episode
    /// switches with it, because the player asks again on every load.
    func sound(for show: Podcast?, normalizationGain: Double?) -> SoundSettings {
        let normalize = show?.volumeNormalizationOverride ?? volumeNormalizationEnabled
        let db = SoundState.normalizationDB(on: normalize, gain: normalizationGain)
        return soundState(for: show).sound(normalizationDB: db)
    }

    /// What the controls are set to for this show.
    func soundState(for show: Podcast?) -> SoundState {
        if let own = show?.customSound { return own }
        var state = soundState
        // Before a show could have its own sound it could only force Voice
        // Boost (now Enhance Dialogue) on or off; that still counts until the
        // show is given its own sound, which takes it over.
        if let forced = show?.voiceBoostOverride { state.setRepair(.dialogue, on: forced) }
        return state
    }

    // Storage for each repair, one UserDefaults-backed property apiece.
    private func storedIsOn(_ repair: Repair) -> Bool {
        switch repair {
        case .rumble:    return rumbleFilterEnabled
        case .boom:      return bassReductionEnabled
        case .mud:       return mudReductionEnabled
        case .nasal:     return nasalReductionEnabled
        case .dialogue:  return voiceBoostEnabled
        case .harshness: return harshnessReductionEnabled
        case .sibilance: return deEsserEnabled
        case .muffled:   return brightenEnabled
        }
    }

    private func storeIsOn(_ repair: Repair, _ on: Bool) {
        switch repair {
        case .rumble:    rumbleFilterEnabled = on
        case .boom:      bassReductionEnabled = on
        case .mud:       mudReductionEnabled = on
        case .nasal:     nasalReductionEnabled = on
        case .dialogue:  voiceBoostEnabled = on
        case .harshness: harshnessReductionEnabled = on
        case .sibilance: deEsserEnabled = on
        case .muffled:   brightenEnabled = on
        }
    }

    private func storedStrength(_ repair: Repair) -> Double {
        switch repair {
        case .rumble:    return 1
        case .boom:      return bassReductionStrength
        case .mud:       return mudReductionStrength
        case .nasal:     return nasalReductionStrength
        case .dialogue:  return voiceBoostStrength
        case .harshness: return harshnessReductionStrength
        case .sibilance: return deEsserStrength
        case .muffled:   return brightenStrength
        }
    }

    private func storeStrength(_ repair: Repair, _ value: Double) {
        switch repair {
        case .rumble:    break
        case .boom:      bassReductionStrength = value
        case .mud:       mudReductionStrength = value
        case .nasal:     nasalReductionStrength = value
        case .dialogue:  voiceBoostStrength = value
        case .harshness: harshnessReductionStrength = value
        case .sibilance: deEsserStrength = value
        case .muffled:   brightenStrength = value
        }
    }
}

// MARK: - Migration

/// Moves settings saved by the old separate controls onto the combined model.
///
/// Runs when the model version is older, and again whenever a key only the old
/// model wrote is present — which is what restoring an old backup brings back.
/// Every step only reads old keys and writes new values, so running it twice
/// changes nothing.
enum SoundSettingsMigration {
    static let versionKey = "audioModel"
    static let version = 2

    /// Keys only the old model wrote.
    private static let legacyKeys = ["clarity", "clarityAmount"]

    static func run(_ d: UserDefaults) {
        let hasLegacy = legacyKeys.contains { d.object(forKey: $0) != nil }
        guard d.integer(forKey: versionKey) < version || hasLegacy else { return }

        // Voice Boost and the old Enhance Dialogue (an air shelf) did the same
        // job; they are one control now, stored on Voice Boost's key.
        let boost = d.bool(forKey: "voiceBoost")
        let clarity = d.object(forKey: "clarity") as? Bool ?? false
        if boost {
            // Voice Boost's presence lift was a fixed +5 dB.
            if d.object(forKey: "voiceBoostAmount") == nil { d.set(5.0, forKey: "voiceBoostAmount") }
        } else if clarity {
            let old = d.object(forKey: "clarityAmount") as? Double ?? 3
            d.set(true, forKey: "voiceBoost")
            d.set(Repair.dialogue.clamped(old + 1), forKey: "voiceBoostAmount")
        }
        for key in legacyKeys { d.removeObject(forKey: key) }

        migratePreset(d)
        d.set(version, forKey: versionKey)
    }

    /// Old preset curves that were really one repair become that repair.
    private static func migratePreset(_ d: UserDefaults) {
        guard let stored = d.string(forKey: "eqPreset") else { return }
        let gains = d.array(forKey: "eqGains") as? [Double]
        let eqOn = d.bool(forKey: "eqOn")

        if let old = legacyShapes[stored] {
            // Already the new model: a repair preset sits on a flat base.
            if stored == old.preset.name, gains == EQPreset.flat.gains { return }
            let untouched = gains == nil || gains == old.gains
            if !untouched, let gains {
                // Hand-tuned from that starting point: keep the curve.
                d.set(gains, forKey: "eqGains")
                d.set(EQPreset.custom.name, forKey: "eqPreset")
            } else if eqOn {
                let repair = old.preset.repair ?? .mud
                if let key = repair.strengthKey {
                    let current = d.bool(forKey: repair.enabledKey) ? d.double(forKey: key) : 0
                    d.set(max(current, old.preset.repairStrength), forKey: key)
                }
                d.set(true, forKey: repair.enabledKey)
                d.set(EQPreset.flat.gains, forKey: "eqGains")
                d.set(old.preset.name, forKey: "eqPreset")
            } else {
                d.set(EQPreset.flat.gains, forKey: "eqGains")
                d.set(EQPreset.flat.name, forKey: "eqPreset")
            }
            return
        }

        // A tone preset whose bands were dragged was still labelled with the
        // preset's name; it's Custom now, so the label matches the curve.
        let resolved = EQPreset.resolving(stored)
        if stored != resolved.name { d.set(resolved.name, forKey: "eqPreset") }
        if let gains, stored != EQPreset.custom.name, gains.count == 10, gains != resolved.gains {
            d.set(EQPreset.custom.name, forKey: "eqPreset")
        }
    }

    /// The curves the old repair-like presets used, by every name they were
    /// ever stored under.
    private static let legacyShapes: [String: (preset: EQPreset, gains: [Double])] = [
        "Reduce Harshness": (.reduceHarshness, [-2, -1, 0, 0, 0, -1, -4, -5, -3, -2]),
        "Reduce Boom":      (.reduceBoom, [-10, -8, -5, -3, -1, 0, 1, 1, 0, 0]),
        "Reduce Mud":       (.reduceMud, [-4, -3, -4, -5, -2, 0, 2, 2, 1, 0]),
        "Bass Reduction":   (.reduceBoom, [-10, -8, -5, -2, 0, 0, 0, 0, 0, 0]),
        "Bass Reduce":      (.reduceBoom, [-10, -8, -5, -2, 0, 0, 0, 0, 0, 0]),
        "Voice Clarity":    (.voiceClarity, [-7, -6, -3, 0, 2, 3, 5, 4, 2, -1]),
        "Voice":            (.voiceClarity, [-7, -6, -3, 0, 2, 3, 5, 4, 2, -1]),
        "Treble Boost":     (.voiceClarity, [-7, -6, -3, 0, 2, 3, 5, 4, 2, -1]),
    ]
}

// MARK: - A show's own sound

extension Podcast {
    /// This show's own sound, or nil to use the app default. Giving a show
    /// its own sound takes over the old Voice Boost override, so that is
    /// cleared at the same time.
    var customSound: SoundState? {
        get { customSoundData.flatMap { try? JSONDecoder().decode(SoundState.self, from: $0) } }
        set {
            customSoundData = newValue.flatMap { try? JSONEncoder().encode($0) }
            if newValue != nil, voiceBoostOverride != nil { voiceBoostOverride = nil }
        }
    }
}
