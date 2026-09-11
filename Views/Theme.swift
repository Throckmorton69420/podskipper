import SwiftUI
import UIKit

/// The app's visual language.
///
/// Two rules from Apple's guidance drive everything here:
///
/// 1. Liquid Glass belongs to the **navigation layer** that floats above
///    content. Never on list rows, cells or media. Glass in the content layer
///    is what made this app read as flat grey slabs.
/// 2. Glass **refracts what is behind it**. Over a pure black background there
///    is nothing to refract, so it renders as grey. Screens that want glass
///    need something behind it — artwork, a colour wash, content scrolling
///    underneath.
enum Theme {

    static let background = Color.black
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.085)

    static let accentWarm = Color(red: 1.0, green: 0.72, blue: 0.34)
    static let accentHot  = Color(red: 1.0, green: 0.19, blue: 0.50)
    static let adTint     = Color(red: 1.0, green: 0.55, blue: 0.20)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentWarm, accentHot],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let hairline = Color.white.opacity(0.09)

    /// Minimum comfortable touch target. Apple asks for 44; transport
    /// controls get used without looking, so they get more.
    static let tapTarget: CGFloat = 56
}

// MARK: - Content layer

extension View {

    func contentRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.hairline)
            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
    }

    func plainRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
    }

    /// True black page. The soft scroll edge keeps content from cutting
    /// abruptly under the floating tab bar and toolbar.
    func amoledScreen() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .scrollEdgeEffectStyle(.soft, for: .all)
            // Keeps list rows from stretching to 13 inches on an iPad.
            .environment(\.defaultMinListRowHeight, 44)
    }

    /// Caps content width on wide screens so lines stay readable, while
    /// staying edge-to-edge on a phone.
    func readableWidth(_ maximum: CGFloat = 760) -> some View {
        frame(maxWidth: maximum)
            .frame(maxWidth: .infinity)
    }

    /// A quiet bordered control for use *inside* content rows, where glass
    /// isn't allowed. Cheap to render, which matters in a long list.
    func contentChip(tint: Color = .primary) -> some View {
        self
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.8))
            .contentShape(Capsule())
    }
}

// MARK: - Glass layer

extension View {
    /// Floating panel — progress cards, action bars, overlays.
    /// Non-interactive by design: `.interactive()` on a non-capsule shape has
    /// a known hit-testing bug where taps are matched against a capsule, which
    /// is why some buttons needed pressing two or three times.
    func glassPanel(cornerRadius: CGFloat = 22) -> some View {
        self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius, style: .continuous))
    }

    func glassCapsule(tinted: Bool = false) -> some View {
        self.glassEffect(tinted ? .regular.tint(Theme.accentHot) : .regular, in: .capsule)
    }

    /// Kept so older call sites still build.
    func glassCard(cornerRadius: CGFloat = 22, padding: CGFloat = 14) -> some View {
        self.padding(padding).glassPanel(cornerRadius: cornerRadius)
    }

    func glassControl(cornerRadius: CGFloat = 22, tinted: Bool = false) -> some View {
        self.glassPanel(cornerRadius: cornerRadius)
    }
}

// MARK: - Buttons
//
// Every tappable glass thing goes through these. They use `.buttonStyle(.glass)`
// rather than `.glassEffect(.interactive())`, which is Apple's own workaround
// for the hit-testing mismatch.

/// Circular icon button with a generous target.
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = Theme.tapTarget
    var label: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .clipShape(Circle())
        .accessibilityLabel(label.isEmpty ? symbol : label)
    }
}

/// Pill button with a text label.
struct GlassPillButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }
}

// MARK: - Section headers

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
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
    init(_ title: String) { self.init(title: title, trailing: { EmptyView() }) }
}

// MARK: - Filter chips

/// One `GlassEffectContainer` around the whole strip. Multiple loose glass
/// effects share no sampling region, which is what produced the flicker when
/// anything on screen changed.
struct FilterChips<T: Hashable & Identifiable>: View {
    let options: [T]
    let label: (T) -> String
    @Binding var selection: T
    var symbol: ((T) -> String?)? = nil

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(options) { option in
                        chip(option)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    private func chip(_ option: T) -> some View {
        let isOn = option == selection
        return Button {
            withAnimation(.snappy(duration: 0.2)) { selection = option }
        } label: {
            HStack(spacing: 5) {
                if let symbol, let name = symbol(option) {
                    Image(systemName: name).font(.caption2)
                }
                Text(label(option)).font(.subheadline.weight(.medium))
            }
        }
        // One style for both states, tinted when selected. Branching between
        // two button styles means two different opaque types, which Swift
        // won't unify without wrappers that aren't worth the risk.
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .tint(isOn ? Theme.accentHot : nil)
        .fontWeight(isOn ? .semibold : .regular)
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
                    .contentTransition(.numericText())
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

// MARK: - Cached artwork
//
// AsyncImage refetches and re-decodes every time a row scrolls back on
// screen. In a list of 500 episodes that is the whole stutter.

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func cached(_ url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func load(_ urlString: String) async -> UIImage? {
        if let image = cached(urlString) { return image }
        if let existing = inFlight[urlString] { return await existing.value }

        let task = Task<UIImage?, Never> {
            guard let url = URL(string: urlString),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return nil }
            // Decode once, off the render path.
            let decoded = await image.byPreparingForDisplay() ?? image
            return decoded
        }
        inFlight[urlString] = task
        let image = await task.value
        inFlight[urlString] = nil
        if let image {
            cache.setObject(image, forKey: urlString as NSString,
                            cost: image.jpegData(compressionQuality: 1)?.count ?? 0)
        }
        return image
    }
}

struct Artwork: View {
    let url: String?
    var size: CGFloat = 52
    var corner: CGFloat = 10

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.surface)
                .overlay(Image(systemName: "waveform").foregroundStyle(.tertiary))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let ready = ImageCache.shared.cached(url) {
                image = ready
                return
            }
            image = await ImageCache.shared.load(url)
        }
    }
}
