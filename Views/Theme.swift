import SwiftUI
import UIKit
import ImageIO
import CoreGraphics

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

/// A slim status bar that appears wherever you are while an episode is being
/// processed. You tapped "Find ads" and nothing visibly happened — this is
/// that missing feedback, and it follows you between screens.
struct ProcessingBanner: View {
    let pipeline: ProcessingPipeline
    var publisher: FeedPublisher? = nil

    private var active: Bool {
        pipeline.isRunning || (publisher?.isPublishing ?? false)
    }

    var body: some View {
        Group {
            if active {
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 3)
                        Circle()
                            .trim(from: 0, to: max(0.02, fraction))
                            .stroke(Theme.accentGradient,
                                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.easeOut(duration: 0.3), value: fraction)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .contentTransition(.numericText())
                    }

                    Spacer(minLength: 0)

                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassPanel(cornerRadius: 18)
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: active)
    }

    private var fraction: Double {
        pipeline.isRunning ? pipeline.overallFraction : (publisher?.overallFraction ?? 0)
    }

    private var title: String {
        if pipeline.isRunning { return pipeline.currentEpisodeTitle ?? "Processing" }
        return publisher?.currentEpisodeTitle ?? "Publishing"
    }

    private var detail: String {
        let stage: String
        let step: Int
        let total: Int
        let eta: Double?
        let queued: Int
        if pipeline.isRunning {
            stage = pipeline.stage.label
            step = pipeline.stage.number
            total = ProcessingPipeline.Stage.count
            eta = pipeline.etaSeconds
            queued = pipeline.queueRemaining
        } else {
            stage = publisher?.stage.label ?? ""
            step = publisher?.stage.number ?? 1
            total = FeedPublisher.Stage.count
            eta = publisher?.etaSeconds
            queued = publisher?.itemsRemaining ?? 0
        }
        var parts = ["Step \(step)/\(total)", stage]
        if let eta, eta.isFinite, eta > 1 {
            parts.append(DetailedProgressView.timeLeft(eta))
        }
        if queued > 0 { parts.append("+\(queued) queued") }
        return parts.joined(separator: " · ")
    }
}

extension View {
    /// Drops the banner under the navigation bar on any screen.
    func processingBanner(_ pipeline: ProcessingPipeline,
                          publisher: FeedPublisher? = nil) -> some View {
        safeAreaInset(edge: .top) {
            ProcessingBanner(pipeline: pipeline, publisher: publisher)
        }
    }

    /// A soft press highlight for content rows. Liquid Glass gives floating
    /// controls this for free; plain rows need it drawn.
    func pressGlow() -> some View {
        buttonStyle(PressGlowStyle())
    }
}

struct PressGlowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
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
    /// Raw bytes, keyed by URL, so a second request at a larger size doesn't
    /// have to hit the network again.
    private let dataCache = NSCache<NSString, NSData>()

    private init() {
        cache.countLimit = 250
        cache.totalCostLimit = 48 * 1024 * 1024
        dataCache.countLimit = 60
        dataCache.totalCostLimit = 24 * 1024 * 1024
    }

    /// Fixed rather than read from `UIScreen`, which is main-actor bound while
    /// the downsampler deliberately is not. 3 is the highest scale shipping
    /// iPhones use, so this only ever over-samples slightly on a 2x device —
    /// never under-samples, which would show as soft artwork.
    nonisolated(unsafe) static let screenScale: CGFloat = 3.0

    /// Artwork is requested at a handful of sizes — 30pt in the mini player,
    /// 46–56pt in rows, 104pt in grids, 168pt and 296pt on the show and player
    /// screens. Rounding to buckets keeps the cache from holding a separate
    /// copy for every pixel size a layout happens to produce.
    private static func bucket(for size: CGFloat) -> Int {
        let pixels = size * screenScale
        for candidate in [96, 160, 256, 400, 640, 900] where pixels <= CGFloat(candidate) {
            return candidate
        }
        return 1200
    }

    private static func key(_ url: String, _ bucket: Int) -> NSString {
        "\(url)#\(bucket)" as NSString
    }

    func cached(_ url: String, size: CGFloat) -> UIImage? {
        cache.object(forKey: Self.key(url, Self.bucket(for: size)))
    }

    func load(_ urlString: String, size: CGFloat) async -> UIImage? {
        let bucket = Self.bucket(for: size)
        let cacheKey = Self.key(urlString, bucket)
        if let image = cache.object(forKey: cacheKey) { return image }

        let requestKey = cacheKey as String
        if let existing = inFlight[requestKey] { return await existing.value }

        let cachedData = dataCache.object(forKey: urlString as NSString) as Data?

        let task = Task<UIImage?, Never> { [weak self] in
            let data: Data
            if let cachedData {
                data = cachedData
            } else {
                guard let url = URL(string: urlString),
                      let (fetched, _) = try? await URLSession.shared.data(from: url)
                else { return nil }
                data = fetched
                // Keep the bytes so the same artwork asked for at a second
                // size — a 56pt row and a 296pt player, say — doesn't go back
                // to the network.
                await self?.storeData(fetched, for: urlString)
            }
            // Decode straight to the size it will be drawn at.
            //
            // Podcast artwork is routinely 3000x3000. Decoding that to a
            // UIImage costs ~36 MB of RAM *each*, so a screen of rows used to
            // blow through the cache ceiling and re-decode constantly — the
            // stutter people read as "scrolling is janky".
            return Self.downsample(data: data, to: bucket)
        }

        inFlight[requestKey] = task
        let image = await task.value
        inFlight[requestKey] = nil

        if let image {
            let bytes = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: cacheKey, cost: bytes)
        }
        return image
    }

    private func storeData(_ data: Data, for url: String) {
        // Only worth keeping if it's small enough to be cheap. A 4 MB cover
        // isn't worth holding on to just to avoid one refetch.
        guard data.count < 2_000_000 else { return }
        dataCache.setObject(data as NSData, forKey: url as NSString, cost: data.count)
    }

    /// ImageIO decodes at the requested size directly, so the full-resolution
    /// bitmap never exists in memory at all.
    nonisolated private static func downsample(data: Data, to maxPixels: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return UIImage(data: data)
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ] as [CFString: Any] as CFDictionary

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: thumbnail, scale: screenScale, orientation: .up)
    }
}

struct Artwork: View {
    let url: String?
    var size: CGFloat = 52
    var corner: CGFloat = 10
    /// Set when the artwork fills a region rather than a square of `size` —
    /// the hero wash behind a show header, for instance.
    var renderSize: CGFloat? = nil

    @State private var image: UIImage?

    private var decodeSize: CGFloat { renderSize ?? size }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: max(11, size * 0.26)))
                        .foregroundStyle(.tertiary)
                )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .task(id: url) {
            guard let url else { image = nil; return }
            if let ready = ImageCache.shared.cached(url, size: decodeSize) {
                image = ready
                return
            }
            image = await ImageCache.shared.load(url, size: decodeSize)
        }
    }
}


extension Double {
    /// Keeps speed steps from accumulating floating-point drift.
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
