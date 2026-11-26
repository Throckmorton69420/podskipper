import XCTest
@testable import PodSkipper

/// Pass 72 (his Pass 72 prompt): Apple Podcasts 27.3's `heroBlur` hero cards —
/// the card colour taken from the artwork and held to a legible range, and the
/// spacing 27.3 beta 2 uses with the flag on.
@MainActor
final class Pass72Tests: XCTestCase {

    private func rgb(_ c: HeroCardColor) -> (Double, Double, Double) { (c.red, c.green, c.blue) }

    /// Whatever colour the artwork brings, the card's primary text clears
    /// 7:1, so its secondary text (74 % opacity) still reads.
    func testHeroCardColourKeepsTextLegible() {
        let samples = ["000000", "FFFFFF", "808080", "FFD400", "00FF66", "1D3B78", "F4E7B8",
                       "B23A1E", "7F7F00", "33CCFF", "FF00FF", "C0C0C0", "5A5A5A", "17614F"]
        for hex in samples {
            let color = HeroCardColor(artwork: StoreArtwork(template: "", width: 1, height: 1, background: hex,
                                                             textPrimary: nil, textSecondary: nil, crop: nil))
            let text: (Double, Double, Double) = color.isDark ? (1, 1, 1) : (0.06, 0.06, 0.07)
            XCTAssertGreaterThanOrEqual(HeroCardColor.contrast(text, rgb(color)), 7, "\(hex) → \(color.hexColor)")
        }
    }

    /// Dark artwork gives a dark card (white text), pale artwork a light one,
    /// and the hue is kept; no colour at all falls back to a dark card.
    func testHeroCardColourFollowsTheArtwork() {
        func card(_ hex: String?) -> HeroCardColor {
            HeroCardColor(artwork: hex.map { StoreArtwork(template: "", width: 1, height: 1, background: $0,
                                                          textPrimary: nil, textSecondary: nil, crop: nil) })
        }
        XCTAssertTrue(card("1D3B78").isDark)
        XCTAssertEqual(card("1D3B78").colorScheme, .dark)
        XCTAssertFalse(card("F4E7B8").isDark)
        XCTAssertEqual(card("F4E7B8").colorScheme, .light)
        XCTAssertEqual(card(nil), .fallback)
        XCTAssertEqual(card("not a colour"), .fallback)
        let blue = card("1D3B78")
        XCTAssertGreaterThan(blue.blue, blue.red, "the hue survives clamping")
    }

    /// The `HeroContainer` values 27.3 beta 2 uses with `heroBlur` on
    /// (`build/p70/parity-27.3.md` §4).
    func testHeroContainerMatches27Point3WithHeroBlur() {
        XCTAssertEqual(HeroContainer.episodeSpaceBetweenTextAndButtons, 6)
        XCTAssertEqual(HeroContainer.showSpaceBetweenTextAndButtons, 10)
        XCTAssertEqual(HeroContainer.showPlayButtonInsets.top, -10)
        XCTAssertEqual(HeroContainer.buttonAreaOutsets.top, 6)
        XCTAssertEqual(HeroContainer.episodeTextZoneSpacing, 2)
        XCTAssertEqual(HeroContainer.showMetadataSpacing, 6)
        XCTAssertEqual(HeroContainer.showInsetArtworkTextGap, 8)
        XCTAssertEqual(HeroContainer.spaceBetweenPlayButtonAndContextMenu, 8)
        XCTAssertEqual(HeroContainer.chinGeneralPadding, 16)
    }

    /// Increase Contrast raises secondary and tertiary text; primary is full.
    func testIncreaseContrastRaisesTheLesserText() {
        let color = HeroCardColor.fallback
        XCTAssertEqual(color.textStyle(.primary), color.textStyle(.primary, increasedContrast: true))
        XCTAssertNotEqual(color.textStyle(.secondary), color.textStyle(.secondary, increasedContrast: true))
        XCTAssertNotEqual(color.textStyle(.tertiary), color.textStyle(.tertiary, increasedContrast: true))
    }
}
