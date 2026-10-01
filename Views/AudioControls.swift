import SwiftUI

/// One speech repair: a switch, a sentence about the problem it fixes, and a
/// strength slider that only appears once it is on.
///
/// The brief for these was explicit — don't expose only DSP terminology. So the
/// name says what it fixes ("Reduce Sibilance"), the line under it describes the
/// symptom in the words someone would actually use ("harsh S and T sounds"),
/// and the technical description is there, smaller, for anyone curious enough
/// to look. Each is a small, fixed filter shape, so the honest technical line
/// is one short clause rather than a paragraph. A plain switch (the rumble
/// filter) passes no strength and gets no slider.
struct RepairRow: View {
    let title: String
    let plain: String
    let technical: String
    let symbol: String
    @Binding var isOn: Bool
    let strength: Binding<Double>?
    let range: ClosedRange<Double>

    @State private var showTechnical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: UIScale.pt(17)))
                    .foregroundStyle(isOn ? Theme.accentHot : .secondary)
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: Metrics.bodySize, weight: .medium))
                    Text(plain)
                        .font(.system(size: Metrics.metaSize))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if showTechnical {
                        Text(technical)
                            .font(.system(size: Metrics.metaSize).monospaced())
                            .foregroundStyle(.tertiary)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.snappy(duration: 0.2)) { showTechnical.toggle() }
                }

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(Theme.accentHot)
                    .accessibilityLabel(title)
            }

            if isOn, let strength {
                HStack(spacing: 10) {
                    Text("Less")
                        .font(.system(size: Metrics.metaSize))
                        .foregroundStyle(.tertiary)
                    Slider(value: strength, in: range, step: 0.5)
                        .feelSteps(strength.wrappedValue, step: 1)
                        .tint(Theme.accentHot)
                    Text("More")
                        .font(.system(size: Metrics.metaSize))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 38)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement()
                .accessibilityLabel("\(title) strength")
                .accessibilityValue("\(Int(strength.wrappedValue))")
            }
        }
        .animation(.snappy(duration: 0.22), value: isOn)
        .contentRow()
    }
}

/// Conservative / Balanced / Aggressive, with the sentence that makes each one
/// mean something.
///
/// This replaces a stepper labelled "Minimum confidence: 60", which asked a
/// listener to have an opinion about a machine-learning score. The number is
/// still there — it is what these set — and it is still adjustable by hand on
/// the advanced row underneath, where moving it puts the choice into Custom.
struct SensitivityPicker: View {
    @Binding var sensitivity: String
    @Binding var threshold: Int
    @State private var showAdvanced = false

    private var current: DetectionSensitivity {
        DetectionSensitivity(rawValue: sensitivity) ?? .balanced
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(DetectionSensitivity.allCases.filter { $0 != .custom }) { option in
                    Button {
                        sensitivity = option.rawValue
                        threshold = option.threshold
                        Haptics.select()
                    } label: {
                        Text(option.rawValue)
                            .font(.system(size: Metrics.metaSize, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(current == option ? Color.black : Color.primary)
                    .background {
                        if current == option {
                            Capsule().fill(Theme.accentGradient)
                        } else {
                            Capsule().fill(Color.white.opacity(0.08))
                        }
                    }
                }
            }

            Text(current.summary)
                .font(.system(size: Metrics.metaSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 6) {
                    Stepper(value: $threshold, in: 20...95, step: 5) {
                        Text("Confidence threshold: \(threshold)")
                            .font(.system(size: Metrics.metaSize).monospacedDigit())
                    }
                    .feel(.selection, trigger: threshold)
                    Text("A passage is cut only when detection is at least this sure it is an ad. Lower catches more and risks more.")
                        .font(.system(size: Metrics.metaSize))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
            }
            .font(.system(size: Metrics.metaSize, weight: .medium))
            .tint(.secondary)
        }
        .onChange(of: threshold) { _, new in
            // Moving the number by hand means the named choice no longer
            // describes what is happening, so stop claiming it does.
            let matched = DetectionSensitivity.matching(new)
            if matched.rawValue != sensitivity { sensitivity = matched.rawValue }
        }
        .contentRow()
    }
}

// MARK: - Equalizer

/// The preset menu, in two groups: tone presets are a base curve, and the
/// "fix one problem" ones switch on the matching repair instead.
struct EQPresetPicker: View {
    @Binding var state: SoundState

    var body: some View {
        let current = EQPreset.resolving(state.preset)
        VStack(alignment: .leading, spacing: 6) {
            Picker("Preset", selection: Binding(
                get: { current.name },
                set: { state.choosePreset(named: $0) }
            )) {
                if current == EQPreset.custom {
                    Text(EQPreset.custom.name).tag(EQPreset.custom.name)
                }
                Section("Tone") {
                    ForEach(EQPreset.tone) { Text($0.name).tag($0.name) }
                }
                Section("Fix one problem") {
                    ForEach(EQPreset.fixes) { Text($0.name).tag($0.name) }
                }
            }
            .feel(.selection, trigger: state.preset)
            .pickerStyle(.menu)

            Text(current.summary)
                .font(.system(size: Metrics.metaSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The ten bands, showing preset plus fixes.
///
/// Each slider sits where the band really is, fixes included, so switching on
/// Reduce Muddiness pulls the 250 slider down. Dragging a slider puts that
/// band where the finger is: the fixes stay as they are and the preset part
/// takes up the difference, which makes the preset Custom.
struct EQBandSliders: View {
    @Binding var state: SoundState
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        let repairs = state.enabledRepairs
        let combined = EQMath.combinedGains(preset: state.baseGains, repairs: repairs)
        let enabled = state.equalizerOn

        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                VStack(spacing: 4) {
                    Text("\(Int(combined[index].rounded()))")
                        .font(.system(size: UIScale.pt(9)).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { combined[index] },
                        set: { target in
                            state.setBaseGain(
                                EQMath.baseGain(forTarget: target, band: index, repairs: repairs),
                                band: index)
                        }
                    ), in: EQMath.gainRange)
                    // The band's own part, so switching a fix on doesn't
                    // also tick every band it moves.
                    .feelSteps(state.gains.indices.contains(index) ? state.gains[index] : 0, step: 1)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 130, height: 20)
                    .frame(width: 24, height: 140)
                    .tint(Theme.accentHot)
                    .disabled(!enabled)
                    .accessibilityLabel("\(labels[index]) hertz")
                    Text(labels[index]).font(.system(size: UIScale.pt(9))).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        // Off, the bands still show what the fixes are doing; they just can't
        // be dragged until the equalizer is on.
        .opacity(enabled ? 1 : 0.55)
    }
}

/// The whole chain as one curve: preset, fixes, the rumble filter, the
/// sibilance notch and the overall level — everything that plays, drawn from
/// the same `EQMath.plan` the audio engine is set from.
///
/// Task 10 (his 30 Sep note: "hard to make sense of for a layperson"): the
/// axes say what they mean — Louder / Quieter, a line for unchanged, plain
/// names under the frequencies — lifts and cuts are shaded differently, each
/// fix draws its own part in its own colour, and every word, fix and the ⓘ
/// open a short explanation. A sentence underneath says what it all adds up to.
///
/// Its own small view because it redraws on every slider movement. Nothing in
/// it animates per frame; the drawing is one Canvas.
struct EQCurvePanel: View {
    /// The sound to draw, already resolved (default or a show's own).
    let sound: SoundSettings
    /// The preset's name, for the legend. nil or Flat: no preset line.
    var presetName: String? = nil
    /// Volume levelling is on (it may be 0 dB with no episode playing).
    var levelling = false

    /// The drawn range. Past it the line is clipped to the edge.
    private static let dbRange = 15.0
    private static let lowHz = 20.0, highHz = 20_000.0

    enum Info: Hashable {
        case howToRead, preset, level
        case region(String)
        case fix(Repair)
    }

    @State private var info: Info?
    @State private var chartWidth: CGFloat = 0
    @AppStorage("sound.detailedChart") private var detailed = false

    /// One fix's own part of the curve, and its deepest point.
    fileprivate struct FixPart: Identifiable {
        let repair: Repair
        let plan: SoundPlan
        let peakDB: Double
        let peakHz: Double
        var id: Repair { repair }

        var label: String {
            if repair == .rumble { return "\(repair.title), below 80 Hz" }
            return "\(repair.title) \(SoundGuide.db(peakDB)) at \(SoundGuide.hz(EQCurvePanel.roundHz(peakHz)))"
        }
    }

    var body: some View {
        let plan = EQMath.plan(sound)
        let presetOnly = EQMath.plan(SoundSettings(base: sound.base, repairs: [:], normalizationDB: 0))
        let hasPreset = sound.base.contains { $0 != 0 }
        let parts = fixParts()
        let highlighted: SoundRegion? = {
            if case .region(let name) = info { return SoundRegion.all.first { $0.name == name } }
            return nil
        }()

        VStack(alignment: .leading, spacing: 6) {
            // Pass 27f: the plain view first; the frequency curve for those
            // who want it. Remembered.
            Picker("Chart", selection: $detailed) {
                Text("Simple").tag(false)
                Text("Detailed").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("sound.chartStyle")
            if !detailed {
                SoundZonesView(sound: sound, levelling: levelling)
                    .padding(.top, 4)
            } else {
            Canvas { context, size in
                if let highlighted { drawHighlight(highlighted, in: &context, size: size) }
                drawGrid(in: &context, size: size)
                drawBandBoundaries(in: &context, size: size)
                drawShading(plan, in: &context, size: size)
                if hasPreset {
                    context.stroke(curve(presetOnly, size: size, level: false),
                                   with: .color(.white.opacity(0.45)),
                                   style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                }
                for part in parts {
                    context.stroke(curve(part.plan, size: size, level: false),
                                   with: .color(part.repair.chartColor.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                context.stroke(curve(plan, size: size, level: true),
                               with: .color(Theme.accentHot),
                               style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
                drawAxisWords(in: &context, size: size)
            }
            .frame(height: 118)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sound chart")
            .accessibilityValue(SoundGuide.summary(sound, levelling: levelling))
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chartWidth = $0 }
            // A tap on the chart explains the stretch under the finger.
            .onTapGesture { location in
                guard chartWidth > 0 else { return }
                let fraction = Double(location.x / chartWidth)
                let hz = Self.lowHz * pow(Self.highHz / Self.lowHz, fraction)
                if let region = SoundRegion.all.first(where: { hz >= $0.low && hz < $0.high }) ?? SoundRegion.all.last {
                    info = .region(region.name)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { info = .howToRead } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: UIScale.pt(15)))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How to read this chart")
                .popover(isPresented: shows(.howToRead), arrowEdge: .top) { howToReadCard }
            }

            bandWords

            legend(parts: parts, plan: plan, hasPreset: hasPreset)
            }

            Text(SoundGuide.summary(sound, levelling: levelling))
                .font(.system(size: Metrics.metaSize))
                .foregroundStyle(Color.primary.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: SoundGuide.summary(sound, levelling: levelling))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
        .feel(.selection, trigger: info)
    }

    // MARK: Pieces

    /// The plain names under the frequency numbers, each at the middle of
    /// its stretch, on two staggered rows so neighbours don't collide.
    private var bandWords: some View {
        BandWordLayout(positions: SoundRegion.all.map { x(fraction: $0.centre) }) {
            ForEach(SoundRegion.all) { region in
                let selected = info == .region(region.name)
                Button { info = .region(region.name) } label: {
                    Text(region.name)
                        .font(.system(size: UIScale.pt(10), weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(region.name), \(region.range)")
                .accessibilityHint("Explains this part of the sound")
                .popover(isPresented: shows(.region(region.name)), arrowEdge: .top) {
                    regionCard(region)
                }
            }
        }
    }

    private func legend(parts: [FixPart], plan: SoundPlan, hasPreset: Bool) -> some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    chip(.howToRead, text: "What you hear") {
                        Capsule().fill(Theme.accentHot).frame(width: 14, height: 3)
                    }
                    if hasPreset {
                        chip(.preset, text: "Preset: " + presetTitle) {
                            Capsule()
                                .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                                .frame(width: 14, height: 1)
                        }
                        .popover(isPresented: shows(.preset), arrowEdge: .top) { presetCard }
                    }
                    ForEach(parts) { part in
                        chip(.fix(part.repair), text: part.label) {
                            Capsule().fill(part.repair.chartColor).frame(width: 14, height: 3)
                        }
                        .popover(isPresented: shows(.fix(part.repair)), arrowEdge: .top) {
                            fixCard(part)
                        }
                    }
                    if plan.levelDB != 0 || levelling {
                        chip(.level, text: "Level " + Self.format(plan.levelDB)) {
                            Image(systemName: "speaker.wave.2").font(.system(size: 9))
                        }
                        .popover(isPresented: shows(.level), arrowEdge: .top) { levelCard(plan.levelDB) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
    }

    private func chip<Swatch: View>(_ item: Info, text: String,
                                    @ViewBuilder swatch: () -> Swatch) -> some View {
        Button { info = item } label: {
            HStack(spacing: 5) {
                swatch()
                Text(text)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityHint("Explains this")
    }

    private var presetTitle: String {
        guard let presetName else { return "Custom" }
        return EQPreset.resolving(presetName).name
    }

    // MARK: Explanations

    private var howToReadCard: some View {
        InfoCard(title: "Reading the chart", lines: [
            ("Left to right", "Low sounds on the left (rumble, bass), high on the right (S sounds, air)."),
            ("Up and down", "Above the middle line is louder, below is quieter. On the line is unchanged."),
            ("Colours", "Warm shading is lifted, blue is cut. The pink line is what you hear; each fix has its own coloured line; a dashed line is the preset."),
            ("Tap", "Tap a word under the chart, a fix, or anywhere on the chart to learn more."),
        ])
    }

    private func regionCard(_ region: SoundRegion) -> some View {
        var lines: [(String, String)] = [("", region.about)]
        let now = EQMath.responseDB(at: region.centre, plan: EQMath.plan(sound))
        lines.append(("Right now", abs(now) < 0.5 ? "Unchanged here." : "\(SoundGuide.db(now)) here."))
        if let fix = region.fix {
            let on = sound.repairs[fix] != nil
            lines.append(("Fix", fix.title + (on ? " (on)" : " (off)")))
        }
        return InfoCard(title: "\(region.name) · \(region.range)", lines: lines)
    }

    private func fixCard(_ part: FixPart) -> some View {
        InfoCard(title: part.repair.title, lines: [
            ("What it does", part.repair.plain),
            ("When to use it", part.repair.whenToUse),
            ("What you'll hear", part.repair.whatYouHear),
            ("On the chart", part.label + ". " + part.repair.technical),
        ])
    }

    private var presetCard: some View {
        InfoCard(title: presetTitle, lines: [
            ("", EQPreset.resolving(presetName ?? EQPreset.custom.name).summary),
            ("On the chart", "The dashed line: the preset alone, before the fixes are added."),
        ])
    }

    private func levelCard(_ db: Double) -> some View {
        InfoCard(title: "Level " + Self.format(db), lines: [
            ("", "How much louder or quieter everything is, on top of the tone changes."),
            ("Made of", (levelling ? "Volume Normalization, so every show plays at the same loudness; " : "")
                + "a small match so the fixes change tone, not loudness; and Enhance Dialogue's lift for quiet hosts, when it's on."),
        ])
    }

    /// Only this item's popover shows; closing it clears the choice.
    private func shows(_ item: Info) -> Binding<Bool> {
        Binding(get: { info == item }, set: { if !$0, info == item { info = nil } })
    }

    // MARK: Numbers

    private func fixParts() -> [FixPart] {
        Repair.allCases.compactMap { repair in
            guard let strength = sound.repairs[repair] else { return nil }
            let plan = EQMath.plan(SoundSettings(base: EQPreset.flat.gains,
                                                 repairs: [repair: strength], normalizationDB: 0))
            var peak = 0.0, peakHz = 1_000.0
            for step in 0...60 {
                let hz = 50 * pow(16_000 / 50, Double(step) / 60)
                let db = EQMath.toneResponseDB(at: hz, plan: plan)
                if abs(db) > abs(peak) { peak = db; peakHz = hz }
            }
            return FixPart(repair: repair, plan: plan, peakDB: peak, peakHz: peakHz)
        }
    }

    /// Two significant figures: 283 → 280, 3_470 → 3_500.
    static func roundHz(_ hz: Double) -> Double {
        let scale = pow(10, floor(log10(hz)) - 1)
        return (hz / scale).rounded() * scale
    }

    static func format(_ db: Double) -> String {
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0 dB" }
        return String(format: "%+.1f dB", rounded)
    }

    // MARK: Drawing

    private func x(fraction hz: Double) -> Double {
        log10(hz / Self.lowHz) / log10(Self.highHz / Self.lowHz)
    }

    private func x(_ hz: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(x(fraction: hz)) * width
    }

    private func y(_ db: Double, _ height: CGFloat) -> CGFloat {
        let clamped = min(Self.dbRange, max(-Self.dbRange, db))
        return height / 2 - CGFloat(clamped / Self.dbRange) * (height / 2)
    }

    private func curve(_ plan: SoundPlan, size: CGSize, level: Bool) -> Path {
        var path = Path()
        let steps = 120
        for step in 0...steps {
            let fraction = Double(step) / Double(steps)
            let hz = Self.lowHz * pow(Self.highHz / Self.lowHz, fraction)
            let db = level ? EQMath.responseDB(at: hz, plan: plan)
                           : EQMath.toneResponseDB(at: hz, plan: plan)
            let point = CGPoint(x: x(hz, size.width), y: y(db, size.height))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    /// Lifts shaded warm above the line, cuts shaded blue below it.
    private func drawShading(_ plan: SoundPlan, in context: inout GraphicsContext, size: CGSize) {
        var area = curve(plan, size: size, level: true)
        area.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        area.addLine(to: CGPoint(x: 0, y: size.height / 2))
        area.closeSubpath()
        let top = CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        let bottom = CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        context.drawLayer { layer in
            layer.clip(to: Path(top))
            layer.fill(area, with: .color(Theme.accentWarm.opacity(0.26)))
        }
        context.drawLayer { layer in
            layer.clip(to: Path(bottom))
            layer.fill(area, with: .color(Color.blue.opacity(0.30)))
        }
    }

    /// Subtle vertical separators make the detailed curve correspond to
    /// the named listening bands below it. A coloured cap is used only where
    /// that band has an active repair, so the line itself remains the primary
    /// data rather than becoming a rainbow chart.
    private func drawBandBoundaries(in context: inout GraphicsContext, size: CGSize) {
        var separators = Path()
        for region in SoundRegion.all.dropLast() {
            let xPosition = x(region.high, size.width)
            separators.move(to: CGPoint(x: xPosition, y: 0))
            separators.addLine(to: CGPoint(x: xPosition, y: size.height))
        }
        context.stroke(separators,
                       with: .color(Color.white.opacity(0.14)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        // Make the named listening regions part of the chart itself, not only
        // a legend below it. This keeps Rumble/Bo​om/Warmth/Body/etc. visually
        // aligned with the actual logarithmic frequency curve.
        for (index, region) in SoundRegion.all.enumerated() {
            let left = x(max(region.low, Self.lowHz), size.width)
            let right = x(min(region.high, Self.highHz), size.width)
            guard right > left else { continue }
            let fixColor = region.fix?.chartColor ?? .white
            let alpha = region.fix == nil ? 0.025 : 0.045
            context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: size.height)),
                         with: .color(fixColor.opacity(alpha)))

            let label = Text(region.name)
                .font(.system(size: UIScale.pt(8.5), weight: region.fix == nil ? .medium : .semibold))
                .foregroundStyle(region.fix?.chartColor ?? Color.secondary)
            let labelX = max(left + 2, min((left + right) / 2, right - 2))
            context.draw(label, at: CGPoint(x: labelX, y: 4), anchor: .top)

            if let fix = region.fix {
                context.fill(Path(CGRect(x: left, y: size.height - 3,
                                          width: right - left, height: 3)),
                             with: .color(fix.chartColor.opacity(0.85)))
            }
            _ = index
        }
    }

    private func drawHighlight(_ region: SoundRegion, in context: inout GraphicsContext, size: CGSize) {
        let left = x(max(region.low, Self.lowHz), size.width)
        let right = x(min(region.high, Self.highHz), size.width)
        context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: size.height)),
                     with: .color(.white.opacity(0.09)))
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var lines = Path()
        for db in [-12.0, -6, 6, 12] {
            lines.move(to: CGPoint(x: 0, y: y(db, size.height)))
            lines.addLine(to: CGPoint(x: size.width, y: y(db, size.height)))
        }
        for hz in [100.0, 1_000, 10_000] {
            lines.move(to: CGPoint(x: x(hz, size.width), y: 0))
            lines.addLine(to: CGPoint(x: x(hz, size.width), y: size.height))
        }
        context.stroke(lines, with: .color(.white.opacity(0.08)), lineWidth: 1)

        // 0 dB: what the recording is, untouched.
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: size.height / 2))
        zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(zero, with: .color(.white.opacity(0.4)), lineWidth: 1.2)

        let labels: [(Double, String)] = [(100, "100 Hz"), (1_000, "1k"), (10_000, "10k")]
        for (hz, text) in labels {
            context.draw(Text(text).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: x(hz, size.width) + 3, y: size.height - 2),
                         anchor: .bottomLeading)
        }
    }

    private func drawAxisWords(in context: inout GraphicsContext, size: CGSize) {
        let style = Font.system(size: 9, weight: .semibold)
        context.draw(Text("▲ Louder").font(style).foregroundStyle(Theme.accentWarm),
                     at: CGPoint(x: 2, y: 2), anchor: .topLeading)
        context.draw(Text("▼ Quieter").font(style).foregroundStyle(Color.blue.opacity(0.9)),
                     at: CGPoint(x: 2, y: size.height - 14), anchor: .bottomLeading)
        context.draw(Text("Unchanged").font(.system(size: 9)).foregroundStyle(.secondary),
                     at: CGPoint(x: size.width - 2, y: size.height / 2 - 2), anchor: .bottomTrailing)
    }
}

/// A short explanation in a popover: a title and a few labelled lines.
private struct InfoCard: View {
    let title: String
    let lines: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 1) {
                    if !line.0.isEmpty {
                        Text(line.0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(line.1).font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .presentationCompactAdaptation(.popover)
    }
}

/// Puts each word centred at its fraction of the width, alternating between
/// two rows, kept inside the edges. A Layout rather than a GeometryReader:
/// it sizes itself and costs nothing to redraw.
private struct BandWordLayout: Layout {
    let positions: [Double]
    private let rowGap: CGFloat = 1

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let row = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 320, height: row * 2 + rowGap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let row = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let fraction = positions.indices.contains(index) ? positions[index] : 0
            let centre = bounds.minX + CGFloat(fraction) * bounds.width
            let left = min(bounds.maxX - size.width, max(bounds.minX, centre - size.width / 2))
            let top = bounds.minY + (index.isMultiple(of: 2) ? 0 : row + rowGap)
            subview.place(at: CGPoint(x: left, y: top), proposal: .unspecified)
        }
    }
}

/// The speed half of "Speed and Audio", in words: "Playback 1.2× · Smart
/// Speed saves about 4 min an hour". Its own view so the chart doesn't
/// redraw when the speed changes.
struct PlaybackSpeedLine: View {
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(Theme.accentWarm)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .font(.system(size: Metrics.metaSize))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .background(Color.black)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        let rate = player.playbackRate
        let speed = "Playback " + (rate.rounded() == rate ? "\(Int(rate))×" : String(format: "%g×", (rate * 100).rounded() / 100))
        guard settings.smartSpeedEnabled else { return speed + " · Smart Speed off" }
        guard let episode = player.currentEpisode, episode.duration > 0 else {
            return speed + " · Smart Speed on"
        }
        let jumps = AudioAnalyzer.smartSpeedJumps(from: episode.silenceRanges,
                                                  aggressiveness: settings.smartSpeedAggressiveness)
        guard !jumps.isEmpty else { return speed + " · Smart Speed on, once this episode's pauses are measured" }
        let saved = jumps.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        let perHour = Int((saved / episode.duration * 60).rounded())
        return speed + (perHour < 1 ? " · Smart Speed saves under a minute an hour"
                                    : " · Smart Speed saves about \(perHour) min an hour")
    }
}
