import SwiftUI

/// The app's visual language.
///
/// Apple's own guidance on Liquid Glass is that it belongs to the *navigation
/// layer* — tab bars, toolbars, floating controls, sheets — and explicitly not
/// to content cells, lists or long scrolling content. Glass on every row is
/// the mistake that makes an app read as grey slabs.
///
/// So: content sits plain on true black, and glass is reserved for things that
/// float above it.
enum Theme {

    // MARK: - Palette

    /// True black. On OLED these pixels are off.
    static let background = Color.black
    /// One step up, for the rare surface that must separate from the page.
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.085)

    static let accentWarm = Color(red: 1.0, green: 0.72, blue: 0.34)
    static let accentHot  = Color(red: 1.0, green: 0.19, blue: 0.50)
    static let adTint     = Color(red: 1.0, green: 0.55, blue: 0.20)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentWarm, accentHot],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let hairline = Color.white.opacity(0.09)
}

// MARK: - Content surfaces

extension View {

    /// A plain content row on the page background — the Apple Podcasts
    /// treatment. No card, no material, just a hairline between rows.
    func contentRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.hairline)
            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
    }

    /// Rows that shouldn't carry a separator — headers, chip strips, banners.
    func plainRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
    }

    /// Puts a screen on true black and clears SwiftUI's own list backdrop.
    func amoledScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

// MARK: - The glass layer

/// Every glass surface in the app funnels through these two modifiers, so if
/// the API shifts there is exactly one place to change.
extension View {

    /// A floating control: filter chips, action bars, overlay panels.
    func glassControl(cornerRadius: CGFloat = 22, tinted: Bool = false) -> some View {
        self.glassEffect(
            tinted ? .regular.tint(Theme.accentHot).interactive() : .regular.interactive(),
            in: .rect(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// Capsule-shaped floating control.
    func glassCapsule(tinted: Bool = false) -> some View {
        self.glassEffect(
            tinted ? .regular.tint(Theme.accentHot) : .regular,
            in: .capsule
        )
    }

    /// Legacy name kept so older call sites still build. Prefer glassControl.
    func glassCard(cornerRadius: CGFloat = 22, padding: CGFloat = 14) -> some View {
        self.padding(padding).glassControl(cornerRadius: cornerRadius)
    }
}

// MARK: - Section headers

/// Large, bold, left-aligned — the way Apple titles a section, with an
/// optional trailing action.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.primary)
            Spacer()
            trailing
        }
        .textCase(nil)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 4, trailing: 20))
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title: title, trailing: { EmptyView() })
    }
}

// MARK: - Filter chips

/// A floating strip of glass chips. This is the correct place for glass:
/// a control layer sitting above content.
struct FilterChips<T: Hashable & Identifiable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    var symbol: ((T) -> String?)? = nil

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        let isOn = option == selection
                        Button {
                            withAnimation(.snappy(duration: 0.22)) { selection = option }
                        } label: {
                            HStack(spacing: 5) {
                                if let symbol, let name = symbol(option) {
                                    Image(systemName: name).font(.caption2)
                                }
                                Text(label(option)).font(.subheadline.weight(.medium))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(isOn ? Color.black : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .glassCapsule(tinted: isOn)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Status pill

struct StatusPill: View {
    let text: String
    let tint: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(filled ? tint.opacity(0.95) : tint.opacity(0.16)))
            .foregroundStyle(filled ? Color.black : tint)
    }
}

// MARK: - Progress

/// Step, percentage, bar and time remaining. Shown inside a glass panel.
struct DetailedProgressView: View {
    let title: String
    let stepName: String
    let stepIndex: Int
    let stepCount: Int
    let fraction: Double
    let etaSeconds: Double?
    var queueRemaining: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(Theme.accentGradient)
                        .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 7)

            HStack(spacing: 6) {
                Text("Step \(stepIndex) of \(stepCount)")
                Text("·")
                Text(stepName)
                Spacer()
                if let etaSeconds, etaSeconds.isFinite, etaSeconds > 1 {
                    Label(Self.timeLeft(etaSeconds), systemImage: "clock").monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if queueRemaining > 0 {
                Text("\(queueRemaining) more after this")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    static func timeLeft(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s left" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s left" }
        return "\(minutes / 60)h \(minutes % 60)m left"
    }
}
