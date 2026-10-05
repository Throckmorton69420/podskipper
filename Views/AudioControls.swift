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
    @ScaledMetric(relativeTo: .footnote) private var bandWidth = 64
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    /// All ten bands across the width, portrait and landscape alike (4 Oct:
    /// "I don't want fewer bands on portrait"). Only when the text is too big
    /// for ten columns does the row scroll sideways, still with all ten.
    var body: some View {
        let enabled = state.equalizerOn
        ViewThatFits(in: .horizontal) {
            bandRow(fitted: true)
            ScrollView(.horizontal) { bandRow(fitted: false) }
                .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity)
        // Off, the bands still show what the fixes are doing; they just can't
        // be dragged until the equalizer is on.
        .opacity(enabled ? 1 : 0.55)
    }

    private func bandRow(fitted: Bool) -> some View {
        let repairs = state.enabledRepairs
        let combined = EQMath.combinedGains(preset: state.baseGains, repairs: repairs)
        let enabled = state.equalizerOn
        return HStack(alignment: .bottom, spacing: fitted ? 0 : 8) {
            ForEach(0..<10, id: \.self) { index in
                VStack(spacing: 4) {
                    Text("\(Int(combined[index].rounded()))")
                        .font(.footnote.monospacedDigit())
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
                    // An ideal width the row can actually meet, so the fitted
                    // row is chosen whenever its labels fit.
                    .frame(minWidth: fitted ? 28 : bandWidth, idealWidth: fitted ? 28 : bandWidth,
                           maxWidth: fitted ? .infinity : bandWidth, minHeight: 140, maxHeight: 140)
                    .tint(Theme.accentHot)
                    .disabled(!enabled)
                    .accessibilityLabel("\(labels[index]) hertz")
                    .accessibilityIdentifier("sound.eq.band.\(index)")
                    Text(labels[index]).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: fitted ? .infinity : bandWidth)
            }
        }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The sound to draw, already resolved (default or a show's own).
    let sound: SoundSettings
    /// The preset's name, for the legend. nil or Flat: no preset line.
    var presetName: String? = nil
    /// Volume levelling is on (it may be 0 dB with no episode playing).
    var levelling = false

    enum Presentation { case full, compactPlot, details }
    var presentation: Presentation = .full
    var plotHeight: CGFloat = 120

    /// The drawn range. Past it the line is clipped to the edge.
    private static let dbRange = 15.0
    private static let lowHz = 20.0, highHz = 20_000.0

    enum Info: Hashable { case fix(Repair) }
    @State private var info: Info?

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

    @ScaledMetric(relativeTo: .footnote) private var axisHeight: CGFloat = 22

    var body: some View {
        let plan = EQMath.plan(sound)
        let parts = fixParts()
        let preset = presetPlan
        VStack(alignment: .leading, spacing: 10) {
            // One chart (4 Oct: "get rid of the simple chart altogether").
            // Every line on it is a real frequency response from `EQMath`:
            // the preset, each fix on its own, and the total that plays.
            // Volume levelling changes the whole sound equally, so it moves
            // the total line up or down and is named in the key; it is never
            // drawn as a shape of its own.
            if presentation != .details {
                HStack(spacing: 8) {
                    if !typeSize.isAccessibilitySize { SoundChartScale() }
                    Canvas { context, size in
                        drawGrid(in: &context, size: size)
                        drawShading(plan, in: &context, size: size)
                        if let preset, sound.base.contains(where: { abs($0) > 0.01 }) {
                            context.stroke(curve(preset, size: size, level: false),
                                           with: .color(.cyan.opacity(0.85)),
                                           style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        }
                        for part in parts {
                            context.stroke(curve(part.plan, size: size, level: false),
                                           with: .color(part.repair.chartColor.opacity(0.88)),
                                           style: StrokeStyle(lineWidth: 1.35, dash: [3, 3]))
                        }
                        context.stroke(curve(plan, size: size, level: true),
                                       with: .color(Theme.accentHot),
                                       style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    }
                    .accessibilityHidden(true)
                }
                .frame(height: plotHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Sound chart: how much louder or quieter each part of the sound is")
                .accessibilityValue(accessibilitySummary(parts: parts))
                .accessibilityIdentifier("sound.plot")
                HStack(spacing: 8) {
                    // Only its width: the scale's spacers would otherwise
                    // stretch this row to whatever height is offered (the
                    // pinned header measured the whole sheet).
                    if !typeSize.isAccessibilitySize { SoundChartScale().hidden().frame(height: 1) }
                    // Pinned above the controls there is room for one row:
                    // the plain names. The full chart adds the Hz marks.
                    VStack(spacing: 2) {
                        if presentation == .full { frequencyAxis }
                        zoneAxis
                    }
                }
                .accessibilityHidden(true)
            }
            if presentation != .compactPlot {
                Text("Left is deep bass, right is treble. Above the middle line is louder than the recording, below is quieter. The solid line is what you hear; each dashed line is one setting on its own.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SoundContributionLegend(items: contributions(parts: parts))
                    .accessibilityIdentifier("sound.contributions")
                DisclosureGroup("Chart details") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(SoundGuide.summary(sound, levelling: levelling))
                        Text("This shows your sound settings, not a live measurement of the podcast.")
                            .foregroundStyle(.secondary)
                        ForEach(Self.zones, id: \.name) { band in
                            HStack {
                                Text(band.name + " · " + band.range)
                                Spacer()
                                Text(Self.format(bandAverage(band, plan: plan))).monospacedDigit()
                            }
                        }
                        if sound.base.contains(where: { $0 != 0 }) {
                            Text("Preset: " + presetTitle)
                        }
                        ForEach(fixParts()) { part in
                            Button { info = .fix(part.repair) } label: {
                                Label(part.label, systemImage: "info.circle")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }.buttonStyle(.plain)
                            .popover(isPresented: shows(.fix(part.repair)), arrowEdge: .top) { fixCard(part) }
                        }
                        Text("Overall level: " + Self.format(plan.levelDB))
                    }
                    .font(.subheadline).padding(.vertical, 8)
                }
                .font(.subheadline)
                .accessibilityIdentifier("sound.chartDetails")
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, 10)
        .feel(.selection, trigger: info)
    }

    /// Plain names for the stretches of the frequency axis, at their real
    /// positions under the plot.
    private struct Zone {
        let name: String
        let range: String
        let low: Double
        let high: Double
    }
    private static let zones = [
        Zone(name: "Bass", range: "20–250 Hz", low: 20, high: 250),
        Zone(name: "Voice", range: "250 Hz–4 kHz", low: 250, high: 4_000),
        Zone(name: "Treble", range: "4–20 kHz", low: 4_000, high: 20_000)
    ]

    private func bandAverage(_ band: Zone, plan: SoundPlan) -> Double {
        rangeAverage(low: band.low, high: band.high, plan: plan)
    }

    private func rangeAverage(low: Double, high: Double, plan: SoundPlan) -> Double {
        (0..<32).reduce(0.0) { sum, step in
            let hz = low * pow(high / low, (Double(step) + 0.5) / 32)
            return sum + EQMath.toneResponseDB(at: hz, plan: plan)
        } / 32
    }

    private var presetPlan: SoundPlan? {
        guard presetName != nil else { return nil }
        return EQMath.plan(SoundSettings(base: sound.base, repairs: [:], normalizationDB: 0))
    }

    private func contributions(parts: [FixPart]) -> [SoundContribution] {
        var items = [SoundContribution(id: "combined", label: "What you hear", color: Theme.accentHot, style: .solid)]
        if presetName != nil, sound.base.contains(where: { abs($0) > 0.01 }) {
            items.append(SoundContribution(id: "preset", label: "Preset: " + presetTitle, color: .cyan, style: .longDash))
        } else if presetName == nil {
            items.append(SoundContribution(id: "preset-off", label: "Equalizer off", color: .secondary, style: .none))
        }
        // Each fix with what it actually does where it does it, e.g.
        // "Clearer Dialogue +3 dB at 2.8 kHz", not just its name.
        items += parts.map {
            SoundContribution(id: $0.repair.id, label: $0.label, color: $0.repair.chartColor, style: .shortDash)
        }
        if levelling {
            let level = abs(sound.normalizationDB) > 0.05 ? " " + Self.format(sound.normalizationDB) : ""
            items.append(SoundContribution(id: "normalization", label: "Volume levelling" + level + ", whole sound",
                                           color: .green, style: .none))
        }
        return items
    }

    private func accessibilitySummary(parts: [FixPart]) -> String {
        let labels = contributions(parts: parts).dropFirst().map(\.label).joined(separator: ", ")
        return "Scale minus 15 to plus 15 decibels. " + SoundGuide.summary(sound, levelling: levelling)
            + " Active settings: " + labels + "."
    }

    /// Decade marks, each matching a grid line in the plot.
    private var frequencyAxis: some View {
        let ticks: [Double] = typeSize.isAccessibilitySize ? [100, 10_000] : [100, 1_000, 10_000]
        return FrequencyLabelLayout(positions: ticks.map { x(fraction: $0) }) {
            ForEach(ticks, id: \.self) { hz in
                Text(hz == 100 ? "100 Hz" : hz == 1_000 ? "1 kHz" : "10 kHz")
                    .font(.footnote.monospacedDigit())
                    .fixedSize()
            }
        }
        .foregroundStyle(.secondary)
        .frame(height: axisHeight)
    }

    /// Bass, Voice and Treble, each centred on its real stretch of the axis.
    private var zoneAxis: some View {
        FrequencyLabelLayout(positions: Self.zones.map { (x(fraction: $0.low) + x(fraction: $0.high)) / 2 }) {
            ForEach(Self.zones, id: \.name) { zone in
                Text(zone.name)
                    .font(.footnote.weight(.semibold))
                    .fixedSize()
            }
        }
        .foregroundStyle(.primary.opacity(0.75))
        .frame(height: axisHeight)
    }

    private var presetTitle: String {
        guard let presetName else { return "Custom" }
        return EQPreset.resolving(presetName).name
    }

    // MARK: Explanations

    private func fixCard(_ part: FixPart) -> some View {
        InfoCard(title: part.repair.title, lines: [
            ("What it does", part.repair.plain),
            ("When to use it", part.repair.whenToUse),
            ("What you'll hear", part.repair.whatYouHear),
            ("On the chart", part.label + ". " + part.repair.technical),
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

    }

}

private struct SoundContribution: Identifiable {
    enum Style { case solid, longDash, shortDash, none }
    let id: String
    let label: String
    let color: Color
    var style: Style = .solid
}

/// The chart's key: one line per curve, drawn the way the curve is drawn
/// (solid, long or short dashes), with the full label wrapping rather than
/// scrolling sideways. Items with no line of their own get a dot.
private struct SoundContributionLegend: View {
    let items: [SoundContribution]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    LineSwatch(color: item.color, style: item.style)
                        .frame(width: 22, height: 8)
                    Text(item.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct LineSwatch: View {
    let color: Color
    let style: SoundContribution.Style

    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 0, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            switch style {
            case .solid:
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            case .longDash:
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            case .shortDash:
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            case .none:
                let dot = CGRect(x: size.width / 2 - 3.5, y: size.height / 2 - 3.5, width: 7, height: 7)
                context.fill(Path(ellipseIn: dot), with: .color(color))
            }
        }
        .accessibilityHidden(true)
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

/// Frequency labels occupy their true log-scale positions, clamped using
/// measured text widths so endpoint labels cannot collide or leave the plot.
private struct FrequencyLabelLayout: Layout {
    let positions: [Double]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 320, height: subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let centre = bounds.minX + CGFloat(positions[index]) * bounds.width
            let left = min(bounds.maxX - size.width, max(bounds.minX, centre - size.width / 2))
            subview.place(at: CGPoint(x: left, y: bounds.midY - size.height / 2), proposal: .unspecified)
        }
    }
}

/// The speed half of "Speed and Audio", in words: "Playback 1.2× · Smart
/// Speed saves about 4 min an hour". Its own view so the chart doesn't
/// redraw when the speed changes.
struct PlaybackSpeedLine: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(Theme.accentWarm)
            Text(text)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.top, 6)
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

/// Both chart modes use the same readable scale and plotting rectangle.
private struct SoundChartScale: View {
    @ScaledMetric(relativeTo: .footnote) private var width: CGFloat = 46
    var body: some View {
        VStack(alignment: .trailing) {
            Text("+15 dB").foregroundStyle(Theme.accentWarm)
            Spacer()
            Text("0 dB").foregroundStyle(.secondary)
            Spacer()
            Text("−15 dB").foregroundStyle(.blue)
        }
        .font(.footnote.monospacedDigit())
        .frame(width: width)
        .accessibilityHidden(true)
    }
}
