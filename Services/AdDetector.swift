import Foundation
import FoundationModels

// MARK: - Why this file looks the way it does
//
// Everything here was measured in the detection lab (build/lab on the Mac),
// which compiles this file outside the app and runs it on real, downloaded
// episodes with the same on-device model the phone uses. Three findings shaped
// it, and each one was a reason detection on the phone was poor:
//
// 1. One `LanguageModelSession` was shared across the whole episode. A session
//    is a conversation, so every passage and answer stayed in its context; the
//    context filled after a handful of windows and every later call failed —
//    silently, because failures were skipped. On a 65-minute episode the old
//    detector found exactly one ad, the first one.
//
// 2. The default guardrails refuse a large share of comedy-podcast passages as
//    "sensitive or unsafe content" — on a Legion of Skanks episode, about half
//    the windows, including the ones with the sponsor reads in them. Those were
//    skipped too. `permissiveContentTransformations` exists for exactly this —
//    classifying text the app was given rather than writing new text — but it
//    only applies to plain-text responses, not to guided generation.
//
// 3. Guided generation cost about eight seconds a window on the Mac; the same
//    question answered as one short line of text costs about one. So the model
//    now answers in a fixed one-line format that is parsed here, which is
//    what makes it affordable to ask more questions: where the episode starts,
//    where it ends, where each cut's edges are, and whether each cut survives
//    being read with a minute of conversation around it.

/// What the detector found, before it becomes an `AdSegment`.
struct DetectedSegment {
    var start: Double
    var end: Double
    var kind: SegmentKind
    var sponsor: String
    var confidence: Int
    /// How clear each edge was, 0–100, and the plain-English reasons.
    var startConfidence: Int = 0
    var endConfidence: Int = 0
    var evidence: [String] = []
}

struct DetectionResult {
    var segments: [DetectedSegment] = []
    /// Sponsors seen in this episode, for the show to remember.
    var sponsors: [String] = []
    /// Why each decision went the way it did. Read by the detection lab.
    var log: [String] = []
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

    /// See finding 2 above.
    private static var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
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

    // MARK: - Instructions

    static let windowInstructions = """
    You read a passage from a podcast transcript and say what it is.

    Reply with one line of five fields separated by semicolons, like these examples:
    kind=advertisement; flow=interruption; selling=yes; sponsor=Acme Mattress; confidence=95
    kind=content; flow=conversation; selling=no; sponsor=none; confidence=90
    kind=selfPromotion; flow=interruption; selling=yes; sponsor=their tour; confidence=85

    kind is one of:
    advertisement: a paid sponsor read, produced or read by a host in their own words.
    selfPromotion: the show or its guests selling their own things: Patreon, subscriptions, bonus episodes, merchandise, tour dates, tickets, specials, books.
    crossPromotion: a plug for a different podcast.
    content: the episode itself. This includes talking about a company or a product as part of the conversation, praising or criticising one, a guest talking about their work because they were asked, and promoting, supporting or raising awareness of a person, a cause or an issue.

    flow is interruption if the passage steps out of the conversation to deliver an ad or a plug, and conversation if it is part of the talk.
    selling is yes only if the listener is asked to buy, subscribe, download, sign up, get tickets or use a code. Praising someone or raising awareness of a cause is no.
    Label only the PASSAGE. The context around it is there so you can tell a sponsor read from a conversation that mentions a brand.
    """

    private static func instructions(knownSponsors: [String],
                                     noteSponsors: [String],
                                     showTitle: String,
                                     corrections: [DetectionCorrection]) -> String {
        var text = windowInstructions
        let show = scrub(showTitle)
        if !show.isEmpty { text += "\nThe show is called \(show)." }
        let known = knownSponsors.map(scrub).filter { !$0.isEmpty }.prefix(12)
        if !known.isEmpty {
            text += "\nThis show has run ads for: \(known.joined(separator: ", ")). Pitching one of them is an advertisement; mentioning one in conversation is not."
        }
        let notes = noteSponsors.map(scrub).filter { !$0.isEmpty }.prefix(10)
        if !notes.isEmpty {
            text += "\nThis episode's show notes mention: \(notes.joined(separator: ", "))."
        }
        text += correctionNotes(corrections)
        return text
    }

    /// Untrusted text — a model's reading of a podcast, or a feed's show notes
    /// — reduced to short plain words before it goes into instructions.
    static func scrub(_ raw: String) -> String {
        let plain = raw.components(separatedBy: CharacterSet.alphanumerics
                                    .union(.whitespaces).union(CharacterSet(charactersIn: "&'-."))
                                    .inverted).joined()
        let squashed = plain.split(separator: " ").joined(separator: " ")
        return String(squashed.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// The listener's own corrections on this show, as worked examples.
    private static func correctionNotes(_ corrections: [DetectionCorrection]) -> String {
        func clean(_ raw: String) -> String {
            let allowed = CharacterSet.alphanumerics
                .union(.whitespaces)
                .union(CharacterSet(charactersIn: ".,'-?!&/"))
            let stripped = raw.components(separatedBy: allowed.inverted).joined(separator: " ")
            let squashed = stripped.split(separator: " ").joined(separator: " ")
            return String(squashed.prefix(140)).trimmingCharacters(in: .whitespaces)
        }
        let newest = corrections.filter { $0.boundary == nil }.sorted { $0.addedAt > $1.addedAt }
        let wrong = newest.filter { $0.segmentKind == nil }
            .map { clean($0.excerpt) }.filter { $0.count >= 12 }.prefix(4)
        let right = newest.filter { $0.segmentKind != nil }
            .compactMap { c -> (String, SegmentKind)? in
                let t = clean(c.excerpt)
                guard t.count >= 12, let kind = c.segmentKind else { return nil }
                return (t, kind)
            }
            .prefix(4)
        guard !wrong.isEmpty || !right.isEmpty else { return "" }

        var note = "\n\nThe listener has corrected earlier answers on this show."
        if !wrong.isEmpty {
            note += "\nThese were part of the episode, not promotions:"
            for excerpt in wrong { note += "\n- \(excerpt)" }
        }
        if !right.isEmpty {
            note += "\nThese were promotions:"
            for (excerpt, kind) in right { note += "\n- \(excerpt) (\(promptName(for: kind)))" }
        }
        return note
    }

    private static func promptName(for kind: SegmentKind) -> String {
        switch kind {
        case .ad:         return "advertisement"
        case .selfPromo:  return "selfPromotion"
        case .crossPromo: return "crossPromotion"
        case .intro:      return "introduction"
        case .outro:      return "outro"
        }
    }

    // MARK: - Cues

    /// Phrases that essentially never occur in conversation. One is enough to
    /// send a window to the model, and one also counts as the passage asking
    /// the listener to do something.
    static func welcomesToShow(_ lower: String, showTitle: String) -> Bool {
        let title = normalise(showTitle)
        let words = title.split(separator: " ").filter { $0.count > 2 && $0 != "the" && $0 != "podcast" }
        guard !words.isEmpty else { return false }
        for phrase in ["welcome to the ", "welcome to ", "welcome back to the ", "welcome back to "] {
            var search = lower[...]
            while let range = search.range(of: phrase) {
                let after = normalise(String(search[range.upperBound...].prefix(60)))
                if words.prefix(2).allSatisfy({ after.contains($0) }) { return true }
                search = search[range.upperBound...]
            }
        }
        return false
    }

    private static let strongCues = [
        "sponsor", "promo code", "discount code", "offer code", "coupon code",
        "brought to you by", "supported by", "our partners at", "use code",
        "use the code", "terms apply", "free trial", "sign up at", "dot com slash",
        ".com/", ".com", "dot com", ".co", "percent off", "% off", "first-time customers",
        "cancel anytime", "that's spelled", "patreon", "merch", "ad-free",
        "ad free", "bonus episode", "rate and review", "leave us a review",
        "wherever you get your podcasts", "link in the show notes",
        "link in the description", "support the show", "paid ad", "app store",
        "free shipping", "money back", "limited time", "for tickets", "tour dates"
    ]

    /// Ordinary words that sometimes signal a promotion. Two are needed.
    private static let weakCues = [
        "tickets", "on tour", "live show", "membership", "subscribe", "download",
        "start your", "listen to", "check out", "follow us", "t-shirt", "venmo",
        "early access", "join", "podcast", "network", "go to", "head to", "offer",
        "save", "insurance", "shop", "learn more", "order", "deal", "visit",
        "website", "available", "customers", "guarantee", "price", "try"
    ]

    // MARK: - Detection

    func detect(windows: [TranscriptWindow],
                segments: [TranscriptSegment] = [],
                silences: [ClosedRange<Double>] = [],
                knownSponsors: [String] = [],
                corrections: [DetectionCorrection] = [],
                globalCorrections: [DetectionCorrection] = [],
                showTitle: String = "",
                episodeTitle: String = "",
                showNotes: String = "",
                audioDuration: Double = 0,
                minimumConfidence: Int = 60,
                padding: Double = 0.4,
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> DetectionResult {

        if let reason = Self.availability() {
            throw AdDetectorError.modelUnavailable(reason)
        }
        guard let lastWindow = windows.last, !segments.isEmpty else { return DetectionResult() }

        var log: [String] = []
        let noteSponsors = Self.sponsorsFromNotes(showNotes)
        if !noteSponsors.isEmpty { log.append("notes mention: \(noteSponsors)") }
        let instructions = Self.instructions(knownSponsors: knownSponsors,
                                             noteSponsors: noteSponsors,
                                             showTitle: showTitle,
                                             corrections: corrections)
        let duration = max(lastWindow.end, audioDuration)
        let brandNames = (knownSponsors + noteSponsors).map(Self.normalise).filter { $0.count >= 3 }
        let ownExcerpts = Set(corrections.map(\.excerpt))
        let memory = FeedbackMemory(corrections: corrections
                                    + globalCorrections.filter { !ownExcerpts.contains($0.excerpt) })

        // MARK: 1. Windows

        let candidates = Self.prefilter(windows)
        log.append("windows: \(windows.count), sent to the model: \(candidates.count)")
        var found: [Int: DetectedSegment] = [:]
        var sponsors: [String] = []

        for (n, index) in candidates.enumerated() {
            let window = windows[index]
            defer { progress?(0.65 * Double(n + 1) / Double(max(1, candidates.count))) }

            let prompt = Self.windowPrompt(index: index, windows: windows,
                                           duration: duration, episodeTitle: episodeTitle)
            guard let reply = await Self.ask(prompt, instructions: instructions, log: &log,
                                             label: "window \(Self.clock(window.start))") else { continue }
            let fields = Self.fields(reply)
            let label = fields["kind"] ?? ""
            guard let kind = SegmentKind(modelLabel: label),
                  kind == .ad || kind == .selfPromo || kind == .crossPromo else { continue }

            let interruption = (fields["flow"] ?? "").hasPrefix("interrupt")
            let selling = (fields["selling"] ?? "").hasPrefix("yes")
            var sponsor = fields["sponsor"] ?? ""
            if sponsor == "none" { sponsor = "" }
            let lower = window.text.lowercased()
            let asking = Self.strongCues.contains { lower.contains($0) }
                || brandNames.contains { Self.normalise(lower).contains($0) }
            var confidence = Int(fields["confidence"] ?? "") ?? 60
            let tag = "window \(Self.clock(window.start)) \(reply.prefix(120))"

            // The two rules that stop a conversation being cut.
            //
            // Nothing that is part of the conversation and asks nothing of the
            // listener is a promotion, whatever it was labelled. And nothing
            // that is not selling is a promotion unless it also has the words
            // an ad has — a URL, a code, "brought to you by". That second rule
            // is the answer to "promote awareness" being cut: the model can
            // be talked into "selling" by the word, but not into a promo code.
            if !interruption && !asking { log.append(tag + " → dropped: conversation"); continue }
            if !selling && !asking { log.append(tag + " → dropped: not selling"); continue }

            if !interruption { confidence -= 20 }
            if !selling { confidence -= 20 }
            if !asking { confidence -= 15 }
            if !sponsor.isEmpty, brandNames.contains(Self.normalise(sponsor)) {
                confidence = min(100, confidence + 10)
            }
            if kind == .ad, selling, asking, !sponsor.isEmpty { sponsors.append(sponsor) }
            found[index] = DetectedSegment(start: window.start, end: window.end, kind: kind,
                                           sponsor: sponsor, confidence: max(0, confidence))
            log.append(tag + " → candidate \(confidence)")
        }

        let kept = Self.keep(found, minimumConfidence: minimumConfidence, duration: duration)
        var promos = Self.merge(kept, padding: 0, gapTolerance: 12)

        // MARK: 2. Edges, memory and a second look at each cut

        var reviewed: [DetectedSegment] = []
        for (n, original) in promos.enumerated() {
            defer { progress?(0.65 + 0.25 * Double(n + 1) / Double(max(1, promos.count))) }
            var segment = original

            if let start = await walkEdge(of: segment, atStart: true, segments: segments, log: &log) {
                segment.start = start
            }
            if let end = await walkEdge(of: segment, atStart: false, segments: segments, log: &log) {
                segment.end = end
            }
            // The words an ad cannot do without — its sponsor's name, a URL, a
            // code — hold the edges where the model's reading would move them.
            let names = found.values
                .filter { $0.start < original.end && $0.end > original.start }
                .map { Self.normalise($0.sponsor) } + brandNames
            segment = Self.anchorToCues(segment, names: names.filter { $0.count >= 3 },
                                        segments: segments, log: &log)
            guard segment.end > segment.start + 3 else { continue }

            let text = Self.text(in: segment.start...segment.end, of: segments)
            switch memory.match(text) {
            case .rejected(let similarity):
                log.append("cut \(Self.clock(segment.start)) → dropped: reads like one the listener rejected (\(similarity))")
                continue
            case .confirmed(let similarity):
                segment.confidence = min(100, segment.confidence + 20)
                log.append("cut \(Self.clock(segment.start)) → kept: reads like one the listener confirmed (\(similarity))")
                reviewed.append(segment)
                continue
            case .none:
                break
            }

            let lower = text.lowercased()
            let asking = Self.strongCues.contains { lower.contains($0) }
            // The show welcoming you by name is the show, not an ad. A cut
            // that contains it, with no ad wording anywhere in it, is the
            // opening of a segment being mistaken for a break.
            if !asking, Self.welcomesToShow(lower, showTitle: showTitle), segment.kind == .ad {
                log.append("cut \(Self.clock(segment.start)) → dropped: the show welcoming you, no ad wording")
                continue
            }
            let prompt = Self.reviewPrompt(for: segment, segments: segments)
            if let reply = await Self.ask(prompt, instructions: Self.reviewInstructions, log: &log,
                                          label: "review \(Self.clock(segment.start))") {
                let f = Self.fields(reply)
                let removable = (f["removable"] ?? "yes").hasPrefix("yes")
                let selling = (f["selling"] ?? "yes").hasPrefix("yes")
                let verdict = f["kind"] ?? ""
                let tag = "cut \(Self.clock(segment.start))–\(Self.clock(segment.end)) review '\(reply.prefix(100))'"
                // Only a clear "this is part of the conversation" undoes a cut,
                // and never one that has an ad's own words in it: a small model
                // reading three minutes of text is less reliable than a promo
                // code is.
                if !removable, verdict.hasPrefix("content") || !selling, !asking {
                    log.append(tag + " → dropped"); continue
                }
                // Nothing for sale and none of an ad's own words. Measured on
                // Legion of Skanks 955: at 4:48 the hosts joke about doing an
                // ad ("have him do the ad shirtless", a brand name in a joke),
                // then welcome everyone to the show. The window reading saw a
                // brand and called it an ad; the review said "selling=no" but
                // "removable=yes", and removable alone kept the cut. A real
                // ad, host-read or not, asks you to buy, visit or use
                // something — so "not selling" with no code, URL or offer in
                // the words is conversation about an ad, not an ad.
                if !selling, !asking, segment.kind == .ad, segment.confidence < 95 {
                    log.append(tag + " → dropped: not selling, no ad wording"); continue
                }
                if let revised = SegmentKind(modelLabel: verdict),
                   revised == .ad || revised == .selfPromo || revised == .crossPromo {
                    segment.kind = revised
                }
                log.append(tag + " → kept")
            }
            reviewed.append(segment)
        }
        promos = reviewed

        // MARK: 3. Where the episode begins and ends

        var bookends: [DetectedSegment] = []
        // Look for the opening after any pre-roll ads and for the closing before
        // any post-roll ones. Measured: a SmartLess episode opens with three
        // minutes of ads, so "the first four minutes" contained no episode at
        // all and the question had no right answer.
        var leadEnd = 0.0
        for promo in promos.sorted(by: { $0.start < $1.start }) where promo.start <= leadEnd + 20 {
            leadEnd = max(leadEnd, promo.end)
        }
        var tailStart = duration
        for promo in promos.sorted(by: { $0.end > $1.end }) where promo.end >= tailStart - 20 {
            tailStart = min(tailStart, promo.start)
        }
        if let intro = await opening(segments: segments.filter { $0.start >= leadEnd - 0.5 },
                                     after: leadEnd, showTitle: showTitle, log: &log) {
            bookends.append(intro)
        }
        progress?(0.95)
        if let outro = await closing(segments: segments.filter { $0.end <= tailStart + 0.5 },
                                     before: tailStart, showTitle: showTitle, log: &log) {
            bookends.append(outro)
        }

        let all = (promos + bookends).sorted { $0.start < $1.start }
        let merged = Self.merge(all, padding: padding)
        let snapped = merged.map { Self.snap($0, to: silences) }
        let finished = Self.extendBookends(snapped, duration: duration)
        progress?(1)

        return DetectionResult(segments: finished.filter { $0.end > $0.start + 1 },
                               sponsors: Array(Set(sponsors)).sorted(),
                               log: log)
    }

    // MARK: - Asking

    static func ask(_ prompt: String,
                            instructions: String,
                            log: inout [String],
                            label: String,
                            maxTokens: Int = 60) async -> String? {
        let key = instructions + "\u{1}" + prompt
        if let cached = replyCache?.get(key) { return cached }
        await breathe()
        do {
            // A new session for every question — see finding 1.
            let session = LanguageModelSession(model: model, instructions: instructions)
            // The label was renamed between SDKs: Xcode 27 deprecates
            // `sampling:` for `samplingMode:`, and the Xcode 26 on the CI
            // runner has only `sampling:`. Using the new one broke CI while
            // every local build passed.
            #if compiler(>=6.4)
            let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maxTokens)
            #else
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: maxTokens)
            #endif
            let reply = try await session.respond(to: prompt, options: options)
            let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            replyCache?.set(key, text)
            return text
        } catch {
            log.append("\(label) error: \(error)")
            return nil
        }
    }

    /// The detection lab's memory of earlier answers, so a change to one stage
    /// doesn't mean asking every question again. Never set in the app.
    nonisolated(unsafe) static var replyCache: (get: (String) -> String?, set: (String, String) -> Void)?

    // MARK: - How an ad is delivered

    struct AdStyle: Equatable {
        /// Read by the show's own host rather than a produced, pre-recorded spot.
        var hostRead: Bool
        /// Played for laughs: the host riffing on, mocking or improvising
        /// around the ad rather than simply delivering it.
        var comedyBit: Bool
    }

    /// Asked once per ad after detection, never as part of it.
    ///
    /// Some listeners want the host-read ads kept, and in comedy shows an ad
    /// read is often a bit in itself. Asking about delivery inside the main
    /// question would change how that question is answered — and the lab's
    /// verified results with it — so this is a separate, short question whose
    /// answer only decides what a setting keeps. Detection is untouched.
    func classifyStyle(of segment: DetectedSegment, text: String) async -> AdStyle? {
        guard Self.availability() == nil else { return nil }
        let passage = Self.scrub(String(text.prefix(1800)))
        guard passage.count > 40 else { return nil }
        // The whole text, not the shortened passage: small print comes last.
        let lower = text.lowercased()

        // Produced spots announce themselves in ways a host never does: the
        // network's sponsorship line and the legal small print. In the lab the
        // model called a 26-second Progressive pre-roll — "Support for this
        // podcast comes from Progressive … casualty insurance company and
        // affiliates" — host-read, so the words decide this, not the model.
        let sponsorLines = ["support for this podcast comes from", "support for this show comes from",
                            "this podcast is brought to you by", "this episode is brought to you by",
                            "this message is brought to you by"]
        let smallPrint = ["terms apply", "restrictions apply", "and affiliates", "not available in all states",
                          "rating based on", "see site for details", "void where prohibited", "member fdic",
                          "for full terms", "individual results may vary", "does not provide legal advice"]
        let producedByWords = smallPrint.contains { lower.contains($0) }
            || (sponsorLines.contains { lower.contains($0) } && segment.end - segment.start < 130)

        let instructions = """
        You label how a podcast advertisement is delivered. The passage may begin and end with a few lines of the show's own conversation; judge only the advertisement itself. Reply with one line only, exactly in this form:
        read=host; bit=no; confidence=80
        read is produced if it is a pre-recorded commercial: a narrator or actors, scripted copy addressed to "you", questions like "do you ever", legal disclaimers, nothing about the hosts' own lives. read is host if the show's hosts deliver it themselves, talking about their own experience with the product.
        bit is yes only if, inside the advertisement, the hosts clearly joke about the product or about themselves using it, heckle each other, or turn the read into a comedy routine. Jokes in the conversation before or after the advertisement do not count. A produced commercial is never a bit.
        confidence is how sure you are about bit, from 0 to 100.
        Examples:
        "Support for this podcast comes from Acme Insurance. Get a quote today. Terms apply." → read=produced; bit=no; confidence=95
        "Hey, do you ever feel tired in the afternoon? Acme drink gives you energy without the crash. Find it in stores." → read=produced; bit=no; confidence=90
        "Okay, Acme razors. Remember when you shaved your whole back with one before the show? Dude, you looked like a plucked chicken. Still smoother than you. Use code SHOW." → read=host; bit=yes; confidence=90
        "This week's sponsor is Acme sheets. I've slept on them for a year, they're great, go to acme.com slash show." → read=host; bit=no; confidence=85
        """
        var discard: [String] = []
        guard let reply = await Self.ask("Advertisement (\(segment.sponsor.isEmpty ? "sponsor unknown" : Self.scrub(segment.sponsor))):\n\(passage)",
                                         instructions: instructions,
                                         log: &discard, label: "style") else {
            return producedByWords ? AdStyle(hostRead: false, comedyBit: false) : nil
        }
        let f = Self.fields(reply)
        if producedByWords { return AdStyle(hostRead: false, comedyBit: false) }
        let hostRead = !(f["read"] ?? "").hasPrefix("produced")
        let sure = Int(f["confidence"] ?? "") ?? 0
        // Conservative on purpose: calling a real ad a bit means the listener
        // hears the ad.
        return AdStyle(hostRead: hostRead,
                       comedyBit: hostRead && (f["bit"] ?? "").hasPrefix("yes") && sure >= 85)
    }

    /// `kind=advertisement; flow=interruption; …` into a dictionary.
    ///
    /// Tolerant of what a small model actually writes: a colon instead of an
    /// equals sign, the explanation from the instructions echoed in brackets
    /// after a value, commas instead of semicolons.
    static func fields(_ reply: String) -> [String: String] {
        var out: [String: String] = [:]
        let firstLine = reply.split(whereSeparator: \.isNewline).first.map(String.init) ?? reply
        for part in firstLine.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "|" }) {
            let pair = part.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == ":" })
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if let bracket = value.firstIndex(of: "(") { value = String(value[..<bracket]) }
            value = value.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            if key != "sponsor" { value = value.lowercased() }
            out[key] = value
        }
        return out
    }

    // MARK: - Prompts

    private static func windowPrompt(index: Int, windows: [TranscriptWindow],
                                     duration: Double, episodeTitle: String) -> String {
        let window = windows[index]
        let percent = duration > 0 ? Int(window.start / duration * 100) : 0
        var parts: [String] = []
        let title = scrub(episodeTitle)
        parts.append("\(title.isEmpty ? "" : "Episode: \(title). ")This passage is \(percent)% into the episode.")
        if index > 0,
           let lead = words(windows[max(0, index - 2)...(index - 1)].map(\.text).joined(separator: " "),
                            take: 60, fromEnd: true) {
            parts.append("CONTEXT BEFORE:\n\(lead)")
        }
        parts.append("PASSAGE:\n\(window.text)")
        if index + 1 < windows.count,
           let trail = words(windows[(index + 1)...min(windows.count - 1, index + 2)].map(\.text).joined(separator: " "),
                             take: 60, fromEnd: false) {
            parts.append("CONTEXT AFTER:\n\(trail)")
        }
        return parts.joined(separator: "\n\n")
    }

    private static let reviewInstructions = """
    You are shown part of a podcast transcript with one section marked. Say whether the marked section is something dropped into the episode, like an ad or a plug, or part of the conversation.

    Reply with one line like these examples:
    removable=yes; selling=yes; kind=advertisement
    removable=no; selling=no; kind=content

    removable is yes if deleting the marked section would leave the text before and after joining up naturally, as it does when an ad or a plug is dropped in. It is no if the marked section is part of the conversation: people discussing the thing, telling a story about it, or answering what was said before.
    selling is yes only if the marked section asks the listener to buy, subscribe, download, sign up, get tickets or use a code.
    kind is advertisement, selfPromotion, crossPromotion or content.
    """

    private static func reviewPrompt(for segment: DetectedSegment,
                                     segments: [TranscriptSegment]) -> String {
        let before = segments.filter { $0.end <= segment.start + 0.5 && $0.start >= segment.start - 75 }
            .map(\.text).joined(separator: " ")
        let after = segments.filter { $0.start >= segment.end - 0.5 && $0.end <= segment.end + 75 }
            .map(\.text).joined(separator: " ")
        var marked = text(in: segment.start...segment.end, of: segments)
        let markedWords = marked.split(separator: " ")
        if markedWords.count > 360 {
            marked = markedWords.prefix(200).joined(separator: " ") + " … "
                + markedWords.suffix(140).joined(separator: " ")
        }
        return """
        BEFORE:
        \(words(before, take: 130, fromEnd: true) ?? "(start of episode)")

        MARKED SECTION:
        \(marked)

        AFTER:
        \(words(after, take: 130, fromEnd: false) ?? "(end of episode)")
        """
    }

    // MARK: - Edges

    /// Finds where a cut really starts or ends by walking a few short pieces
    /// across its rough edge and asking about each one.
    ///
    /// A cut built from forty-five-second windows starts up to half a minute
    /// early and ends up to half a minute late. The first fix asked the model
    /// to point at the edge in a list of numbered lines, and in the lab it was
    /// wrong more often than right — it moved a SkinnyPop start thirty seconds
    /// into the ad and pushed a Helix end forty seconds into the conversation.
    /// The window question asked about one short piece is one it answers
    /// well, and a walk needs two to four of them.
    private func walkEdge(of segment: DetectedSegment,
                          atStart: Bool,
                          segments: [TranscriptSegment],
                          log: inout [String]) async -> Double? {
        let edge = atStart ? segment.start : segment.end
        let nearby = segments.filter { $0.end > edge - 75 && $0.start < edge + 75 }
        let pieces = Self.pieces(of: nearby)
        guard pieces.count >= 2 else { return nil }

        // The piece that contains the rough edge, from the inside of the cut.
        guard let anchor = atStart
                ? pieces.firstIndex(where: { $0.end > edge + 0.5 })
                : pieces.lastIndex(where: { $0.start < edge - 0.5 }) else { return nil }

        var cache: [Int: Bool] = [:]
        func isPromo(_ i: Int, _ log: inout [String]) async -> Bool? {
            if let known = cache[i] { return known }
            let before = Self.words(nearby.filter { $0.end <= pieces[i].start + 0.5 }.map(\.text)
                                        .joined(separator: " "), take: 35, fromEnd: true) ?? ""
            let after = Self.words(nearby.filter { $0.start >= pieces[i].end - 0.5 }.map(\.text)
                                       .joined(separator: " "), take: 35, fromEnd: false) ?? ""
            // The same question, in the same words, as the windows — the one
            // the lab showed the model answers well. A bare yes-or-no version
            // said yes to nearly everything next to an ad.
            let prompt = "CONTEXT BEFORE:\n\(before)\n\nPASSAGE:\n\(pieces[i].text)\n\nCONTEXT AFTER:\n\(after)"
            guard let reply = await Self.ask(prompt, instructions: Self.windowInstructions,
                                             log: &log, label: "edge piece") else { return nil }
            let f = Self.fields(reply)
            let kind = f["kind"] ?? "content"
            let answer = !kind.hasPrefix("content") && (f["flow"] ?? "").hasPrefix("interrupt")
            cache[i] = answer
            return answer
        }

        let outward = atStart ? -1 : 1
        var result: Int?
        guard let insideIsPromo = await isPromo(anchor, &log) else { return nil }
        if insideIsPromo {
            // Walk outward while it is still the ad.
            var last = anchor
            var i = anchor + outward
            while i >= 0, i < pieces.count, abs(i - anchor) <= 4 {
                guard let promo = await isPromo(i, &log), promo else { break }
                last = i
                i += outward
            }
            result = last
        } else {
            // The rough edge is in conversation; walk inward to the ad.
            var i = anchor - outward
            while i >= 0, i < pieces.count, abs(i - anchor) <= 4 {
                if let promo = await isPromo(i, &log), promo { result = i; break }
                i -= outward
            }
        }
        guard let index = result else {
            log.append("edge \(Self.clock(edge)) \(atStart ? "start" : "end"): no change")
            return nil
        }
        let refined = atStart ? pieces[index].start : pieces[index].end
        let middle = (segment.start + segment.end) / 2
        guard atStart ? refined < middle : refined > middle else { return nil }
        log.append("edge \(Self.clock(edge)) \(atStart ? "start" : "end") → \(Self.clock(refined)) after \(cache.count) questions '\(pieces[index].text.prefix(50))'")
        return refined
    }

    /// Keeps a cut's edges on the words that make it an ad.
    ///
    /// Two things the lab showed. A host-read ad often opens with the sponsor's
    /// name and then riffs — "let's talk about GLD, the best in the game", then
    /// forty seconds about a holiday in Spain — and a piece of pure riffing
    /// reads as conversation, so the start was walked forward past the
    /// sponsor's name. And a cut can run on past the last URL or code into
    /// the conversation that follows. So: a start never lands after a mention
    /// of the sponsor that sits just before it, and an end that is more than
    /// twenty-five seconds past the last mention is pulled back to it.
    private static func anchorToCues(_ segment: DetectedSegment,
                                     names: [String],
                                     segments: [TranscriptSegment],
                                     log: inout [String]) -> DetectedSegment {
        func isCue(_ line: TranscriptSegment) -> Bool {
            let lower = line.text.lowercased()
            if strongCues.contains(where: { lower.contains($0) }) { return true }
            let plain = normalise(lower)
            return names.contains { plain.contains($0) }
        }
        var out = segment

        if let earliest = segments.first(where: {
            $0.start >= segment.start - 45 && $0.start < segment.start && isCue($0)
        }) {
            out.start = earliest.start
        }

        let inside = segments.filter { $0.start >= out.start && $0.end <= segment.end + 30 && isCue($0) }
        if let lastCue = inside.last {
            if lastCue.end > segment.end {
                out.end = lastCue.end
            } else if segment.end - lastCue.end > 25 {
                // The sentence after the last cue is usually the sign-off —
                // "and now back to the show" — so keep one more line.
                let next = segments.first { $0.start >= lastCue.end - 0.1 }
                out.end = min(segment.end, max(lastCue.end, (next?.end ?? lastCue.end)))
            }
        }
        if out.start != segment.start || out.end != segment.end {
            log.append("cues moved \(clock(segment.start))–\(clock(segment.end)) to \(clock(out.start))–\(clock(out.end))")
        }
        return out
    }

    private struct Piece {
        let start: Double
        let end: Double
        let text: String
    }

    /// Consecutive lines grouped into pieces of at least ten seconds and
    /// fifteen words — long enough to judge, short enough to place an edge.
    private static func pieces(of lines: [TranscriptSegment]) -> [Piece] {
        var out: [Piece] = []
        var current: [TranscriptSegment] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(Piece(start: first.start, end: last.end,
                             text: current.map { $0.text.trimmingCharacters(in: .whitespaces) }
                                 .joined(separator: " ")))
            current = []
        }
        for line in lines {
            current.append(line)
            let words = current.reduce(0) { $0 + $1.text.split(separator: " ").count }
            if let first = current.first, line.end - first.start >= 12, words >= 25 { flush() }
        }
        flush()
        return out
    }

    // MARK: - Opening and closing

    private static let bookendInstructions = """
    You read a short piece from the very beginning or the very end of a podcast episode and say whether it is part of the show's opening or closing, or part of the episode itself.

    Reply with one line like these examples:
    part=opening; confidence=90
    part=episode; confidence=85
    part=closing; confidence=80

    opening: things that come before the episode proper, like a network announcement, the theme song or its lyrics, the show saying or singing its own name, a teaser clip from later in the episode, or a guest's pre-recorded hello.
    closing: things that come after the episode proper, like goodbyes and thanks for listening, telling people where to find the show or the guests, plugs, the show's name said or sung as a theme, credits, or a preview of the next episode.
    episode: the hosts and guests actually talking — including casual chat once they have started.
    """

    /// Walks piece by piece from where the episode's audio proper begins (or
    /// ends) for as long as each piece is still opening (or closing).
    ///
    /// The first version showed the model seventy numbered lines and asked for
    /// the one where the episode begins. In the lab it answered "line 1" on
    /// both test episodes — one of which opens with a network announcement and
    /// a sung theme — so no intro was ever cut. A question about one short
    /// piece at a time is one it answers.
    private func walkBookend(from boundary: Double,
                             forward: Bool,
                             showTitle: String,
                             segments: [TranscriptSegment],
                             log: inout [String]) async -> Double? {
        let span = forward
            ? segments.filter { $0.start >= boundary - 0.5 && $0.start < boundary + 180 }
            : segments.filter { $0.end <= boundary + 0.5 && $0.end > boundary - 180 }
        var pieces = Self.pieces(of: span)
        if !forward { pieces.reverse() }
        guard !pieces.isEmpty else { return nil }

        let wanted = forward ? "opening" : "closing"
        var reached: Double?
        var asked = 0
        let cues = forward ? Self.openingCues : Self.closingCues
        let window = Array(pieces.prefix(10))

        // A sung or chanted theme transcribes as sparse fragments — "Welcome to
        // SmartLess. Smart. Smart. Smart. Less." over twenty seconds — and the
        // model reads a fragment of speech as the episode. Speech runs at two
        // to three words a second; a piece near the edge at under 1.3 is
        // music, and counts as the opening or closing without asking — but
        // only a run of them starting right at the edge.
        var first = 0
        for piece in window.prefix(3) {
            let seconds = piece.end - piece.start
            let words = Double(piece.text.split(separator: " ").count)
            guard seconds > 0, words / seconds < 1.3 else { break }
            reached = forward ? piece.end : piece.start
            first += 1
        }

        // The show welcoming you by name, when something came before it.
        // That something was a cold open or a theme: SmartLess opens with the
        // guest's recorded hello and then "Welcome to SmartLess", and a Conan
        // episode with a guest clip, the theme song, then "welcome to Conan
        // O'Brien Needs a Friend". But when the welcome is the very first thing
        // said, it is the host starting the conversation — another Conan
        // episode begins "Hey Peter, welcome to Conan O'Brien Needs a Fan" —
        // and cutting it loses the start of the episode. Measured on all three.
        if forward {
            let title = Self.normalise(showTitle).replacingOccurrences(of: " ", with: "")
            let named = window.prefix(3).lastIndex { piece in
                let plain = Self.normalise(piece.text)
                let squashed = plain.replacingOccurrences(of: " ", with: "")
                return plain.contains("welcome to") || plain.contains("listening to")
                    || (title.count >= 4 && squashed.contains(title))
            }
            if let named, named >= 1, named >= first {
                reached = window[named].end
                first = named + 1
            }
        }

        for (index, piece) in window.enumerated() where index >= first {
            asked += 1
            let prompt = "\(forward ? "From the beginning" : "From the end") of the episode:\n\n\(piece.text)"
            guard let reply = await Self.ask(prompt, instructions: Self.bookendInstructions,
                                             log: &log, label: wanted) else { break }
            let f = Self.fields(reply)
            guard (f["part"] ?? "").hasPrefix(wanted),
                  (Int(f["confidence"] ?? "") ?? 0) >= 80 else { break }
            // Past the pieces right at the edge, the model's word is not
            // enough. Measured: walking back from the end of a Legion of
            // Skanks episode it called ten pieces in a row "closing" — two
            // minutes of the hosts riffing about a playlist. A closing says
            // goodbye, thanks someone or says where to find the show; an
            // opening welcomes or names the show. Theme lyrics have none of
            // these, which is why the first pieces are exempt.
            let lower = piece.text.lowercased()
            if index >= (forward ? 2 : 1), !cues.contains(where: { lower.contains($0) }) { break }
            reached = forward ? piece.end : piece.start
        }
        log.append("\(wanted) from \(Self.clock(boundary)): \(reached.map { Self.clock($0) } ?? "none") after \(asked) questions")
        return reached
    }

    private static let openingCues = [
        "welcome", "listening to", "this is", "you're listening", "network", "podcast",
        "episode", "i'm your host", "my name is", "on today's", "today we", "presents"
    ]

    private static let closingCues = [
        "thank", "thanks", "see you", "goodbye", "bye", "next week", "next time",
        "follow", "find us", "find me", "subscribe", "rate", "review", "produced by",
        "edited by", "music by", "that's the show", "that's our show", "take care",
        "love you guys", "until next", "catch you", "peace", "good night", "that's it"
    ]

    private func opening(segments: [TranscriptSegment],
                         after leadEnd: Double,
                         showTitle: String,
                         log: inout [String]) async -> DetectedSegment? {
        guard let first = segments.first else { return nil }
        // Music before anyone speaks is a theme or a sting.
        var end = first.start - leadEnd >= 8 ? first.start : leadEnd
        if let reached = await walkBookend(from: leadEnd, forward: true, showTitle: showTitle,
                                               segments: segments, log: &log),
           reached - leadEnd <= 150 {
            end = max(end, reached)
        }
        guard end > leadEnd + 1 else { return nil }
        if let extended = Self.musicTail(after: end, segments: segments) {
            log.append("intro runs on through the theme to \(Self.clock(extended))")
            end = extended
        }
        return DetectedSegment(start: leadEnd, end: end, kind: .intro, sponsor: "", confidence: 80)
    }

    /// A theme song usually ends in music with nobody talking, and the show
    /// starts after it.
    ///
    /// Measured on Legion of Skanks 955: the intro was cut at 0:47, after the
    /// network announcement and the first sung line, but the theme's rapped
    /// verses ran to 1:03 and the music to 1:10, where the hosts start. The
    /// lyrics are dense enough to read as speech, and name nothing the
    /// opening cues look for. What marks the real end is the gap: eight
    /// seconds with no words. So if, within the next half minute of words,
    /// there is a stretch of five seconds or more with none, the intro runs to
    /// where speech resumes after it. Conversation near the start of an
    /// episode does not pause for five seconds; a theme's instrumental does.
    static func musicTail(after end: Double, segments: [TranscriptSegment]) -> Double? {
        let following = segments.filter { $0.end > end + 0.5 }.prefix(30)
        guard !following.isEmpty else { return nil }
        var cursor = end
        for segment in following {
            let gap = segment.start - cursor
            if gap >= 5 {
                // Too much talk before the gap and it is not the theme.
                guard cursor - end <= 30 else { return nil }
                return segment.start - 0.8
            }
            cursor = max(cursor, segment.end)
            if cursor - end > 30 { return nil }
        }
        return nil
    }

    private func closing(segments: [TranscriptSegment],
                         before tailStart: Double,
                         showTitle: String,
                         log: inout [String]) async -> DetectedSegment? {
        guard let last = segments.last, tailStart > 0 else { return nil }
        var start = tailStart - last.end >= 8 ? last.end : tailStart
        if let reached = await walkBookend(from: tailStart, forward: false, showTitle: showTitle,
                                               segments: segments, log: &log),
           tailStart - reached <= 180 {
            start = min(start, reached)
        }
        guard start < tailStart - 1 else { return nil }
        return DetectedSegment(start: start, end: tailStart, kind: .outro, sponsor: "", confidence: 80)
    }

    // MARK: - Text helpers

    private static func text(in range: ClosedRange<Double>, of segments: [TranscriptSegment]) -> String {
        segments.filter { $0.start < range.upperBound && $0.end > range.lowerBound }
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
    }

    private static func words(_ text: String, take: Int, fromEnd: Bool) -> String? {
        let all = text.split(separator: " ", omittingEmptySubsequences: true)
        guard !all.isEmpty else { return nil }
        let slice = fromEnd ? all.suffix(take) : all.prefix(take)
        return slice.joined(separator: " ")
    }

    static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Heat and battery, in the one place every question passes through.
    ///
    /// Finding ads is minutes of the on-device model, and on a phone that is
    /// the hottest thing the app ever does. When the system says the device is
    /// warm, or the listener has turned on Low Power Mode, the questions are
    /// spaced out rather than asked back to back. Slower, but it does not cook
    /// the phone or flatten it.
    static func breathe() async {
        let state = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let pause: Duration?
        switch state {
        case .critical: pause = .seconds(5)
        case .serious: pause = .seconds(2)
        case .fair: pause = lowPower ? .milliseconds(600) : .milliseconds(120)
        default: pause = lowPower ? .milliseconds(400) : nil
        }
        if let pause { try? await Task.sleep(for: pause) }
    }

    // MARK: - Show notes

    /// Sponsors a feed names in its own show notes — "Go to example.com/show and
    /// use code SHOW". The strongest evidence there is about what the ads in an
    /// episode will be, and it was never read.
    static func sponsorsFromNotes(_ notes: String) -> [String] {
        guard !notes.isEmpty else { return [] }
        let plain = notes.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let ignore: Set<String> = [
            "art19", "megaphone", "simplecast", "podtrac", "libsyn", "acast", "omny",
            "omnystudio", "spotify", "apple", "podcasts", "instagram", "twitter", "x",
            "facebook", "tiktok", "youtube", "youtu", "bit", "linktr", "pod", "anchor",
            "google", "amazon", "iheart", "iheartradio", "wondery", "pdst", "pscrb",
            "clrtpod", "mgln", "chartable", "chrt", "podscribe", "privacy", "www",
            "http", "https", "feeds", "rss", "substack", "twitch", "discord", "threads",
            "bsky", "gmail", "email", "mailto", "adswizz", "pcm", "podcastchoices",
            "iheartpodcasts", "spreaker", "buzzsprout", "transistor", "captivate",
            "redcircle", "audioboom", "soundcloud"
        ]
        var names: [String] = []
        if let regex = try? NSRegularExpression(
            pattern: "\\b([a-z0-9][a-z0-9-]{1,30})\\.(com|co|io|net|org|app|ly|tv|fm|us|shop)\\b",
            options: [.caseInsensitive]) {
            let range = NSRange(plain.startIndex..., in: plain)
            for match in regex.matches(in: plain, range: range) {
                guard let r = Range(match.range(at: 1), in: plain) else { continue }
                let name = plain[r].lowercased()
                if !ignore.contains(name), !names.contains(name) { names.append(name) }
            }
        }
        return Array(names.prefix(10))
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
            guard strong || weak >= 2 else { continue }
            keep.insert(i)
            if i > 0 { keep.insert(i - 1) }
            if i + 1 < windows.count { keep.insert(i + 1) }
        }
        // Pre-rolls and post-rolls often have no cue words at all.
        for (i, w) in windows.enumerated() where w.start < 90 { keep.insert(i) }
        if let last = windows.last {
            for (i, w) in windows.enumerated() where w.end > last.end - 90 { keep.insert(i) }
        }
        return keep.sorted()
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
    static func merge(_ segments: [DetectedSegment],
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
    static func extendBookends(_ segments: [DetectedSegment],
                                       duration: Double,
                                       reach: Double = 45) -> [DetectedSegment] {
        guard duration > 0 else { return segments }
        return segments.map { segment in
            var s = segment
            // Only when nothing else is there first — a pre-roll ad before the
            // intro keeps its own place.
            if s.kind == .intro, s.start <= reach,
               !segments.contains(where: { $0.kind != .intro && $0.start < s.start }) { s.start = 0 }
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
    static func snap(_ segment: DetectedSegment,
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
