import Foundation
import FoundationModels

// MARK: - What we ask the model for

/// Guided generation: the framework constrains decoding so the model
/// physically cannot return malformed JSON, and `.anyOf` means `kind` comes
/// back as one of our labels rather than a sentence about them. This is why
/// on-device classification with a small model is usable at all.
///
/// The field **order** is doing real work here. Guided generation fills these
/// in one after another, and each one is written with the earlier ones already
/// in front of the model — so asking for the evidence before the label makes
/// the label better. `callToAction` and `stance` come first for exactly that
/// reason, and they are the two fields that fix the failure this file is named
/// after below.
@Generable
struct PassageVerdict {

    /// The single most useful question to ask about a podcast passage, and the
    /// one nobody was asking.
    ///
    /// Two hosts spending three minutes tearing into Barstool Sports and two
    /// hosts reading a Barstool ad contain the same brand the same number of
    /// times. What separates them is that one of them tells you to go and do
    /// something. Nothing else is as reliable — not tone, not enthusiasm, not
    /// how long they spend on it.
    @Guide(description: """
        The exact instruction the listener is given, if there is one — a web \
        address, a promo code, "go to", "sign up", "download", "use code", \
        "get tickets". Copy it from the passage. If the passage does not tell \
        the listener to do anything, leave this empty.
        """)
    let callToAction: String

    @Guide(description: """
        "promoting" if the speaker is recommending or selling this thing to \
        the listener. "discussing" if they are only talking about it — \
        reporting on it, joking about it, criticising it, arguing about it, \
        or answering a question about it.
        """,
        .anyOf(["promoting", "discussing"]))
    let stance: String

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

    Three things that are commonly got wrong:

    Talking about a company is not advertising it. Hosts arguing about a
    brand, making fun of it, reporting on what it did, complaining about it,
    or answering a listener's question about it is content — even when the
    name comes up twenty times, even when one of them likes it, and even if
    the same brand sponsors the show in some other episode. Criticism is
    never an advertisement. If nobody is being told to go anywhere, buy
    anything, or use a code, it is content.

    A sponsor read that is buried inside a bit is still an advertisement. The
    hosts riffing for ninety seconds about a mattress before saying the promo
    code is one advertisement, not content followed by an ad.

    Talking about the show's own Patreon or tour is never content, however
    long they spend on it and however much of it is joking around.

    Some passages come with a little of the surrounding conversation for
    context. Label only the passage itself. The context is there so you can
    tell a sponsor read from a conversation that happens to mention a brand.
    """

    /// A show's own sponsors, folded into the instructions. Recognition is
    /// far more reliable than inference: the same four brands come back every
    /// week, and after one episode the model no longer has to work them out.
    private static func instructions(knownSponsors: [String],
                                     corrections: [DetectionCorrection] = []) -> String {
        // Scrubbed before it goes anywhere near the instructions. These names
        // came out of a model reading a podcast, which makes them untrusted
        // text, and instructions are the one place that outranks the prompt —
        // so they are reduced to short plain words and nothing else.
        let safe = knownSponsors
            .map { $0.components(separatedBy: CharacterSet.alphanumerics
                                    .union(.whitespaces).inverted).joined() }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 40 }
            .prefix(12)

        var text = baseInstructions

        if !safe.isEmpty {
            // Deliberately weaker than it used to be. "Very likely an
            // advertisement" turned every mention of a past sponsor into a cut,
            // which is how three minutes of hosts criticising a company got
            // removed from an episode. Recognition is a hint, not a verdict.
            text += """



            This show has run ads for these before: \(safe.joined(separator: ", ")).
            A passage that pitches one of them is an advertisement. A passage that
            merely mentions one, with nothing being asked of the listener, is not.
            """
        }

        text += correctionNotes(corrections)
        return text
    }

    /// The listener's own corrections on this show, as worked examples.
    ///
    /// Newest first and capped, because these sit in the instructions — the one
    /// place that outranks the passage being judged — and a wall of examples
    /// would drown the thing it is meant to help with. Scrubbed the same way
    /// sponsor names are: this text originally came out of a transcript, which
    /// makes it untrusted, so quotes, newlines and anything that could read as
    /// a new instruction are stripped before it goes anywhere.
    private static func correctionNotes(_ corrections: [DetectionCorrection]) -> String {
        func clean(_ raw: String) -> String {
            let allowed = CharacterSet.alphanumerics
                .union(.whitespaces)
                .union(CharacterSet(charactersIn: ".,'-?!&/"))
            let stripped = raw.components(separatedBy: allowed.inverted).joined(separator: " ")
            let squashed = stripped.split(separator: " ").joined(separator: " ")
            return String(squashed.prefix(140)).trimmingCharacters(in: .whitespaces)
        }

        let newest = corrections.sorted { $0.addedAt > $1.addedAt }
        let wrong = newest.filter { $0.segmentKind == nil }
            .compactMap { c -> String? in
                let t = clean(c.excerpt)
                return t.count >= 12 ? t : nil
            }
            .prefix(5)
        let right = newest.filter { $0.segmentKind != nil }
            .compactMap { c -> (String, SegmentKind)? in
                let t = clean(c.excerpt)
                guard t.count >= 12, let kind = c.segmentKind else { return nil }
                return (t, kind)
            }
            .prefix(5)

        guard !wrong.isEmpty || !right.isEmpty else { return "" }

        var note = "\n\n\nThe listener has corrected earlier judgements on this show."

        if !wrong.isEmpty {
            note += """


            These passages are part of the episode itself, not promotions. Do not
            label anything that reads like them as a promotion:
            """
            for excerpt in wrong { note += "\n- \(excerpt)" }
        }

        if !right.isEmpty {
            note += """


            These passages are promotions, and the listener confirmed what each
            one was:
            """
            for (excerpt, kind) in right {
                note += "\n- \(excerpt) — \(Self.promptName(for: kind))"
            }
        }

        return note
    }

    /// The words used for a kind in the instructions, kept in one place so the
    /// examples above and the `kind` field of the schema cannot drift apart.
    private static func promptName(for kind: SegmentKind) -> String {
        switch kind {
        case .ad:         return "advertisement"
        case .selfPromo:  return "selfPromotion"
        case .crossPromo: return "crossPromotion"
        case .intro:      return "introduction"
        case .outro:      return "outro"
        }
    }

    // MARK: - Cheap prefilter

    /// Anything that looks nothing like a promotion never reaches the model,
    /// which cuts inference calls by roughly an order of magnitude on a
    /// typical episode. Neighbours of a hit are kept too, so the run-up and
    /// the tail of a sponsor read still get classified.
    ///
    /// Cues come in two strengths. A strong cue is one that essentially never
    /// turns up in ordinary conversation, and one of them is enough. A weak
    /// cue is a phrase that *can* mean a promotion and very often doesn't —
    /// "listen to", "tickets", "check out" — and two are needed. The old list
    /// had no such split, so "listen to" alone matched nearly every window in
    /// the episode and the prefilter was doing no filtering at all.
    private static let strongCues = [
        "sponsor", "sponsored by", "promo code", "discount code", "offer code",
        "coupon code", "brought to you by", "this episode is brought to you",
        "supported by", "our partners at", "use code", "terms apply",
        "free trial", "sign up at", "dot com slash", ".com/", "percent off",
        "% off", "first-time customers", "cancel anytime", "that's spelled",
        "patreon", "our merch", "merch store", "ad-free", "ad free feed",
        "bonus episode", "bonus episodes", "rate and review",
        "leave us a review", "five stars", "wherever you get your podcasts",
        "link in the show notes", "link in the description", "hit subscribe",
        "support the show", "buy me a coffee"
    ]

    /// Ordinary English that sometimes signals a promotion. Two, or nothing.
    private static let weakCues = [
        "tickets", "on tour", "tour dates", "live show", "live shows",
        "membership", "subscribe", "download the app", "free shipping",
        "start your", "listen to", "check out", "follow us", "t-shirts",
        "venmo", "cameo", "early access", "join our", "another podcast",
        "new podcast", "our other show", "our other podcast", "on the network",
        "new series from", "podcast you should"
    ]

    private static let bookendCues = [
        "welcome to", "welcome back to", "this is episode", "i'm your host",
        "thanks for listening", "see you next week", "see you next time",
        "until next time", "produced by", "edited by", "our theme music",
        "engineered by"
    ]

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
                corrections: [DetectionCorrection] = [],
                minimumConfidence: Int = 60,
                padding: Double = 0.4,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> DetectionResult {

        if let reason = Self.availability() {
            throw AdDetectorError.modelUnavailable(reason)
        }

        let candidates = Self.prefilter(windows)
        guard !candidates.isEmpty, let lastWindow = windows.last else { return DetectionResult() }

        let session = LanguageModelSession(
            instructions: Self.instructions(knownSponsors: knownSponsors,
                                            corrections: corrections))
        // The first window otherwise pays for loading the model. On an
        // hour-long episode that is a visible stall at the start of the
        // "finding ads" stage.
        session.prewarm()

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
            let prompt = Self.prompt(for: index,
                                     in: windows,
                                     percent: percent,
                                     duration: duration)

            do {
                // A fresh classification per window, not a conversation —
                // there is nothing to carry forward, and it keeps every call
                // far away from the context limit.
                let reply = try await session.respond(to: prompt, generating: PassageVerdict.self)
                let verdict = reply.content
                guard let kind = SegmentKind(modelLabel: verdict.kind) else { continue }

                let subject = verdict.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let asking = !verdict.callToAction
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let promoting = verdict.stance.lowercased().hasPrefix("promot")

                // The Barstool rule.
                //
                // Hosts spent three minutes taking a company apart and the
                // whole passage was cut as a sponsor read, because in
                // isolation a brand named thirty times looks like an ad. A
                // third-party promotion that neither asks the listener to do
                // anything nor reads as a pitch is not a promotion at all.
                if kind == .ad || kind == .crossPromo, !promoting, !asking {
                    continue
                }

                var confidence = verdict.confidence
                if kind == .ad || kind == .crossPromo {
                    // Heavier on stance than on the call to action, and
                    // deliberately so. "Discussing it but telling you where to
                    // find it" is the genuinely ambiguous case and deserves to
                    // fall below the bar on its own. "Pitching it without a
                    // URL" is an ordinary brand-awareness read and must not —
                    // penalise that hard and half the real ads stop being cut,
                    // which is the failure nobody notices until they are
                    // listening to one.
                    if !promoting { confidence -= 35 }
                    else if !asking { confidence -= 10 }
                } else if kind == .selfPromo {
                    // A show mentioning its own tour without saying where to
                    // get tickets is still selling, so this is gentler — but
                    // "we played that venue in 2019" is not.
                    if !promoting { confidence -= 25 }
                }

                // A brand this show has read before is not a guess — but only
                // when it is actually being pitched.
                if promoting, !subject.isEmpty,
                   normalisedKnown.contains(Self.normalise(subject)) {
                    confidence = min(100, confidence + 12)
                }
                if kind == .ad, promoting, !subject.isEmpty {
                    sponsors.append(subject)
                }

                let bounds = Self.bounds(for: verdict, in: window, segments: segments)
                found[index] = DetectedSegment(start: bounds.lowerBound,
                                               end: bounds.upperBound,
                                               kind: kind,
                                               sponsor: subject,
                                               confidence: max(0, confidence))
            } catch {
                // One bad window shouldn't sink the episode.
                continue
            }
        }

        let kept = Self.keep(found,
                             minimumConfidence: minimumConfidence,
                             duration: duration)
        let merged = Self.merge(kept, padding: padding)
        // Snap first, then take the bookends to the edges. The other order
        // undoes itself: an intro pulled back to zero would be snapped
        // straight back to the end of the first pause in the file, leaving
        // exactly the second of theme tune it was there to remove.
        let snapped = merged.map { Self.snap($0, to: silences) }
        let bookended = Self.extendBookends(snapped, duration: duration)

        return DetectionResult(segments: bookended.filter { $0.end > $0.start + 1 },
                               sponsors: Array(Set(sponsors)).sorted())
    }

    // MARK: - Prompt

    /// The passage, plus a little of what surrounds it.
    ///
    /// Every window used to be judged completely alone, which is what made a
    /// conversation about a company indistinguishable from a read for it: an
    /// ad break has silence and a tonal handoff on either side, and a
    /// mid-conversation tangent does not. Forty words in each direction is
    /// enough to see that and cheap enough not to slow the pass down.
    private static func prompt(for index: Int,
                               in windows: [TranscriptWindow],
                               percent: Int,
                               duration: Double) -> String {
        let window = windows[index]
        var parts: [String] = [
            """
            This passage begins \(percent)% into the episode, at \
            \(clock(window.start)) of \(clock(duration)).
            """
        ]

        if index > 0, let lead = words(windows[index - 1].text, take: 40, fromEnd: true) {
            parts.append("""
            CONTEXT BEFORE (do not label this):
            \(lead)
            """)
        }

        parts.append("""
        PASSAGE TO LABEL:
        \(window.text)
        """)

        if index + 1 < windows.count,
           let trail = words(windows[index + 1].text, take: 40, fromEnd: false) {
            parts.append("""
            CONTEXT AFTER (do not label this):
            \(trail)
            """)
        }

        return parts.joined(separator: "\n\n")
    }

    private static func words(_ text: String, take: Int, fromEnd: Bool) -> String? {
        let all = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !all.isEmpty else { return nil }
        let slice = fromEnd ? all.suffix(take) : all.prefix(take)
        return slice.joined(separator: " ")
    }

    // MARK: - Prefilter

    private static func prefilter(_ windows: [TranscriptWindow]) -> [Int] {
        var keep = Set<Int>()
        for (i, w) in windows.enumerated() {
            let lower = w.text.lowercased()
            let strong = strongCues.contains { lower.contains($0) }
            let weak = weakCues.reduce(into: 0) { total, cue in
                if lower.contains(cue) { total += 1 }
            }
            let bookend = bookendCues.contains { lower.contains($0) }
            guard strong || weak >= 2 || bookend else { continue }
            keep.insert(i)
            if i > 0 { keep.insert(i - 1) }
            if i + 1 < windows.count { keep.insert(i + 1) }
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

    // MARK: - What survives the confidence floor

    /// Three ways a window gets kept.
    ///
    /// The plain one is clearing the threshold. The second is sitting next to
    /// something that did: ad breaks are contiguous, and a window the model
    /// called promotional at only 45%, wedged between two confident hits, is
    /// part of the same break — leaving it out is exactly how eight seconds of
    /// sponsor survives in the middle of a cut.
    ///
    /// The third is position, and it is new. An intro is at the start of the
    /// episode and an outro is at the end; that is what the words mean. The
    /// old version threw away *everything* unless at least one window cleared
    /// the full threshold, so a show whose opening the model was only 55% sure
    /// about got no intro cut at all even on the most aggressive setting —
    /// which is precisely what was reported. A bookend in the right place is
    /// now evidence in its own right, and the cost of getting one wrong is a
    /// few seconds of theme music rather than a piece of the episode.
    private static func keep(_ found: [Int: DetectedSegment],
                             minimumConfidence: Int,
                             duration: Double) -> [DetectedSegment] {
        let confident = Set(found.filter { $0.value.confidence >= minimumConfidence }.keys)
        let rescueFloor = max(30, minimumConfidence - 25)
        let bookendFloor = max(25, minimumConfidence - 30)

        // The first and last tenth of the episode, with sane limits either way
        // so a four-minute bonus clip and a four-hour marathon both behave.
        let head = min(max(duration * 0.10, 60), 300)
        let tail = duration - min(max(duration * 0.10, 60), 300)

        var kept: [DetectedSegment] = []

        for (index, segment) in found.sorted(by: { $0.key < $1.key }) {
            if segment.confidence >= minimumConfidence {
                kept.append(segment)
                continue
            }

            // A bookend where a bookend belongs.
            let wellPlaced = (segment.kind == .intro && segment.start <= head)
                || (segment.kind == .outro && segment.end >= tail)
            if wellPlaced, segment.confidence >= bookendFloor {
                kept.append(segment)
                continue
            }

            // No `kind != .content` check: content isn't a case. A passage
            // the model called content never became a DetectedSegment in the
            // first place, because `SegmentKind(modelLabel:)` returns nil for
            // it and the window is dropped.
            guard segment.confidence >= rescueFloor else { continue }
            if confident.contains(index - 1) || confident.contains(index + 1) {
                kept.append(segment)
            }
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

    // MARK: - Bookends

    /// An intro that starts at 0:14 leaves fourteen seconds of theme tune
    /// playing before the skip, which reads as the feature not working.
    /// Nothing precedes an intro and nothing follows an outro, so if one
    /// begins or ends near the edge of the episode, take it to the edge.
    private static func extendBookends(_ segments: [DetectedSegment],
                                       duration: Double,
                                       reach: Double = 45) -> [DetectedSegment] {
        guard duration > 0 else { return segments }
        return segments.map { segment in
            var s = segment
            if s.kind == .intro, s.start <= reach { s.start = 0 }
            if s.kind == .outro, s.end >= duration - reach { s.end = duration }
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
