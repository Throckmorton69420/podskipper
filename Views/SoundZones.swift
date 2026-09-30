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
    @State private var width: CGFloat = 0

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

    /// The chart spans ±12 dB.
    private static let range = 12.0
    private static let lowHz = 20.0, highHz = 20_000.0

    var body: some View {
        let plan = EQMath.plan(sound)
        let values = Self.zones.map { Self.average($0, plan: plan) }
        VStack(alignment: .leading, spacing: 10) {
            // Pass 27g (his words: colour-coded, clearly split into the parts
            // of the sound, with the loudness scale shown): five coloured
            // bands across, a labelled up/down scale, and the curve filled in
            // each band's colour where it lifts or cuts.
            HStack(alignment: .top, spacing: 4) {
                scale
                chart(plan)
                    .frame(height: 150)
            }
            HStack(spacing: 6) {
                ForEach(Array(Self.zones.enumerated()), id: \.element.id) { index, zone in
                    chip(zone, db: values[index])
                }
                volumeChip(plan.levelDB)
            }
        }
        .animation(.snappy(duration: 0.3), value: values)
        .feel(.selection, trigger: shown)
    }

    // MARK: Chart

    private var scale: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach([12, 6, 0, -6, -12], id: \.self) { db in
                Text(db == 0 ? "0 dB" : String(format: "%+d", db))
                    .font(.system(size: 9, weight: db == 0 ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(db > 0 ? Theme.accentWarm : db < 0 ? Color.blue : Color.secondary)
                    .frame(height: 150 / 5, alignment: db > 0 ? .top : db < 0 ? .bottom : .center)
            }
        }
        .frame(width: 30)
        .accessibilityHidden(true)
    }

    private func chart(_ plan: SoundPlan) -> some View {
        Canvas { context, size in
            let zones = Self.zones
            func x(_ hz: Double) -> CGFloat {
                CGFloat(log10(hz / Self.lowHz) / log10(Self.highHz / Self.lowHz)) * size.width
            }
            func y(_ db: Double) -> CGFloat {
                let c = min(Self.range, max(-Self.range, db))
                return size.height / 2 - CGFloat(c / Self.range) * size.height / 2
            }
            // The curve, and the area between it and the unchanged line.
            var line = Path(), area = Path()
            let steps = 140
            for step in 0...steps {
                let hz = Self.lowHz * pow(Self.highHz / Self.lowHz, Double(step) / Double(steps))
                let p = CGPoint(x: x(hz), y: y(EQMath.toneResponseDB(at: hz, plan: plan)))
                if step == 0 { line.move(to: p); area.move(to: CGPoint(x: p.x, y: size.height / 2)) }
                else { line.addLine(to: p) }
                area.addLine(to: p)
            }
            area.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            area.closeSubpath()

            for zone in zones {
                let rect = CGRect(x: x(zone.low), y: 0, width: x(zone.high) - x(zone.low), height: size.height)
                let color = Self.color(zone)
                let picked = shown == zone
                // The band itself, faint; brighter when tapped.
                context.fill(Path(rect), with: .color(color.opacity(picked ? 0.20 : 0.09)))
                // The lift or cut inside this band, in its colour.
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.fill(area, with: .color(color.opacity(0.55)))
                }
                // Its name across the top.
                context.draw(Text(zone.name).font(.system(size: 10, weight: .bold)).foregroundStyle(color),
                             at: CGPoint(x: rect.midX, y: 3), anchor: .top)
                // A thin divider between bands.
                var edge = Path()
                edge.move(to: CGPoint(x: rect.maxX, y: 0))
                edge.addLine(to: CGPoint(x: rect.maxX, y: size.height))
                context.stroke(edge, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
            // Scale lines: ±6 faint, 0 (unchanged) solid.
            for db in [-6.0, 6.0] {
                var g = Path()
                g.move(to: CGPoint(x: 0, y: y(db))); g.addLine(to: CGPoint(x: size.width, y: y(db)))
                context.stroke(g, with: .color(.white.opacity(0.10)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: size.height / 2)); zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(zero, with: .color(.white.opacity(0.45)), lineWidth: 1)
            context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            // Frequencies along the bottom, for those who want them.
            for (hz, text) in [(100.0, "100 Hz"), (1_000.0, "1 kHz"), (10_000.0, "10 kHz")] {
                context.draw(Text(text).font(.system(size: 8)).foregroundStyle(.secondary),
                             at: CGPoint(x: x(hz), y: size.height - 2), anchor: .bottom)
            }
        }
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onTapGesture { location in
            guard width > 0 else { return }
            let hz = Self.lowHz * pow(Self.highHz / Self.lowHz, Double(location.x / width))
            shown = Self.zones.first { hz >= $0.low && hz < $0.high } ?? Self.zones.last
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound chart")
        .accessibilityValue(SoundGuide.summary(sound, levelling: levelling))
        .popover(item: $shown, arrowEdge: .bottom) { zone in
            card(zone, db: Self.average(zone, plan: EQMath.plan(sound)))
        }
    }

    private func chip(_ zone: Zone, db: Double) -> some View {
        Button { shown = zone } label: {
            VStack(spacing: 2) {
                Image(systemName: zone.symbol).font(.system(size: UIScale.pt(11)))
                Text(zone.name).font(.system(size: UIScale.pt(9), weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(Self.short(db)).font(.system(size: UIScale.pt(10), weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(Self.color(zone))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Self.color(zone).opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(zone.name): \(Self.words(db))")
        .accessibilityHint("Explains this part of the sound")
    }

    private func volumeChip(_ db: Double) -> some View {
        Button { showsVolume = true } label: {
            VStack(spacing: 2) {
                Image(systemName: "speaker.wave.3.fill").font(.system(size: UIScale.pt(11)))
                Text("Volume").font(.system(size: UIScale.pt(9), weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(Self.short(db)).font(.system(size: UIScale.pt(10), weight: .semibold).monospacedDigit())
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
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
