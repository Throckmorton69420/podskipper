import Foundation

/// Pass 60: the PodSkipper test's episodes as the app ships them
/// (`Resources/Detection/PodTest.json`, written by
/// `Tools/ReaderData/podtest.py pack`). Time spans, kinds and durations only:
/// the repository is public, so no transcript text or titles. The phone reads
/// these episodes from its own library and transcripts.
struct PodTestPack: Codable, Sendable, Equatable {
    struct Constants: Codable, Sendable, Equatable {
        /// Seconds at each edge of a break that may be left either way.
        var edge: Double
        /// Seconds of a break heard before you notice it.
        var noticed: Double
        /// Seconds added for a break you notice.
        var noticeCost: Double
        /// A second of the show cut costs this many of an ad heard.
        var showWeight: Double
        /// A show cut longer than this is a jump you hear.
        var jump: Double
        /// Seconds added per jump.
        var jumpCost: Double
        /// Seconds of the show next to a break that may be cut either way.
        var showMargin: Double
    }

    /// A labelled ad, plug, promo, intro or outro, and the situations of
    /// the Challenge view it is an instance of.
    struct Break: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var kind: String
        var situations: [String]
    }

    /// Show talk with selling or plug words in it: to keep.
    struct Trap: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var situation: String
    }

    struct Episode: Codable, Sendable, Equatable, Identifiable {
        var guid: String
        var show: String
        /// The episode's length when it was labelled; the phone's copy must
        /// match it within `PodTestRunner.durationTolerance`.
        var duration: Double
        var breaks: [Break]
        /// Every labelled break and either-way stretch, joined.
        var labelled: [[Double]]
        var traps: [Trap]
        var id: String { guid }
    }

    var version: Int
    var constants: Constants
    var situations: [String]
    var episodes: [Episode]

    static func bundled(_ bundle: Bundle = .main) -> PodTestPack? {
        guard let url = bundle.url(forResource: "PodTest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PodTestPack.self, from: data)
    }

    func episode(_ guid: String) -> Episode? { episodes.first { $0.guid == guid } }
}

/// One cut an engine made: what is scored and exported (no words).
struct PodTestCut: Codable, Sendable, Equatable, Hashable {
    var start: Double
    var end: Double
    var kind: String
}

/// The PodSkipper test's score, exactly as `Tools/ReaderData/podtest.py`
/// (`score_pack`, `everyday`, `challenge`) computes it; `PodTestScoreTests`
/// checks the two give the same numbers on the same input.
///
/// Everyday (0–100): how much of the interruption an engine removes, net
/// of the damage it does, every show counting the same. Cost of an episode
/// = seconds of a break still heard (beyond an allowance at each edge) + a
/// cost for every break you'd notice + twice every second of the show cut +
/// a cost for every jump in the show. Skipping nothing is about 0; every
/// break skipped exactly is 100.
///
/// Challenge: the share of each situation handled (less than 5 s heard, or
/// for a trap, not cut), each situation counting the same.
enum PodTestScore {
    struct Episode: Sendable, Equatable {
        var heard = 0.0
        var noticed = 0
        var show = 0.0
        var jumps = 0
        var base = 0.0
        var breaks = 0
        var caught = 0
        var skippable = 0.0
        var sit: [String: Int] = [:]
        var sitN: [String: Int] = [:]
        var cost = 0.0
        var audio = 0.0
    }

    struct Summary: Sendable, Equatable {
        var everyday: Double?
        var challenge: Double?
        /// Share handled per situation (0–1), for situations that occur.
        var rates: [String: Double]
        var counts: [String: Int]
        var episodes: Int
        var shows: Int
        var noticed: Int
        var breaks: Int
        var heard: Double
        var skippable: Double
        var showCut: Double
        var jumps: Int
        var hours: Double

        var showCutPerHour: Double { hours > 0 ? showCut / hours : 0 }
        var heardShare: Double { skippable > 0 ? heard / skippable : 0 }
    }

    static func union(_ intervals: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (a, b) in intervals.sorted(by: { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }) {
            if b <= a { continue }
            if let last = out.last, a <= last.1 {
                out[out.count - 1].1 = max(last.1, b)
            } else {
                out.append((a, b))
            }
        }
        return out
    }

    static func covered(_ a: Double, _ b: Double, _ intervals: [(Double, Double)]) -> Double {
        var total = 0.0
        for (x, y) in intervals { total += max(0, min(b, y) - max(a, x)) }
        return total
    }

    /// One episode's cost and Challenge tallies (podtest.py `score_pack`).
    static func episode(_ e: PodTestPack.Episode, cuts: [PodTestCut], constants c: PodTestPack.Constants) -> Episode {
        var r = Episode()
        r.breaks = e.breaks.count
        let cutIntervals = union(cuts.map { ($0.start, $0.end) })
        for s in e.breaks {
            let length = s.end - s.start
            let allowance = min(c.edge, 0.15 * length)
            let core = (s.start + allowance, s.end - allowance)
            let heard = core.1 > core.0 ? (core.1 - core.0) - covered(core.0, core.1, cutIntervals) : 0.0
            let noticed = heard > c.noticed
            r.heard += heard
            r.noticed += noticed ? 1 : 0
            r.base += max(0.0, core.1 - core.0) + c.noticeCost
            r.skippable += max(0.0, core.1 - core.0)
            r.caught += noticed ? 0 : 1
            for situation in s.situations {
                r.sitN[situation, default: 0] += 1
                r.sit[situation, default: 0] += noticed ? 0 : 1
            }
        }
        // The show: everything unlabelled, less a margin next to each break.
        let margin = union(e.labelled.compactMap { $0.count == 2 ? ($0[0] - c.showMargin, $0[1] + c.showMargin) : nil })
        for (a, b) in cutIntervals {
            var pieces: [(Double, Double)] = []
            var start = a
            for (x, y) in margin {
                if y <= start || x >= b { continue }
                if x > start { pieces.append((start, x)) }
                start = max(start, y)
            }
            if start < b { pieces.append((start, b)) }
            for (x, y) in pieces {
                r.show += y - x
                r.jumps += (y - x) > c.jump ? 1 : 0
            }
        }
        for t in e.traps {
            r.sitN[t.situation, default: 0] += 1
            r.sit[t.situation, default: 0] += covered(t.start, t.end, cutIntervals) < 0.5 * (t.end - t.start) ? 1 : 0
        }
        r.cost = r.heard + c.noticeCost * Double(r.noticed) + c.showWeight * r.show + c.jumpCost * Double(r.jumps)
        r.audio = e.duration
        return r
    }

    /// podtest.py `everyday` with `show_weights`: each episode weighs 1 / its
    /// show's episode count, so a show with many episodes can't outvote one
    /// with few. Nil when there is nothing to skip.
    static func everyday(_ rows: [String: Episode], showOf: [String: String]) -> Double? {
        var perShow: [String: Int] = [:]
        for guid in rows.keys { perShow[showOf[guid] ?? guid, default: 0] += 1 }
        var cost = 0.0, base = 0.0
        for guid in rows.keys.sorted() {
            guard let row = rows[guid] else { continue }
            let weight = 1.0 / Double(perShow[showOf[guid] ?? guid] ?? 1)
            cost += weight * row.cost
            base += weight * row.base
        }
        return base != 0 ? 100 * (1 - cost / base) : nil
    }

    /// podtest.py `challenge`: the mean of each situation's pass rate.
    static func challenge(_ rows: [String: Episode], situations: [String]) -> (score: Double?, rates: [String: Double], counts: [String: Int]) {
        var n: [String: Int] = [:], ok: [String: Int] = [:]
        for row in rows.values {
            for (k, v) in row.sitN { n[k, default: 0] += v }
            for (k, v) in row.sit { ok[k, default: 0] += v }
        }
        var rates: [String: Double] = [:]
        var ordered: [Double] = []
        for situation in situations where (n[situation] ?? 0) > 0 {
            let rate = Double(ok[situation] ?? 0) / Double(n[situation]!)
            rates[situation] = rate
            ordered.append(rate)
        }
        let score = ordered.isEmpty ? nil : 100 * ordered.reduce(0, +) / Double(ordered.count)
        return (score, rates, n)
    }

    /// Everything shown for one engine: on `guids` only (pass the episodes
    /// it shares with the engine it is compared with, so both face the same
    /// breaks).
    static func summary(pack: PodTestPack, cuts: [String: [PodTestCut]], guids: Set<String>? = nil) -> Summary {
        var rows: [String: Episode] = [:]
        var showOf: [String: String] = [:]
        for e in pack.episodes {
            guard let c = cuts[e.guid], guids?.contains(e.guid) ?? true else { continue }
            rows[e.guid] = episode(e, cuts: c, constants: pack.constants)
            showOf[e.guid] = e.show
        }
        let (challenge, rates, counts) = challenge(rows, situations: pack.situations)
        let all = rows.values
        return Summary(everyday: everyday(rows, showOf: showOf), challenge: challenge, rates: rates, counts: counts,
                       episodes: rows.count, shows: Set(showOf.values).count,
                       noticed: all.reduce(0) { $0 + $1.noticed }, breaks: all.reduce(0) { $0 + $1.breaks },
                       heard: all.reduce(0) { $0 + $1.heard }, skippable: all.reduce(0) { $0 + $1.skippable },
                       showCut: all.reduce(0) { $0 + $1.show }, jumps: all.reduce(0) { $0 + $1.jumps },
                       hours: all.reduce(0) { $0 + $1.audio } / 3600)
    }
}

// MARK: - Pass 63: the four-part score

extension PodTestScore {
    /// Pass 63 (his 10 Nov report: one over-long cut took a finder's Basic or
    /// Hard to 0 %, and the score said nothing about kinds): what a finder
    /// did, in four parts he can read, and one score made from them.
    ///
    /// - **Ads cut**: the share of every break's seconds removed (the first
    ///   and last 2 s of a break may be left either way, as in Everyday).
    /// - **Show kept**: the share of the show's seconds still there (1 s next
    ///   to a break may go either way).
    /// - **Edges**: of the breaks found, the share of their starts and ends
    ///   within 3 s of where the break really starts and ends.
    /// - **Kinds**: of the breaks found, the share given the right kind (ad,
    ///   plug, another show's promo, intro or credits).
    ///
    /// Score = ads cut × show kept² × (0.8 + 0.1 × edges + 0.1 × kinds).
    /// The show counts twice (squared): losing a tenth of the show costs
    /// about twice what hearing a tenth of the ads does. Cutting nothing is
    /// 0; cutting everything is 0; every break cut exactly, named right, is
    /// 100. One line too many costs a few points, not all of them.
    struct Quality: Codable, Sendable, Equatable {
        var skippable = 0.0
        var heard = 0.0
        var showSeconds = 0.0
        var showSecondsCut = 0.0
        var breaks = 0
        var breaksFound = 0
        var edgesChecked = 0
        var edgesRight = 0
        var kindsChecked = 0
        var kindsRight = 0

        var adsCut: Double { skippable > 0 ? max(0, min(1, 1 - heard / skippable)) : 0 }
        var showKept: Double { showSeconds > 0 ? max(0, min(1, 1 - showSecondsCut / showSeconds)) : 1 }
        var edges: Double { edgesChecked > 0 ? Double(edgesRight) / Double(edgesChecked) : 0 }
        var kinds: Double { kindsChecked > 0 ? Double(kindsRight) / Double(kindsChecked) : 0 }
        /// 0–1.
        var score: Double { adsCut * showKept * showKept * (0.8 + 0.1 * edges + 0.1 * kinds) }

        static func + (a: Quality, b: Quality) -> Quality {
            Quality(skippable: a.skippable + b.skippable, heard: a.heard + b.heard,
                    showSeconds: a.showSeconds + b.showSeconds, showSecondsCut: a.showSecondsCut + b.showSecondsCut,
                    breaks: a.breaks + b.breaks, breaksFound: a.breaksFound + b.breaksFound,
                    edgesChecked: a.edgesChecked + b.edgesChecked, edgesRight: a.edgesRight + b.edgesRight,
                    kindsChecked: a.kindsChecked + b.kindsChecked, kindsRight: a.kindsRight + b.kindsRight)
        }

        static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

        /// "Ads cut 96% · Show kept 100%".
        var short: String { "Ads cut \(Self.percent(adsCut)) · Show kept \(Self.percent(showKept))" }

        /// "Ads cut 96% · Show kept 100% · Edges 17 of 18 · Kinds 9 of 9".
        var summary: String {
            var text = short
            if breaksFound > 0 {
                text += " · Edges \(edgesRight) of \(edgesChecked) · Kinds \(kindsRight) of \(kindsChecked)"
            }
            return text
        }
    }

    /// Seconds an edge may be off and still count as right.
    static let edgeTolerance = 3.0

    /// A break's or a cut's kind as one of four groups: ad, plug, promo
    /// (another show's), bookend (intro, outro, credits).
    static func group(_ kind: String) -> String? {
        switch kind.lowercased() {
        case "ad", "paid_ad", "host_read_ad": "ad"
        case "self", "selfpromo", "self_promo", "guestplug", "guest_plug", "plug": "plug"
        case "network", "crosspromo", "network_promo", "cross_promo": "promo"
        case "intro", "outro", "credits": "bookend"
        default: nil
        }
    }

    static func quality(_ e: PodTestPack.Episode, cuts: [PodTestCut], constants c: PodTestPack.Constants) -> Quality {
        var q = Quality()
        let cutIntervals = union(cuts.map { ($0.start, $0.end) })
        let labelled = union(e.labelled.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil })
        let margin = union(e.labelled.compactMap { $0.count == 2 ? ($0[0] - c.showMargin, $0[1] + c.showMargin) : nil })
        // Seconds of a..b that are the show (not labelled, not next to a break).
        func show(_ a: Double, _ b: Double) -> Double { b > a ? (b - a) - covered(a, b, margin) : 0 }
        q.breaks = e.breaks.count
        for s in e.breaks {
            let length = s.end - s.start
            let allowance = min(c.edge, 0.15 * length)
            let core = (s.start + allowance, s.end - allowance)
            let size = max(0, core.1 - core.0)
            let heard = size - covered(core.0, core.1, cutIntervals)
            q.skippable += size
            q.heard += max(0, heard)
            guard size > 0, heard <= 0.5 * size else { continue }
            q.breaksFound += 1
            // Each edge: show taken before the break plus break left at its start.
            let over = cutIntervals.filter { $0.0 < s.end && $0.1 > s.start }
            if let first = over.first, let last = over.last {
                let startError = first.0 <= s.start ? show(first.0, s.start) : first.0 - s.start
                let endError = last.1 >= s.end ? show(s.end, last.1) : s.end - last.1
                q.edgesChecked += 2
                q.edgesRight += (startError <= edgeTolerance ? 1 : 0) + (endError <= edgeTolerance ? 1 : 0)
            }
            // The kind that took most of it.
            var seconds: [String: Double] = [:]
            for cut in cuts {
                let inside = max(0, min(cut.end, s.end) - max(cut.start, s.start))
                if inside > 0 { seconds[group(cut.kind) ?? "", default: 0] += inside }
            }
            q.kindsChecked += 1
            if let named = seconds.max(by: { $0.value < $1.value })?.key, named == group(s.kind) { q.kindsRight += 1 }
        }
        q.showSeconds = max(1, e.duration - labelled.reduce(0) { $0 + ($1.1 - $1.0) })
        for (a, b) in cutIntervals { q.showSecondsCut += show(max(0, a), min(e.duration, b)) }
        return q
    }

    /// Every episode's parts added up (seconds and counts), for one finder.
    static func quality(pack: PodTestPack, cuts: [String: [PodTestCut]], guids: Set<String>? = nil) -> Quality? {
        var total: Quality?
        for e in pack.episodes {
            guard let c = cuts[e.guid], guids?.contains(e.guid) ?? true else { continue }
            let q = quality(e, cuts: c, constants: pack.constants)
            total = total.map { $0 + q } ?? q
        }
        return total
    }
}
