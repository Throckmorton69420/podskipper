import Foundation

// MARK: - The structure detector (pass 14)
//
// Pass 13 labelled sentences one at a time, in batches, then walked every edge
// with a question per sentence. That is roughly four hundred questions an
// episode — three to five minutes of model time on a Mac — and it still missed
// things, because no single question ever saw the shape of a break: the hosts
// winding down, the set-up story, the read itself, the small print, and the
// hosts coming back.
//
// This one asks a different question, of a whole stretch at a time:
//
//     "Split this stretch into consecutive parts and say what each is."
//
// The reply is a partition — every part starts where the last one ended — so
// boundaries come out consistent by construction, and the model is reasoning
// about the passage's structure rather than about a sentence in isolation.
//
// Every stretch of the episode is read, so nothing depends on a keyword being
// present to be looked at. Stretches with any promotional signal are read a
// second time, offset by half a stretch, so two independent readings cover
// every boundary there: where they agree, confidence is high; where they
// disagree, the segment is flagged for review rather than guessed at.
//
// Cost: about two questions per three minutes of audio, against pass 13's
// four hundred per episode.

/// One part of a stretch, as the model returned it.
struct StructurePart: Sendable {
    var kind: SentenceLabel
    /// The sentence it starts at.
    var start: Int
}

/// What made the detector think this: shown in the review screen and used to
/// break ties. Facts, not opinions.
enum SegmentEvidence: String, Sendable {
    case webAddress = "a web address"
    case promoCode = "a discount code"
    case smallPrint = "small print or terms"
    case sponsorOpener = "an ad opener (\"brought to you by\")"
    case knownSponsor = "a sponsor this show has used before"
    case notesSponsor = "a sponsor named in the show notes"
    case brandRepeated = "one product named again and again"
    case tourDates = "tour dates, tickets or merch"
    case patreon = "Patreon or a bonus feed"
    case otherShow = "another show or network named"
    case signOff = "a goodbye or credits"
    case welcome = "a welcome or theme"
    case silenceAtEdges = "a pause at both edges"
    case bothReadingsAgree = "two readings agreed"
    case readingsDisagreed = "two readings disagreed"
    case sponsorBlock = "SponsorBlock viewers marked this"
    case listenerConfirmed = "like a cut you confirmed"
}

actor StructureDetector {

    /// The last run's readings, for the detection lab's trace. Not read in the app.
    nonisolated(unsafe) static var lastVotes: [[SentenceLabel]] = []
    nonisolated(unsafe) static var lastVerdicts: [Verdict] = []

    // MARK: Regions

    /// How much of the episode one question covers, and how far apart the
    /// questions start. Three minutes is about 450 words: enough to hold a
    /// whole break with the conversation either side, and well inside the
    /// model's context once the instructions are there too.
    static let regionLength: Double = 90
    static let regionStep: Double = 45

    struct Region: Sendable {
        var first: Int
        var last: Int
        var offset: Bool
    }

    /// Back-to-back stretches covering the whole episode, plus half-offset
    /// ones over anything that looks promotional, so those boundaries get two
    /// independent readings.
    static func regions(_ sentences: [Sentence], evidence: [Set<SegmentEvidence>],
                        hints: [ClosedRange<Double>]) -> [Region] {
        guard let last = sentences.last else { return [] }
        var out: [Region] = []
        func region(from time: Double, offset: Bool) -> Region? {
            guard let first = sentences.firstIndex(where: { $0.end > time }),
                  let end = sentences.lastIndex(where: { $0.start < time + regionLength }),
                  end >= first else { return nil }
            return Region(first: first, last: end, offset: offset)
        }
        var t = 0.0
        while t < last.end {
            if let r = region(from: t, offset: false) { out.append(r) }
            t += regionLength
        }
        // Second opinions where it matters: any stretch holding a signal, the
        // first two minutes and the last four (openings and sign-offs), and
        // anywhere SponsorBlock's viewers marked something.
        t = regionStep
        while t < last.end {
            let window = t...(t + regionLength)
            let interesting = sentences.indices.contains { i in
                sentences[i].start < window.upperBound && sentences[i].end > window.lowerBound && !evidence[i].isEmpty
            }
            let bookend = window.lowerBound < 120 || window.upperBound > last.end - 240
            let hinted = hints.contains { $0.lowerBound < window.upperBound && $0.upperBound > window.lowerBound }
            if interesting || bookend || hinted, let r = region(from: t, offset: true) { out.append(r) }
            t += regionLength
        }
        return out.sorted { $0.first < $1.first }
    }

    // MARK: Evidence

    private static let addresses = [".com", ".co", ".net", ".org", "dot com", " slash ", ".edu", ".io"]
    private static let codes = ["promo code", "use code", "code word", "offer code", "discount code", "coupon"]
    private static let terms = ["terms apply", "restrictions apply", "offer details", "drink responsibly",
                                "must be 21", "21 plus", "safety information", "see site for", "while supplies",
                                "not available in", "individual results"]
    private static let openers = ["brought to you by", "sponsored by", "support for this", "this episode is",
                                  "today's episode is", "this message is", "take a quick moment and",
                                  "for supporting the show", "our awesome sponsors", "one of our sponsors",
                                  "thanks to our sponsor", "let's talk about"]
    private static let tour = ["tickets", "on tour", "tour dates", "live show", "merch", "tour", "stand up",
                               "on sale", "get your tickets", "see me live"]
    private static let patreon = ["patreon", "bonus episode", "bonus feed", "subscribers", "members only",
                                  "ad free version", "ad-free version", "early access", "supercast", "substack"]
    private static let shows = ["podcast network", "wherever you get your podcasts", "new episodes of",
                                "follow the show", "another show", "spotify", "apple podcasts", "youtube channel",
                                "download the", "app store"]
    private static let goodbyes = ["thanks for listening", "see you next", "goodbye everybody", "until next time",
                                   "produced by", "engineering by", "you've been listening to", "edited by"]
    private static let welcomes = ["welcome to", "you are listening to", "this is the", "coming up on"]

    /// Cheap, deterministic facts about each sentence. Never a decision by
    /// itself: they steer where to read twice, break ties, and are shown to
    /// the listener as the reason.
    static func evidence(_ sentences: [Sentence], knownSponsors: [String], notesSponsors: [String],
                         duration: Double) -> [Set<SegmentEvidence>] {
        sentences.enumerated().map { i, sentence in
            let lower = sentence.text.lowercased()
            let plain = AdDetector.normalise(lower)
            var found: Set<SegmentEvidence> = []
            if addresses.contains(where: { lower.contains($0) }) { found.insert(.webAddress) }
            if codes.contains(where: { lower.contains($0) }) { found.insert(.promoCode) }
            if terms.contains(where: { lower.contains($0) }) { found.insert(.smallPrint) }
            if openers.contains(where: { lower.contains($0) }) { found.insert(.sponsorOpener) }
            if knownSponsors.contains(where: { plain.contains($0) }) { found.insert(.knownSponsor) }
            if notesSponsors.contains(where: { plain.contains($0) }) { found.insert(.notesSponsor) }
            if tour.contains(where: { lower.contains($0) }) { found.insert(.tourDates) }
            if patreon.contains(where: { lower.contains($0) }) { found.insert(.patreon) }
            if shows.contains(where: { lower.contains($0) }) { found.insert(.otherShow) }
            if goodbyes.contains(where: { lower.contains($0) }), sentence.start > duration * 0.5 { found.insert(.signOff) }
            if welcomes.contains(where: { lower.contains($0) }), sentence.start < 300 { found.insert(.welcome) }
            _ = i
            return found
        }
    }

    // MARK: The question

    static let instructions = """
    You are given a numbered stretch of a podcast transcript, one line per sentence. Say what it is made of.

    Most stretches are nothing but the hosts talking. When that is true, your whole answer is one line:

    1|conversation

    Only when the stretch really does contain a read or a plug, give one line per part, in order, each as <line number>|<kind>, where the number is the line that part starts at. The first part always starts at line 1, and each part runs to the line before the next one. Never invent a change: split only where the words on the page change from one thing to another.

    The kinds:
    conversation: the hosts' own talk, whatever it is about. Their jokes about a product, their lead-in to a break ("all right, here we go", "let's take a quick break"), and what they say when they come back are all conversation.
    advertisement: a paid read for a company's product, read by a host or produced. It runs from its set-up — often "this episode is brought to you by…", or a short story about a problem — through to the address, code or small print it ends with.
    selfpromotion: the show's own tour dates, tickets, merch, Patreon, bonus feed or live shows.
    crosspromotion: another podcast, a network or an app being promoted.
    opening: theme music, a network ident or a welcome, before the conversation starts.
    closing: credits, thanks and sign-off, after the hosts have said goodbye.
    """

    static func prompt(_ sentences: [Sentence], region: Region, showTitle: String,
                       sponsors: [String]) -> String {
        var lines: [String] = []
        // Numbered from 1 inside the stretch: small numbers, and the model
        // never has to know where in the episode it is.
        for i in region.first...region.last {
            lines.append("\(i - region.first + 1)| \(sentences[i].text)")
        }
        var head = ""
        if !showTitle.isEmpty { head += "The show is \"\(showTitle)\".\n" }
        if !sponsors.isEmpty { head += "Sponsors this show has read before: \(sponsors.prefix(6).joined(separator: ", ")).\n" }
        if region.first > 0 { head += "This stretch starts partway through the episode.\n" }
        return head + "\nTRANSCRIPT\n" + lines.joined(separator: "\n")
    }

    /// Reads "12|advertisement" lines into parts, dropping anything that
    /// points outside the stretch or backwards.
    static func parse(_ reply: String, region: Region) -> [StructurePart] {
        var out: [StructurePart] = []
        for raw in reply.split(whereSeparator: \.isNewline) {
            let bits = raw.split(separator: "|")
            guard bits.count >= 2, let index = Int(bits[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let word = bits[1].lowercased().trimmingCharacters(in: .whitespaces)
            let kind: SentenceLabel
            switch true {
            case word.hasPrefix("advert"), word.hasPrefix("ad"), word.hasPrefix("sponsor"): kind = .advertisement
            case word.hasPrefix("selfpromo"), word.hasPrefix("self promo"), word.hasPrefix("self-promo"): kind = .selfPromotion
            case word.hasPrefix("crosspromo"), word.hasPrefix("cross promo"), word.hasPrefix("cross-promo"),
                 word.hasPrefix("network"), word.hasPrefix("promotion"): kind = .networkPromotion
            case word.hasPrefix("open"), word.hasPrefix("intro"): kind = .opening
            case word.hasPrefix("clos"), word.hasPrefix("outro"), word.hasPrefix("credits"): kind = .closing
            case word.hasPrefix("conversation"), word.hasPrefix("content"), word.hasPrefix("show"),
                 word.hasPrefix("talk"), word.hasPrefix("normal"): kind = .content
            default: continue
            }
            let absolute = region.first + index - 1
            guard absolute >= region.first, absolute <= region.last else { continue }
            if let previous = out.last, absolute <= previous.start { continue }
            out.append(StructurePart(kind: kind, start: absolute))
        }
        if out.first?.start != region.first {
            // Whatever it called the first part, the stretch starts where it
            // starts: anything before the first named part is conversation
            // unless the model said otherwise.
            out.insert(StructurePart(kind: out.first?.kind == .content ? .content : .content, start: region.first), at: 0)
        }
        return out
    }

    // MARK: Reading the episode

    /// Reads every stretch, returns one kind per sentence per reading.
    /// `votes[i]` holds one entry per reading that covered sentence `i`.
    func read(_ sentences: [Sentence], regions: [Region], showTitle: String, sponsors: [String],
              log: inout [String], progress: ((Double) -> Void)? = nil) async -> [[SentenceLabel]] {
        var votes = [[SentenceLabel]](repeating: [], count: sentences.count)
        for (n, region) in regions.enumerated() {
            let prompt = Self.prompt(sentences, region: region, showTitle: showTitle, sponsors: sponsors)
            let reply = await AdDetector.ask(prompt, instructions: Self.instructions, log: &log,
                                             label: "structure \(Self.clock(sentences[region.first].start))",
                                             maxTokens: 90)
            guard let reply else { continue }
            let parts = Self.parse(reply, region: region)
            log.append("\(Self.clock(sentences[region.first].start)): " + parts.map { "\($0.start)\($0.kind.rawValue)" }.joined(separator: " "))
            for (index, part) in parts.enumerated() {
                let end = index + 1 < parts.count ? parts[index + 1].start - 1 : region.last
                guard part.start <= end else { continue }
                for i in part.start...end where i < votes.count { votes[i].append(part.kind) }
            }
            progress?(Double(n + 1) / Double(max(1, regions.count)))
        }
        return votes
    }

    static func clock(_ seconds: Double) -> String { SegmentDetector.clock(seconds) }
}

// MARK: - From readings to segments

extension StructureDetector {

    /// One sentence's verdict, with how sure the readings were.
    struct Verdict: Sendable {
        var kind: SentenceLabel
        var agreed: Bool
        var readings: Int
    }

    /// What the readings say about each sentence.
    static func verdicts(_ votes: [[SentenceLabel]], evidence: [Set<SegmentEvidence>]) -> [Verdict] {
        votes.enumerated().map { i, vote in
            guard let first = vote.first else { return Verdict(kind: .content, agreed: false, readings: 0) }
            if vote.allSatisfy({ $0 == first }) { return Verdict(kind: first, agreed: true, readings: vote.count) }
            var counts: [SentenceLabel: Int] = [:]
            for v in vote { counts[v, default: 0] += 1 }
            let top = counts.max { a, b in a.value < b.value }!
            let tied = counts.filter { $0.value == top.value }.count > 1
            if tied {
                // One reading says promotion, the other conversation. Follow
                // the promotion only where the words back it up; otherwise
                // leave it in the show, because cutting the show is the
                // mistake the listener actually notices.
                let promotional = vote.first { $0 != .content }
                let backed = !evidence[i].isEmpty
                return Verdict(kind: backed ? (promotional ?? .content) : .content, agreed: false, readings: vote.count)
            }
            return Verdict(kind: top.key, agreed: false, readings: vote.count)
        }
    }

    /// Runs of one kind, with confidence, boundary confidence and evidence.
    static func assemble(_ sentences: [Sentence], verdicts: [Verdict], evidence: [Set<SegmentEvidence>],
                         silences: [ClosedRange<Double>], hints: [ClosedRange<Double>],
                         memory: FeedbackMemory, log: inout [String]) -> [SegmentFinding] {
        var findings: [SegmentFinding] = []
        var i = 0
        while i < verdicts.count {
            guard let kind = verdicts[i].kind.kind else { i += 1; continue }
            var j = i
            while j + 1 < verdicts.count, verdicts[j + 1].kind == verdicts[i].kind { j += 1 }
            findings.append(build(sentences, from: i, to: j, kind: kind, verdicts: verdicts,
                                  evidence: evidence, silences: silences, hints: hints, memory: memory))
            i = j + 1
        }
        // A read the two readings split in the middle: same kind, a sentence
        // or two of "conversation" between, none of it agreed on.
        var merged: [SegmentFinding] = []
        for finding in findings {
            if var previous = merged.last, previous.kind == finding.kind,
               finding.start - previous.end <= 8,
               (previous.lastSentence + 1..<finding.firstSentence).allSatisfy({ !verdicts[$0].agreed }) {
                previous.end = finding.end
                previous.lastSentence = finding.lastSentence
                previous.endConfidence = finding.endConfidence
                previous.confidence = min(previous.confidence, finding.confidence)
                previous.evidence = Array(Set(previous.evidence + finding.evidence))
                if previous.sponsor.isEmpty { previous.sponsor = finding.sponsor }
                merged[merged.count - 1] = previous
                log.append("joined \(clock(previous.start))–\(clock(previous.end)): the two readings split one \(finding.kind.rawValue)")
                continue
            }
            merged.append(finding)
        }
        return merged.filter { finding in
            // Floors, unless the words themselves say it is a read.
            let strong = finding.evidence.contains(SegmentEvidence.webAddress.rawValue)
                || finding.evidence.contains(SegmentEvidence.promoCode.rawValue)
                || finding.evidence.contains(SegmentEvidence.sponsorOpener.rawValue)
            let floor: Double = finding.kind == .ad ? (strong ? 6 : 12) : (strong ? 3 : 5)
            if finding.end - finding.start < floor {
                log.append("\(clock(finding.start)) \(finding.kind.rawValue) dropped: \(Int(finding.end - finding.start)) s, nothing in it says otherwise")
                return false
            }
            return true
        }
    }

    private static func build(_ sentences: [Sentence], from first: Int, to last: Int, kind: SegmentKind,
                              verdicts: [Verdict], evidence: [Set<SegmentEvidence>],
                              silences: [ClosedRange<Double>], hints: [ClosedRange<Double>],
                              memory: FeedbackMemory) -> SegmentFinding {
        let range = first...last
        let agreed = range.filter { verdicts[$0].agreed }.count
        let twice = range.filter { verdicts[$0].readings >= 2 }.count
        var confidence: Int
        if twice == 0 {
            // Read once. Fine, but not the same as two readings agreeing.
            confidence = 70
        } else {
            confidence = Int(100 * Double(agreed) / Double(range.count))
        }
        var facts = range.reduce(into: Set<SegmentEvidence>()) { $0.formUnion(evidence[$1]) }
        if twice > 0 { facts.insert(agreed == range.count ? .bothReadingsAgree : .readingsDisagreed) }
        if !facts.isEmpty, facts != [.readingsDisagreed] { confidence = min(100, confidence + 8) }

        // Repeated product name: a read says what it is selling over and over.
        let lines = sentences[range]
        if !SegmentDetector.salient(lines).isEmpty, kind == .ad { facts.insert(.brandRepeated) }

        var start = sentences[first].start
        var end = sentences[last].end
        var startConfidence = edgeConfidence(at: first, inward: 1, verdicts: verdicts)
        var endConfidence = edgeConfidence(at: last, inward: -1, verdicts: verdicts)

        // A cut lands better in a pause, and a pause at the edge is itself
        // evidence that this is where the join is.
        var snapped = 0
        if let pause = silences.filter({ abs($0.upperBound - start) <= 1.5 })
            .min(by: { abs($0.upperBound - start) < abs($1.upperBound - start) }) {
            start = pause.upperBound
            startConfidence = min(100, startConfidence + 15)
            snapped += 1
        }
        if let pause = silences.filter({ abs($0.lowerBound - end) <= 1.5 })
            .min(by: { abs($0.lowerBound - end) < abs($1.lowerBound - end) }) {
            end = pause.lowerBound
            endConfidence = min(100, endConfidence + 15)
            snapped += 1
        }
        if snapped == 2 { facts.insert(.silenceAtEdges) }

        if hints.contains(where: { $0.lowerBound < end && $0.upperBound > start }) { facts.insert(.sponsorBlock) }
        let text = lines.map(\.text).joined(separator: " ")
        if case .confirmed = memory.match(text) {
            facts.insert(.listenerConfirmed)
            confidence = min(100, confidence + 10)
        }
        return SegmentFinding(kind: kind, start: start, end: end,
                              sponsor: kind == .ad ? SegmentDetector.sponsorName(in: text) : "",
                              confidence: confidence,
                              startConfidence: startConfidence, endConfidence: endConfidence,
                              firstSentence: first, lastSentence: last,
                              evidence: facts.map(\.rawValue).sorted())
    }

    /// How sure the edge is: both readings agreeing on the sentence inside and
    /// the one outside is what a clear boundary looks like.
    private static func edgeConfidence(at index: Int, inward: Int, verdicts: [Verdict]) -> Int {
        let outside = index - inward
        var score = 50
        if verdicts[index].agreed { score += 25 }
        if outside >= 0, outside < verdicts.count {
            if verdicts[outside].agreed { score += 25 }
            if verdicts[outside].kind == verdicts[index].kind { score -= 20 }
        } else {
            score += 25
        }
        return min(100, max(0, score))
    }
}

// MARK: - The whole run

extension StructureDetector {

    /// Reads the episode and returns its promotional segments.
    func detect(segments: [TranscriptSegment],
                knownSponsors: [String] = [],
                corrections: [DetectionCorrection] = [],
                globalCorrections: [DetectionCorrection] = [],
                showTitle: String = "",
                episodeTitle: String = "",
                showNotes: String = "",
                silences: [ClosedRange<Double>] = [],
                hints: [ClosedRange<Double>] = [],
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> (findings: [SegmentFinding], log: [String]) {
        if let reason = AdDetector.availability() { throw AdDetectorError.modelUnavailable(reason) }
        let sentences = SegmentDetector.sentences(from: segments)
        guard let lastSentence = sentences.last else { return ([], []) }
        var log = ["sentences: \(sentences.count)"]

        let noteSponsors = AdDetector.sponsorsFromNotes(showNotes)
        let known = knownSponsors.map(AdDetector.normalise).filter { $0.count >= 3 }
        let evidence = Self.evidence(sentences, knownSponsors: known,
                                     notesSponsors: noteSponsors.map(AdDetector.normalise),
                                     duration: lastSentence.end)
        let regions = Self.regions(sentences, evidence: evidence, hints: hints)
        log.append("stretches: \(regions.count) (\(regions.filter(\.offset).count) read a second time)")

        let votes = await read(sentences, regions: regions, showTitle: showTitle,
                               sponsors: Array(Set(knownSponsors + noteSponsors)).sorted(),
                               log: &log) { progress?(0.9 * $0) }
        Self.lastVotes = votes

        let verdicts = Self.verdicts(votes, evidence: evidence)
        Self.lastVerdicts = verdicts
        let own = Set(corrections.map(\.excerpt))
        let memory = FeedbackMemory(corrections: corrections + globalCorrections.filter { !own.contains($0.excerpt) })
        var findings = Self.assemble(sentences, verdicts: verdicts, evidence: evidence,
                                     silences: silences, hints: hints, memory: memory, log: &log)

        // What the listener has already rejected on this show, gone.
        if !memory.isEmpty {
            findings = findings.filter { finding in
                let text = sentences[finding.firstSentence...finding.lastSentence].map(\.text).joined(separator: " ")
                if case .rejected(let similarity) = memory.match(text) {
                    log.append("\(Self.clock(finding.start)) dropped: like one you rejected (\(similarity))")
                    return false
                }
                return true
            }
        }
        for finding in findings {
            log.append("final \(finding.kind.rawValue) \(Self.clock(finding.start))–\(Self.clock(finding.end)) "
                       + "conf \(finding.confidence) edges \(finding.startConfidence)/\(finding.endConfidence) "
                       + "[\(finding.evidence.joined(separator: ", "))]")
        }
        progress?(1)
        return (findings, log)
    }
}
