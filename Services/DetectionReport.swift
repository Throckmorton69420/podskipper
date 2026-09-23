import Foundation
import SwiftData
import UIKit

// MARK: - Detection report and edit counts (pass 17: D7, research §6)
//
// Two things the lab can't get any other way:
// - How often the listener has to fix a cut ("rarely needs manual edits" is
//   a claim until it is counted). Counted from the cuts themselves, so it is
//   always current: confirmed, rejected, moved, added, locked.
// - His real corrections, as test episodes. One episode's report holds its
//   transcript (with word times), what the finder cut and what he made of
//   it; the lab turns that into a fixture labelled by him, not by Claude.

/// What the listener did to one episode's cuts.
struct EditCounts: Codable, Sendable {
    var detected = 0
    var confirmed = 0
    var rejected = 0
    var moved = 0
    var added = 0
    var locked = 0
    /// Anything he changed or overruled; confirming isn't a fix.
    var fixes: Int { rejected + moved + added }

    init() {}
    init(_ segments: [AdSegment]) {
        for s in segments {
            if s.isAdded { added += 1; continue }
            detected += 1
            if s.userVerdict == .confirmed { confirmed += 1 }
            if s.userVerdict == .notAnAd { rejected += 1 }
            if s.isEdited { moved += 1 }
            if s.isLocked { locked += 1 }
        }
    }

    static func + (a: EditCounts, b: EditCounts) -> EditCounts {
        var c = a
        c.detected += b.detected; c.confirmed += b.confirmed; c.rejected += b.rejected
        c.moved += b.moved; c.added += b.added; c.locked += b.locked
        return c
    }
}

enum DetectionReport {

    struct Cut: Codable {
        var kind: String
        var detail: String
        var start: Double
        var end: Double
        var detectedKind: String
        var detectedStart: Double
        var detectedEnd: Double
        var verdict: String
        var origin: String
        var locked: Bool
        var edited: Bool
        var delivery: String
        var comedyBit: Bool
        var insertedAtDownload: Bool
        var confidence: Int
        var startConfidence: Int
        var endConfidence: Int
        var sponsor: String
        var evidence: String
    }

    struct Report: Codable {
        var exportedAt = Date()
        var app: String
        var build: String
        var device: String
        var show: String
        var feed: String
        var episode: String
        var guid: String
        var enclosure: String
        var fileBytes: Int?
        var duration: Double
        var detectorVersion: Int
        var inserted: [InsertedSpan]
        var edits: EditCounts
        var cuts: [Cut]
        var transcript: [TimedLine]
    }

    /// One episode's report, written to a temporary JSON file for sharing.
    @MainActor static func file(for episode: Episode) throws -> URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let bytes = episode.localFileURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int
        }
        let cuts = episode.adSegments.sorted { $0.start < $1.start }.map { s in
            Cut(kind: s.kind.rawValue, detail: s.detailRaw, start: s.start, end: s.end,
                detectedKind: s.originalKind.rawValue, detectedStart: s.originalStart, detectedEnd: s.originalEnd,
                verdict: s.userVerdict.rawValue, origin: s.origin, locked: s.isLocked, edited: s.isEdited,
                delivery: s.deliveryRaw, comedyBit: s.isComedyBit, insertedAtDownload: s.insertedAtDownload,
                confidence: s.confidence, startConfidence: s.startConfidence, endConfidence: s.endConfidence,
                sponsor: s.sponsor, evidence: s.evidenceText)
        }
        let report = Report(
            app: "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            build: BuildInfo.commit, device: Diagnostics.deviceModel,
            show: episode.podcast?.title ?? "", feed: episode.podcast?.feedURL ?? "",
            episode: episode.title, guid: episode.guid, enclosure: episode.audioURL,
            fileBytes: bytes, duration: episode.duration, detectorVersion: episode.detectorVersion,
            inserted: episode.insertedSpans, edits: EditCounts(episode.adSegments),
            cuts: cuts, transcript: episode.timedTranscript)
        let data = try JSONEncoder.iso.encode(report)
        let safe = episode.title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined().prefix(40)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PodSkipper-detection-\(safe)-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url)
        return url
    }

    /// Every processed episode's edit counts, newest first, for Diagnostics.
    @MainActor static func editsByEpisode(_ context: ModelContext, limit: Int = 200) -> [(show: String, episode: String, edits: EditCounts)] {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.lastProcessedAt != nil },
            sortBy: [SortDescriptor(\.lastProcessedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        let episodes = (try? context.fetch(descriptor)) ?? []
        return episodes.map { ($0.podcast?.title ?? "", $0.title, EditCounts($0.adSegments)) }
    }
}

extension Episode {
    var insertedSpans: [InsertedSpan] {
        guard let insertedSpansData else { return [] }
        return (try? JSONDecoder().decode([InsertedSpan].self, from: insertedSpansData)) ?? []
    }

    var producedSpans: [AdPrints.Produced] {
        guard let producedSpansData else { return [] }
        return (try? JSONDecoder().decode([AdPrints.Produced].self, from: producedSpansData)) ?? []
    }
}
