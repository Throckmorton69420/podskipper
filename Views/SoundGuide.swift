import SwiftUI

// MARK: - The sound chart, in plain words
//
// Pass 29 (his 5 Oct notes): the chart didn't say which part of the sound
// each frequency is, wasn't colour-coded, nothing could be tapped, and the
// labels ("+5 dB at 3.8 kHz", "Volume levelling −0.2 dB, whole sound",
// "Overall level +0.7 dB") meant nothing to a listener. Now the frequency
// axis is seven named, coloured zones — the names dialogue engineers use —
// and every fix is coloured like the zone it works on. Each zone and each fix
// can be tapped for what it is, what it sounds like and what is changing it.
// Loudness (Volume Normalization, Even Out Volume) is not a frequency change,
// so it is described beside the chart, never drawn as a shift of the curve.

/// A stretch of the frequency axis, named the way a listener would.
struct SoundZone: Identifiable, Hashable {
    let name: String
    let low: Double
    let high: Double
    /// What lives here.
    let about: String
    /// What too much or too little of it sounds like.
    let sounds: String
    let color: Color
    var id: String { name }

    var range: String { "\(SoundGuide.hz(low))–\(SoundGuide.hz(high))" }
    /// The middle, on the chart's log scale.
    var centre: Double { (low * high).squareRoot() }

    static let all: [SoundZone] = [
        SoundZone(name: "Rumble", low: 20, high: 80,
                  about: "Below even the deepest voice: traffic, air conditioning, hum, a bumped desk or mic stand.",
                  sounds: "Too much: a low drone or thuds under the voices. Removing it doesn't touch speech.",
                  color: Color(red: 0.47, green: 0.42, blue: 0.98)),
        SoundZone(name: "Boom", low: 80, high: 200,
                  about: "Chest resonance and the bass a mic adds when someone talks right into it.",
                  sounds: "Too much: boomy, chesty, bass-heavy. Too little: thin.",
                  color: Color(red: 0.78, green: 0.40, blue: 0.95)),
        SoundZone(name: "Mud", low: 200, high: 500,
                  about: "Where a small or untreated room piles up its echoes.",
                  sounds: "Too much: boxy, muddy, as if recorded in a cupboard. Too little: hollow.",
                  color: Color(red: 0.95, green: 0.55, blue: 0.25)),
        SoundZone(name: "Body", low: 500, high: 2_000,
                  about: "The vowels: most of a voice's energy and its natural tone. Nasal, honky sound sits around 1 kHz.",
                  sounds: "Too much: honky or nasal. Too little: distant and thin.",
                  color: Color(red: 0.96, green: 0.80, blue: 0.25)),
        SoundZone(name: "Clarity", low: 2_000, high: 5_000,
                  about: "The consonants that make words understandable. The ear is most sensitive here.",
                  sounds: "A little more: clearer words. Too much: harsh, glaring, tiring.",
                  color: Color(red: 0.30, green: 0.84, blue: 0.50)),
        SoundZone(name: "Sibilance", low: 5_000, high: 10_000,
                  about: "S, SH, T and CH sounds.",
                  sounds: "Too much: hissy, spitty S sounds. Too little: lisping, dull.",
                  color: Color(red: 0.25, green: 0.80, blue: 0.92)),
        SoundZone(name: "Air", low: 10_000, high: 20_000,
                  about: "Breath and sparkle at the very top.",
                  sounds: "A little more: open and crisp. Too little: muffled, as if behind a blanket. Also where tape hiss lives.",
                  color: Color(red: 0.42, green: 0.60, blue: 1.0)),
    ]

    static func containing(_ hz: Double) -> SoundZone {
        all.first { hz >= $0.low && hz < $0.high } ?? (hz < 20 ? all[0] : all[all.count - 1])
    }
}

extension Repair {
    /// When to switch it on.
    var whenToUse: String {
        switch self {
        case .rumble:    return "You hear a low hum or thuds under the voice, often from a guest calling in."
        case .boom:      return "A host sounds chesty or bass-heavy, or is right on top of the mic."
        case .mud:       return "Speech sounds boxy, as if recorded in a small room."
        case .nasal:     return "A voice sounds honky, pinched or blocked-up."
        case .dialogue:  return "Words are hard to make out, or a guest is quiet or far from the mic."
        case .harshness: return "A voice sounds bright, glaring or tiring."
        case .sibilance: return "S and T sounds hiss or spit."
        case .muffled:   return "A voice sounds dull, distant or as if behind a blanket."
        }
    }

    /// What changes when it's on.
    var whatYouHear: String {
        switch self {
        case .rumble:    return "The hum goes; voices stay as they were."
        case .boom:      return "Voices lighter and tighter."
        case .mud:       return "Voices clearer and more open."
        case .nasal:     return "Voices rounder and more natural."
        case .dialogue:  return "Words clearer and a little louder, with less bass."
        case .harshness: return "Voices smoother and easier to listen to for a long time."
        case .sibilance: return "S sounds softer; the rest of the voice unchanged."
        case .muffled:   return "Voices crisper and more present; some hiss may come up too."
        }
    }

    /// The zone it mainly works on; its colour is that zone's.
    var zone: SoundZone {
        let name: String
        switch self {
        case .rumble:    name = "Rumble"
        case .boom:      name = "Boom"
        case .mud:       name = "Mud"
        case .nasal:     name = "Body"
        case .dialogue, .harshness: name = "Clarity"
        case .sibilance: name = "Sibilance"
        case .muffled:   name = "Air"
        }
        return SoundZone.all.first { $0.name == name } ?? SoundZone.all[0]
    }

    /// Its colour on the chart, in the key and on its switch.
    var chartColor: Color {
        // Harshness shares Clarity's zone with Enhance Dialogue; a teal so
        // the two can be told apart when both are on.
        self == .harshness ? Color(red: 0.20, green: 0.70, blue: 0.62) : zone.color
    }

    /// The change in plain words: "Mud quieter by up to 5 dB".
    func effect(peakDB: Double) -> String {
        if self == .rumble { return "Rumble removed below 80 Hz" }
        let size = SoundGuide.db(abs(peakDB)).replacingOccurrences(of: "+", with: "")
        let way = peakDB < 0 ? "quieter" : "louder"
        switch self {
        case .dialogue: return "Clarity louder by up to \(size), a little less Rumble and Boom"
        case .muffled:  return "Sibilance and Air louder by up to \(size)"
        case .harshness: return "Upper Clarity quieter by up to \(size)"
        default: return "\(zone.name) \(way) by up to \(size)"
        }
    }

    /// How it reads in the summary, by how hard it's pushed (0…1).
    fileprivate func phrase(_ amount: Double) -> String {
        let degree = amount < 0.35 ? "a bit " : amount > 0.75 ? "much " : ""
        switch self {
        case .rumble:    return "low hum removed"
        case .boom:      return degree + "less boomy"
        case .mud:       return degree + "less boxy"
        case .nasal:     return degree + "less nasal"
        case .dialogue:  return "words " + degree + "clearer"
        case .harshness: return degree + "less harsh"
        case .sibilance: return "S sounds " + (amount < 0.35 ? "a little softer" : amount > 0.75 ? "much softer" : "softened")
        case .muffled:   return degree + "brighter"
        }
    }

    /// 0 at the bottom of its slider, 1 at the top.
    fileprivate func amount(_ strength: Double) -> Double {
        guard let range else { return 0.5 }
        return (clamped(strength) - range.lowerBound) / (range.upperBound - range.lowerBound)
    }
}

enum SoundGuide {
    /// "80 Hz", "2 kHz", "3.5 kHz".
    static func hz(_ value: Double) -> String {
        if value >= 1_000 {
            let k = value / 1_000
            return k.rounded() == k || k >= 10 ? "\(Int(k.rounded())) kHz" : String(format: "%.1f kHz", k)
        }
        return "\(Int(value.rounded())) Hz"
    }

    /// "−4 dB", "+2.5 dB".
    static func db(_ value: Double) -> String {
        let rounded = (value * 2).rounded() / 2
        if rounded == 0 { return "0 dB" }
        let sign = rounded > 0 ? "+" : "−"
        let size = abs(rounded)
        return sign + (size.rounded() == size ? "\(Int(size))" : String(format: "%.1f", size)) + " dB"
    }

    /// "much quieter" … "much louder".
    static func words(_ db: Double) -> String {
        switch db {
        case ..<(-6): return "much quieter"
        case ..<(-2.5): return "quieter"
        case ..<(-0.5): return "a little quieter"
        case ..<0.5: return "unchanged"
        case ..<2.5: return "a little louder"
        case ..<6: return "louder"
        default: return "much louder"
        }
    }

    /// The one line under the chart: "Voices a bit warmer, less boxy; S
    /// sounds softened."
    static func summary(_ sound: SoundSettings, levelling: Bool) -> String {
        var tone: [String] = []
        var others: [String] = []

        // The preset, read from its curve rather than its name, so Custom
        // gets words too.
        let base = sound.base.count == 10 ? sound.base : Array(repeating: 0, count: 10)
        let low = (base[1] + base[2] + base[3]) / 3
        let high = (base[6] + base[7] + base[8]) / 3
        func degree(_ db: Double) -> String { abs(db) < 2.5 ? "a bit " : abs(db) > 5 ? "much " : "" }
        if low > 1 { tone.append(degree(low) + "warmer") }
        if low < -1 { tone.append(degree(low) + "lighter in the bass") }
        if high > 1 { tone.append(degree(high) + "brighter") }
        if high < -1 { tone.append(degree(high) + "softer on top") }

        for repair in Repair.allCases {
            guard let strength = sound.repairs[repair] else { continue }
            let words = repair.phrase(repair.amount(strength))
            switch repair {
            case .boom, .mud, .nasal, .harshness, .muffled: tone.append(words)
            case .rumble, .dialogue, .sibilance: others.append(words)
            }
        }

        var clauses: [String] = []
        if !tone.isEmpty { clauses.append("Voices " + tone.joined(separator: ", ")) }
        clauses += others
        guard var line = clauses.first else {
            return "Tone unchanged: you hear the episode as it was recorded."
        }
        line = line.prefix(1).uppercased() + line.dropFirst()
        return ([line] + clauses.dropFirst()).joined(separator: "; ") + "."
    }
}
