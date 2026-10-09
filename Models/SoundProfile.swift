import Foundation

/// Pass 33 (A04, his 9 Oct request): everything Speed and Audio sets, as one
/// value — so a show can have its own, the app can have a default, and Reset
/// knows exactly what it is putting back.
///
/// The hierarchy:
/// - the app default (`AppSettings.profile`), what every show uses unless…
/// - …a show has its own. Each field of a show's own settings is optional
///   and falls back to the default (that is how Show Settings has always
///   stored speed, Smart Speed and normalization). Choosing "This Show" in
///   Speed and Audio saves a complete copy, so later changes to the default
///   don't reach that show.
/// - "Use My Default" removes a show's own settings; "Reset" puts the app
///   default back to how PodSkipper starts (and, only if asked, the shows).
///
/// Mono is not part of a show's settings: it describes how you are
/// listening (one earbud), not the show, so it stays one switch for all.
struct SoundProfile: Equatable {
    var speed: Double
    var smartSpeed: Bool
    var smartSpeedAmount: Double
    var normalize: Bool
    var evenOut: Bool
    var evenOutStrength: Double
    var sound: SoundState
}

extension AppSettings {
    /// Every UserDefaults key Speed and Audio writes. Reset removes them, so
    /// each reads back as the registered default — exactly what a fresh
    /// install starts with, with no second copy of the defaults to drift.
    static let soundKeys = [
        "speed", "smartSpeed", "smartSpeedAmount", "normalize", "evenOut", "evenOutAmount", "mono",
        "eqOn", "eqPreset", "eqGains",
        "rumble", "voiceBoost", "voiceBoostAmount", "deEsser", "deEsserAmount",
        "mudCut", "mudCutAmount", "bassCut", "bassCutAmount", "harshCut", "harshCutAmount",
        "nasalCut", "nasalCutAmount", "brighten", "brightenAmount",
    ]

    /// The app default.
    var profile: SoundProfile {
        get {
            SoundProfile(speed: defaultPlaybackSpeed, smartSpeed: smartSpeedEnabled,
                         smartSpeedAmount: smartSpeedAggressiveness, normalize: volumeNormalizationEnabled,
                         evenOut: evenOutVolumeEnabled, evenOutStrength: evenOutVolumeStrength, sound: soundState)
        }
        set {
            if defaultPlaybackSpeed != newValue.speed { defaultPlaybackSpeed = newValue.speed }
            if smartSpeedEnabled != newValue.smartSpeed { smartSpeedEnabled = newValue.smartSpeed }
            if smartSpeedAggressiveness != newValue.smartSpeedAmount { smartSpeedAggressiveness = newValue.smartSpeedAmount }
            if volumeNormalizationEnabled != newValue.normalize { volumeNormalizationEnabled = newValue.normalize }
            if evenOutVolumeEnabled != newValue.evenOut { evenOutVolumeEnabled = newValue.evenOut }
            if evenOutVolumeStrength != newValue.evenOutStrength { evenOutVolumeStrength = newValue.evenOutStrength }
            var sound = newValue.sound
            sound.evenOut = nil; sound.evenOutStrength = nil
            if soundState != sound { soundState = sound }
        }
    }

    /// What an episode of this show plays with: each of the show's own
    /// fields, else the default's.
    func profile(for show: Podcast?) -> SoundProfile {
        guard let show else { return profile }
        let level = evenOut(for: show)
        return SoundProfile(speed: show.playbackSpeedOverride ?? defaultPlaybackSpeed,
                            smartSpeed: show.smartSpeedOverride ?? smartSpeedEnabled,
                            smartSpeedAmount: show.smartSpeedAmountOverride ?? smartSpeedAggressiveness,
                            normalize: show.volumeNormalizationOverride ?? volumeNormalizationEnabled,
                            evenOut: level.on, evenOutStrength: level.strength,
                            sound: soundState(for: show))
    }

    func smartSpeed(for show: Podcast?) -> (on: Bool, amount: Double) {
        (show?.smartSpeedOverride ?? smartSpeedEnabled, show?.smartSpeedAmountOverride ?? smartSpeedAggressiveness)
    }

    func evenOut(for show: Podcast?) -> (on: Bool, strength: Double) {
        let own = show?.customSound
        return (own?.evenOut ?? evenOutVolumeEnabled, own?.evenOutStrength ?? evenOutVolumeStrength)
    }

    /// Puts the app default back to how PodSkipper starts. Shows keep their
    /// own settings; the caller resets those separately, only if asked.
    func resetSoundToDefaults(defaults: UserDefaults = .standard) {
        for key in Self.soundKeys { defaults.removeObject(forKey: key) }
        let d = defaults
        defaultPlaybackSpeed = d.double(forKey: "speed")
        smartSpeedEnabled = d.bool(forKey: "smartSpeed")
        smartSpeedAggressiveness = d.double(forKey: "smartSpeedAmount")
        volumeNormalizationEnabled = d.bool(forKey: "normalize")
        evenOutVolumeEnabled = d.bool(forKey: "evenOut")
        evenOutVolumeStrength = d.double(forKey: "evenOutAmount")
        monoDownmix = d.bool(forKey: "mono")
        equalizerEnabled = d.bool(forKey: "eqOn")
        equalizerPreset = d.string(forKey: "eqPreset") ?? EQPreset.flat.name
        equalizerGains = (d.array(forKey: "eqGains") as? [Double]) ?? EQPreset.flat.gains
        rumbleFilterEnabled = d.bool(forKey: "rumble")
        voiceBoostEnabled = d.bool(forKey: "voiceBoost")
        voiceBoostStrength = d.double(forKey: "voiceBoostAmount")
        deEsserEnabled = d.bool(forKey: "deEsser")
        deEsserStrength = d.double(forKey: "deEsserAmount")
        mudReductionEnabled = d.bool(forKey: "mudCut")
        mudReductionStrength = d.double(forKey: "mudCutAmount")
        bassReductionEnabled = d.bool(forKey: "bassCut")
        bassReductionStrength = d.double(forKey: "bassCutAmount")
        harshnessReductionEnabled = d.bool(forKey: "harshCut")
        harshnessReductionStrength = d.double(forKey: "harshCutAmount")
        nasalReductionEnabled = d.bool(forKey: "nasalCut")
        nasalReductionStrength = d.double(forKey: "nasalCutAmount")
        brightenEnabled = d.bool(forKey: "brighten")
        brightenStrength = d.double(forKey: "brightenAmount")
    }
}

extension Podcast {
    /// Whether any part of Speed and Audio is this show's own.
    var hasOwnSound: Bool {
        customSoundData != nil || playbackSpeedOverride != nil || smartSpeedOverride != nil
            || smartSpeedAmountOverride != nil || volumeNormalizationOverride != nil || voiceBoostOverride != nil
    }

    /// Saves a complete copy as this show's own settings.
    func setOwnSound(_ profile: SoundProfile) {
        playbackSpeedOverride = profile.speed
        smartSpeedOverride = profile.smartSpeed
        smartSpeedAmountOverride = profile.smartSpeedAmount
        volumeNormalizationOverride = profile.normalize
        var sound = profile.sound
        sound.evenOut = profile.evenOut
        sound.evenOutStrength = profile.evenOutStrength
        customSound = sound
    }

    /// Back to the app default for everything Speed and Audio sets.
    func useDefaultSound() {
        playbackSpeedOverride = nil
        smartSpeedOverride = nil
        smartSpeedAmountOverride = nil
        volumeNormalizationOverride = nil
        voiceBoostOverride = nil
        customSoundData = nil
    }

    /// The stored fields exactly, so an undo puts back what was there —
    /// including a show that had only some of them.
    struct SoundOverrides: Equatable {
        var speed: Double?, smartSpeed: Bool?, smartSpeedAmount: Double?, normalize: Bool?
        var voiceBoost: Bool?, sound: Data?
    }

    var soundOverrides: SoundOverrides {
        get {
            SoundOverrides(speed: playbackSpeedOverride, smartSpeed: smartSpeedOverride,
                           smartSpeedAmount: smartSpeedAmountOverride, normalize: volumeNormalizationOverride,
                           voiceBoost: voiceBoostOverride, sound: customSoundData)
        }
        set {
            playbackSpeedOverride = newValue.speed
            smartSpeedOverride = newValue.smartSpeed
            smartSpeedAmountOverride = newValue.smartSpeedAmount
            volumeNormalizationOverride = newValue.normalize
            voiceBoostOverride = newValue.voiceBoost
            customSoundData = newValue.sound
        }
    }
}

/// What a Reset changed, so it can be undone while Speed and Audio is open.
@MainActor
struct SoundResetUndo {
    private let app: SoundProfile
    private let mono: Bool
    private let shows: [(Podcast, Podcast.SoundOverrides)]

    init(settings: AppSettings, shows: [Podcast]) {
        app = settings.profile
        mono = settings.monoDownmix
        self.shows = shows.map { ($0, $0.soundOverrides) }
    }

    func restore(settings: AppSettings) {
        settings.profile = app
        if settings.monoDownmix != mono { settings.monoDownmix = mono }
        for (show, overrides) in shows { show.soundOverrides = overrides }
    }
}
