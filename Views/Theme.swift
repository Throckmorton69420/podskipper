import SwiftUI

/// One place for the app's look.
///
/// On iOS 26 the system chrome — tab bar, navigation bar, toolbars, sheets,
/// standard buttons — already renders in Liquid Glass automatically when the
/// app is built against the iOS 26 SDK, which this one is. What's here is the
/// custom surfaces: true-black backgrounds for OLED screens, and glass cards
/// for the panels the system doesn't draw for us.
enum Theme {

    // MARK: - Palette

    /// True black. On an OLED panel these pixels are switched off, which is
    /// both the deepest contrast available and the cheapest to display.
    static let background = Color.black

    /// One step up from the background, for cards that need to separate.
    static let surface = Color(red: 0.055, green: 0.055, blue: 0.070)

    /// The waveform gradient, matching the app icon.
    static let accentWarm = Color(red: 1.0, green: 0.73, blue: 0.35)
    static let accentHot  = Color(red: 1.0, green: 0.19, blue: 0.50)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentWarm, accentHot],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Ads on the timeline and in status pills.
    static let adTint = Color(red: 1.0, green: 0.55, blue: 0.20)

    static let hairline = Color.white.opacity(0.10)
}

// MARK: - Glass surfaces

extension View {

    /// A floating panel: blurred backdrop, a lit top edge, and a soft drop
    /// shadow so it reads as a pane of glass sitting above the content.
    func glassCard(cornerRadius: CGFloat = 20, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.30),
                                                Color.white.opacity(0.04)],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.55), radius: 18, x: 0, y: 8)
    }

    /// Thinner treatment for inline rows, where a full card would be heavy.
    func glassRow(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(.thinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }

    /// Puts a screen on the true-black background and clears SwiftUI's own
    /// grouped-list backdrop, which would otherwise sit at dark grey.
    func amoledScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}

/// Makes a `List` look like floating glass on black instead of the default
/// dark-grey grouped rows. Apply to every row.
struct GlassRowModifier: ViewModifier {
    var inset: CGFloat = 6
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.20),
                                                Color.white.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.8)
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: inset / 2, leading: 14,
                                      bottom: inset / 2, trailing: 14))
    }
}

extension View {
    func glassListRow(inset: CGFloat = 6) -> some View {
        modifier(GlassRowModifier(inset: inset))
    }

    /// Section headers that sit on black without the default grey slab.
    func glassSectionHeader() -> some View {
        self
            .font(.caption.weight(.semibold))
            .textCase(nil)
            .foregroundStyle(.secondary)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 6, trailing: 20))
    }
}

/// A horizontal row of selectable chips — used for filters everywhere.
struct ChipRow<T: Hashable & Identifiable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options) { option in
                    let isOn = option == selection
                    Button {
                        selection = option
                    } label: {
                        Text(label(option))
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(isOn
                                    ? AnyShapeStyle(Theme.accentGradient)
                                    : AnyShapeStyle(Material.ultraThin))
                            )
                            .overlay(Capsule().strokeBorder(
                                isOn ? Color.clear : Theme.hairline, lineWidth: 1))
                            .foregroundStyle(isOn ? Color.black : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - Status pill

/// Small coloured label used everywhere an episode's state is shown, so the
/// same state always looks the same.
struct StatusPill: View {
    let text: String
    let tint: Color
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? tint.opacity(0.9) : tint.opacity(0.16))
            )
            .foregroundStyle(filled ? Color.black : tint)
            .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.35), lineWidth: 1))
    }
}

// MARK: - Progress bar with steps and a time estimate

/// Replaces the bare "transcribing…" label. Shows which step of how many,
/// a real filled bar, and a running estimate of the time left.
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
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(Theme.accentGradient)
                        .frame(width: max(4, geo.size.width * min(1, max(0, fraction))))
                }
            }
            .frame(height: 8)

            HStack(spacing: 6) {
                Text("Step \(stepIndex) of \(stepCount)")
                Text("·")
                Text(stepName)
                Spacer()
                if let etaSeconds, etaSeconds.isFinite, etaSeconds > 1 {
                    Label(Self.timeLeft(etaSeconds), systemImage: "clock")
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if queueRemaining > 0 {
                Text("\(queueRemaining) more episode\(queueRemaining == 1 ? "" : "s") after this")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
