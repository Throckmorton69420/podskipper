import Foundation
import SwiftData

/// One thing he settled, with what the detector had said about it.
struct CorrectionDelta: Codable, Sendable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    /// "lock", "notAnAd", "confirm", "add".
    var action: String
    /// The stretch as he left it (for "notAnAd", the stretch he rejected).
    var start: Double
    var end: Double
    var kind: String
    /// Every kind it holds (first is the main one).
    var contains: [String]
    /// The detector's original cuts in or across it.
    var predictions: [CutGrade.Piece]
    var grade: CutGrade
    /// Who found the episode's ads at the time ("Found by Gemma 4 E4B…").
    var finder: String
    /// Cuts of the detector's that this one took in.
    var absorbed: Int
    /// Which segment it was, by the detector's original edges.
    var key: String
}

/// Pass 31 (his 6 Oct message): his edits as graded feedback, and locking a
/// cut over the detector's fragments merges them.
///
/// - Lock a cut that covers other, unlocked cuts (≥ 80 % of each inside
///   it): those cuts go from What Was Skipped, and what they said (edges,
///   kind, sponsor, confidence, evidence) is kept on the locked cut.
/// - Each settled stretch is graded against the detector's original cuts
///   (`CutGrade`) and kept on the episode, so the results export shows the
///   original answer, his answer and the grade side by side.
/// - The gaps he bridged become a lesson for the show (`BreakBridge`): next
///   time, cuts that close together on this show are joined.
/// - Grades add up per finder (`FinderGrades`), so the model that does best
///   on his own corrections can be told apart from the one that does best
///   on the two test samples.
enum CorrectionLedger {
    static let perEpisodeLimit = 60
    /// Cuts this much inside a locked one are taken in by it.
    static let absorbShare = 0.8

    static func deltas(for episode: Episode) -> [CorrectionDelta] {
        guard let data = episode.correctionLogData else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([CorrectionDelta].self, from: data)) ?? []
    }

    static func pieces(_ segment: AdSegment) -> [CutGrade.Piece] {
        var out: [CutGrade.Piece] = []
        if !segment.isAdded {
            out.append(CutGrade.Piece(start: segment.originalStart, end: segment.originalEnd,
                                      kind: segment.originalKind.rawValue, detail: segment.detailRaw,
                                      sponsor: segment.sponsor, confidence: segment.confidence,
                                      delivery: segment.deliveryRaw, evidence: String(segment.evidenceText.prefix(300))))
        }
        if let data = segment.mergedFromData, let merged = try? JSONDecoder().decode([CutGrade.Piece].self, from: data) {
            out += merged
        }
        return out
    }

    static func key(_ segment: AdSegment) -> String {
        String(format: "%.2f-%.2f", segment.originalStart, segment.originalEnd)
    }

    static func kinds(_ segment: AdSegment) -> [String] {
        var all = [segment.kind.rawValue]
        for k in segment.containsRaw.split(separator: ",").map(String.init) where !all.contains(k) { all.append(k) }
        return all
    }

    /// He locked `segment`. Takes in the unlocked cuts it covers, grades it,
    /// files the bridged gaps for the show. Returns how many it took in.
    @discardableResult
    static func locked(_ segment: AdSegment, in episode: Episode, context: ModelContext) -> Int {
        let others = episode.adSegments.filter {
            $0 !== segment && !$0.isLocked && overlapShare($0, segment.start, segment.end) >= absorbShare
        }
        var merged: [CutGrade.Piece] = []   // the absorbed cuts' own predictions
        var containsKinds = kinds(segment)
        for other in others {
            merged += pieces(other)
            for k in [other.originalKind.rawValue, other.kind.rawValue] where !containsKinds.contains(k) {
                containsKinds.append(k)
            }
            if segment.sponsor.isEmpty, !other.sponsor.isEmpty { segment.sponsor = other.sponsor }
        }
        if !merged.isEmpty {
            var existing: [CutGrade.Piece] = []
            if let data = segment.mergedFromData { existing = (try? JSONDecoder().decode([CutGrade.Piece].self, from: data)) ?? [] }
            segment.mergedFromData = try? JSONEncoder().encode(existing + merged)
            for other in others { context.delete(other) }
        }
        segment.containsRaw = containsKinds.dropFirst().joined(separator: ",")
        let predictions = pieces(segment)
        fileBridges(segment, predictions: predictions, episode: episode)
        record(CorrectionDelta(date: .now, action: segment.isAdded && predictions.isEmpty ? "add" : "lock",
                               start: segment.start, end: segment.end, kind: segment.kind.rawValue,
                               contains: containsKinds, predictions: predictions,
                               grade: CutGrade.grade(start: segment.start, end: segment.end, kinds: containsKinds,
                                                     predictions: predictions),
                               finder: episode.finderNote, absorbed: others.count, key: key(segment)),
               on: episode)
        return others.count
    }

    /// He moved an edge or changed the type without locking: graded as it
    /// stands now (the next change or the lock replaces it).
    static func edited(_ segment: AdSegment, in episode: Episode) {
        let predictions = pieces(segment)
        let kinds = kinds(segment)
        record(CorrectionDelta(date: .now, action: segment.isAdded ? "add" : "edit",
                               start: segment.start, end: segment.end, kind: segment.kind.rawValue,
                               contains: kinds, predictions: predictions,
                               grade: CutGrade.grade(start: segment.start, end: segment.end, kinds: kinds,
                                                     predictions: predictions),
                               finder: episode.finderNote, absorbed: 0, key: key(segment)),
               on: episode)
    }

    /// A thumbs up or down on a cut as the detector left it.
    static func verdict(_ verdict: UserVerdict, on segment: AdSegment, in episode: Episode) {
        guard !segment.isAdded else { return }
        let predictions = pieces(segment)
        switch verdict {
        case .notAnAd:
            // Everything it said here was wrong.
            record(CorrectionDelta(date: .now, action: "notAnAd", start: segment.originalStart, end: segment.originalEnd,
                                   kind: "show", contains: [], predictions: predictions,
                                   grade: CutGrade(recall: 0, precision: 0, labelAgreement: 0,
                                                   fragments: predictions.count, score: 0),
                                   finder: episode.finderNote, absorbed: 0, key: key(segment)), on: episode)
        case .confirmed:
            let kinds = kinds(segment)
            record(CorrectionDelta(date: .now, action: "confirm", start: segment.start, end: segment.end,
                                   kind: segment.kind.rawValue, contains: kinds, predictions: predictions,
                                   grade: CutGrade.grade(start: segment.start, end: segment.end, kinds: kinds,
                                                         predictions: predictions),
                                   finder: episode.finderNote, absorbed: 0, key: key(segment)), on: episode)
        case .unreviewed:
            forget(key: key(segment), on: episode)
        }
    }

    /// The episode's grade: each settled stretch's score, weighted by its
    /// length. Nil until he has settled something.
    static func episodeGrade(_ episode: Episode) -> (score: Int, letter: String, count: Int)? {
        let all = deltas(for: episode)
        guard !all.isEmpty else { return nil }
        var weight = 0.0, sum = 0.0
        for d in all {
            let w = max(5, d.end - d.start)
            weight += w; sum += w * Double(d.grade.score)
        }
        let score = Int((sum / max(1, weight)).rounded())
        return (score, CutGrade.letter(score), all.count)
    }

    // MARK: Private

    private static func record(_ delta: CorrectionDelta, on episode: Episode) {
        var all = deltas(for: episode).filter { $0.key != delta.key }
        all.append(delta)
        if all.count > perEpisodeLimit { all.removeFirst(all.count - perEpisodeLimit) }
        episode.correctionLogData = try? JSONEncoder.iso.encode(all)
        FinderGrades.note(episode: episode)
    }

    private static func forget(key: String, on episode: Episode) {
        let all = deltas(for: episode).filter { $0.key != key }
        episode.correctionLogData = all.isEmpty ? nil : try? JSONEncoder.iso.encode(all)
        FinderGrades.note(episode: episode)
    }

    /// The gaps between the detector's pieces inside a locked plug or ad
    /// stretch: he says they were not the show. The largest becomes a
    /// lesson for the show.
    private static func fileBridges(_ segment: AdSegment, predictions: [CutGrade.Piece], episode: Episode) {
        guard [.ad, .selfPromo, .crossPromo].contains(segment.kind), let show = episode.podcast else { return }
        let inside = predictions.filter { $0.end > segment.start && $0.start < segment.end }
            .map { (max($0.start, segment.start), min($0.end, segment.end)) }
            .sorted { $0.0 < $1.0 }
        guard inside.count > 1 else { return }
        var widest: (gap: Double, from: Double, to: Double)?
        var reach = inside[0].1
        for piece in inside.dropFirst() {
            let gap = piece.0 - reach
            if gap > SkipJoin.maxGap, gap > (widest?.gap ?? 0) { widest = (gap, reach, piece.0) }
            reach = max(reach, piece.1)
        }
        guard let widest, widest.gap <= BreakBridge.learnedLimit else { return }
        let words = episode.words(in: widest.from...widest.to)
        show.recordCorrection(DetectionCorrection(excerpt: words.isEmpty ? "(no words)" : words, kind: segment.kind,
                                                  boundary: BreakBridge.lessonTag(widest.gap)))
    }

    private static func overlapShare(_ s: AdSegment, _ start: Double, _ end: Double) -> Double {
        let length = s.end - s.start
        guard length > 0 else { return 0 }
        return max(0, min(s.end, end) - max(s.start, start)) / length
    }
}

/// Pass 31: how each finder (reader, Apple Intelligence, each MLX or Core AI
/// model) has done on the episodes he corrected, kept on the phone. His
/// real episodes, not the two test samples.
enum FinderGrades {
    private static let key = "finderGrades.v1"

    /// finder → [episode guid → score]
    static var all: [String: [String: Int]] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Int]]) ?? [:]
    }

    static func note(episode: Episode) {
        var table = all
        let finder = finderName(episode.finderNote)
        for name in table.keys { table[name]?[episode.guid] = nil }
        if let grade = CorrectionLedger.episodeGrade(episode) {
            table[finder, default: [:]][episode.guid] = grade.score
        }
        UserDefaults.standard.set(table.filter { !$0.value.isEmpty }, forKey: key)
    }

    /// "Gemma 4 E4B" from "Found by Gemma 4 E4B, reading …"; the reader
    /// and Apple Intelligence by name.
    static func finderName(_ note: String) -> String {
        if note.contains("reader") { return "PodSkipper's reader" }
        if note.contains("Apple Intelligence") { return "Apple Intelligence" }
        var name = note.replacingOccurrences(of: "Found by ", with: "")
        if let cut = name.range(of: ",") ?? name.range(of: "'s fast check") { name = String(name[..<cut.lowerBound]) }
        return name.isEmpty ? "unknown" : name
    }

    /// Average score and how many episodes, for one finder.
    static func summary(for finder: String) -> (score: Int, episodes: Int)? {
        guard let scores = all[finder], !scores.isEmpty else { return nil }
        let total = scores.values.reduce(0, +)
        return (Int((Double(total) / Double(scores.count)).rounded()), scores.count)
    }
}
