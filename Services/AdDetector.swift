import Foundation
import FoundationModels

// MARK: - What we ask the model for

/// Guided generation: the framework constrains decoding so the model
/// physically cannot return malformed JSON, and `.anyOf` means `kind` comes
/// back as one of our labels rather than a sentence about them. This is why
/// on-device classification with a small model is usable at all.
@Generable
struct PassageVerdict {

    @Guide(description: """
        What this passage is. Use "advertisement" for a paid third-party \
        sponsor, "selfPromotion" when the show is selling its own things, \
        "crossPromotion" for another podcast, "introduction" for the opening \
        of the episode itself, "outro" for the sign-off or credits, and \
        "content" for the episode proper.
        """,
        .anyOf(["advertisement", "selfPromotion", "crossPromotion",
                "introduction", "outro", "content"]))
    let kind: String

    @Guide(description: "The brand, show, or thing being promoted. Empty string for content.")
    let subject: String

    @Guide(description: "How certain you are, from 0 to 100")
    let confidence: Int

    /// The two fields that make the cut land in the right place.
    ///
    /// A 45-second window almost never begins exactly where the ad begins.
    /// Cutting on window edges either ate the end of a sentence or left two
    /// seconds of sponsor hanging off the front. Asking for the first and
    /// last words lets the boundary be found in the transcript instead.
    @Guide(description: "The first four words of the promotional part, copied exactly from the passage. Empty for content.")
    let openingWords: String

    @Guide(description: "The last four words of the promotional part, copied exactly from the passage. Empty for content.")
    let closingWords: String
}

/// What the detector found, before it becomes an `AdSegment`.
struct DetectedSegment {
    var start: Double
    var end: Double
    var kind: SegmentKind
    var sponsor: String
    var confidence: Int
}

struct DetectionResult {
    var segments: [DetectedSegment] = []
    /// Sponsors seen in this episode, for the show to remember. A show reads
    /// the same four sponsors for months; knowing them is worth more than any
    /// amount of prompt engineering.
    var sponsors: [String] = []
}

enum AdDetectorError: LocalizedError {
    case modelUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let reason):
            return "On-device AI isn't available: \(reason)"
        }
    }
}

actor AdDetector {

    // MARK: - Instructions

    private static let baseInstructions = """
    You label passages from podcast transcripts. Every passage gets exactly
    one label.

    advertisement — a paid spot for someone else's product or service. A
    read-out commercial, or a host reading a sponsor script in their own
    casual voice. The tell is a second-person pitch, a call to action, a URL,
    or a discount code — not the mere mention of a brand.

    selfPromotion — the show selling its own things. Patreon, memberships,
    the ad-free feed, bonus episodes, merchandise, tour dates, tickets, live
    shows, the hosts' other projects, the network's other shows. This counts
    even when it is funny, rambling, or woven into the conversation, and even
    when no money is named. If the hosts are telling you to go somewhere and
    give them money or attention, it is selfPromotion.

    crossPromotion — a plug for a different podcast that is not theirs.

    introduction — the opening of the episode itself: the theme, the cold
    open, the hosts naming the show and saying what today is about.

    outro — the sign-off, the credits, the thanks, "see you next week".

    content — the actual episode. Conversation, interview, jokes, argument,
    reporting, a guest describing their own work, the hosts discussing a
    company as part of the topic, news about a business.

    Two things that are commonly got wrong:

    A sponsor read that is buried inside a bit is still an advertisement. The
    hosts riffing for ninety seconds about a mattress before saying the promo
    code is one advertisement, not content followed by an ad.

    Talking about the show's own Patreon or tour is never content, however
    long they spend on it and however much of it is joking around.
    """

    /// A show's own sponsors, folded into the instructions. Recognition is
    /// far more reliable than inference: the same four brands come back every
    /// week, and after one episode the model no longer has to work them out.
    private static func instructions(knownSponsors: [String]) -> String {
        guard !knownSponsors.isEmpty else { return baseInstructions }
        let list = knownSponsors.prefix(12).joined(separator: ", ")
        return baseInstructions + """


        This show has advertised these before, so a passage mentioning one is
        very likely an advertisement: \(list).
        """
    }

    // MARK: - Cheap prefilter

    /// Anything that looks nothing like a promotion never reaches the model,
    /// which cuts inference calls by roughly an order of magnitude on a
    /// typical episode. Neighbours of a hit are kept too, so the run-up and
    /// the tail of a sponsor read still get classified.
    private static let sponsorCues = [
        "sponsor", "sponsored", "promo code", "discount code", "coupon",
        "dot com slash", ".com/", "offer code", "free trial", "sign up at",
        "use code", "this episode is brought to you", "brought to you by",
        "supported by", "our partners at", "terms apply", "percent off",
        "% off", "download the app", "first-time customers", "free shipping",
        "cancel anytime", "start your", "that's spelled"
    ]

    /// The half of this the old detector had no idea about. Everything here
    /// is the show selling itself, which a listener experiences as an ad and
    /// the previous classifier waved straight through.
    private static let selfPromoCues = [
        "patreon", "our merch", "merch store", "t-shirts", "tour dates",
        "on tour", "tickets", "live show", "live shows", "bonus episode",
        "bonus episodes", "ad-free", "ad free feed", "early access",
        "subscribe to our", "join our", "membership", "our other show",
        "our other podcast", "on the network", "link in the description",
        "link in the show notes", "check out our", "rate and review",
        "five stars", "leave us a review", "follow us on", "hit subscribe",
        "support the show", "buy me a coffee", "venmo", "cameo"
    ]

    private static let crossPromoCues = [
        "another podcast", "podcast you should", "wherever you get your podcasts",
        "new podcast from", "listen to", "new series from"
    ]

    private static let bookendCues = [
        "welcome to", "welcome back to", "this is episode", "i'm your host",
        "thanks for listening", "see you next week", "see you next time",
        "until next time", "produced by", "edited by", "our theme music",
        "engineered by"
    ]

    private static var allCues: [String] {
        sponsorCues + selfPromoCues + crossPromoCues + bookendCues
    }

    static func availability() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            return String(describing: reason)
        @unknown default:
            return "unknown"
        }
    }

    // MARK: - Detection

    /// Classify an episode's transcript and return merged, boundary-snapped
    /// segments.
    ///
    /// - Parameters:
    ///   - windows: overlapping slices of the transcript, for the model.
    ///   - segments: the raw utterances with their timings, used to find
    ///     where inside a window a promotion actually starts and stops.
    ///   - silences: pauses measured from the audio. A break almost always
    ///     begins and ends in one, so snapping to them is what makes a cut
    ///     sound deliberate rather than sliced.
    ///   - knownSponsors: brands this show has advertised before.
    func detect(windows: [TranscriptWindow],
                segments: [TranscriptSegment] = [],
                silences: [ClosedRange<Double>] = [],
                knownSponsors: [String] = [],
                minimumConfidence: Int = 60,
                padding: Double = 0.4,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> DetectionResult {

        if let reason = Self.availability() {
            throw AdDetectorError.modelUnavailable(reason)
        }

        let candidates = Self.prefilter(windows)
        guard !candidates.isEmpty, let lastWindow = windows.last else { return DetectionResult() }

        let session = LanguageModelSession(instructions: Self.instructions(knownSponsors: knownSponsors))
        let duration = lastWindow.end
        let normalisedKnown = knownSponsors.map(Self.normalise)

        var found: [Int: DetectedSegment] = [:]
        var sponsors: [String] = []

        for (n, index) in candidates.enumerated() {
            let window = windows[index]
            defer { progress?(Double(n + 1) / Double(candidates.count)) }

            // Where we are in the episode is most of what separates an intro
            // from a mid-roll from a sign-off, and the model cannot see it
            // from the words alone.
            let percent = duration > 0 ? Int((window.start / duration) * 100) : 0
            let prompt = """
            This passage begins \(percent)% into the episode, at \
            \(Self.clock(window.start)) of \(Self.clock(duration)).

            \(window.text)
            """

            do {
                // A fresh classification per window, not a conversation —
                // there is nothing to carry forward, and it keeps every call
                // far away from the context limit.
                let reply = try await session.respond(to: prompt, generating: PassageVerdict.self)
                let verdict = reply.content
                guard let kind = SegmentKind(modelLabel: verdict.kind) else { continue }

                var confidence = verdict.confidence
                let subject = verdict.subject.trimmingCharacters(in: .whitespacesAndNewlines)

                // A brand this show has read before is not a guess.
                if !subject.isEmpty, normalisedKnown.contains(Self.normalise(subject)) {
                    confidence = min(100, confidence + 12)
                }
                if kind == .ad, !subject.isEmpty {
                    sponsors.append(subject)
                }

                let bounds = Self.bounds(for: verdict, in: window, segments: segments)
                found[index] = DetectedSegment(start: bounds.lowerBound,
                                               end: bounds.upperBound,
                                               kind: kind,
                                               sponsor: subject,
                                               confidence: confidence)
            } catch {
                // One bad window shouldn't sink the episode.
                continue
            }
        }

        let kept = Self.rescueNeighbours(found, minimumConfidence: minimumConfidence)
        let merged = Self.merge(kept, padding: padding)
        let snapped = merged.map { Self.snap($0, to: silences) }

        return DetectionResult(segments: snapped.filter { $0.end > $0.start + 1 },
                               sponsors: Array(Set(sponsors)).sorted())
    }

    // MARK: - Prefilter

    private static func prefilter(_ windows: [TranscriptWindow]) -> [Int] {
        var keep = Set<Int>()
        let cues = allCues
        for (i, w) in windows.enumerated() {
            let lower = w.text.lowercased()
            if cues.contains(where: { lower.contains($0) }) {
                keep.insert(i)
                if i > 0 { keep.insert(i - 1) }
                if i + 1 < windows.count { keep.insert(i + 1) }
            }
        }
        // The ends of an episode are promotional far more often than not, and
        // 90 seconds was short — plenty of shows open with two minutes of
        // sponsor before the theme.
        for (i, w) in windows.enumerated() where w.start < 150 {
            keep.insert(i)
        }
        if let last = windows.last {
            for (i, w) in windows.enumerated() where w.end > last.end - 150 {
                keep.insert(i)
            }
        }
        return keep.sorted()
    }

    // MARK: - Where the promotion actually starts

    /// Finds the quoted opening and closing words in the transcript and uses
    /// their timings, falling back to the window's own edges.
    private static func bounds(for verdict: PassageVerdict,
                               in window: TranscriptWindow,
                               segments: [TranscriptSegment]) -> ClosedRange<Double> {
        guard !segments.isEmpty else { return window.start...window.end }
        let inside = segments.filter { $0.start < window.end && $0.end > window.start }
        guard !inside.isEmpty else { return window.start...window.end }

        var start = window.start
        var end = window.end

        if let opener = match(verdict.openingWords, in: inside) {
            start = max(window.start, opener.start)
        }
        if let closer = match(verdict.closingWords, in: inside) {
            end = min(window.end, closer.end)
        }
        // A quote the model invented can invert the range. Ignore it rather
        // than cut backwards.
        guard end > start + 1 else { return window.start...window.end }
        return start...end
    }

    private static func match(_ quote: String, in segments: [TranscriptSegment]) -> TranscriptSegment? {
        let needle = normalise(quote)
        guard needle.count > 6 else { return nil }
        // Whole phrase first, then the leading half, because a model asked
        // for four words often gives three or five.
        if let exact = segments.first(where: { normalise($0.text).contains(needle) }) {
            return exact
        }
        let words = needle.split(separator: " ")
        guard words.count > 2 else { return nil }
        let shorter = words.prefix(words.count - 1).joined(separator: " ")
        guard shorter.count > 6 else { return nil }
        return segments.first(where: { normalise($0.text).contains(shorter) })
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Neighbours

    /// Ad breaks are contiguous. A window sitting between two confident hits,
    /// or immediately beside one, that the model called promotional but only
    /// at 45%, is part of the same break — and leaving it out is exactly how
    /// you get eight seconds of sponsor surviving in the middle of a cut.
    private static func rescueNeighbours(_ found: [Int: DetectedSegment],
                                         minimumConfidence: Int) -> [DetectedSegment] {
        let confident = Set(found.filter { $0.value.confidence >= minimumConfidence }.keys)
        guard !confident.isEmpty else { return [] }

        let rescueFloor = max(30, minimumConfidence - 25)
        var kept: [DetectedSegment] = []

        for (index, segment) in found.sorted(by: { $0.key < $1.key }) {
            if segment.confidence >= minimumConfidence {
                kept.append(segment)
                continue
            }
            // No `kind != .content` check: content isn't a case. A passage
            // the model called content never became a DetectedSegment in the
            // first place, because `SegmentKind(modelLabel:)` returns nil for
            // it and the window is dropped.
            guard segment.confidence >= rescueFloor else { continue }
            let touchesConfident = confident.contains(index - 1) || confident.contains(index + 1)
            if touchesConfident { kept.append(segment) }
        }
        return kept
    }

    // MARK: - Merging

    /// Overlapping windows produce overlapping hits. Fuse anything that
    /// touches or nearly touches into one continuous cut.
    private static func merge(_ segments: [DetectedSegment],
                              padding: Double,
                              gapTolerance: Double = 6) -> [DetectedSegment] {
        guard !segments.isEmpty else { return [] }
        let sorted = segments.sorted { $0.start < $1.start }
        var out: [DetectedSegment] = [sorted[0]]

        for segment in sorted.dropFirst() {
            let lastIndex = out.count - 1
            // Only fuse like with like. An ad that runs straight into the
            // show's own Patreon plug is two segments, because the user can
            // choose to skip one and keep the other.
            let sameFamily = out[lastIndex].kind == segment.kind
            if sameFamily, segment.start <= out[lastIndex].end + gapTolerance {
                out[lastIndex].end = Swift.max(out[lastIndex].end, segment.end)
                out[lastIndex].confidence = Swift.max(out[lastIndex].confidence, segment.confidence)
                if out[lastIndex].sponsor.isEmpty { out[lastIndex].sponsor = segment.sponsor }
            } else if segment.start < out[lastIndex].end {
                // Different kinds that overlap: give the earlier one the
                // ground up to where the later one starts.
                out[lastIndex].end = Swift.max(out[lastIndex].start, segment.start)
                out.append(segment)
            } else {
                out.append(segment)
            }
        }

        // Pull the boundaries in slightly. Better to leak half a second of ad
        // than to eat the first word of the thing you actually wanted to hear.
        return out.map {
            var s = $0
            s.start += padding
            s.end -= padding
            return s
        }
    }

    // MARK: - Snapping to silence

    /// Moves each edge to the nearest measured pause, if one is close.
    ///
    /// Transcript timings land mid-breath. A pause is where a producer would
    /// have put the join, so a cut made there is the difference between a
    /// skip you notice and one you don't.
    private static func snap(_ segment: DetectedSegment,
                             to silences: [ClosedRange<Double>],
                             tolerance: Double = 2.5) -> DetectedSegment {
        guard !silences.isEmpty else { return segment }
        var out = segment

        // Start: prefer the END of a pause just before it, so the cut begins
        // in silence rather than clipping the words ahead of it.
        if let before = silences
            .filter({ abs($0.upperBound - segment.start) <= tolerance })
            .min(by: { abs($0.upperBound - segment.start) < abs($1.upperBound - segment.start) }) {
            out.start = before.upperBound
        }

        // End: prefer the START of a pause just after it, for the same reason
        // in reverse.
        if let after = silences
            .filter({ abs($0.lowerBound - segment.end) <= tolerance })
            .min(by: { abs($0.lowerBound - segment.end) < abs($1.lowerBound - segment.end) }) {
            out.end = after.lowerBound
        }

        return out.end > out.start ? out : segment
    }

    // MARK: - Formatting

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
