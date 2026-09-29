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
    @Bindable var settings: AppSettings

    var body: some View {
        let current = EQPreset.resolving(settings.equalizerPreset)
        VStack(alignment: .leading, spacing: 6) {
            Picker("Preset", selection: Binding(
                get: { current.name },
                set: { settings.choosePreset(named: $0) }
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
    @Bindable var settings: AppSettings
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        let repairs = settings.enabledRepairs
        let combined = EQMath.combinedGains(preset: settings.baseGains, repairs: repairs)
        let enabled = settings.equalizerEnabled

        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<10, id: \.self) { index in
                VStack(spacing: 4) {
                    Text("\(Int(combined[index].rounded()))")
                        .font(.system(size: UIScale.pt(9)).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { combined[index] },
                        set: { target in
                            settings.setBaseGain(
                                EQMath.baseGain(forTarget: target, band: index, repairs: repairs),
                                band: index)
                        }
                    ), in: EQMath.gainRange)
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
/// Its own small view because it redraws on every slider movement.
struct EQCurvePanel: View {
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared

    /// The drawn range. Past it the line is clipped to the edge.
    private static let dbRange = 15.0
    private static let lowHz = 20.0, highHz = 20_000.0

    var body: some View {
        let sound = settings.sound(normalizationGain: player.currentEpisode?.normalizationGain)
        let plan = EQMath.plan(sound)
        let presetOnly = EQMath.plan(SoundSettings(base: sound.base, repairs: [:], normalizationDB: 0))

        VStack(alignment: .leading, spacing: 6) {
            Canvas { context, size in
                drawGrid(in: &context, size: size)
                context.stroke(curve(presetOnly, size: size, level: false),
                               with: .color(.white.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                context.stroke(curve(plan, size: size, level: true),
                               with: .color(Theme.accentHot),
                               style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
            }
            .frame(height: 96)

            HStack(spacing: 12) {
                legend(color: .white.opacity(0.5), dashed: true, text: "Preset")
                legend(color: Theme.accentHot, dashed: false, text: "What you hear")
                Spacer()
                Text("Level " + Self.format(plan.levelDB))
                    .font(.system(size: Metrics.metaSize).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Equalizer curve")
        .accessibilityValue("Overall level \(Self.format(plan.levelDB))")
    }

    private func legend(color: Color, dashed: Bool, text: String) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 1)
            Text(text)
                .font(.system(size: Metrics.metaSize))
                .foregroundStyle(.secondary)
        }
    }

    static func format(_ db: Double) -> String {
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0 dB" }
        return String(format: "%+.1f dB", rounded)
    }

    private func x(_ hz: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(log10(hz / Self.lowHz) / log10(Self.highHz / Self.lowHz)) * width
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

        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: size.height / 2))
        zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(zero, with: .color(.white.opacity(0.22)), lineWidth: 1)

        let labels: [(Double, String)] = [(100, "100"), (1_000, "1k"), (10_000, "10k")]
        for (hz, text) in labels {
            context.draw(Text(text).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: x(hz, size.width) + 3, y: size.height - 2),
                         anchor: .bottomLeading)
        }
    }
}
