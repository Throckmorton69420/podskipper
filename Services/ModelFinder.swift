import Foundation

/// The on-device model as the ad finder (cloud task 05).
///
/// PodSkipper's reader still runs first on every job: it takes seconds,
/// locked or not, and its cuts are kept on the episode for comparison. When
/// the model is the chosen finder and downloaded, its parts then replace the
/// reader's cuts. This file holds the pieces that don't touch the pipeline's
/// state: which stretches a fast read looks at, the listener's past
/// corrections as a prompt block, and the model's parts turned into cuts.
enum ModelFinder {
    /// Stamped on an episode whose cuts the model made (`Episode.modelVersion`).
    /// Kept apart from `AdDetector.version` so a new reader doesn't send
    /// every old episode through the model.
    static let version = 1
    /// Tries per job before the reader's cuts are kept for now.
    static let attempts = 3
    static let retryWait: Duration = .seconds(8)
    /// Old episodes re-read by the model on their own, per day, only while
    /// the app is open and charging.
    static let oldEpisodesPerDay = 5
    /// Corrections handed to the model, newest first.
    static let correctionLimit = 20

    enum Mode: String, Codable, Sendable {
        /// Every line, with the app open.
        case full
        /// Only the suspicious stretches, with the phone locked.
        case fast
    }

    /// One job's ad finding, for Diagnostics and the background log.
    struct Run: Codable, Sendable, Equatable {
        /// "model" or "reader": whose cuts were saved.
        var finder: String
        var mode: String?
        var windows = 0
        var seconds = 0.0
        var tokensPerSecond = 0.0
        var attempts = 0
        /// Why the model's cuts weren't used, in words.
        var failure: String?

        var byModel: Bool { finder == "model" }

        /// "Ads found in 94 s by the on-device model (full read)".
        func logLine(totalSeconds: Double) -> String {
            let seconds = Int(totalSeconds.rounded())
            if byModel {
                let how = mode == Mode.fast.rawValue ? "fast read, phone locked" : "full read"
                return "Ads found in \(seconds) s by the on-device model (\(how))"
            }
            return "Ads found in \(seconds) s by PodSkipper's reader"
                + (failure.map { " · the on-device model wasn't used: \($0)" } ?? "")
        }
    }

    // MARK: What the model is shown

    /// «I» for audio the host's ad-free copy doesn't have, «R» for a
    /// recording that plays elsewhere too.
    static func evidence(inserted: [InsertedSpan], produced: [AdPrints.Produced]) -> [EvidenceSpan] {
        inserted.map { EvidenceSpan(start: $0.start, end: $0.end, kind: .inserted) }
            + produced.filter { !$0.negative }.map { EvidenceSpan(start: $0.start, end: $0.end, kind: .repeated) }
    }

    /// The lines a fast read looks at: every reader cut ±90 s, the first and
    /// last 3 minutes, every «I»/«R» span ±30 s and every SponsorBlock hint
    /// ±60 s. The engine adds 40 lines either side of each.
    static func fastRanges(lines: [TimedLine], readerCuts: [DetectedSegment], duration: Double,
                           evidence: [EvidenceSpan], hints: [ClosedRange<Double>]) -> [Range<Int>] {
        guard !lines.isEmpty else { return [] }
        let end = Swift.max(duration, lines.last?.end ?? 0)
        func span(_ a: Double, _ b: Double, _ pad: Double) -> ClosedRange<Double> {
            Swift.max(0, Swift.min(a, b) - pad)...(Swift.max(a, b) + pad)
        }
        var spans: [ClosedRange<Double>] = [span(0, 0, 180), span(end, end, 180)]
        spans += readerCuts.map { span($0.start, $0.end, 90) }
        spans += evidence.map { span($0.start, $0.end, 30) }
        spans += hints.map { span($0.lowerBound, $0.upperBound, 60) }

        var ranges: [Range<Int>] = []
        for time in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard let first = lines.firstIndex(where: { $0.end >= time.lowerBound }),
                  let last = lines.lastIndex(where: { $0.start <= time.upperBound }),
                  first <= last else { continue }
            let range = first..<(last + 1)
            if let previous = ranges.last, range.lowerBound <= previous.upperBound {
                ranges[ranges.count - 1] = previous.lowerBound..<Swift.max(previous.upperBound, range.upperBound)
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }

    /// "This listener's past corrections on this show", newest first, as a
    /// short block before the transcript. The rules themselves stay as
    /// benchmarked. Edge lessons (a dragged handle) are a few words at an
    /// edge, not an example of what a part is, so they are left out.
    static func correctionsBlock(_ corrections: [DetectionCorrection]) -> String {
        let passages = corrections.filter { $0.boundary == nil }
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(correctionLimit)
        guard !passages.isEmpty else { return "" }
        var text = "This listener's past corrections on this show (newest first):"
        for correction in passages {
            // Short: twenty of these still leave the window its room.
            let excerpt = correction.excerpt.count > 200
                ? String(correction.excerpt.prefix(200)) + "…" : correction.excerpt
            if let kind = correction.kind {
                text += "\n- CUT, \(label(forKind: kind)): \"\(excerpt)\""
            } else {
                text += "\n- KEEP, not an ad or promo: \"\(excerpt)\""
            }
        }
        return text
    }

    /// The app's kind in the prompt's own label words.
    static func label(forKind kind: String) -> String {
        switch SegmentKind(rawValue: kind) {
        case .ad: return "PAID_AD or HOST_READ_AD"
        case .selfPromo: return "SELF_PROMO or GUEST_PLUG"
        case .crossPromo: return "NETWORK_PROMO"
        case .intro: return "INTRO"
        case .outro: return "OUTRO"
        case nil: return kind
        }
    }

    // MARK: What the model found, as cuts

    /// The model's parts as the app's cuts.
    ///
    /// Labels map to kinds as `KIND` in gemini_bench.py; CREDITS becomes an
    /// outro, which is the app's kind for "the sign-off and credits". Start
    /// and end are the first line's start and the last line's end (the
    /// engine has already anchored them on the quoted words), then the
    /// listener's padding and the snap to a measured pause, as the reader's
    /// cuts get. Stretches the ad-free comparison proved were stitched in are
    /// cut even if the model missed them. RECURRING_SEGMENT and MOCK_AD are
    /// kept: nothing is cut there but those proven stitched-in stretches.
    static func cuts(from parts: [JudgedPart], lines: [TimedLine], readerCuts: [DetectedSegment],
                     inserted: [InsertedSpan], silences: [ClosedRange<Double>],
                     padding: Double, duration: Double) -> [DetectedSegment] {
        var cuts: [DetectedSegment] = []
        for part in parts where part.isCut {
            guard lines.indices.contains(part.firstLine), lines.indices.contains(part.lastLine),
                  part.firstLine <= part.lastLine else { continue }
            let kind = part.label.segmentKind ?? .outro
            var cut = DetectedSegment(start: lines[part.firstLine].start + padding,
                                      end: lines[part.lastLine].end - padding,
                                      kind: kind, sponsor: part.sponsor,
                                      confidence: Swift.min(100, Swift.max(0, part.confidence)),
                                      evidence: ["On-device model: \(part.why)"])
            if kind == .ad {
                cut.style = AdDetector.AdStyle(hostRead: part.label == .hostReadAd, comedyBit: part.funny)
            }
            cuts.append(AdDetector.snap(cut, to: silences, tolerance: 0.8))
        }
        cuts = AdDetector.extendBookends(cuts, duration: duration)

        // Proven stitched in: the reader's own cut for it when there is one
        // (it carries the sponsor and delivery), otherwise the span itself.
        var stitched = readerCuts.filter(\.insertedAtDownload)
        for span in inserted where !stitched.contains(where: { overlap($0, span.start, span.end) > 0.5 }) {
            stitched.append(DetectedSegment(start: span.start, end: span.end, kind: .ad, sponsor: "",
                                            confidence: 100, evidence: ["Not in the host's ad-free copy"],
                                            insertedAtDownload: true))
        }
        for cut in stitched where !cuts.contains(where: { overlap(cut, $0.start, $0.end) >= 0.9 }) {
            cuts.append(cut)
        }
        return cuts.filter { $0.end > $0.start + 1 }.sorted { $0.start < $1.start }
    }

    /// How much of `cut` lies inside start…end, 0–1.
    private static func overlap(_ cut: DetectedSegment, _ start: Double, _ end: Double) -> Double {
        let length = cut.end - cut.start
        guard length > 0 else { return 0 }
        return Swift.max(0, Swift.min(cut.end, end) - Swift.max(cut.start, start)) / length
    }

    // MARK: Stored on the episode

    /// The reader's cuts as saved on the episode (`readerSegmentsData`), so
    /// both answers exist for comparison.
    struct StoredCut: Codable, Sendable, Equatable {
        var start: Double
        var end: Double
        var kind: String
        var sponsor: String
        var confidence: Int
        var delivery: String
        var comedyBit: Bool
        var insertedAtDownload: Bool
        var evidence: String
    }

    static func encode(_ cuts: [DetectedSegment]) -> Data? {
        let stored = cuts.map { cut in
            StoredCut(start: cut.start, end: cut.end, kind: cut.kind.rawValue, sponsor: cut.sponsor,
                      confidence: cut.confidence,
                      delivery: cut.style.map { $0.hostRead ? "host" : "produced" } ?? "",
                      comedyBit: cut.style?.comedyBit ?? false,
                      insertedAtDownload: cut.insertedAtDownload,
                      evidence: cut.evidence.joined(separator: " · "))
        }
        return try? JSONEncoder().encode(stored)
    }
}
