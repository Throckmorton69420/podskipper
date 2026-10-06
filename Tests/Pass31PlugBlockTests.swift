import XCTest
@testable import PodSkipper

/// Pass 31 (his "fragmentation" report): his LoS #958 plug block, 47:00–50:05
/// — Pete's tour dates, Lewis's dates and book, the bonus show, banter, the
/// Gas Digital code — as transcribed on his phone (results export, 6 Oct).
/// A model that calls the whole block one plug must come out of the cut
/// check, and the bridge, as one stretch, not islands with holes of show.
final class Pass31PlugBlockTests: XCTestCase {
    private let raw: [(String, Double, Double)] = [
        ("Pete, you're gonna be in Detroit soon?", 2816.94, 2818.74),
        ("I am going to be at the Mineral Point Opera House this weekend.", 2820.90, 2824.14),
        ("I'm going to be at Comedy on State in 2 weeks after that.", 2824.20, 2826.96),
        ("Back home in Wisconsin.", 2827.56, 2828.40),
        ("I'm going back home to Wisconsin.", 2828.46, 2829.72),
        ("Can I tell you something?", 2829.84, 2830.62),
        ("They have a cheese place by the club that will mail bigger cheese home.", 2830.68, 2834.64),
        ("Go on.", 2835.18, 2835.66),
        ("Let him do his plugs.", 2836.14, 2837.22),
        ("No.", 2837.34, 2837.88),
        ("No, because you can't travel with it in your carry-on because it looks like C4.", 2837.94, 2841.18),
        ("A block of cheese does.", 2841.54, 2842.62),
        ("We don't have to do plugs.", 2842.68, 2843.52),
        ("We can just talk about these things.", 2843.58, 2844.90),
        ("Lewis, they'll mail your cheese to you.", 2845.02, 2846.76),
        ("If you go in the store, they understand you're visiting and you can't bring CDs on a plane.", 2846.82, 2850.78),
        ("home.", 2850.90, 2851.26),
        ("So they will ship your cheese to you.", 2851.44, 2853.42),
        ("It's two blocks from the hotel between the club and the hotel.", 2853.78, 2856.72),
        ("It's fine.", 2856.90, 2857.50),
        ("Hey, hey, Lewis.", 2857.56, 2858.52),
        ("Um, you can go to my Instagram at Peatley, Peatley, Peatley.", 2858.64, 2861.70),
        ("I would love to.", 2861.82, 2862.42),
        ("You can go to my website, peatley.net for all my tour dates.", 2862.60, 2865.60),
        ("Please come see me.", 2865.66, 2866.26),
        ("By the way, I wanted to point out that I was less way less drunk tonight than I was on Story Wars every time.", 2866.62, 2871.90),
        ("I've been blackout drunk on Story Wars, and I wanted just to keep...", 2872.08, 2875.32),
        ("Well, so I guess you're slowing down.", 2875.44, 2876.58),
        ("Fucking terrible, Paul.", 2877.18, 2878.20),
        ("Get him a whiskey.", 2878.26, 2879.10),
        ("Terrible Paul.", 2880.06, 2880.96),
        ("Terrible, Paul.", 2882.10, 2882.88),
        ("No, don't don't terrible, Paul.", 2882.94, 2884.20),
        ("Hey, Sarah, Paul.", 2884.26, 2884.86),
        ("Come see me on the road this weekend.", 2884.92, 2886.24),
        ("I'll be in Rochester.", 2886.30, 2887.44),
        ("Comedy of the Carlson Friday and Saturday night.", 2887.50, 2889.60),
        ("Very excited.", 2889.66, 2890.26),
        ("Low ticket warning, as in low a low number of tickets have been sold.", 2890.32, 2893.44),
        ("You're warned. Please buy tickets for a warn.", 2894.52, 2896.74),
        ("Brokerage, I'm doing a makeup date.", 2897.40, 2898.72),
        ("couldn't make it this past weekend because of the Nor'easter, but I'll be back there October 10th doing that makeup date Saturday, 7 p.m. one show.", 2898.78, 2904.96),
        ("After that, October 22nd through 24th, North Charleston, South Carolina.", 2905.38, 2909.40),
        ("Story Wars, Los Angeles is happening at the Comedy Store November 4th and 5th.", 2910.12, 2914.62),
        ("So get those tickets.", 2914.68, 2915.34),
        ("They will sell out, and then I'll be in Poughkeepsie.", 2915.40, 2917.44),
        ("then I have side splitters Tampa for New Year's Eve and New Year's Eve weekend.", 2917.50, 2920.26),
        ("So come and get tickets for all those shows, and many more go to my website, louisofscanks.com, buy my book, knives and spoons, in hardcover, or the audiobook.", 2920.32, 2928.24),
        ("We'll be out in the next couple weeks.", 2928.30, 2929.56),
        ("The publishing company just got back to me today.", 2929.68, 2931.48),
        ("Completely read by Machine Gun Kelly.", 2932.56, 2934.30),
        ("Really? 100%.", 2934.54, 2935.26),
        ("Are you kidding me?", 2935.32, 2936.04),
        ("Yeah, true story.", 2936.28, 2937.24),
        ("weird, right?", 2937.30, 2937.90),
        ("For no reason, for no reason, it means nothing.", 2937.96, 2939.46),
        ("And also, guys, if you love the show, we do a bonus Friday night hang, just the 3 of us, we'll be doing it for 15 years straight, the 3 of us.", 2940.30, 2947.86),
        ("15 years, you've been included the whole time.", 2947.98, 2949.48),
        ("never left.", 2950.20, 2950.68),
        ("Steve, it's easy.", 2950.80, 2952.12),
        ("Honestly, God.", 2952.18, 2953.02),
        ("A few times, me and Lewis got in the bicker wars where we were like, let's just stop the show.", 2953.08, 2957.34),
        ("And Steve was like, the glue.", 2958.18, 2959.56),
        ("The glue.", 2959.80, 2960.40),
        ("I was there for one of them.", 2960.64, 2961.72),
        ("There was a show that I went on with you guys where I said nothing.", 2961.78, 2964.12),
        ("I was there the whole time.", 2964.60, 2965.74),
        ("It was back when you guys would do it in Anthony Kumia's studio for a little while, and you guys got into such a big argument.", 2965.86, 2972.10),
        ("And you're like, Pete, aren't you going to say anything?", 2972.22, 2973.72),
        ("I was like, I'm just loving this.", 2973.78, 2975.40),
        ("No, we were on the Kumi network, so we had to really, we were really a lot of most of our commercial throws.", 2975.82, 2983.74),
        ("Yeah, just armbands.", 2984.22, 2985.30),
        ("So yeah, also, go to Gas Digital.", 2986.02, 2987.82),
        ("If you want to get that bonus show every Friday night and you get the uncensored ad-free version of this show plus access to over 900 episodes.", 2987.88, 2996.64),
        ("Gasdigital.com.", 2996.70, 2997.66),
        ("Use the promo code LOS.", 2997.72, 2998.74),
        ("It saves you a couple bucks a month.", 2998.80, 2999.82),
        ("It supports the show directly.", 2999.88, 3000.90),
        ("And God bless America.", 3001.14, 3002.82),
        ("Steve Areno.", 3003.18, 3004.14),
        ("Well,", 3004.80, 3005.34),
        ("First and foremost, I'll have you know, I beat Carrot Top last week at fantasy football.", 3008.46, 3012.96),
    ]

    private func cut(_ start: Double, _ end: Double, _ kind: SegmentKind) -> DetectedSegment {
        DetectedSegment(start: start, end: end, kind: kind, sponsor: "", confidence: 80)
    }

    func testHisPlugBlockStaysOneStretchThroughTheCheck() {
        let lines = raw.map { TimedLine(text: $0.0, start: $0.1, end: $0.2) }
        let part = JudgedPart(firstLine: 1, lastLine: 79, label: .selfPromo, sponsor: "", funny: false, confidence: 85, why: "")
        // Without the reader, and with the reader's two cuts from his phone.
        for readers in [[], [cut(2_845.42, 2_945.48, .selfPromo), cut(2_984.62, 3_004.94, .ad)]] {
            let checked = ModelFinder.checkedCuts(from: [part], lines: lines, readerCuts: readers, inserted: [], evidence: [],
                                                  silences: [], padding: 0, duration: 7_331)
            let bridged = BreakBridge.bridge(checked.cuts, lines: lines).cuts
            let joined = SkipJoin.joined(bridged.map { $0.start...$0.end })
            let inBlock = joined.filter { $0.upperBound > 2_820.9 && $0.lowerBound < 3_004.14 }
            let covered = inBlock.reduce(0) { $0 + max(0, min($1.upperBound, 3_004.14) - max($1.lowerBound, 2_820.9)) }
            XCTAssertGreaterThan(covered / (3_004.14 - 2_820.9), 0.85,
                                 "with \(readers.count) reader cuts: \(inBlock) · \(checked.notes)")
            XCTAssertEqual(inBlock.count, 1, "one stretch, not islands: \(inBlock) · \(checked.notes)")
        }
    }
}
