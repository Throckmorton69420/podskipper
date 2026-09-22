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
        case .selfPromo:  return "Self-Promotion"
        case .crossPromo: return "Other Shows"
        case .intro:      return "Intros"
        case .outro:      return "Outros"
        }
    }

    /// Singular, for labelling one segment on the timeline.
    var label: String {
        switch self {
        case .ad:         return "Ad"
        case .selfPromo:  return "Promo"
        case .crossPromo: return "Other Show"
        case .intro:      return "Intro"
        case .outro:      return "Outro"
        }
    }

    var detail: String {
        switch self {
        case .ad:         return "Paid sponsor reads, including host-read ones."
        case .selfPromo:  return "Patreon, merch, tour dates, bonus feeds, the hosts' other projects."
        case .crossPromo: return "Plugs for podcasts that aren't theirs."
        case .intro:      return "The theme and the opening of the episode."
        case .outro:      return "The sign-off, thanks and credits."
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

