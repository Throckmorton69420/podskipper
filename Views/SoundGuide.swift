import SwiftUI

// MARK: - The sound chart, in plain words (task 10)
//
// He found the curve hard to read (30 Sep): "make it more visually intuitive
// and explanatory, or have some sort of labels that can be tapped". This is
// the words: what each stretch of the frequency axis is called, what each fix
// does and when to use it, and the one-line summary under the chart. The
// ranges are the ones `Repair`'s notes in SoundModel.swift use.

/// A stretch of the frequency axis, named the way a listener would.
struct SoundRegion: Identifiable, Hashable {
    let name: String
    let low: Double
    let high: Double
    /// What lives here, and what cutting or lifting it does.
    let about: String
    /// The fix that works here, if there is one.
    var fix: Repair? = nil

    var id: String { name }

    /// The middle, on the chart's log scale.
    var centre: Double { (low * high).squareRoot() }

    var range: String { "\(SoundGuide.hz(low))–\(SoundGuide.hz(high))" }

    static let all: [SoundRegion] = [
        SoundRegion(name: "Rumble", low: 20, high: 80,
                    about: "Below the lowest voice: traffic, air conditioning, desk thumps. Taking it out removes hum without touching speech.",
                    fix: .rumble),
        SoundRegion(name: "Boom", low: 80, high: 150,
                    about: "Chest resonance, and a mic held very close. Cutting it makes voices less boomy; lifting it makes them fuller.",
                    fix: .boom),
        SoundRegion(name: "Warmth", low: 150, high: 200,
                    about: "The low body of a voice. A little more sounds warm and close; too much sounds thick."),
        SoundRegion(name: "Mud", low: 200, high: 400,
                    about: "Small rooms pile up sound here. Cutting it makes voices less boxy.",
                    fix: .mud),
        SoundRegion(name: "Body", low: 400, high: 700,
                    about: "Where most of a voice's energy sits. Cutting it thins voices out; lifting it sounds nasal."),
        SoundRegion(name: "Voice", low: 700, high: 2_000,
                    about: "The core of the words. Changes here make voices sound nearer or further away."),
        SoundRegion(name: "Presence", low: 2_000, high: 4_000,
                    about: "The consonants that make words understandable, where the ear is most sensitive. A lift makes speech clearer without making it much louder.",
                    fix: .dialogue),
        SoundRegion(name: "Clarity", low: 4_000, high: 5_000,
                    about: "The edge of words. Too much sounds harsh and tiring; a small cut is easier over a long listen.",
                    fix: .harshness),
        SoundRegion(name: "Sibilance", low: 5_000, high: 9_000,
                    about: "S, SH and T sounds. Cutting it softens hissy, sharp S sounds.",
                    fix: .sibilance),
        SoundRegion(name: "Air", low: 9_000, high: 20_000,
                    about: "Breath and sparkle. A lift sounds open; a cut quiets hiss in a noisy recording."),
    ]
}

extension Repair {
    /// When to switch it on.
    var whenToUse: String {
        switch self {
        case .rumble:    return "You hear a low hum or thuds under the voice, often from a guest calling in."
        case .boom:      return "A host sounds chesty or bass-heavy, or is right on top of the mic."
        case .mud:       return "Speech sounds boxy, as if recorded in a small room."
        case .dialogue:  return "Words are hard to make out, or a guest is quiet or far from the mic."
        case .harshness: return "A voice sounds bright, glaring or tiring."
        case .sibilance: return "S and T sounds hiss or spit."
        }
    }

    /// What changes when it's on.
    var whatYouHear: String {
        switch self {
        case .rumble:    return "The hum goes; voices stay as they were."
        case .boom:      return "Voices lighter and tighter."
        case .mud:       return "Voices clearer and more open."
        case .dialogue:  return "Words clearer and a little louder, with less bass."
        case .harshness: return "Voices smoother and easier to listen to for a long time."
        case .sibilance: return "S sounds softer; the rest of the voice unchanged."
        }
    }

    /// Its colour on the chart and in the legend.
    var chartColor: Color {
        switch self {
        case .rumble:    return .indigo
        case .boom:      return .purple
        case .mud:       return .orange
        case .dialogue:  return .green
        case .harshness: return .pink
        case .sibilance: return .cyan
        }
    }

    /// How it reads in the summary, by how hard it's pushed (0…1).
    fileprivate func phrase(_ amount: Double) -> String {
        let degree = amount < 0.35 ? "a bit " : amount > 0.75 ? "much " : ""
        switch self {
        case .rumble:    return "low hum removed"
        case .boom:      return degree + "less boomy"
        case .mud:       return degree + "less boxy"
        case .dialogue:  return "words " + degree + "clearer"
        case .harshness: return degree + "less harsh"
        case .sibilance: return "S sounds " + (amount < 0.35 ? "a little softer" : amount > 0.75 ? "much softer" : "softened")
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

    /// The one line under the chart: "Voices a bit warmer, less boxy; S
    /// sounds softened; loudness levelled."
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
            case .boom, .mud, .harshness: tone.append(words)
            case .rumble, .dialogue, .sibilance: others.append(words)
            }
        }
        if levelling { others.append("loudness levelled") }

        var clauses: [String] = []
        if !tone.isEmpty { clauses.append("Voices " + tone.joined(separator: ", ")) }
        clauses += others
        guard var line = clauses.first else {
            return "Unchanged: you hear the episode as it was recorded."
        }
        line = line.prefix(1).uppercased() + line.dropFirst()
        return ([line] + clauses.dropFirst()).joined(separator: "; ") + "."
    }
}
