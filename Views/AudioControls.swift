import SwiftUI
import UIKit

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
    /// The fix's chart colour, so the switch and its shape on the chart match.
    var tint: Color = Theme.accentHot

    @State private var showTechnical = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: UIScale.pt(17)))
                    .foregroundStyle(isOn ? tint : .secondary)
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
                        .tint(tint)
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

/// The sound chart (pass 29 redesign, his 5 Oct notes).
///
/// - The frequency axis is seven named, coloured zones (Rumble, Boom, Mud,
///   Body, Clarity, Sibilance, Air), shaded behind the plot and labelled under
///   it. Tap a zone, on the plot or its label, for what it is and what is
///   changing it.
/// - The solid line is the tone you hear: preset plus every fix, from the
///   same `EQMath.plan` the audio engine is set from. Each fix is a filled
///   shape in its own colour (the colour of the zone it works on), so you can
///   see where it acts and by how much. The preset is a dashed line.
/// - Changes slide into place, and whatever was just changed is highlighted
///   for a few seconds with a sentence saying what it did, in words.
/// - Loudness (Volume Normalization, Even Out Volume and the automatic level
///   match) is not a change of tone, so it is never drawn as a shift of the
///   curve; it is described in words beside it.
///
/// Its own small view because it redraws on every slider movement.
struct EQCurvePanel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The sound to draw, already resolved (default or a show's own).
    let sound: SoundSettings
    /// The preset's name, for the key. nil: equalizer off.
    var presetName: String? = nil
    /// Volume Normalization is on.
    var levelling = false
    /// Even Out Volume is on.
    var evenOut = false

    enum Presentation { case full, compactPlot, details }
    var presentation: Presentation = .full
    var plotHeight: CGFloat = 120
    /// Pass 30 (his 5 Oct request, after Gemini's idea): each fix gets a
    /// handle on the chart at its peak; dragging it sets that fix's strength,
    /// exactly as its slider does. Nil: no handles (a show's own sound page).
    var onStrength: ((Repair, Double) -> Void)? = nil

    private static let dbRange = 15.0
    /// Pass 32 (his 7 Oct screenshot: the fix handles were cut in half at
    /// the top and bottom of the plot). ±15 dB is drawn this far inside the
    /// plot's edges, so a handle at either end is whole and can be grabbed.
    static let edgeInset: CGFloat = 12
    private static let lowHz = 20.0, highHz = 20_000.0
    /// Log-spaced sample frequencies across the plot, left to right.
    /// Pass 37: 192 steps (was 96), so a curve stays smooth at 4× zoom.
    static let sampleHz: [Double] = (0...192).map { lowHz * pow(highHz / lowHz, Double($0) / 192) }

    /// What was changed last, highlighted for a few seconds.
    enum Focus: Equatable { case fix(Repair), preset }
    @State private var focus: Focus?
    @State private var focusStamp = 0
    @State private var zoneShown: SoundZone?
    @State private var fixShown: Repair?
    @State private var plotWidth: CGFloat = 1
    /// Pass 37 (his request, Gemini's spec): the chart zooms across the
    /// frequencies, not as a picture — knobs, lines and the dB scale stay
    /// the same size while the high-frequency knobs spread apart. `zoom`
    /// 1–4 (0.92 while pinching in), `pan` the left edge of what's shown, as
    /// a fraction of 20 Hz–20 kHz on the chart's log scale.
    @State private var zoom: CGFloat = 1
    @State private var pan: CGFloat = 0
    @State private var pinchFrom: (zoom: CGFloat, anchor: CGFloat, distance: CGFloat)?
    @State private var gate = ChartTouchGate()
    /// The fix whose knob is being dragged, for the frequency marks.
    @State private var dragging: Repair?
    @State private var resetTick = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    fileprivate struct FixPart: Identifiable {
        let repair: Repair
        let samples: CurveSamples
        let peakDB: Double
        var id: Repair { repair }
    }

    var body: some View {
        let plan = EQMath.plan(sound)
        let parts = fixParts()
        VStack(alignment: .leading, spacing: 8) {
            if presentation != .details {
                plot(plan: plan, parts: parts)
                zoneStrip
                if presentation == .compactPlot || focus != nil { changeLine(parts: parts) }
            }
            if presentation != .compactPlot {
                key(plan: plan, parts: parts)
            }
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, presentation == .compactPlot ? 6 : 10)
        .onChange(of: sound) { old, new in
            guard let changed = Self.changed(from: old, to: new) else { return }
            focus = changed
            focusStamp &+= 1
        }
        .task(id: focusStamp) {
            guard focus != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.4)) { focus = nil } }
        }
        .feel(.selection, trigger: zoneShown)
    }

    // MARK: Plot

    private func plot(plan: SoundPlan, parts: [FixPart]) -> some View {
        let total = CurveSamples(values: Self.sampleHz.map { EQMath.toneResponseDB(at: $0, plan: plan) })
        let presetSamples = presetCurve
        let zoomed = zoom > 1.02
        let ruler = Self.ramp(zoom, from: 1.25, to: 1.5)
        let fine = max(Self.ramp(zoom, from: 2.2, to: 2.5), dragging == nil ? 0 : 1)
        return HStack(spacing: 6) {
            if !typeSize.isAccessibilitySize { SoundChartScale() }
            Color.clear
                // The frequencies, as wide as the zoom makes them, slid to
                // the part being shown and clipped to the plot. Lines keep
                // their width: this is a wider drawing, not a scaled one.
                .overlay(alignment: .topLeading) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, size in
                            drawBackground(in: &context, size: size, ruler: ruler, fine: fine)
                        }
                        Group {
                            ForEach(parts) { part in
                                let lit = focus == nil || focus == .fix(part.repair)
                                CurveShape(samples: part.samples, dbRange: Self.dbRange, filled: true)
                                    .fill(part.repair.chartColor.opacity(lit ? (focus == nil ? 0.32 : 0.6) : 0.14))
                                CurveShape(samples: part.samples, dbRange: Self.dbRange, filled: false)
                                    .stroke(part.repair.chartColor.opacity(lit ? 0.95 : 0.35), lineWidth: lit && focus != nil ? 2 : 1.2)
                            }
                            if let presetSamples {
                                CurveShape(samples: presetSamples, dbRange: Self.dbRange, filled: false)
                                    .stroke(Color.white.opacity(focus == .preset ? 0.95 : 0.6),
                                            style: StrokeStyle(lineWidth: focus == .preset ? 2.2 : 1.4, dash: [6, 4]))
                            }
                            CurveShape(samples: total, dbRange: Self.dbRange, filled: false)
                                .stroke(Theme.accentHot, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                        }
                        .padding(.vertical, Self.edgeInset)
                    }
                    .frame(width: plotWidth * zoom, height: plotHeight)
                    .offset(x: -pan * zoom * plotWidth)
                }
                .overlay(alignment: .leading) {
                    VStack(alignment: .leading) {
                        Text("Louder").foregroundStyle(Theme.accentWarm)
                        Spacer(minLength: 0)
                        Text("Quieter").foregroundStyle(.blue)
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .allowsHitTesting(false)
                }
                // Which slice of 20 Hz–20 kHz is shown.
                .overlay(alignment: .topLeading) {
                    if zoomed {
                        Capsule().fill(.white.opacity(0.14))
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.7))
                                    .frame(width: max(8, plotWidth / zoom), height: 3)
                                    .offset(x: pan * plotWidth)
                            }
                            .padding(.horizontal, 2).padding(.top, 2)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            .animation(.smooth(duration: 0.35), value: total)
            .animation(.smooth(duration: 0.35), value: parts.map(\.samples))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // The handles sit above the clipped plot, so one at ±15 dB is
            // never cut off (the curves themselves stay inside the plot).
            .overlay(alignment: .topLeading) {
                if let onStrength {
                    ZStack(alignment: .topLeading) {
                        Color.clear
                        ForEach(parts) { part in
                            if let range = part.repair.range, let strength = sound.repairs[part.repair],
                               let peak = Self.peakIndex(part.samples) {
                                let fraction = CGFloat(peak) / CGFloat(max(1, part.samples.values.count - 1))
                                let x = screenX(fraction)
                                let shown = x > -11 && x < plotWidth + 11
                                ChartHandle(repair: part.repair, strength: strength, range: range,
                                            peakDB: part.peakDB, peakHz: Self.sampleHz[min(peak, Self.sampleHz.count - 1)],
                                            x: x, plotHeight: plotHeight, dbRange: Self.dbRange,
                                            inset: Self.edgeInset, gate: gate,
                                            onDragging: { dragging = $0 ? part.repair : (dragging == part.repair ? nil : dragging) },
                                            onTap: { tappedHandle(part.repair, x: x, fraction: fraction, parts: parts) }) {
                                    onStrength(part.repair, $0)
                                }
                                .opacity(shown ? 1 : 0)
                                .allowsHitTesting(shown)
                            }
                        }
                    }
                }
            }
            // Snap back to the whole range: shows only while zoomed.
            .overlay(alignment: .topTrailing) {
                if zoomed {
                    Button { resetZoom() } label: {
                        Text(String(format: "%.1f× ↺", zoom))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .glassEffect(.regular, in: .capsule)
                            .frame(minWidth: 44, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6).padding(.trailing, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .accessibilityLabel("Show All Frequencies")
                    .accessibilityValue(String(format: "Zoomed %.1f times", zoom))
                    .accessibilityIdentifier("sound.zoomReset")
                }
            }
            .coordinateSpace(.named("soundPlot"))
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { plotWidth = max(1, $0) }
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                // Zoomed: back to everything. Not zoomed: closer, there.
                if zoom > 1.01 { resetZoom() } else { zoomTo(2.2, around: Self.clamp01(location.x / plotWidth)) }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                zoneShown = SoundZone.containing(hz(atScreenX: location.x))
            }
            .gesture(TwoFingerZoom(gate: gate,
                                   began: { centroid, distance in
                                       pinchFrom = (zoom, pan + centroid / max(1, plotWidth) / zoom, max(1, distance))
                                   },
                                   changed: { centroid, distance in
                                       guard let from = pinchFrom else { return }
                                       let raw = from.zoom * distance / from.distance
                                       // A little give below 1×, back to 1× on release.
                                       let next = raw >= 1 ? min(4, raw) : max(0.92, 1 - (1 - raw) * 0.3)
                                       zoom = next
                                       pan = Self.clampPan(from.anchor - centroid / max(1, plotWidth) / max(1, next), zoom: next)
                                   },
                                   ended: {
                                       pinchFrom = nil
                                       if zoom < 1.05 { resetZoom(feedback: false) }
                                   }))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sound chart: how much louder or quieter each part of the sound is")
            .accessibilityValue(accessibilitySummary(parts: parts)
                                + (zoomed ? String(format: " Zoomed %.1f times, showing %@ to %@.", zoom,
                                                   SoundGuide.hz(hz(atFraction: pan)), SoundGuide.hz(hz(atFraction: pan + 1 / zoom))) : ""))
            .accessibilityZoomAction { action in
                let centre = pan + 0.5 / zoom
                switch action.direction {
                case .zoomIn: zoomTo(min(4, zoom * 1.5), around: centre)
                case .zoomOut: zoom * 0.66 < 1.05 ? resetZoom() : zoomTo(zoom * 0.66, around: centre)
                @unknown default: break
                }
            }
            .accessibilityIdentifier("sound.plot")
            .background {
                if DemoData.isEnabled {
                    // Pass 38: for testSoundChartZoom — how far the page moved under a pinch.
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel("Page shift")
                        .accessibilityValue(String(format: "%.0f", gate.pageShift))
                        .accessibilityIdentifier("sound.pageShift")
                }
            }
            .popover(item: $zoneShown, arrowEdge: .top) { zone in zoneCard(zone, plan: plan) }
            .sensoryFeedback(.impact(weight: .light), trigger: resetTick)
        }
        .frame(height: plotHeight)
    }

    // MARK: Zoom

    /// Screen x of a fraction of the chart's log scale.
    private func screenX(_ fraction: CGFloat) -> CGFloat { (fraction - pan) * zoom * plotWidth }

    private func hz(atFraction fraction: CGFloat) -> Double {
        Self.lowHz * pow(Self.highHz / Self.lowHz, Double(Self.clamp01(fraction)))
    }

    private func hz(atScreenX x: CGFloat) -> Double { hz(atFraction: pan + x / max(1, plotWidth) / zoom) }

    static func clamp01(_ value: CGFloat) -> CGFloat { min(1, max(0, value)) }

    /// The left edge can't go past the point where the right edge is 20 kHz.
    static func clampPan(_ pan: CGFloat, zoom: CGFloat) -> CGFloat {
        min(max(0, 1 - 1 / max(1, zoom)), max(0, pan))
    }

    /// 0 below `from`, 1 above `to`, a straight fade between: what shows at
    /// each zoom fades in rather than popping.
    static func ramp(_ zoom: CGFloat, from: CGFloat, to: CGFloat) -> Double {
        Double(min(1, max(0, (zoom - from) / (to - from))))
    }

    private var zoomAnimation: Animation? { reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15) }

    private func zoomTo(_ target: CGFloat, around fraction: CGFloat) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.12)) {
            zoom = target
            pan = Self.clampPan(fraction - 0.5 / target, zoom: target)
        }
    }

    private func resetZoom(feedback: Bool = true) {
        withAnimation(zoomAnimation) { zoom = 1; pan = 0 }
        if feedback { resetTick &+= 1 }
    }

    /// A knob tapped (not dragged) in a crowd at full width: zoom in on it
    /// so the crowd spreads out (34 points: the knobs are 22 wide).
    private func tappedHandle(_ repair: Repair, x: CGFloat, fraction: CGFloat, parts: [FixPart]) {
        guard zoom <= 1.01 else { return }
        let crowded = parts.contains { other in
            guard other.repair != repair, sound.repairs[other.repair] != nil, other.repair.range != nil,
                  let peak = Self.peakIndex(other.samples) else { return false }
            let otherX = screenX(CGFloat(peak) / CGFloat(max(1, other.samples.values.count - 1)))
            return abs(otherX - x) < 34
        }
        if crowded { zoomTo(2.5, around: fraction) }
    }

    /// The zones' colours, the grid and the "as recorded" line, drawn across
    /// the zoomed width. Pass 37: zoomed in, an octave ruler (the
    /// equalizer's ten bands) fades in along the bottom, and deeper in (or
    /// while a knob is dragged) the half-octave marks between them.
    private func drawBackground(in context: inout GraphicsContext, size: CGSize, ruler: Double, fine: Double) {
        for zone in SoundZone.all {
            let x0 = x(zone.low, size.width), x1 = x(zone.high, size.width)
            let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
            let chosen = zoneShown == zone
            context.fill(Path(rect), with: .color(zone.color.opacity(chosen ? 0.30 : 0.11)))
            var edge = Path()
            edge.move(to: CGPoint(x: x0, y: 0)); edge.addLine(to: CGPoint(x: x0, y: size.height))
            context.stroke(edge, with: .color(.white.opacity(0.07)), lineWidth: 1)
        }
        var lines = Path()
        for db in [-12.0, -6, 6, 12] {
            lines.move(to: CGPoint(x: 0, y: y(db, size.height)))
            lines.addLine(to: CGPoint(x: size.width, y: y(db, size.height)))
        }
        context.stroke(lines, with: .color(.white.opacity(0.06)), lineWidth: 1)
        var zero = Path()
        zero.move(to: CGPoint(x: 0, y: size.height / 2))
        zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(zero, with: .color(.white.opacity(0.45)), lineWidth: 1)
        for (marks, strength) in [(Self.octaveMarks, ruler), (Self.halfOctaveMarks, fine)] where strength > 0.01 {
            for hz in marks {
                let px = x(hz, size.width)
                var tick = Path()
                tick.move(to: CGPoint(x: px, y: 0)); tick.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(tick, with: .color(.white.opacity(0.10 * strength)), lineWidth: 1)
                // Not under the fixed "Quieter" tag at the plot's bottom left.
                guard px - pan * size.width > 64 else { continue }
                let label = Text(Self.markLabel(hz)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.75 * strength))
                context.draw(label, at: CGPoint(x: px + 2, y: size.height - 3), anchor: .bottomLeading)
            }
        }
    }

    /// The equalizer's ten bands, and the marks halfway between them.
    static let octaveMarks: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    static let halfOctaveMarks: [Double] = [45, 90, 180, 350, 700, 1_400, 2_800, 5_600, 11_000]

    static func markLabel(_ hz: Double) -> String {
        hz >= 1_000 ? (hz.truncatingRemainder(dividingBy: 1_000) == 0 ? "\(Int(hz / 1_000))k" : String(format: "%.1fk", hz / 1_000)) : "\(Int(hz))"
    }

    /// The zone names under the plot, at their real positions, in two
    /// staggered rows so all seven fit on a phone. Each opens its card.
    private var zoneStrip: some View {
        let first = [0, 2, 4, 6].map { SoundZone.all[$0] }
        let second = [1, 3, 5].map { SoundZone.all[$0] }
        return HStack(spacing: 6) {
            if !typeSize.isAccessibilitySize { SoundChartScale().hidden().frame(height: 1) }
            VStack(spacing: 1) {
                zoneRow(first)
                zoneRow(second)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Parts of the sound")
    }

    private func zoneRow(_ zones: [SoundZone]) -> some View {
        // Pass 37: each name stays under its zone as the chart zooms; a name
        // whose zone is out of view is hidden.
        let positions = zones.map { (CGFloat((x(fraction: $0.low) + x(fraction: $0.high)) / 2) - pan) * zoom }
        return FrequencyLabelLayout(positions: positions.map(Double.init)) {
            ForEach(Array(zones.enumerated()), id: \.element.id) { index, zone in
                let visible = positions[index] >= -0.02 && positions[index] <= 1.02
                Button { zoneShown = zone } label: {
                    Text(zone.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(zone.color)
                        .fixedSize()
                        .padding(.vertical, 1)
                }
                .buttonStyle(.plain)
                .opacity(visible ? 1 : 0)
                .allowsHitTesting(visible)
                .accessibilityHidden(!visible)
                .accessibilityLabel("\(zone.name), \(zone.range)")
                .accessibilityHint("Explains this part of the sound")
            }
        }
    }

    /// What was just changed, in words; otherwise what it all adds up to.
    private func changeLine(parts: [FixPart]) -> some View {
        let text: String
        let color: Color
        switch focus {
        case .fix(let repair):
            if let part = parts.first(where: { $0.repair == repair }) {
                text = repair.title + ": " + repair.effect(peakDB: part.peakDB)
            } else {
                text = repair.title + " off"
            }
            color = repair.chartColor
        case .preset:
            text = "Preset " + presetTitle + ": " + presetWords
            color = .white
        case nil:
            text = SoundGuide.summary(sound, levelling: levelling)
            color = Theme.accentHot
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.footnote)
                .foregroundStyle(focus == nil ? .secondary : .primary)
                .lineLimit(presentation == .compactPlot ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .animation(.easeOut(duration: 0.2), value: text)
        .accessibilityIdentifier("sound.changeLine")
    }

    // MARK: Key

    private func key(plan: SoundPlan, parts: [FixPart]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            KeyRow(swatch: .line(Theme.accentHot), title: "What you hear",
                   detail: SoundGuide.summary(sound, levelling: levelling))
            if presetName != nil, presetCurve != nil {
                KeyRow(swatch: .dashed, title: "Preset: " + presetTitle, detail: presetWords)
            } else if presetName == nil {
                KeyRow(swatch: .none, title: "Equalizer off",
                       detail: "Only the fixes below shape the sound.")
            }
            ForEach(parts) { part in
                Button { fixShown = part.repair } label: {
                    KeyRow(swatch: .area(part.repair.chartColor), title: part.repair.title,
                           detail: part.repair.effect(peakDB: part.peakDB), tappable: true)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { fixShown == part.repair },
                                              set: { if !$0, fixShown == part.repair { fixShown = nil } }),
                         arrowEdge: .top) { fixCard(part) }
            }
            Divider().opacity(0.4)
            Text("Loudness").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(loudnessLines(plan: plan), id: \.self) { line in
                Label(line, systemImage: "speaker.wave.2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Tap a coloured zone or its name for what that part of the sound is.")
                .font(.footnote).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("sound.contributions")
    }

    /// Loudness, in words: not a change of tone, so not on the chart.
    private func loudnessLines(plan: SoundPlan) -> [String] {
        var lines: [String] = []
        lines.append(levelling
            ? "Volume Normalization: every episode plays at about the same overall loudness."
            : "Volume Normalization is off: each episode plays as loud as it was published.")
        lines.append(evenOut
            ? "Even Out Volume: loud and quiet voices in an episode are brought closer together."
            : "Even Out Volume is off: a quiet guest stays quieter than the host.")
        let match = plan.levelDB - sound.normalizationDB
        if abs(match) >= 0.5 {
            lines.append("The whole sound is turned \(match > 0 ? "up" : "down") \(SoundGuide.db(abs(match)).replacingOccurrences(of: "+", with: "")) to make up for what the fixes \(match > 0 ? "take away" : "add"), so switching them on doesn't just sound louder or quieter.")
        }
        return lines
    }

    // MARK: Cards

    private func zoneCard(_ zone: SoundZone, plan: SoundPlan) -> some View {
        let change = Self.average(low: zone.low, high: zone.high, plan: plan)
        let working = Repair.allCases.filter { repair in
            guard sound.repairs[repair] != nil else { return false }
            let alone = EQMath.plan(SoundSettings(base: EQPreset.flat.gains, repairs: [repair: sound.repairs[repair]!], normalizationDB: 0))
            return abs(Self.average(low: zone.low, high: zone.high, plan: alone)) >= 0.5
        }
        var lines: [(String, String)] = [
            ("What it is", zone.about),
            ("How it sounds", zone.sounds),
            ("Right now", abs(change) < 0.5 ? "Unchanged." : "\(SoundGuide.words(change).capitalized(firstOnly: true)) than recorded (\(SoundGuide.db(change)) on average)."),
        ]
        if !working.isEmpty {
            lines.append(("Changing it", working.map(\.title).joined(separator: ", ")))
        }
        let fixes = Repair.allCases.filter { $0.zone == zone && sound.repairs[$0] == nil }
        if !fixes.isEmpty {
            lines.append(("Fixes for this zone", fixes.map(\.title).joined(separator: ", ")))
        }
        return InfoCard(title: "\(zone.name) · \(zone.range)", lines: lines)
    }

    private func fixCard(_ part: FixPart) -> some View {
        InfoCard(title: part.repair.title, lines: [
            ("What it does", part.repair.plain),
            ("When to use it", part.repair.whenToUse),
            ("What you'll hear", part.repair.whatYouHear),
            ("On the chart", part.repair.effect(peakDB: part.peakDB) + ". " + part.repair.technical),
        ])
    }

    // MARK: Numbers

    private var presetTitle: String {
        guard let presetName else { return "Off" }
        return EQPreset.resolving(presetName).name
    }

    private var presetCurve: CurveSamples? {
        guard presetName != nil, sound.base.contains(where: { abs($0) > 0.01 }) else { return nil }
        let plan = EQMath.plan(SoundSettings(base: sound.base, repairs: [:], normalizationDB: 0))
        return CurveSamples(values: Self.sampleHz.map { EQMath.toneResponseDB(at: $0, plan: plan) })
    }

    /// The preset in zone words: "Clarity louder, Rumble quieter".
    private var presetWords: String {
        let plan = EQMath.plan(SoundSettings(base: sound.base, repairs: [:], normalizationDB: 0))
        let parts = SoundZone.all.compactMap { zone -> String? in
            let db = Self.average(low: zone.low, high: zone.high, plan: plan)
            guard abs(db) >= 1 else { return nil }
            return "\(zone.name) \(db > 0 ? "louder" : "quieter") (\(SoundGuide.db(db)))"
        }
        return parts.isEmpty ? "Flat: no change." : parts.joined(separator: ", ")
    }

    private func fixParts() -> [FixPart] {
        Repair.allCases.compactMap { repair in
            guard let strength = sound.repairs[repair] else { return nil }
            let plan = EQMath.plan(SoundSettings(base: EQPreset.flat.gains,
                                                 repairs: [repair: strength], normalizationDB: 0))
            let values = Self.sampleHz.map { EQMath.toneResponseDB(at: $0, plan: plan) }
            var peak = 0.0
            for (index, db) in values.enumerated() where Self.sampleHz[index] >= 50 && Self.sampleHz[index] <= 16_000 {
                if abs(db) > abs(peak) { peak = db }
            }
            return FixPart(repair: repair, samples: CurveSamples(values: values), peakDB: peak)
        }
    }

    /// The fix or preset that differs between two settings, if exactly
    /// what changed can be told.
    static func changed(from old: SoundSettings, to new: SoundSettings) -> Focus? {
        for repair in Repair.allCases where old.repairs[repair] != new.repairs[repair] {
            return .fix(repair)
        }
        if old.base != new.base { return .preset }
        return nil
    }

    /// Where a fix's curve is furthest from "as recorded", 50 Hz–16 kHz.
    static func peakIndex(_ samples: CurveSamples) -> Int? {
        var best: Int?
        var bestDB = 0.0
        for (index, db) in samples.values.enumerated()
        where sampleHz.indices.contains(index) && sampleHz[index] >= 50 && sampleHz[index] <= 16_000 {
            if abs(db) > abs(bestDB) { bestDB = db; best = index }
        }
        return abs(bestDB) >= 0.3 ? best : nil
    }

    static func average(low: Double, high: Double, plan: SoundPlan) -> Double {
        (0..<24).reduce(0.0) { sum, step in
            let hz = low * pow(high / low, (Double(step) + 0.5) / 24)
            return sum + EQMath.toneResponseDB(at: hz, plan: plan)
        } / 24
    }

    private func accessibilitySummary(parts: [FixPart]) -> String {
        let fixes = parts.map { $0.repair.title + ", " + $0.repair.effect(peakDB: $0.peakDB) }
        return SoundGuide.summary(sound, levelling: levelling)
            + (fixes.isEmpty ? "" : " " + fixes.joined(separator: ". ") + ".")
    }

    private func x(fraction hz: Double) -> Double {
        log10(hz / Self.lowHz) / log10(Self.highHz / Self.lowHz)
    }

    private func x(_ hz: Double, _ width: CGFloat) -> CGFloat {
        CGFloat(x(fraction: hz)) * width
    }

    private func y(_ db: Double, _ height: CGFloat) -> CGFloat {
        let clamped = min(Self.dbRange, max(-Self.dbRange, db))
        let half = max(1, height / 2 - Self.edgeInset)
        return height / 2 - CGFloat(clamped / Self.dbRange) * half
    }

    static func format(_ db: Double) -> String {
        let rounded = (db * 10).rounded() / 10
        if rounded == 0 { return "0 dB" }
        return String(format: "%+.1f dB", rounded)
    }
}

/// Pass 30: a fix's handle on the sound chart. It sits on the fix's peak;
/// dragging it away from the "as recorded" line makes the fix stronger,
/// toward it weaker, in the slider's own half-step clicks — the fix's switch
/// row and its slider move with it. Up and down only: each fix acts at its
/// own fixed frequency, so the handle can't move it sideways.
///
/// Pass 37: while dragged, a callout says which fix, where and how much
/// ("Reduce Sibilance · 6.2 kHz · −8.5 dB"); a second finger landing just
/// after the first (a pinch starting on a handle) puts the strength back as
/// it was, and a later one stops the drag where it is (`ChartTouchGate`);
/// a tap without a drag is reported (it zooms into a crowd of handles).
private struct ChartHandle: View {
    let repair: Repair
    let strength: Double
    let range: ClosedRange<Double>
    let peakDB: Double
    let peakHz: Double
    let x: CGFloat
    let plotHeight: CGFloat
    let dbRange: Double
    /// ±15 dB sits this far inside the plot (`EQCurvePanel.edgeInset`).
    var inset: CGFloat = 0
    let gate: ChartTouchGate
    var onDragging: (Bool) -> Void = { _ in }
    var onTap: () -> Void = {}
    let onChange: (Double) -> Void

    @State private var dragStart: Double?
    @State private var shown: Double?

    /// dB at the peak per unit of strength (the fixes are linear in it).
    private var unit: Double { strength > 0 ? abs(peakDB) / strength : 1 }

    private var half: CGFloat { max(1, plotHeight / 2 - inset) }

    private func y(_ db: Double) -> CGFloat {
        let clamped = min(dbRange, max(-dbRange, db))
        return plotHeight / 2 - CGFloat(clamped / dbRange) * half
    }

    var body: some View {
        let size: CGFloat = 22
        Circle()
            .fill(repair.chartColor)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .scaleEffect(dragStart == nil ? 1 : 1.25)
            .overlay(alignment: .top) {
                if let shown {
                    Text("\(repair.title) · \(SoundGuide.hz(peakHz)) · \(EQCurvePanel.format(peakDB < 0 ? -shown * unit : shown * unit))")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        // Inside the plot: below a handle near the top,
                        // above one near the bottom.
                        .offset(y: y(peakDB) < 34 ? size + 4 : (y(peakDB) > plotHeight - 34 ? -22 : (peakDB < 0 ? size + 4 : -22)))
                        .accessibilityIdentifier("sound.handleCallout")
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(x: x, y: y(peakDB))
            .onTapGesture { onTap() }
            .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("soundPlot"))
                .onChanged { value in
                    guard !gate.twoFingers, !gate.stopped.contains(repair) else { return }
                    let start = dragStart ?? strength
                    if dragStart == nil {
                        dragStart = strength
                        gate.dragBegan(repair, strength: strength, revert: onChange)
                        onDragging(true)
                    }
                    // Away from the zero line is stronger, whichever way the fix goes.
                    let dbPerPoint = dbRange / Double(half)
                    let moved = -Double(value.translation.height) * dbPerPoint * (peakDB < 0 ? -1 : 1)
                    let raw = start + moved / max(0.1, unit)
                    let stepped = min(range.upperBound, max(range.lowerBound, (raw * 2).rounded() / 2))
                    if stepped != shown {
                        shown = stepped
                        onChange(stepped)
                    }
                }
                .onEnded { _ in
                    dragStart = nil
                    gate.dragEnded(repair)
                    onDragging(false)
                    withAnimation(.easeOut(duration: 0.3)) { shown = nil }
                })
            .onChange(of: gate.generation) {
                // A pinch took over: drop the callout and the lifted look.
                if gate.stopped.contains(repair), dragStart != nil {
                    dragStart = nil
                    onDragging(false)
                    withAnimation(.easeOut(duration: 0.2)) { shown = nil }
                }
            }
            .sensoryFeedback(.selection, trigger: shown)
            .accessibilityElement()
            .accessibilityLabel(repair.title)
            .accessibilityValue(EQCurvePanel.format(peakDB) + " at " + SoundGuide.hz(peakHz))
    }
}

/// Pass 37: what the one-finger knob drags and the two-finger zoom need to
/// know about each other. Watched by the zoom's recognizer, which sees every
/// finger landing, including on a knob.
@Observable
final class ChartTouchGate {
    /// Two fingers are down.
    private(set) var twoFingers = false
    /// Knob drags a second finger ended; they ignore the rest of the drag.
    private(set) var stopped: Set<Repair> = []
    /// Bumped when `stopped` changes, so the handles can react.
    private(set) var generation = 0
    @ObservationIgnored private var firstFingerAt: TimeInterval?
    @ObservationIgnored private var drag: (repair: Repair, strength: Double, revert: (Double) -> Void)?

    /// A second finger this soon after the first means the touch was a
    /// pinch from the start: the knob is put back.
    static let pinchWindow: TimeInterval = 0.075

    /// A knob is being dragged (the zoom's recognizer then holds the page).
    var knobDragging: Bool { drag != nil }

    /// Pass 38, demo/UI tests only: the furthest the page has moved (points)
    /// while fingers were on the chart. Stays 0 when nothing above the chart
    /// joins in.
    private(set) var pageShift: CGFloat = 0
    func notePageShift(_ shift: CGFloat) {
        if shift > pageShift + 0.5 { pageShift = shift }
    }

    func dragBegan(_ repair: Repair, strength: Double, revert: @escaping (Double) -> Void) {
        drag = (repair, strength, revert)
    }

    func dragEnded(_ repair: Repair) {
        if drag?.repair == repair { drag = nil }
        if stopped.contains(repair) { stopped.remove(repair) }
    }

    /// From the recognizer: how many fingers are down, and when this one landed.
    func fingers(_ count: Int, at time: TimeInterval) {
        switch count {
        case 0:
            twoFingers = false
            firstFingerAt = nil
        case 1:
            if firstFingerAt == nil { firstFingerAt = time }
        default:
            guard !twoFingers else { return }
            twoFingers = true
            if let drag {
                if let first = firstFingerAt, time - first <= Self.pinchWindow { drag.revert(drag.strength) }
                stopped.insert(drag.repair)
                self.drag = nil
                generation &+= 1
            }
        }
    }
}

/// Pass 37: the chart's two-finger pinch and pan, one UIKit recognizer for
/// both so they can't fight: the pinch's spread sets the zoom about the
/// point between the fingers, and moving both fingers slides the view. It
/// reports every finger landing to `ChartTouchGate` without ever taking a
/// touch from the knobs.
///
/// Pass 38 (his 14 Oct screenshots: pinching the chart shrank and tilted the
/// whole Speed and Audio page; in the simulator a pinch-in at 1× dismissed
/// it): the sheet opens with `.navigationTransition(.zoom)`, which puts
/// UIKit's interactive-dismiss recognizers ("ZoomInteractiveDismissPinch",
/// a scale-and-rotate recognizer, plus its swipe-down and edge pan) on the
/// page above the chart, beside the sheet's own drag and the navigation
/// swipes. This recognizer used to agree to run together with all of them.
/// Now, from the moment a second finger lands on the chart (or a knob drag
/// starts), every recognizer on the views above the chart, up to the window,
/// is switched off until the fingers lift — so the page can't scale, tilt,
/// move or close — and the list under the fingers stops scrolling. It never
/// runs together with them either. One-finger drags on the chart's empty
/// space still scroll the list and move the sheet as anywhere else.
private struct TwoFingerZoom: UIGestureRecognizerRepresentable {
    let gate: ChartTouchGate
    /// Centroid x (in the plot) and the fingers' distance.
    let began: (CGFloat, CGFloat) -> Void
    let changed: (CGFloat, CGFloat) -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> Recognizer {
        let recognizer = Recognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        wire(recognizer)
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: Recognizer, context: Context) {
        wire(recognizer)
    }

    private func wire(_ recognizer: Recognizer) {
        recognizer.onFingers = { [gate] count, time in gate.fingers(count, at: time) }
        recognizer.knobDragging = { [gate] in gate.knobDragging }
        recognizer.onPageShift = DemoData.isEnabled ? { [gate] shift in gate.notePageShift(shift) } : nil
    }

    func handleUIGestureRecognizerAction(_ recognizer: Recognizer, context: Context) {
        let centroid = context.converter.localLocation.x
        switch recognizer.state {
        case .began:
            began(centroid, recognizer.spread)
        case .changed:
            changed(centroid, recognizer.spread)
        case .ended, .cancelled, .failed:
            ended()
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Together with the chart's own (the knobs, on the same view or
        /// inside it), never with the page's, the sheet's or the window's.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            !Recognizer.isAbove(other, gestureRecognizer)
        }
    }

    final class Recognizer: UIGestureRecognizer {
        var onFingers: ((Int, TimeInterval) -> Void)?
        var knobDragging: (() -> Bool)?
        /// Demo/UI tests only: how far the page has moved while held.
        var onPageShift: ((CGFloat) -> Void)?
        private var down: Set<UITouch> = []
        private var startSpread: CGFloat = 0
        private var startCentre: CGPoint = .zero
        /// The recognizers this one switched off, to switch back on.
        private var suspended: [UIGestureRecognizer] = []
        private weak var heldScroll: UIScrollView?
        private var pageFrame: CGRect?

        var spread: CGFloat {
            let points = down.prefix(2).map { $0.location(in: view) }
            guard points.count == 2 else { return startSpread }
            return max(1, hypot(points[0].x - points[1].x, points[0].y - points[1].y))
        }

        private var centre: CGPoint {
            let points = down.prefix(2).map { $0.location(in: view) }
            guard points.count == 2 else { return startCentre }
            return CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
        }

        /// `other` sits on a view above `mine`'s (the sheet, the zoom
        /// transition's page, the navigation container, the window).
        static func isAbove(_ other: UIGestureRecognizer, _ mine: UIGestureRecognizer) -> Bool {
            guard let otherView = other.view, let view = mine.view, otherView !== view else { return false }
            return view.isDescendant(of: otherView)
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            for touch in touches { down.insert(touch); onFingers?(down.count, touch.timestamp) }
            if down.count >= 2 { holdPage() }
            if down.count == 2, state == .possible { startSpread = spread; startCentre = centre }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            // A knob being dragged holds the page too (its drag starts after
            // the first few points of movement, so this is the next move).
            if suspended.isEmpty, knobDragging?() == true { holdPage() }
            if let onPageShift, let pageFrame, let view {
                let now = view.convert(view.bounds, to: nil)
                onPageShift(max(abs(now.minX - pageFrame.minX), abs(now.minY - pageFrame.minY),
                                abs(now.width - pageFrame.width), abs(now.height - pageFrame.height)))
            }
            guard down.count >= 2 else { return }
            switch state {
            case .possible:
                // Moving apart, together, or sideways together: a zoom or a slide.
                let c = centre
                if abs(spread - startSpread) > 6 || abs(c.x - startCentre.x) > 6 { state = .began }
            case .began, .changed:
                state = .changed
            default:
                break
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { lift(touches, event) }

        private func lift(_ touches: Set<UITouch>, _ event: UIEvent) {
            for touch in touches { down.remove(touch) }
            onFingers?(down.count, event.timestamp)
            if down.count < 2 {
                switch state {
                case .began, .changed: state = .ended
                case .possible: if down.isEmpty { state = .failed }
                default: break
                }
            }
            if down.isEmpty { releasePage() }
        }

        override func reset() {
            super.reset()
            down.removeAll()
            releasePage()
        }

        /// Switches off every recognizer on the views above the chart (not
        /// the window's own system gestures), and the scrolling list under
        /// the fingers. Switching one off mid-gesture cancels it, so a sheet
        /// drag that had just started springs back.
        private func holdPage() {
            guard suspended.isEmpty, let view else { return }
            pageFrame = view.convert(view.bounds, to: nil)
            var ancestor = view.superview
            while let current = ancestor, !(current is UIWindow) {
                for recognizer in current.gestureRecognizers ?? []
                where recognizer.isEnabled && !(recognizer is UIHoverGestureRecognizer) {
                    recognizer.isEnabled = false
                    suspended.append(recognizer)
                }
                ancestor = current.superview
            }
            // The list is inside the page, under the touch, not above it.
            var hit = down.first?.view
            while let current = hit, !(current is UIScrollView), current !== view { hit = current.superview }
            if let scroll = hit as? UIScrollView, scroll.panGestureRecognizer.isEnabled {
                scroll.panGestureRecognizer.isEnabled = false
                heldScroll = scroll
            }
        }

        private func releasePage() {
            for recognizer in suspended { recognizer.isEnabled = true }
            suspended.removeAll()
            heldScroll?.panGestureRecognizer.isEnabled = true
            heldScroll = nil
            pageFrame = nil
        }
    }
}

/// A response curve's samples, animatable, so a change slides into place
/// instead of jumping.
struct CurveSamples: VectorArithmetic, Equatable {
    var values: [Double]

    static var zero: CurveSamples { CurveSamples(values: []) }

    private static func combine(_ a: CurveSamples, _ b: CurveSamples, _ op: (Double, Double) -> Double) -> CurveSamples {
        let count = max(a.values.count, b.values.count)
        return CurveSamples(values: (0..<count).map { index in
            op(index < a.values.count ? a.values[index] : 0, index < b.values.count ? b.values[index] : 0)
        })
    }

    static func + (a: CurveSamples, b: CurveSamples) -> CurveSamples { combine(a, b, +) }
    static func - (a: CurveSamples, b: CurveSamples) -> CurveSamples { combine(a, b, -) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// One curve on the sound chart; filled, it is the area between the curve
/// and the "as recorded" line.
struct CurveShape: Shape {
    var samples: CurveSamples
    let dbRange: Double
    let filled: Bool

    var animatableData: CurveSamples {
        get { samples }
        set { samples = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let values = samples.values
        guard values.count > 1 else { return path }
        func point(_ index: Int) -> CGPoint {
            let db = min(dbRange, max(-dbRange, values[index]))
            return CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                           y: rect.midY - CGFloat(db / dbRange) * rect.height / 2)
        }
        if filled { path.move(to: CGPoint(x: rect.minX, y: rect.midY)); path.addLine(to: point(0)) }
        else { path.move(to: point(0)) }
        for index in 1..<values.count { path.addLine(to: point(index)) }
        if filled { path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); path.closeSubpath() }
        return path
    }
}

/// One line of the chart's key: how it is drawn, its name, what it does.
private struct KeyRow: View {
    enum Swatch { case line(Color), dashed, area(Color), none }
    let swatch: Swatch
    let title: String
    let detail: String
    var tappable = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            swatchView.frame(width: 24, height: 14).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if tappable {
                Image(systemName: "info.circle").font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var swatchView: some View {
        switch swatch {
        case .line(let color):
            Capsule().fill(color).frame(height: 3)
        case .dashed:
            Canvas { context, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(line, with: .color(.white.opacity(0.75)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        case .area(let color):
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.45))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
        case .none:
            Circle().fill(.secondary).frame(width: 6, height: 6)
        }
    }
}

private extension String {
    func capitalized(firstOnly: Bool) -> String {
        prefix(1).uppercased() + dropFirst()
    }
}

/// A short explanation in a popover: a title and a few labelled lines.
///
/// Pass 30 (his 5 Oct screenshot): a card taller than the room the popover
/// got was cut off top and bottom. It now scrolls inside the popover when it
/// doesn't fit, with the scroll bar shown (and flashed when it opens) and a
/// "Scroll for more" line at the bottom until the end is reached.
private struct InfoCard: View {
    let title: String
    let lines: [(String, String)]
    @State private var contentHeight: CGFloat = 0
    @State private var visibleHeight: CGFloat = 0
    @State private var atEnd = false

    /// UI tests can shrink the room to exercise the scrolling (`-UITestShortInfoCard`).
    private static let tallest: CGFloat = ProcessInfo.processInfo.arguments.contains("-UITestShortInfoCard") ? 200 : 380

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollIndicators(.visible)
        .scrollIndicatorsFlash(onAppear: true)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 4
        } action: { _, end in atEnd = end }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
        .overlay(alignment: .bottom) {
            if contentHeight > visibleHeight + 4, !atEnd {
                Label("Scroll for more", systemImage: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.bottom, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: atEnd)
        .frame(width: 300, height: contentHeight > 0 ? min(contentHeight, Self.tallest) : 220)
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("sound.infoCard")
    }

    private var content: some View {
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
        // ±15 dB is drawn `edgeInset` inside the plot; the labels follow.
        .padding(.vertical, max(0, EQCurvePanel.edgeInset - 8))
        .frame(width: width)
        .accessibilityHidden(true)
    }
}
