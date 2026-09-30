import SwiftUI

/// The sound, the way a listener thinks about it (pass 27f, his words: the
/// chart "is still not as visually intuitive as it can be").
///
/// Five plain zones from low to high — Bass, Warmth, Voice, Clarity,
/// Sparkle — each a bar that rises when that part is louder and drops when
/// it is quieter, with the change in words and the fixes working there,
/// plus Volume on its own. Tap a zone for what lives there. The detailed
/// frequency curve is one switch away (`EQCurvePanel`).
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

    /// Bars reach the top or bottom at this many dB.
    private static let fullScale = 9.0

    @State private var shown: Zone?
    @State private var showsVolume = false

    var body: some View {
        let plan = EQMath.plan(sound)
        let values = Self.zones.map { Self.average($0, plan: plan) }
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(Self.zones.enumerated()), id: \.element.id) { index, zone in
                Button { shown = zone } label: {
                    bar(name: zone.name, symbol: zone.symbol, db: values[index],
                        fixes: fixes(in: zone))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(zone.name): \(Self.words(values[index]))")
                .accessibilityHint("Explains this part of the sound")
                .popover(isPresented: binding(for: zone), arrowEdge: .bottom) { card(zone, db: values[index]) }
            }
            Divider().frame(height: 120).padding(.horizontal, 2)
            Button { showsVolume = true } label: {
                bar(name: "Volume", symbol: "speaker.wave.3.fill", db: plan.levelDB,
                    fixes: levelling ? ["Levelled"] : [])
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Volume: \(Self.words(plan.levelDB))")
            .popover(isPresented: $showsVolume, arrowEdge: .bottom) { volumeCard(plan.levelDB) }
        }
        .animation(.snappy(duration: 0.3), value: values)
        .feel(.selection, trigger: shown)
    }

    // MARK: One bar

    private func bar(name: String, symbol: String, db: Double, fixes: [String]) -> some View {
        let fraction = min(1, abs(db) / Self.fullScale)
        let louder = db > 0.25, quieter = db < -0.25
        let tint: Color = louder ? Theme.accentWarm : (quieter ? .blue : .secondary)
        return VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(13), weight: .semibold))
                .foregroundStyle(louder || quieter ? tint : .secondary)
                .symbolEffect(.bounce, value: louder || quieter)
                .frame(height: 16)
            GeometryReader { geo in
                let half = geo.size.height / 2
                ZStack {
                    Capsule().fill(Color.white.opacity(0.07))
                    Rectangle().fill(Color.white.opacity(0.35)).frame(height: 1)
                    // From the middle line up (louder) or down (quieter).
                    Capsule()
                        .fill(tint.gradient)
                        .frame(height: max(louder || quieter ? 4 : 0, half * fraction))
                        .offset(y: louder ? -half * fraction / 2 : half * fraction / 2)
                }
            }
            .frame(width: 26, height: 88)
            Text(name)
                .font(.system(size: UIScale.pt(11), weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(Self.short(db))
                .font(.system(size: UIScale.pt(10)).monospacedDigit())
                .foregroundStyle(louder || quieter ? tint : .secondary)
                .lineLimit(1)
            Text(fixes.joined(separator: ", "))
                .font(.system(size: UIScale.pt(9)))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 22, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
