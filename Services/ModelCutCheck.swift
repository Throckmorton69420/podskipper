import Foundation

/// Pass 30: every cut an open model proposes is checked against the
/// episode's own words and audio before it is saved.
///
/// His 5 Oct phone: Core AI Qwen3 4B marked about 47 of Bad Friends' 66
/// minutes ("Bobby Is Tone Tone Galore") as ads and MLX Qwen3.5 4B about 18,
/// while the reader and Apple Intelligence found the two real breaks
/// (≈ 8.5 min: Liquid IV / Rocket Money / TalkSpace, BlueChew / Shopify /
/// QUO). A single answer like that removes most of a show, so a model's cut
/// now stands only where something backs it:
///
/// - the reader cut the same stretch, or the audio proves it (stitched in by
///   the ad server «I», or a recording that plays elsewhere «R»); or
/// - the lines themselves sell: an offer, a code, a web address, a hand-off
///   ("brought to you by"), the sponsor's name, tickets and merch for a plug.
///
/// Unbacked stretches are cut down to the lines that sell, with room for a
/// lead-in and a sign-off; whatever is left with nothing selling is dropped.
/// Intros and outros have to sit at the edges of the episode. If even after
/// that the model's own cuts would take an implausible share of the
/// episode, its unbacked cuts are dropped altogether.
///
/// Model silence is not a veto: an ad the reader was sure of (or one the ad
/// server stitched in) stays cut unless the model explicitly called that
/// stretch the show (MOCK_AD or RECURRING_SEGMENT).
enum ModelCutCheck {
    /// Before the first selling line: a hand-off and the product's pitch.
    static let leadIn: Double = 50
    /// After the last selling line: the repeated address, "that's…", the
    /// small print read fast (Progressive's 30 s of "savings vary").
    static let tail: Double = 35
    /// Selling stretches this close together are one read.
    static let joinGap: Double = 90
    /// Longest stretch kept on the model's word alone, by kind.
    static func cap(_ kind: SegmentKind) -> Double {
        switch kind {
        case .ad: return 330
        case .selfPromo, .crossPromo: return 200
        case .intro, .outro: return 150
        }
    }
    /// The model's unbacked cuts may not take more than this of an episode.
    static func ceiling(duration: Double) -> Double { max(600, duration * 0.3) }

    struct Outcome {
        /// What the model asked for, before the check.
        var proposed: [DetectedSegment] = []
        var cuts: [DetectedSegment]
        /// One plain line per change, for the background log and Diagnostics.
        var notes: [String]
        /// Seconds the model asked for that were not kept.
        var droppedSeconds: Double
    }

    static func verify(_ proposed: [DetectedSegment], lines: [TimedLine], readerCuts: [DetectedSegment],
                       evidence: [EvidenceSpan], keeps: [ClosedRange<Double>], duration: Double) -> Outcome {
        let end = max(duration, lines.last?.end ?? 0)
        var notes: [String] = []
        var dropped = 0.0
        var backed: [DetectedSegment] = []
        var unbacked: [DetectedSegment] = []

        for cut in proposed {
            if cut.insertedAtDownload { backed.append(cut); continue }
            let support = backing(for: cut, readerCuts: readerCuts, evidence: evidence)
            let pieces = kept(cut, lines: lines, support: support, duration: end)
            let keptSeconds = pieces.reduce(0.0) { $0 + ($1.cut.end - $1.cut.start) }
            let asked = cut.end - cut.start
            if keptSeconds + 1 < asked {
                dropped += asked - keptSeconds
                notes.append(pieces.isEmpty
                    ? "dropped \(clock(cut.start))–\(clock(cut.end)) \(cut.kind.rawValue): nothing in it sells and nothing else found it"
                    : "trimmed \(clock(cut.start))–\(clock(cut.end)) \(cut.kind.rawValue) to the \(Int(keptSeconds)) s that sell")
            }
            for piece in pieces {
                if piece.backed { backed.append(piece.cut) } else { unbacked.append(piece.cut) }
            }
        }

        let modelOnly = unbacked.reduce(0) { $0 + ($1.end - $1.start) }
        if modelOnly > ceiling(duration: end) {
            notes.append("the model's own cuts came to \(Int(modelOnly / 60)) min of a \(Int(end / 60))-min episode; only the ones something else backs were kept")
            dropped += modelOnly
            unbacked = []
        }

        var cuts = backed + unbacked
        // The reader's sure ads stay unless the model said they are the show.
        for reader in readerCuts where reader.insertedAtDownload || (reader.kind == .ad && reader.confidence >= 90) {
            let covered = cuts.contains { overlap(reader, $0.start, $0.end) >= 0.5 }
            let vetoed = keeps.contains { overlap(reader, $0.lowerBound, $0.upperBound) >= 0.5 }
            guard !covered, !vetoed else { continue }
            var kept = reader
            kept.evidence.append("kept from PodSkipper's reader: the model didn't mention this stretch")
            cuts.append(kept)
            notes.append("kept the reader's \(reader.kind.rawValue) at \(clock(reader.start)) (\(Int(reader.end - reader.start)) s) the model left out")
        }
        return Outcome(proposed: proposed, cuts: merge(cuts), notes: notes, droppedSeconds: dropped)
    }

    // MARK: Pieces

    private struct Piece { var cut: DetectedSegment; var backed: Bool }

    /// Time ranges something other than the model vouches for, padded a little.
    private static func backing(for cut: DetectedSegment, readerCuts: [DetectedSegment],
                                evidence: [EvidenceSpan]) -> [ClosedRange<Double>] {
        let pad = 8.0
        var ranges = readerCuts.filter { $0.end > cut.start && $0.start < cut.end }
            .map { ($0.start - pad)...($0.end + pad) }
        ranges += evidence.filter { $0.end > cut.start && $0.start < cut.end }
            .map { ($0.start - pad)...($0.end + pad) }
        return ranges
    }

    /// What of `cut` survives: backed stretches, plus the lines that sell
    /// with a lead-in and a tail, inside the model's own edges.
    private static func kept(_ cut: DetectedSegment, lines: [TimedLine], support: [ClosedRange<Double>],
                             duration: Double) -> [Piece] {
        var ranges = support
        let inside = lines.indices.filter {
            let mid = (lines[$0].start + lines[$0].end) / 2
            return mid >= cut.start && mid <= cut.end
        }
        switch cut.kind {
        case .intro, .outro:
            // Openers and sign-offs live at the edges of an episode.
            let atEdge = cut.kind == .intro ? cut.start <= 240 : cut.end >= duration - 420
            if atEdge, cut.end - cut.start <= cap(cut.kind) { ranges.append(cut.start...cut.end) }
        case .ad, .selfPromo, .crossPromo:
            let brand = brandTokens(cut.sponsor)
            var selling: [Int] = []
            for i in inside where sells(lines[i].text, kind: cut.kind, brand: brand) { selling.append(i) }
            for i in selling {
                ranges.append((lines[i].start - leadIn)...(lines[i].end + tail))
            }
        }
        // Join and clip to the model's own edges.
        var joined: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let a = max(r.lowerBound, cut.start), b = min(r.upperBound, cut.end)
            guard b > a else { continue }
            // Inside one stretch the model called a single part, selling
            // lines a short gap apart are one read, not two with a hole.
            if let last = joined.last, a <= last.upperBound + joinGap {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, b)
            } else {
                joined.append(a...b)
            }
        }
        var pieces: [Piece] = []
        for r in joined {
            // On line edges, so a cut never starts or ends mid-sentence.
            let members = inside.filter { lines[$0].end > r.lowerBound && lines[$0].start < r.upperBound }
            // The model's own edge stays where it is (music before the first
            // word of a jingle is part of it); only edges the check made snap.
            let start = r.lowerBound <= cut.start + 0.5 ? cut.start
                : members.first.map { max(cut.start, lines[$0].start) } ?? r.lowerBound
            let stop = r.upperBound >= cut.end - 0.5 ? cut.end
                : members.last.map { min(cut.end, lines[$0].end) } ?? r.upperBound
            guard stop - start >= 6 else { continue }
            let span = stop - start
            let vouched = support.reduce(0) { $0 + max(0, min($1.upperBound, stop) - max($1.lowerBound, start)) }
            let isBacked = vouched >= 0.5 * span
            if !isBacked, span > cap(cut.kind) {
                let brand = brandTokens(cut.sponsor)
                let sellingCount = members.filter { sells(lines[$0].text, kind: cut.kind, brand: brand) }.count
                // A long stretch on the model's word alone needs selling all through it.
                guard Double(sellingCount) >= span / 45 else { continue }
            }
            var piece = cut
            piece.start = start
            piece.end = stop
            if start > cut.start + 1 || stop < cut.end - 1 {
                piece.evidence.append("trimmed to the lines that sell")
            }
            pieces.append(Piece(cut: piece, backed: isBacked))
        }
        return pieces
    }

    /// Whether one line does what this kind of cut does.
    static func sells(_ text: String, kind: SegmentKind, brand: [String]) -> Bool {
        let lower = text.lowercased()
        if SegmentDetector.offersSomething(lower) || SegmentDetector.opensAnAd(text) { return true }
        if !brand.isEmpty {
            let flat = AdDetector.normalise(text).replacingOccurrences(of: " ", with: "")
            if brand.contains(where: { flat.contains($0) }) { return true }
        }
        switch kind {
        case .ad:
            return false
        case .selfPromo:
            let plugs = ["tickets", "on tour", "tour dates", "merch", "patreon", "subscribe", "rate and review",
                         "five star", "5 star", "youtube channel", "instagram", "follow me", "follow us",
                         "link in the", "in the description", "come see", "special is out", "my special", "new special",
                         "bonus episode", "premium feed", "live show", "go see", "pre-order", "preorder", "out now",
                         "go get it", "new episodes", "on spotify", "on youtube", "theater", "theatre", "dates",
                         "become a member", "support the show", "newsletter", "available for"]
            return plugs.contains { lower.contains($0) } || SegmentDetector.strongCues.contains { lower.contains($0) }
        case .crossPromo:
            let promo = ["check out", "new show", "listen to", "wherever you get your podcasts", "new episodes",
                         "subscribe", "podcast called", "series"]
            return promo.contains { lower.contains($0) } || SegmentDetector.promoCues.contains { lower.contains($0) }
        case .intro, .outro:
            return false
        }
    }

    /// The sponsor as squashed lowercase pieces worth matching ("liquidiv").
    static func brandTokens(_ sponsor: String) -> [String] {
        let words = AdDetector.normalise(sponsor).split(separator: " ").map(String.init)
        let squashed = words.joined()
        var tokens = words.filter { $0.count >= 4 && !["with", "from", "your", "show", "this"].contains($0) }
        if squashed.count >= 4 { tokens.append(squashed) }
        return Array(Set(tokens))
    }

    // MARK: Helpers

    /// Overlapping cuts of the same kind become one (back-to-back reads that
    /// only touch stay apart, each with its sponsor); sorted by start.
    static func merge(_ cuts: [DetectedSegment]) -> [DetectedSegment] {
        var out: [DetectedSegment] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if let i = out.indices.last, out[i].kind == cut.kind, cut.start < out[i].end - 0.5 {
                out[i].end = max(out[i].end, cut.end)
                out[i].confidence = max(out[i].confidence, cut.confidence)
                out[i].insertedAtDownload = out[i].insertedAtDownload || cut.insertedAtDownload
                if out[i].sponsor.isEmpty { out[i].sponsor = cut.sponsor }
            } else {
                out.append(cut)
            }
        }
        return out.filter { $0.end > $0.start + 1 }
    }

    static func overlap(_ cut: DetectedSegment, _ start: Double, _ end: Double) -> Double {
        let length = cut.end - cut.start
        guard length > 0 else { return 0 }
        return max(0, min(cut.end, end) - max(cut.start, start)) / length
    }

    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
}
