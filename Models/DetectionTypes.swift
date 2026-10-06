import Foundation

// Plain Foundation types shared by the app and the detection lab
// (build/lab on the Mac), which compiles the detector outside the app so it
// can be run against real episodes. Nothing here may import SwiftUI or
// SwiftData.

/// What a detected stretch of audio actually is.
///
/// The app used to have one bucket, "ad", and a host spending four minutes on
/// their own tour dates went straight through it — which is the thing you
/// most want cut on a comedy show. Separating the kinds is what lets each one
/// have its own switch.
enum SegmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A paid third-party spot.
    case ad
    /// The show selling its own things: Patreon, merch, tour, bonus feed.
    case selfPromo
    /// A plug for somebody else's podcast.
    case crossPromo
    /// The opening of the episode itself.
    case intro
    /// The sign-off and credits.
    case outro

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ad:         return "Ads"
        case .selfPromo:  return "Plugs"
        case .crossPromo: return "Other Podcasts"
        case .intro:      return "Intros"
        case .outro:      return "Outros & Credits"
        }
    }

    /// Singular, for labelling one segment on the timeline.
    var label: String {
        switch self {
        case .ad:         return "Ad"
        case .selfPromo:  return "Plug"
        case .crossPromo: return "Other Podcast"
        case .intro:      return "Intro"
        case .outro:      return "Outro"
        }
    }

    var detail: String {
        switch self {
        case .ad:         return "Paid sponsor messages: produced spots, ones the ad server inserts, and ones a host reads."
        case .selfPromo:  return "The hosts' own tour dates, Patreon, bonus feeds and merch, and the guest's plugs for their own work."
        case .crossPromo: return "Trailers and plugs for a different podcast, and for the network or app the show is on."
        case .intro:      return "The produced opening: theme, announcer, network sting."
        case .outro:      return "The produced closing: sign-off, theme and credits."
        }
    }

    var symbol: String {
        switch self {
        case .ad:         return "megaphone"
        case .selfPromo:  return "heart.text.square"
        case .crossPromo: return "arrow.triangle.branch"
        case .intro:      return "text.line.first.and.arrowtriangle.forward"
        case .outro:      return "text.line.last.and.arrowtriangle.forward"
        }
    }

    /// The kinds that get their own switch in Settings, in the order they
    /// appear there. Intro and outro share one, because nobody wants to skip
    /// one and keep the other.
    static var switchable: [SegmentKind] { [.ad, .selfPromo, .crossPromo, .intro] }

    /// Maps whatever the model returned onto a case, tolerantly.
    init?(modelLabel: String) {
        switch modelLabel.lowercased().replacingOccurrences(of: " ", with: "") {
        case "advertisement", "ad", "advert":         self = .ad
        case "selfpromotion", "selfpromo":            self = .selfPromo
        case "crosspromotion", "crosspromo":          self = .crossPromo
        case "introduction", "intro":                 self = .intro
        case "outro", "outroorcredits", "credits":    self = .outro
        default:                                      return nil   // content
        }
    }
}

/// The finer class of a cut, within its kind (D17: his 22 Sep list). The
/// five kinds keep their switches; this is what What Was Skipped calls it.
/// Credits are an outro, so the outro switch skips them (decided from his
/// 14 and 22 Sep messages). Host-read vs inserted is not here: that is
/// `deliveryRaw` and `insertedAtDownload`.
enum CutDetail: String, Codable, CaseIterable, Sendable {
    case credits, trailer, patreon, merch, tour, bonus, network, otherShow
    /// Pass 31: the guest plugging their own work (it used to be filed as
    /// a plain plug, so "Promo" meant two different things).
    case guest

    var label: String {
        switch self {
        case .credits:   return "credits"
        case .trailer:   return "trailer"
        case .patreon:   return "Patreon or membership"
        case .merch:     return "merch"
        case .tour:      return "tour dates"
        case .bonus:     return "bonus or ad-free feed"
        case .network:   return "network or app"
        case .otherShow: return "another show"
        case .guest:     return "the guest's plug"
        }
    }

    private static let creditWords = ["produced by", "executive produc", "theme song", "engineering", "mixed by",
                                      "mixing by", "talent book", "associate producer", "supervising producer",
                                      "music by", "edited by", "production support", "incidental music"]

    /// How many credit lines a passage holds.
    static func creditLines(_ text: String) -> Int {
        let lower = text.lowercased()
        return creditWords.filter { lower.contains($0) }.count
    }

    /// From the cut's own words: no model, same answer every time.
    static func classify(kind: SegmentKind, text: String) -> CutDetail? {
        let t = text.lowercased()
        func hits(_ words: [String]) -> Int { words.filter { t.contains($0) }.count }
        switch kind {
        case .outro:
            return creditLines(t) >= 2 ? .credits : nil
        case .intro:
            return nil
        case .ad:
            return hits(["trailer", "in theaters", "only in theaters", "in imax", "now streaming", "premieres",
                         "coming soon to", "season premiere"]) >= 1 ? .trailer : nil
        case .selfPromo:
            let scores: [(CutDetail, Int)] = [
                (.patreon, hits(["patreon", "membership", "members", "supporting cast", "supercast", "join the"])),
                (.merch, hits(["merch", "shirt", "hoodie", "store", "hat ", "poster"])),
                (.tour, hits(["tickets", "tour", "on sale", "live show", "comedy club", "this weekend", "come see",
                              "come out", "dates"])),
                (.bonus, hits(["bonus", "ad-free", "ad free", "uncensored", "friday night hang", "premium", "early access"])),
            ]
            let best = scores.max { $0.1 < $1.1 }!
            return best.1 > 0 ? best.0 : nil
        case .crossPromo:
            return hits(["network", "siriusxm", "sirius xm", "the app", "spotify", "youtube", "apple podcasts"]) > 0
                && hits(["podcast called", "new show", "check out the show", "my show"]) == 0 ? .network : .otherShow
        }
    }
}

/// One piece of listener feedback about one passage.
///
/// `kind` nil means "this was not a promotion at all" — the thumbs-down case.
/// A kind means "you were right, and this is what it was" — the thumbs-up
/// case, which is worth keeping because a confirmed example of this show's own
/// Patreon plug is the best possible description of this show's Patreon plug.
struct DetectionCorrection: Codable, Hashable, Sendable {
    var excerpt: String
    var kind: String?
    var addedAt: Date
    /// Set for an edge lesson from a dragged handle: "outsideStart",
    /// "insideStart", "outsideEnd" or "insideEnd". The excerpt is then the
    /// few words at that edge, not a whole passage, and it is never used as
    /// an example of what a promotion is.
    var boundary: String?

    /// Trimmed in one place rather than at every call site. Long enough to be
    /// recognisable, short enough that two dozen of them are still a small part
    /// of a prompt — and, because withdrawing a correction has to find the one
    /// that was stored, the same function has to produce the key both times.
    static func normalise(_ raw: String) -> String {
        let flat = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 400, not 160. The excerpt is also what the feedback memory embeds,
        // and the first thirty words of a sponsor read are often just the
        // host's lead-in.
        return String(flat.prefix(400))
    }

    init(excerpt: String, kind: SegmentKind?, addedAt: Date = .now, boundary: String? = nil) {
        self.excerpt = Self.normalise(excerpt)
        self.kind = kind?.rawValue
        self.addedAt = addedAt
        self.boundary = boundary
    }

    var segmentKind: SegmentKind? { kind.flatMap(SegmentKind.init(rawValue:)) }
}

/// Corrections from every show, most recent last.
///
/// A show's own corrections go into its instructions. This copy is what lets a
/// thumbs-down on one show — "raising awareness is not a promotion" — stop
/// the same mistake on the next show, through the feedback memory.
enum GlobalCorrections {
    private static let key = "globalDetectionCorrections"

    static var all: [DetectionCorrection] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DetectionCorrection].self, from: data)
        else { return [] }
        return decoded
    }

    static func record(_ correction: DetectionCorrection) {
        var list = all.filter { $0.excerpt != correction.excerpt }
        list.append(correction)
        if list.count > 60 { list.removeFirst(list.count - 60) }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
    }

    static func forget(excerpt: String) {
        let key = DetectionCorrection.normalise(excerpt)
        let list = all.filter { $0.excerpt != key }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: Self.key)
    }
}


/// Pass 31: one entry in the cut's type menu — the switch it belongs to
/// and, where there is one, what exactly it is. Reconciles the five
/// switches with the finer kinds the spec lists (paid/produced/host ads;
/// self, guest, tour, Patreon, merch and network plugs; trailers;
/// intros, outros and credits) without adding switches.
struct CutChoice: Identifiable, Hashable, Sendable {
    var kind: SegmentKind
    var detail: CutDetail?
    /// "host" or "produced" for an ad; nil leaves it as it was.
    var delivery: String?
    var title: String

    var id: String { kind.rawValue + "/" + (detail?.rawValue ?? "") + "/" + (delivery ?? "") }

    static func choices(for kind: SegmentKind) -> [CutChoice] {
        switch kind {
        case .ad:
            return [CutChoice(kind: .ad, detail: nil, delivery: "host", title: "Sponsor ad, read by a host"),
                    CutChoice(kind: .ad, detail: nil, delivery: "produced", title: "Sponsor ad, produced spot"),
                    CutChoice(kind: .ad, detail: .trailer, delivery: "produced", title: "Movie or TV trailer")]
        case .selfPromo:
            return [CutChoice(kind: .selfPromo, detail: .tour, title: "Their tour dates or tickets"),
                    CutChoice(kind: .selfPromo, detail: .patreon, title: "Their Patreon or membership"),
                    CutChoice(kind: .selfPromo, detail: .bonus, title: "Their bonus or ad-free feed"),
                    CutChoice(kind: .selfPromo, detail: .merch, title: "Their merch"),
                    CutChoice(kind: .selfPromo, detail: .guest, title: "The guest's plug"),
                    CutChoice(kind: .selfPromo, detail: nil, title: "Another plug of theirs (socials, rate and review)")]
        case .crossPromo:
            return [CutChoice(kind: .crossPromo, detail: .otherShow, title: "A different podcast's trailer or plug"),
                    CutChoice(kind: .crossPromo, detail: .network, title: "The network or app")]
        case .intro:
            return [CutChoice(kind: .intro, detail: nil, title: "Intro (theme or opening)")]
        case .outro:
            return [CutChoice(kind: .outro, detail: nil, title: "Outro (sign-off or theme)"),
                    CutChoice(kind: .outro, detail: .credits, title: "Credits")]
        }
    }

    init(kind: SegmentKind, detail: CutDetail?, delivery: String? = nil, title: String) {
        self.kind = kind; self.detail = detail; self.delivery = delivery; self.title = title
    }

    func matches(kind: SegmentKind, detailRaw: String, deliveryRaw: String) -> Bool {
        guard kind == self.kind, (detail?.rawValue ?? "") == detailRaw else { return false }
        if let delivery, kind == .ad, detail == nil { return delivery == deliveryRaw }
        return true
    }

    /// The menu's title for a cut as it stands.
    static func title(kind: SegmentKind, detailRaw: String, deliveryRaw: String) -> String {
        if let match = choices(for: kind).first(where: { $0.matches(kind: kind, detailRaw: detailRaw, deliveryRaw: deliveryRaw) }) {
            return match.title
        }
        return kind.label
    }
}
