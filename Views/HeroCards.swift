import SwiftUI
import UIKit

// Pass 72: Apple Podcasts 27.3's hero cards with its `heroBlur` feature on.
//
// Read from 27.3 beta 2's ShelfKit / ShelfKitCollectionViews (see
// `build/p70/parity-27.3.md`): a background made from the card's artwork
// (`HeroCardBackground`, `HeroCardBackgroundView`), a colour taken from that
// artwork and held to a legible range (`HeroCardColor(artwork:)`,
// `init(clamping:)`, `isDark`, `colorScheme`, `textStyle(primary/secondary/
// tertiary)`), a round translucent follow control (`ShowHeroFollowCircle`),
// and tighter `HeroContainer` spacing. Used by `ShowHeroCard` and
// `EpisodeHeroCard` in StoreViews.swift.

/// The `HeroContainer` constants 27.3 beta 2 uses with `heroBlur` on
/// (disassembled values; with the flag off they equal 27.2's 14 pt).
enum HeroContainer {
    /// Show card: description/metadata → button row.
    static let showSpaceBetweenTextAndButtons: CGFloat = 10
    /// Episode card: text → button row.
    static let episodeSpaceBetweenTextAndButtons: CGFloat = 6
    /// Episode card: between caption, title and summary.
    static let episodeTextZoneSpacing: CGFloat = 2
    /// Show card: description → metadata line.
    static let showMetadataSpacing: CGFloat = 6
    /// Show card: inset artwork → text.
    static let showInsetArtworkTextGap: CGFloat = 8
    /// Play button → follow / context control.
    static let spaceBetweenPlayButtonAndContextMenu: CGFloat = 8
    /// The chin's side and bottom padding (16 in 27.2 and 27.3).
    static let chinGeneralPadding: CGFloat = 16
    /// How far the play button's touch area reaches past the button. The
    /// whole card is one tap target in PodSkipper (it opens the show), so this
    /// and `buttonAreaOutsets` only shape the button row's hit area.
    static let showPlayButtonInsets = EdgeInsets(top: -10, leading: -16, bottom: -16, trailing: -8)
    /// The button area's outsets around the row.
    static let buttonAreaOutsets = EdgeInsets(top: 6, leading: 16, bottom: 16, trailing: 16)
}

/// The accessibility settings a hero card follows. Read from the system;
/// the hero-card gallery (a test screen) passes its own to show each look
/// side by side, since these settings can't be set from inside the app.
struct HeroCardLook: Equatable {
    var reduceTransparency = false
    var increasedContrast = false
}

private struct HeroCardLookOverrideKey: EnvironmentKey {
    static let defaultValue: HeroCardLook? = nil
}

extension EnvironmentValues {
    var heroCardLookOverride: HeroCardLook? {
        get { self[HeroCardLookOverrideKey.self] }
        set { self[HeroCardLookOverrideKey.self] = newValue }
    }
}

/// Reads the look a hero card should use.
struct HeroCardLookReader<Content: View>: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.heroCardLookOverride) private var override
    @ViewBuilder var content: (HeroCardLook) -> Content

    var body: some View {
        content(override ?? HeroCardLook(reduceTransparency: reduceTransparency,
                                         increasedContrast: contrast == .increased))
    }
}

/// The card's colour: the artwork's own background colour (Apple sends it
/// with every picture), held to a range where the card's text reads — white
/// text on a darkened colour, or near-black text on a lightened one.
struct HeroCardColor: Equatable {
    enum Emphasis { case primary, secondary, tertiary }

    /// sRGB, 0…1, after clamping.
    let red: Double
    let green: Double
    let blue: Double
    let isDark: Bool

    static let fallback = HeroCardColor(red: 0.17, green: 0.17, blue: 0.19, isDark: true)

    var backgroundColor: Color { Color(.sRGB, red: red, green: green, blue: blue) }
    var colorScheme: ColorScheme { isDark ? .dark : .light }
    var hexColor: String {
        String(format: "%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    private init(red: Double, green: Double, blue: Double, isDark: Bool) {
        self.red = red; self.green = green; self.blue = blue; self.isDark = isDark
    }

    init(artwork: StoreArtwork?) {
        if let hex = artwork?.background, let rgb = Self.rgb(hex) {
            self.init(clamping: rgb)
        } else {
            self = .fallback
        }
    }

    /// Keeps the colour's hue; caps its saturation and moves its brightness
    /// until the card's primary text has at least 7:1 contrast (so secondary
    /// text, at lower opacity, still clears 4.5:1).
    init(clamping rgb: (red: Double, green: Double, blue: Double)) {
        let source = UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        source.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let dark = Self.luminance(rgb) < 0.45
        var s = Double(saturation), b = Double(brightness)
        if dark {
            s = min(s, 0.75)
            b = min(b, 0.62)
        } else {
            s = min(s, 0.32)
            b = max(b, 0.84)
        }
        var out = Self.rgb(hue: Double(hue), saturation: s, brightness: b)
        let text: (Double, Double, Double) = dark ? (1, 1, 1) : (0.06, 0.06, 0.07)
        var guardSteps = 0
        while Self.contrast(text, out) < 7, guardSteps < 40 {
            b = dark ? max(0, b - 0.03) : min(1, b + 0.03)
            if !dark { s = max(0, s - 0.03) }
            out = Self.rgb(hue: Double(hue), saturation: s, brightness: b)
            guardSteps += 1
        }
        self.init(red: out.0, green: out.1, blue: out.2, isDark: dark)
    }

    /// Text on this card. Increase Contrast raises the lesser emphases.
    func textStyle(_ emphasis: Emphasis, increasedContrast: Bool = false) -> Color {
        let base: Color = isDark ? .white : Color(.sRGB, red: 0.06, green: 0.06, blue: 0.07)
        switch emphasis {
        case .primary: return base
        case .secondary: return base.opacity(increasedContrast ? 0.9 : 0.74)
        case .tertiary: return base.opacity(increasedContrast ? 0.82 : 0.58)
        }
    }

    // MARK: Colour arithmetic

    static func rgb(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let color = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }

    /// WCAG relative luminance.
    static func luminance(_ c: (Double, Double, Double)) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
    }

    static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// Behind a hero card: the artwork, blurred to fill the card, under a wash
/// of the card's colour so the text reads. Reduce Transparency draws the
/// plain colour instead; Increase Contrast thickens the wash.
struct HeroCardBackgroundView: View {
    let artwork: StoreArtwork?
    /// The size the card already draws this artwork at, so the blur reuses
    /// the same decoded picture rather than fetching another size.
    let sourceSize: CGSize
    let color: HeroCardColor
    let look: HeroCardLook

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                color.backgroundColor
                if !look.reduceTransparency, let artwork, sourceSize.width > 0, sourceSize.height > 0 {
                    let scale = max(proxy.size.width / sourceSize.width, proxy.size.height / sourceSize.height) * 1.15
                    StoreImage(artwork: artwork, width: sourceSize.width, height: sourceSize.height, corner: 0)
                        .scaleEffect(scale, anchor: .top)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                        .blur(radius: 34, opaque: true)
                        .accessibilityHidden(true)
                    color.backgroundColor.opacity(look.increasedContrast ? 0.62 : 0.34)
                    LinearGradient(colors: [.clear, color.backgroundColor.opacity(look.increasedContrast ? 0.9 : 0.6)],
                                   startPoint: .center, endPoint: .bottom)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

/// The follow control on a show's hero card: a plus in a translucent circle.
struct ShowHeroFollowCircle: View {
    let color: HeroCardColor
    let look: HeroCardLook
    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 28

    var body: some View {
        let glyph = color.textStyle(.primary)
        Image(systemName: "plus")
            .font(.caption.weight(.bold))
            .foregroundStyle(glyph)
            .frame(width: side, height: side)
            .background {
                if look.reduceTransparency {
                    Circle().fill(glyph.opacity(0.22))
                } else {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().fill(glyph.opacity(0.14)))
                }
            }
            .overlay {
                if look.increasedContrast {
                    Circle().strokeBorder(glyph.opacity(0.75), lineWidth: 1)
                }
            }
            .clipShape(Circle())
            .environment(\.colorScheme, color.colorScheme)
            .accessibilityLabel("Follow")
    }
}

/// The play button on a hero card ("Trailer", "Latest Episode").
struct HeroPlayCapsule: View {
    let title: String
    let color: HeroCardColor
    let look: HeroCardLook

    var body: some View {
        let text = color.textStyle(.primary)
        HStack(spacing: 5) {
            Image(systemName: "play.fill").font(.caption2)
            Text(title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(text)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(text.opacity(look.increasedContrast ? 0.28 : 0.18)))
        .overlay {
            if look.increasedContrast { Capsule().strokeBorder(text.opacity(0.75), lineWidth: 1) }
        }
    }
}

// MARK: - Test screen

/// Under test only (`-HeroCardDemo` with the screenshot demo): every hero
/// card look on one screen, with drawn artwork, so they can be photographed
/// offline — the live cards appear only on Apple's category pages.
struct HeroCardGallery: View {
    static var isRequested: Bool {
        DemoData.isEnabled && ProcessInfo.processInfo.arguments.contains("-HeroCardDemo")
    }

    private static func art(_ letter: String, hue: Double, name: String, saturation: Double = 0.82,
                            brightness: Double = 0.95, background: String) -> StoreArtwork? {
        guard let url = DemoData.cover(letter: letter, hue: hue, name: "hero-\(name)",
                                       saturation: saturation, brightness: brightness) else { return nil }
        return StoreArtwork(template: url, width: 600, height: 600, background: background,
                            textPrimary: nil, textSecondary: nil, crop: nil)
    }

    private static let shows: [StoreItem] = {
        func show(_ id: String, _ title: String, _ summary: String, art: StoreArtwork?, uber: Bool,
                  button: String, genre: String, rating: Double) -> StoreItem {
            var item = StoreItem(id: id, kind: .showHero)
            item.title = title
            item.summary = summary
            item.artwork = art
            item.uber = uber ? art : nil
            item.buttonTitle = button
            item.genre = genre
            item.rating = rating
            item.ratingCount = 1204
            return item
        }
        return [
            show("hero-dark", "Night Desk", "Two reporters reopen the case that made their careers — and finally ask who it hurt.",
                 art: art("N", hue: 0.62, name: "dark", background: "1D3B78"), uber: true,
                 button: "Trailer", genre: "True Crime", rating: 4.7),
            show("hero-light", "Morning Garden", "Short, cheerful lessons for growing food on a balcony, a windowsill or a single pot.",
                 art: art("M", hue: 0.14, name: "light", saturation: 0.35, brightness: 1.0, background: "F4E7B8"), uber: true,
                 button: "Latest Episode", genre: "Home & Garden", rating: 4.5),
            show("hero-inset", "Signal Loss", "A history of the inventions that almost changed everything, told by the people who built them.",
                 art: art("S", hue: 0.02, name: "inset", background: "B23A1E"), uber: false,
                 button: "Trailer", genre: "Technology", rating: 4.8)
        ]
    }()

    private static let episodes: [StoreItem] = {
        var audio = StoreItem(id: "hero-episode", kind: .episode)
        audio.title = "The Bridge That Sang in the Wind"
        audio.eyebrow = "2D AGO"
        audio.duration = 2_940
        audio.artwork = art("B", hue: 0.45, name: "episode", background: "17614F")
        audio.icon = audio.artwork
        return [audio]
    }()

    private func row(_ title: String, look: HeroCardLook?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).padding(.horizontal, 16)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Self.shows) { ShowHeroCard(item: $0) }
                    ForEach(Self.episodes) { EpisodeHeroCard(item: $0) }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
        .environment(\.heroCardLookOverride, look)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                row("Hero Cards", look: nil)
                row("Reduce Transparency", look: HeroCardLook(reduceTransparency: true, increasedContrast: false))
                row("Increase Contrast", look: HeroCardLook(reduceTransparency: false, increasedContrast: true))
            }
            .padding(.vertical, 16)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .accessibilityIdentifier("heroCardGallery")
    }
}
