import Foundation

// Pass 31 (his 6 Oct message, "fragmentation"): an eight-minute stretch of
// ads, host plugs and guest plugs came back as five cuts with bits of
// obvious non-show left between them. Three separate fixes live here:
//
// - `SkipJoin`: cuts a few seconds apart are skipped as one jump, so a
//   second of audio between two back-to-back sponsors is never played
//   (LoS #958: Sheath ended at 88:05.3 and Body Brain began at 88:06.45).
// - `BreakBridge`: a gap between two cuts that is itself not the show (no
//   words at all, or mostly plugs and offers, or the kind of gap he has
//   bridged on this show before) is cut too.
// - `CutGrade`: how right the detector was, as a grade rather than
//   thumbs, from what he changed (his "C, 74 %" idea).
//
// Foundation only: the detection lab on the Mac compiles this file too.

enum SkipJoin {
    /// Skips closer than this are one jump.
    static let maxGap = 4.0

    static func joined(_ ranges: [ClosedRange<Double>], maxGap: Double = maxGap) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound + maxGap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }
}

enum BreakBridge {
    /// A gap with no words in it at all (music, a sting, silence).
    static let wordlessGap = 30.0
    /// A gap whose lines mostly plug or sell.
    static let sellingGap = 75.0
    /// Longest gap a lesson from his edits can bridge.
    static let learnedLimit = 120.0

    /// The edge lesson's `boundary` for a bridged gap: "bridge:39".
    static func lessonTag(_ gap: Double) -> String { "bridge:\(Int(gap.rounded()))" }

    /// The largest gap he has bridged on this show, from its stored lessons.
    static func learnedGap(_ corrections: [DetectionCorrection]) -> Double {
        corrections.compactMap { c -> Double? in
            guard let b = c.boundary, b.hasPrefix("bridge:") else { return nil }
            return Double(b.dropFirst(7))
        }.map { min(learnedLimit, $0) }.max() ?? 0
    }

    private static let joinable: Set<SegmentKind> = [.ad, .selfPromo, .crossPromo]

    /// Neighbouring cuts with a not-the-show gap between them become one
    /// stretch: the earlier cut is extended to meet the next. Each cut keeps
    /// its own kind and sponsor.
    static func bridge(_ cuts: [DetectedSegment], lines: [TimedLine], learnedGap: Double = 0)
        -> (cuts: [DetectedSegment], notes: [String]) {
        var sorted = cuts.sorted { $0.start < $1.start }
        guard sorted.count > 1 else { return (sorted, []) }
        var notes: [String] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            let gap = b.start - a.end
            guard gap > SkipJoin.maxGap else { continue }
            guard joinable.contains(a.kind) || joinable.contains(b.kind) else { continue }
            let inside = lines.filter { ($0.start + $0.end) / 2 > a.end && ($0.start + $0.end) / 2 < b.start }
            let why: String?
            if inside.isEmpty, gap <= wordlessGap {
                why = "no words between them"
            } else if gap <= sellingGap, !inside.isEmpty,
                      Double(inside.filter { sells($0.text, a.kind, b.kind) }.count) >= Double(inside.count) * 0.5 {
                why = "the lines between them plug or sell too"
            } else if learnedGap > 0, gap <= learnedGap + 1, joinable.contains(a.kind), joinable.contains(b.kind) {
                why = "you've joined gaps like this on this show before"
            } else {
                why = nil
            }
            guard let why else { continue }
            sorted[i].end = b.start
            sorted[i].evidence.append("joined to the next cut: \(why)")
            notes.append("joined \(ModelCutCheck.clock(a.end))–\(ModelCutCheck.clock(b.start)) (\(Int(gap)) s): \(why)")
        }
        return (sorted, notes)
    }

    private static func sells(_ text: String, _ a: SegmentKind, _ b: SegmentKind) -> Bool {
        ModelCutCheck.sells(text, kind: a, brand: []) || ModelCutCheck.sells(text, kind: b, brand: [])
            || ModelCutCheck.sells(text, kind: .selfPromo, brand: [])
    }
}

/// How right the detector was about one stretch he settled, as a grade.
///
/// Thumbs say right or wrong. His edits say more: a cut he widened to take
/// in four neighbours found most of the break but split it (a C, not an F);
/// one he relabelled found the right stretch under the wrong name. The
/// detector's original cuts are compared, second by second, with the
/// stretch as he left it.
struct CutGrade: Codable, Sendable, Equatable {
    /// One original prediction overlapping the settled stretch.
    struct Piece: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var kind: String
        var detail: String
        var sponsor: String
        var confidence: Int
        var delivery: String
        var evidence: String
    }

    /// Share of the settled stretch the predictions covered.
    var recall: Double
    /// Share of the predictions' time inside the settled stretch.
    var precision: Double
    /// Share of the covered time the predictions named the same way.
    var labelAgreement: Double
    /// How many separate predictions it took.
    var fragments: Int
    /// 0–100.
    var score: Int

    var letter: String { Self.letter(score) }

    static func letter(_ score: Int) -> String {
        switch score {
        case 90...: return "A"
        case 80..<90: return "B"
        case 70..<80: return "C"
        case 60..<70: return "D"
        default: return "F"
        }
    }

    /// The settled stretch `start...end` named `kinds` (the first is the
    /// main one) against the original predictions that overlap it.
    static func grade(start: Double, end: Double, kinds: [String], predictions: [Piece]) -> CutGrade {
        let length = max(0.1, end - start)
        let overlapping = predictions.filter { $0.end > start && $0.start < end }
        guard !overlapping.isEmpty else {
            // Missed entirely: he had to add it.
            return CutGrade(recall: 0, precision: 0, labelAgreement: 0, fragments: 0, score: 0)
        }
        let spans = union(overlapping.map { ($0.start, $0.end) })
        let predicted = spans.reduce(0) { $0 + ($1.1 - $1.0) }
        let covered = spans.reduce(0) { $0 + max(0, min($1.1, end) - max($1.0, start)) }
        var agreeing = 0.0
        for p in overlapping where kinds.contains(p.kind) {
            agreeing += max(0, min(p.end, end) - max(p.start, start))
        }
        let recall = min(1, covered / length)
        let precision = predicted > 0 ? min(1, covered / predicted) : 0
        let agreement = covered > 0 ? min(1, agreeing / covered) : 0
        // Fragments: separate pieces once overlaps are joined. One piece is
        // right; every extra split costs a little.
        let pieces = spans.count
        var score = 100 * (0.55 * recall + 0.30 * precision + 0.15 * agreement)
        score -= Double(max(0, pieces - 1)) * 4
        return CutGrade(recall: recall, precision: precision, labelAgreement: agreement, fragments: pieces,
                        score: Int(max(0, min(100, score)).rounded()))
    }

    private static func union(_ spans: [(Double, Double)]) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for s in spans.sorted(by: { $0.0 < $1.0 }) where s.1 > s.0 {
            if let last = out.last, s.0 <= last.1 + SkipJoin.maxGap { out[out.count - 1].1 = max(last.1, s.1) }
            else { out.append(s) }
        }
        return out
    }
}
