import SwiftUI

/// The sound, the way a listener thinks about it (pass 27f, his words: the
/// chart "is still not as visually intuitive as it can be").
///
/// Five plain zones from low to high — Bass, Warmth, Voice, Clarity,
/// Sparkle — readable legend tiles beneath the shared frequency plot.
/// Changes appear in words, with Volume on its own. Tap a zone for its meaning.
struct SoundZonesView: View {
    let sound: SoundSettings
    var levelling = false

    struct Zone: Identifiable, Hashable {
        let name: String
        let symbol: String
        let low: Double
        let high: Double
        let plain: String
        var id: String { name }
        var regions: [SoundRegion] { SoundRegion.all.filter { $0.centre >= low && $0.centre < high } }
    }

    static let zones: [Zone] = [
        Zone(name: "Bass", symbol: "speaker.wave.1.fill", low: 20, high: 150,
             plain: "The deep end: hum, rumble and the boom of a voice close to the mic."),
        Zone(name: "Warmth", symbol: "flame.fill", low: 150, high: 400,
             plain: "The low body of voices. Too much sounds muddy or boxy, like a small room."),
        Zone(name: "Voice", symbol: "person.wave.2.fill", low: 400, high: 2_000,
             plain: "The core of speech. Changes here make voices sound nearer or further away."),
        Zone(name: "Clarity", symbol: "text.bubble.fill", low: 2_000, high: 5_000,
             plain: "The consonants that make words understandable. A lift makes speech clearer; too much is harsh."),
        Zone(name: "Sparkle", symbol: "sparkles", low: 5_000, high: 20_000,
             plain: "S sounds, breath and air. A cut softens hissy S sounds and background hiss."),
    ]

    @State private var shown: Zone?
    @State private var showsVolume = false

    /// Each zone's colour, low (warm red) to high (cool violet).
    static func color(_ zone: Zone) -> Color {
        switch zone.name {
        case "Bass": return Color(red: 0.95, green: 0.33, blue: 0.33)
        case "Warmth": return Color(red: 0.98, green: 0.60, blue: 0.22)
        case "Voice": return Color(red: 0.96, green: 0.84, blue: 0.26)
        case "Clarity": return Color(red: 0.30, green: 0.82, blue: 0.62)
        default: return Color(red: 0.45, green: 0.62, blue: 1.0)
        }
    }

    @ScaledMetric(relativeTo: .footnote) private var tileWidth: CGFloat = 110
    @ScaledMetric(relativeTo: .footnote) private var tileHeight: CGFloat = 72

    var body: some View {
        let plan = EQMath.plan(sound)
        let values = Self.zones.map { Self.average($0, plan: plan) }
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Array(Self.zones.enumerated()), id: \.element.id) { index, zone in
                    chip(zone, db: values[index])
                }
                volumeChip(plan.levelDB)
            }
        }
        .scrollIndicators(.hidden)
        .feel(.selection, trigger: shown)
        .popover(item: $shown, arrowEdge: .bottom) { zone in
            card(zone, db: Self.average(zone, plan: EQMath.plan(sound)))
        }
    }

    private func chip(_ zone: Zone, db: Double) -> some View {
        Button { shown = zone } label: {
            VStack(spacing: 2) {
                Image(systemName: zone.symbol).font(.footnote)
                Text(zone.name).font(.footnote.weight(.medium))

                Text(Self.short(db)).font(.footnote.weight(.semibold).monospacedDigit())

            }
            .foregroundStyle(Self.color(zone))
            .frame(width: tileWidth, height: tileHeight)
            .background(Self.color(zone).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(zone.name): \(Self.words(db))")
        .accessibilityHint("Explains this part of the sound")
    }

    private func volumeChip(_ db: Double) -> some View {
        Button { showsVolume = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "speaker.wave.3.fill").font(.footnote)
                Text("Volume").font(.footnote.weight(.medium))

                Text(Self.short(db)).font(.footnote.weight(.semibold).monospacedDigit())

            }
            .foregroundStyle(.primary)
            .frame(width: tileWidth, height: tileHeight)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Volume: \(Self.words(db))")
        .popover(isPresented: $showsVolume, arrowEdge: .bottom) { volumeCard(db) }
    }

    // MARK: Words

    static func short(_ db: Double) -> String {
        abs(db) < 0.25 ? "Same" : String(format: "%+.0f dB", db.rounded())
    }

    static func words(_ db: Double) -> String {
        switch db {
        case ..<(-6): return "much quieter"
        case ..<(-2.5): return "quieter"
        case ..<(-0.25): return "a little quieter"
        case ..<0.25: return "unchanged"
        case ..<2.5: return "a little louder"
        case ..<6: return "louder"
        default: return "much louder"
        }
    }

    private func card(_ zone: Zone, db: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(zone.name) · \(SoundGuide.hz(zone.low))–\(SoundGuide.hz(zone.high))").font(.headline)
            Text(zone.plain).font(.subheadline)
            Text("Right now: \(Self.words(db))" + (abs(db) >= 0.25 ? " (\(Self.short(db)))" : "") + ".")
                .font(.subheadline.weight(.semibold))
            let fixes = fixes(in: zone)
            if !fixes.isEmpty {
                Text("Working here: " + fixes.joined(separator: ", ") + ".").font(.subheadline)
            }
        }
        .padding()
        .frame(width: 300, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    private func volumeCard(_ db: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Volume").font(.headline)
            Text("How much louder or quieter everything is, on top of the tone changes.").font(.subheadline)
            Text("Right now: \(Self.words(db)).").font(.subheadline.weight(.semibold))
            if levelling {
                Text("Volume Normalization is on, so every show plays at about the same loudness.").font(.subheadline)
            }
        }
        .padding()
        .frame(width: 300, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: Numbers

    /// The fixes that are on and work in this zone.
    private func fixes(in zone: Zone) -> [String] {
        zone.regions.compactMap(\.fix).filter { sound.repairs[$0] != nil }.map(\.title)
    }

    /// The zone's average change in tone, sampled on the log scale.
    static func average(_ zone: Zone, plan: SoundPlan) -> Double {
        let steps = 12
        var total = 0.0
        for step in 0..<steps {
            let hz = zone.low * pow(zone.high / zone.low, (Double(step) + 0.5) / Double(steps))
            total += EQMath.toneResponseDB(at: hz, plan: plan)
        }
        return total / Double(steps)
    }

    private func binding(for zone: Zone) -> Binding<Bool> {
        Binding(get: { shown == zone }, set: { if !$0, shown == zone { shown = nil } })
    }
}
