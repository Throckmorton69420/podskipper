import Foundation

// MARK: - The sentence-level detector (pass 13)
//
// Replaces the window detector's structure; see claude/DETECTION-AUDIT.md for
// why. The short version: the old detector decided in 45-second windows and
// 12-second pieces, let single keywords overrule the model, pulled edges back
// to any line with a cue word, and fused neighbouring cuts. On Matt and Shane's
// Secret Podcast 633 that turned a 20-second ad into a 47-second cut, a
// BlueChew read plus the hosts' own tour dates into one three-minute "ad", and
// "Let's do the Patreon. Goodbye everybody." into a Patreon promotion.
//
// This one works on sentences, with the time of every word:
//
// 1. Sentences, built from word times (a recognizer chunk can hold the end of
//    one thing and the start of the next).
// 2. Candidates: cheap signals decide which stretches are worth reading —
//    permissive on purpose, because a stretch not read here is never cut.
// 3. Labels: the model labels numbered sentences in overlapping batches, with
//    unlabelled context either side, using a fuller set of types than before.
//    Keywords never overrule it.
// 4. Smoothing: a Viterbi pass over the labels, so the answer is a sensible
//    sequence — conversation, ad, self-promotion, conversation — not a
//    flicker of independent guesses.
// 5. Spans: runs of one type, edged on the first and last word, each with a
//    confidence for its type and for each edge.

/// What a sentence is doing. Richer than `SegmentKind`: conversation is a
/// label in its own right, and so is the show's own sign-off.
enum SentenceLabel: Character, CaseIterable, Sendable {
    /// The show itself, including jokes about sponsors, mentions of Patreon,
    /// "let's take a break" and the hosts' own goodbye.
    case content = "C"
    /// A paid read, host-read or produced, including the hosts joking about
    /// that product straight after it.
    case advertisement = "A"
    /// The show's own things: tour dates, merch, Patreon, bonus episodes.
    case selfPromotion = "S"
    /// Another show, a network, an app: "watch us on Spotify", "download the
    /// SiriusXM app".
    case networkPromotion = "N"
    /// The opening before the conversation: theme, network ident, "welcome to".
    case opening = "I"
    /// After the goodbye: credits, theme, "thanks for listening".
    case closing = "O"

    var kind: SegmentKind? {
        switch self {
        case .content: return nil
        case .advertisement: return .ad
        case .selfPromotion: return .selfPromo
        case .networkPromotion: return .crossPromo
        case .opening: return .intro
        case .closing: return .outro
        }
    }
}

/// One sentence, from its first word to its last.
struct Sentence: Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A span the detector is offering, with what it is unsure of.
struct SegmentFinding: Sendable {
    var kind: SegmentKind
    var start: Double
    var end: Double
    var sponsor: String
    /// How consistently its sentences were given its type, 0–100.
    var confidence: Int
    /// How clear the change is at each edge, 0–100: the labels either side
    /// agree, and the sentence just outside was read as conversation.
    var startConfidence: Int
    var endConfidence: Int
    /// First and last sentence indexes, for the review screen's transcript.
    var firstSentence: Int
    var lastSentence: Int
}

actor SegmentDetector {

    /// The last run's votes, for the detection lab's trace. Never read in the app.
    nonisolated(unsafe) static var lastVotes: [[SentenceLabel: Int]] = []

    /// What the listener's dragged handles taught about this show's edges:
    /// words they cut away (outside) and words they pulled in (inside).
    private var lessons: (inside: [String], outside: [String]) = ([], [])

    private static func lessonMatch(_ sentence: String, _ phrases: [String]) -> Bool {
        let plain = AdDetector.normalise(sentence)
        guard plain.split(separator: " ").count >= 2 else { return false }
        return phrases.contains { p in
            (p.split(separator: " ").count >= 3 && plain.contains(p)) || (plain.split(separator: " ").count >= 3 && p.contains(plain))
        }
    }

    // MARK: Sentences

    /// Recognizer chunks split into sentences at . ? ! using each word's time.
    /// A chunk with no word times (a transcript stored before pass 13) is kept
    /// whole.
    static func sentences(from segments: [TranscriptSegment]) -> [Sentence] {
        var out: [Sentence] = []
        for segment in segments {
            guard !segment.words.isEmpty else {
                let text = segment.text.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { out.append(Sentence(text: text, start: segment.start, end: segment.end)) }
                continue
            }
            var current: [TranscriptWord] = []
            func flush() {
                guard let first = current.first, let last = current.last else { return }
                let text = current.map(\.text).joined(separator: " ")
                    .replacingOccurrences(of: " ,", with: ",")
                out.append(Sentence(text: text, start: first.start, end: last.end))
                current = []
            }
            for word in segment.words {
                // A long pause is a boundary even without punctuation.
                if let last = current.last, word.start - last.end > 1.2 { flush() }
                current.append(word)
                if let mark = word.text.last, ".?!".contains(mark), current.count >= 2 { flush() }
            }
            flush()
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Candidates

    /// Words that make a window worth asking about. Only ever a reason to
    /// look — never, as before, a reason to cut.
    static let cues = [
        "sponsor", "brought to you", "support for", "promo code", "use code", "offer code",
        "code ", ".com", "dot com", " slash ", "percent off", "% off", "free trial", "terms apply",
        "restrictions apply", "offer details", "patreon", "merch", "tickets", "tour", "on sale",
        "subscribe", "rate and review", "wherever you get", "spotify", "download the", "app store",
        "free shipping", "first order", "first purchase", "save ", "drink responsibly", "21 plus",
        "must be 21", "visit ", "go to ", "head to ", "sign up", "limited time", "new episodes",
        "listen to", "this episode", "today's episode", "thanks for listening", "produced by",
        "welcome to", "goodbye", "see you next"
    ]

    // MARK: Labelling

    static let labelInstructions = """
    You label every numbered sentence of a podcast transcript with one letter.

    Reply with a single line of number-letter pairs and nothing else, like this:
    1C 2C 3C 4A 5A 6A 7S 8C

    C  the show itself: the hosts and guests talking. This includes joking about a sponsor or about doing an ad, mentioning Patreon or a product as part of the conversation, "let's take a break", "let's do the Patreon", and the hosts saying goodbye.
    A  an advertisement: a paid read for a company's product, read by a host or a produced commercial, from its first sentence about the product through the offer, the code or website and any legal line. The hosts joking about that same product right after the read are still A.
    S  the show promoting itself: its own tour dates and tickets, merch, Patreon or membership, bonus or ad-free episodes, a host's own special or book.
    N  promoting something else that is not a paid product read: another podcast, a network, or an app or platform ("new episodes on Spotify", "download the SiriusXM app").
    I  the opening before the conversation: theme song, network announcement, "welcome to the show".
    O  after the goodbye: closing theme, credits, "thanks for listening".

    Judge each sentence by what it is doing where it is, never by a single word. The sentences marked BEFORE and AFTER are context only; do not label them.
    """

    private struct Batch {
        let indexes: Range<Int>
    }

    /// Overlapping batches of `size` sentences, `step` apart, covering the
    /// sentences inside `ranges`.
    private static func batches(_ sentences: [Sentence], ranges: [ClosedRange<Double>],
                                size: Int = 12, step: Int = 6) -> [Batch] {
        var out: [Batch] = []
        for range in ranges {
            guard let first = sentences.firstIndex(where: { $0.end > range.lowerBound }),
                  let last = sentences.lastIndex(where: { $0.start < range.upperBound }),
                  first <= last else { continue }
            var cursor = first
            while cursor <= last {
                let upper = min(cursor + size, last + 1)
                out.append(Batch(indexes: cursor..<upper))
                if upper > last { break }
                cursor += step
            }
        }
        return out
    }

    private static func prompt(_ batch: Batch, sentences: [Sentence], showTitle: String) -> String {
        let before = sentences[max(0, batch.indexes.lowerBound - 5)..<batch.indexes.lowerBound]
            .map(\.text).joined(separator: " ")
        let after = sentences[batch.indexes.upperBound..<min(sentences.count, batch.indexes.upperBound + 5)]
            .map(\.text).joined(separator: " ")
        var lines: [String] = []
        let show = AdDetector.scrub(showTitle)
        if !show.isEmpty { lines.append("Show: \(show).") }
        lines.append("BEFORE: \(before.isEmpty ? "(start of episode)" : before)")
        for (n, index) in batch.indexes.enumerated() {
            lines.append("\(n + 1). \(sentences[index].text)")
        }
        lines.append("AFTER: \(after.isEmpty ? "(end of episode)" : after)")
        return lines.joined(separator: "\n")
    }

    /// "1C 2A 3a" → [0: C, 1: A, 2: A].
    static func parseLabels(_ reply: String, count: Int) -> [Int: SentenceLabel] {
        var out: [Int: SentenceLabel] = [:]
        let pattern = try! Regex(#"(\d+)\s*[\.:=\-]?\s*([A-Za-z])\b"#)
        for match in reply.matches(of: pattern) {
            guard let n = Int(match.output[1].substring ?? ""), n >= 1, n <= count,
                  let letter = match.output[2].substring?.uppercased().first,
                  let label = SentenceLabel(rawValue: letter) else { continue }
            if out[n - 1] == nil { out[n - 1] = label }
        }
        return out
    }

    // MARK: Smoothing

    /// The most likely sequence of labels given the votes.
    ///
    /// Each sentence's votes give it a score for each label; changing label
    /// costs something, so a single odd vote inside a run doesn't split it,
    /// but a change the votes agree on goes through. Sentences nobody read
    /// (outside every candidate stretch) are conversation.
    static func smooth(_ votes: [[SentenceLabel: Int]], sentences: [Sentence]) -> [SentenceLabel] {
        let labels = SentenceLabel.allCases
        let n = votes.count
        guard n > 0 else { return [] }
        let duration = sentences.last?.end ?? 0

        func emission(_ i: Int, _ label: SentenceLabel) -> Double {
            let v = votes[i]
            let total = v.values.reduce(0, +)
            // Position: an opening can only be near the start, a closing
            // only near the end.
            if label == .opening, sentences[i].start > 240 { return -30 }
            if label == .closing, sentences[i].end < duration - 360 { return -30 }
            guard total > 0 else { return label == .content ? 0 : -8 }
            let share = Double(v[label] ?? 0) / Double(total)
            // Laplace-ish, in log space: agreement is cheap, disagreement dear.
            return log(0.03 + 0.97 * share)
        }
        func transition(_ a: SentenceLabel, _ b: SentenceLabel) -> Double {
            if a == b { return 0 }
            if a == .content || b == .content { return -3.0 }
            return -1.2  // ad → self-promotion needs no conversation between
        }

        var score = [[Double]](repeating: [Double](repeating: -.infinity, count: labels.count), count: n)
        var back = [[Int]](repeating: [Int](repeating: 0, count: labels.count), count: n)
        for (k, label) in labels.enumerated() {
            score[0][k] = emission(0, label) + (label == .content ? 0 : -1)
        }
        for i in 1..<n {
            for (k, label) in labels.enumerated() {
                let e = emission(i, label)
                var best = -Double.infinity, arg = 0
                for (j, previous) in labels.enumerated() {
                    let s = score[i - 1][j] + transition(previous, label)
                    if s > best { best = s; arg = j }
                }
                score[i][k] = best + e
                back[i][k] = arg
            }
        }
        var k = score[n - 1].indices.max { score[n - 1][$0] < score[n - 1][$1] } ?? 0
        var path = [SentenceLabel](repeating: .content, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            path[i] = labels[k]
            k = back[i][k]
        }
        return path
    }

    // MARK: Detection

    /// Every stage, start to finish.
    func detect(segments: [TranscriptSegment],
                knownSponsors: [String] = [],
                corrections: [DetectionCorrection] = [],
                globalCorrections: [DetectionCorrection] = [],
                showTitle: String = "",
                episodeTitle: String = "",
                showNotes: String = "",
                minimumConfidence: Int = 60,
                hints: [ClosedRange<Double>] = [],
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> (findings: [SegmentFinding], log: [String]) {
        if let reason = AdDetector.availability() { throw AdDetectorError.modelUnavailable(reason) }
        let edgeLessons = corrections.filter { $0.boundary != nil }
        lessons = (edgeLessons.filter { $0.boundary?.hasPrefix("inside") == true }.map { AdDetector.normalise($0.excerpt) },
                   edgeLessons.filter { $0.boundary?.hasPrefix("outside") == true }.map { AdDetector.normalise($0.excerpt) })
        let sentences = Self.sentences(from: segments)
        guard !sentences.isEmpty else { return ([], []) }
        var log: [String] = ["sentences: \(sentences.count)"]
        let noteSponsors = AdDetector.sponsorsFromNotes(showNotes)
        let names = (knownSponsors + noteSponsors).map(AdDetector.normalise).filter { $0.count >= 3 }

        // 1. Where to look.
        var hits = await screen(sentences, names: names, episodeTitle: episodeTitle, log: &log) {
            progress?(0.35 * $0)
        }
        // Outside evidence (SponsorBlock, for a show with a YouTube upload):
        // somewhere to look, never a cut by itself.
        if !hints.isEmpty {
            log.append("hints: \(hints.map { "\(Self.clock($0.lowerBound))–\(Self.clock($0.upperBound))" })")
            hits += hints
        }
        let ranges = Self.lookRanges(hits: hits, sentences: sentences)
        let covered = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        log.append("reading \(ranges.count) stretches, \(Int(covered)) s of \(Int(sentences.last!.end)) s")

        // 2. What each sentence is.
        let votes = await label(sentences, ranges: ranges, names: names, showTitle: showTitle, log: &log) {
            progress?(0.35 + 0.3 * $0)
        }
        Self.lastVotes = votes

        // 3. The sequence, as spans.
        var findings = Self.assemble(sentences, votes: votes, corrections: corrections,
                                     globalCorrections: globalCorrections,
                                     minimumConfidence: minimumConfidence, log: &log)

        findings = Self.bridge(findings, sentences: sentences, votes: votes, log: &log)

        // 4. Is each span what it says it is, read as a whole in context?
        var verified: [SegmentFinding] = []
        for finding in findings {
            if let kept = await verify(finding, sentences: sentences, log: &log) { verified.append(kept) }
        }
        findings = await joinParts(verified, sentences: sentences, log: &log)

        // Screening said a window was promotional and the sentence labels
        // produced nothing there: the labels are close to a coin toss on
        // chatty stretches (tour dates read between jokes), and the question
        // about a whole section is not. So the window becomes a span, the
        // section question says what kind it is, and the edges are walked.
        for hit in hits where !findings.contains(where: { $0.start < hit.upperBound && $0.end > hit.lowerBound }) {
            guard let first = sentences.firstIndex(where: { $0.end > hit.lowerBound }),
                  let last = sentences.lastIndex(where: { $0.start < hit.upperBound }), first < last else { continue }
            let probe = SegmentFinding(kind: .ad, start: sentences[first].start, end: sentences[last].end,
                                       sponsor: "", confidence: 50, startConfidence: 30, endConfidence: 30,
                                       firstSentence: first, lastSentence: last)
            if let kind = await classify(probe, sentences: sentences, log: &log) {
                var found = probe
                found.kind = kind
                found.sponsor = kind == .ad ? Self.sponsorName(in: sentences[first...last].map(\.text).joined(separator: " ")) : ""
                log.append("from screening: \(kind.rawValue) \(Self.clock(found.start))–\(Self.clock(found.end))")
                findings.append(found)
            }
        }
        findings.sort { $0.start < $1.start }
        progress?(0.75)

        // 5. Each edge, sentence by sentence.
        for (n, finding) in findings.enumerated() {
            findings[n] = await refine(finding, sentences: sentences, others: findings, log: &log)
            progress?(0.75 + 0.25 * Double(n + 1) / Double(max(1, findings.count)))
        }
        // A paid read under ten seconds is a brand named in passing; a plug
        // under four is a phrase.
        findings = findings.filter { f in
            let floor: Double = f.kind == .ad ? 10 : 2.5
            if f.end - f.start < floor { log.append("\(Self.clock(f.start)) \(f.kind.rawValue) dropped after edges: too short"); return false }
            return true
        }

        // 6. What the words themselves say about the edges.
        findings = Self.mergeReads(findings, sentences: sentences, log: &log)
        let grown = Self.grow(findings, sentences: sentences, votes: votes, log: &log)
        for n in grown.indices where grown[n].start != findings[n].start || grown[n].end != findings[n].end {
            // Moved: the walk continues from the new edge, and may only add.
            let again = await refine(grown[n], sentences: sentences, others: grown, log: &log)
            var out = grown[n]
            if again.firstSentence < out.firstSentence { out.firstSentence = again.firstSentence; out.start = again.start }
            if again.lastSentence > out.lastSentence { out.lastSentence = again.lastSentence; out.end = again.end }
            findings[n] = out
        }
        findings = Self.settle(findings, sentences: sentences, log: &log)
        for finding in findings {
            log.append("final \(finding.kind.rawValue) \(Self.clock(finding.start))–\(Self.clock(finding.end)) conf \(finding.confidence) edges \(finding.startConfidence)/\(finding.endConfidence)")
        }
        progress?(1)
        return (findings, log)
    }

    // MARK: 1. Screening

    /// The window question the old detector asked, now used only to decide
    /// where to look. It was good at that — on both reference episodes it
    /// found every break — and bad only at what it was also used for: edges
    /// and kinds. Nothing it says becomes a cut by itself.
    func screen(_ sentences: [Sentence], names: [String], episodeTitle: String,
                log: inout [String], progress: ((Double) -> Void)? = nil) async -> [ClosedRange<Double>] {
        let windows = Self.windows(sentences)
        let asked = windows.indices.filter { i in
            let lower = windows[i].text.lowercased()
            let plain = AdDetector.normalise(lower)
            return Self.cues.contains(where: { lower.contains($0) })
                || names.contains(where: { plain.contains($0) })
                || windows[i].start < 120 || windows[i].end > (sentences.last?.end ?? 0) - 180
        }
        log.append("windows: \(windows.count), asked about: \(asked.count)")
        var hits: [ClosedRange<Double>] = []
        for (n, i) in asked.enumerated() {
            defer { progress?(Double(n + 1) / Double(max(1, asked.count))) }
            let w = windows[i]
            let before = i > 0 ? windows[i - 1].text.split(separator: " ").suffix(50).joined(separator: " ") : ""
            let after = i + 1 < windows.count ? windows[i + 1].text.split(separator: " ").prefix(50).joined(separator: " ") : ""
            let prompt = "CONTEXT BEFORE:\n\(before.isEmpty ? "(start of episode)" : before)\n\nPASSAGE:\n\(w.text)\n\nCONTEXT AFTER:\n\(after.isEmpty ? "(end of episode)" : after)"
            guard let reply = await AdDetector.ask(prompt, instructions: AdDetector.windowInstructions,
                                                   log: &log, label: "window \(Self.clock(w.start))") else { continue }
            let kind = AdDetector.fields(reply)["kind"] ?? "content"
            if !kind.hasPrefix("content") { hits.append(w.start...w.end) }
        }
        log.append("windows that looked promotional: \(hits.count)")
        return hits
    }

    /// 45-second windows of sentences, 10 seconds overlapping.
    static func windows(_ sentences: [Sentence], length: Double = 45, overlap: Double = 10) -> [Sentence] {
        guard let last = sentences.last else { return [] }
        var out: [Sentence] = []
        var cursor = 0.0
        while cursor < last.end {
            let inside = sentences.filter { $0.start < cursor + length && $0.end > cursor }
            if let first = inside.first, let end = inside.last {
                out.append(Sentence(text: inside.map(\.text).joined(separator: " "), start: first.start, end: end.end))
            }
            cursor += length - overlap
        }
        return out
    }

    /// Screening hits widened by 40 s, so the sentences either side of a
    /// break are read too, plus the opening and closing minutes.
    static func lookRanges(hits: [ClosedRange<Double>], sentences: [Sentence]) -> [ClosedRange<Double>] {
        guard let last = sentences.last else { return [] }
        var ranges = hits.map { max(0, $0.lowerBound - 60)...min(last.end, $0.upperBound + 60) }
        // Lines with an ad's or a plug's own words are read with their
        // neighbours even when the window question passed over them: a tour
        // date list read after a sponsor was missed that way.
        for sentence in sentences {
            let lower = sentence.text.lowercased()
            if strongCues.contains(where: { lower.contains($0) }) {
                ranges.append(max(0, sentence.start - 30)...min(last.end, sentence.end + 30))
            }
        }
        ranges.append(0...min(last.end, 120))
        ranges.append(max(0, last.end - 180)...last.end)
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in sorted {
            if let tail = merged.last, range.lowerBound <= tail.upperBound + 5 {
                merged[merged.count - 1] = tail.lowerBound...max(tail.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// Words that are an ad's or a plug's own: a web address, a code, a
    /// ticket. Reasons to read the lines around them, never to cut.
    static let strongCues = [".com", "dot com", " slash ", "promo code", "use code", "offer code",
                             "brought to you by", "sponsored by", "support for this", "patreon",
                             "tickets", "on tour", "tour dates", "merch", "terms apply", "percent off", "% off"]

    // MARK: 2. Sentence labels

    func label(_ sentences: [Sentence], ranges: [ClosedRange<Double>], names: [String],
               showTitle: String, log: inout [String],
               progress: ((Double) -> Void)? = nil) async -> [[SentenceLabel: Int]] {
        var instructions = Self.labelInstructions
        let known = names.prefix(12)
        if !known.isEmpty {
            instructions += "\nThis show's sponsors have included: \(known.joined(separator: ", ")). Naming one in conversation is still C."
        }
        let batches = Self.batches(sentences, ranges: ranges)
        log.append("sentence batches: \(batches.count)")
        var votes = [[SentenceLabel: Int]](repeating: [:], count: sentences.count)
        for (n, batch) in batches.enumerated() {
            defer { progress?(Double(n + 1) / Double(max(1, batches.count))) }
            let prompt = Self.prompt(batch, sentences: sentences, showTitle: showTitle)
            guard let reply = await AdDetector.ask(prompt, instructions: instructions, log: &log,
                                                   label: "batch \(n)", maxTokens: 120) else { continue }
            let labels = Self.parseLabels(reply, count: batch.indexes.count)
            if labels.count < batch.indexes.count / 2 {
                log.append("batch \(n) unreadable: \(reply.prefix(80))")
                continue
            }
            for (offset, label) in labels {
                votes[batch.indexes.lowerBound + offset][label, default: 0] += 1
            }
        }
        return votes
    }

    // MARK: 3. Spans

    /// Smoothing, spans, confidence and what the listener has already said.
    /// Fast and deterministic given the votes.
    static func assemble(_ sentences: [Sentence],
                         votes: [[SentenceLabel: Int]],
                         corrections: [DetectionCorrection] = [],
                         globalCorrections: [DetectionCorrection] = [],
                         minimumConfidence: Int = 60,
                         log: inout [String]) -> [SegmentFinding] {
        let path = smooth(votes, sentences: sentences)
        var findings: [SegmentFinding] = []
        var i = 0
        while i < path.count {
            guard let kind = path[i].kind else { i += 1; continue }
            var j = i
            while j + 1 < path.count, path[j + 1] == path[i] { j += 1 }
            findings += spans(from: i, to: j, label: path[i], kind: kind,
                              sentences: sentences, votes: votes, path: path)
            i = j + 1
        }

        // What the listener has already said about passages like these.
        let own = Set(corrections.map(\.excerpt))
        let memory = FeedbackMemory(corrections: corrections + globalCorrections.filter { !own.contains($0.excerpt) })
        if !memory.isEmpty {
            findings = findings.filter { finding in
                let text = sentences[finding.firstSentence...finding.lastSentence].map(\.text).joined(separator: " ")
                if case .rejected(let similarity) = memory.match(text) {
                    log.append("\(clock(finding.start)) dropped: like one the listener rejected (\(similarity))")
                    return false
                }
                return true
            }
        }
        // Shorter than the thing it claims to be can be. A paid read under ten
        // seconds is a brand named in passing; a plug under four is a phrase.
        findings = findings.filter { f in
            let length = f.end - f.start
            // Pieces are kept down to a second here: a 5 s "brought to you
            // by…" opener, or a lone "Go to mattmcusker.com" inside a list of
            // tour dates, is how the rest of the read or plug gets found and
            // joined. The real floor is applied after joining.
            let floor: Double = 0.8
            if length < floor { log.append("\(clock(f.start)) \(f.kind.rawValue) dropped: \(Int(length)) s is too short"); return false }
            if f.confidence < max(20, minimumConfidence - 40) { log.append("\(clock(f.start)) dropped: confidence \(f.confidence)"); return false }
            return true
        }
        for finding in findings {
            log.append("span \(finding.kind.rawValue) \(clock(finding.start))–\(clock(finding.end)) conf \(finding.confidence) edges \(finding.startConfidence)/\(finding.endConfidence)")
        }
        return findings
    }

    /// Two spans of the same kind with one short line between them are one
    /// span: "Guys, we've been wearing Vuori… Jim errands… And the Stratotech
    /// T?" is one read with a line the labeller called conversation.
    static func bridge(_ findings: [SegmentFinding], sentences: [Sentence],
                       votes: [[SentenceLabel: Int]], log: inout [String]) -> [SegmentFinding] {
        // Neighbouring pieces a few seconds apart are one thing to judge when
        // they are the same kind, or when one of them is a fragment: the
        // labels break a chatty tour-date list into one- and two-second
        // pieces of three different kinds, and a fragment shown alone reads
        // as conversation. Two substantial spans of different kinds — a
        // sponsor read and then the hosts' own plug — stay apart, and so do
        // two ads when the second opens as a new one.
        var out: [SegmentFinding] = []
        for f in findings.sorted(by: { $0.start < $1.start }) {
            guard var previous = out.last, f.start - previous.end <= 8,
                  !opensAnAd(sentences[f.firstSentence].text) else { out.append(f); continue }
            let fragment = min(previous.end - previous.start, f.end - f.start) < 6
            // …but a stray line next to a full read is not part of the read:
            // "Watch new episodes on Spotify" before a post-roll ad is its
            // own plug.
            let substantialAd = (previous.kind == .ad && previous.end - previous.start >= 15)
                || (f.kind == .ad && f.end - f.start >= 15)
            guard previous.kind == f.kind || (fragment && !substantialAd) else { out.append(f); continue }
            if previous.kind == .ad, f.kind == .ad, !sameSponsor(previous, f, sentences: sentences) { out.append(f); continue }
            // The kind of whichever part is longer, until the section
            // question says otherwise.
            if f.end - f.start > previous.end - previous.start { previous.kind = f.kind }
            previous.end = f.end
            previous.lastSentence = f.lastSentence
            previous.endConfidence = f.endConfidence
            previous.confidence = (previous.confidence + f.confidence) / 2
            if previous.sponsor.isEmpty { previous.sponsor = f.sponsor }
            out[out.count - 1] = previous
            log.append("grouped \(clock(previous.start))–\(clock(f.end)) as \(previous.kind.rawValue)")
        }
        return out
    }

    static func opensAnAd(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["brought to you by", "sponsored by", "support for this", "this episode is", "today's episode is",
                "this message is", "this podcast is", "take a quick moment and", "for supporting the show",
                "our awesome sponsors", "one of our sponsors"].contains { lower.contains($0) }
    }

    static func sameSponsor(_ a: SegmentFinding, _ b: SegmentFinding, sentences: [Sentence]) -> Bool {
        let x = AdDetector.normalise(a.sponsor).replacingOccurrences(of: " ", with: "")
        let y = AdDetector.normalise(b.sponsor).replacingOccurrences(of: " ", with: "")
        if !x.isEmpty, !y.isEmpty {
            // Recognizer spellings wander ("Vyori", "vori"): letter pairs in common.
            func pairs(_ t: String) -> Set<String> {
                let c = Array(t)
                return Set((0..<max(0, c.count - 1)).map { String(c[$0...$0 + 1]) })
            }
            let p = pairs(x), q = pairs(y)
            guard !p.isEmpty, !q.isEmpty else { return x == y }
            return Double(p.intersection(q).count) / Double(min(p.count, q.count)) >= 0.5
        }
        // No name on one of them: compare the words each repeats. A read says
        // its product again and again — "Twisted Tea… Twisted Tea" — and a
        // plug straight after it repeats something else ("SiriusXM", "Jeff
        // Lewis"). Nothing repeated on one side proves nothing either way.
        let ta = salient(sentences[a.firstSentence...a.lastSentence])
        let tb = salient(sentences[b.firstSentence...b.lastSentence])
        if ta.isEmpty || tb.isEmpty { return true }
        return !ta.isDisjoint(with: tb)
    }

    /// Whether `b` carries on the read `a` began: the same sponsor when both
    /// are named, otherwise `b` says something `a` is selling. A few bars of
    /// a theme song after a pre-roll ("Never forget…") say nothing about
    /// Progressive, and so are not part of it.
    static func continues(_ a: SegmentFinding, _ b: SegmentFinding, sentences: [Sentence]) -> Bool {
        if a.kind != .ad { return sameSponsor(a, b, sentences: sentences) }
        if !a.sponsor.isEmpty, !b.sponsor.isEmpty { return sameSponsor(a, b, sentences: sentences) }
        let rare = rareWords(sentences)
        let brand = brandWords(a, sentences: sentences, rare: rare)
        return sentences[b.firstSentence...b.lastSentence].contains { mentions($0, brand) }
    }

    private static let common: Set<String> = [
        "that", "this", "with", "have", "your", "they", "just", "like", "what", "yeah", "know", "from",
        "about", "there", "their", "when", "will", "been", "were", "them", "then", "more", "some",
        "really", "because", "going", "right", "think", "want", "make", "only", "also", "into", "here",
        "okay", "good", "great", "time", "people", "thing", "things", "gonna", "dude", "guys", "fucking"
    ]

    /// What every ad says, whatever it sells. Never evidence that two reads
    /// are one: "use the promo code" is in all of them.
    static let adWords: Set<String> = [
        "promo", "code", "purchase", "order", "orders", "free", "offer", "offers", "deal", "checkout",
        "website", "today", "save", "percent", "first", "entire", "subscribe", "visit", "sponsor",
        "sponsors", "shipping", "discount", "listeners", "terms", "apply", "slash", "month", "months",
        "subscription", "check", "right", "never", "best", "love", "game", "quick", "moment", "support",
        "supporting", "show", "podcast", "episode", "again", "once", "guys", "amazing", "great", "every"
    ]

    /// Words of four letters or more said at least twice in a stretch.
    static func salient(_ lines: ArraySlice<Sentence>) -> Set<String> {
        var counts: [String: Int] = [:]
        for line in lines {
            for word in AdDetector.normalise(line.text).split(separator: " ") where word.count >= 4 {
                let w = String(word)
                if !common.contains(w) { counts[w, default: 0] += 1 }
            }
        }
        return Set(counts.filter { $0.value >= 2 }.keys)
    }

    /// Two spans of one kind with some conversation-sounding lines between
    /// them, and no new sponsor starting: a host-read ad told as a story
    /// ("I had a surprise charge on the card…") labels as conversation in
    /// the middle. Joined if the whole stretch reads as one when shown whole.
    func joinParts(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) async -> [SegmentFinding] {
        var out: [SegmentFinding] = []
        for f in findings.sorted(by: { $0.start < $1.start }) {
            guard let previous = out.last, previous.kind == f.kind, f.kind != .intro, f.kind != .outro,
                  f.start - previous.end <= 50, !Self.opensAnAd(sentences[f.firstSentence].text),
                  Self.continues(previous, f, sentences: sentences) else { out.append(f); continue }
            var combined = previous
            combined.end = f.end
            combined.lastSentence = f.lastSentence
            combined.endConfidence = f.endConfidence
            combined.confidence = (previous.confidence + f.confidence) / 2
            if combined.sponsor.isEmpty { combined.sponsor = f.sponsor }
            if await verify(combined, sentences: sentences, log: &log, strict: true) != nil {
                out[out.count - 1] = combined
                log.append("joined \(Self.clock(previous.start))–\(Self.clock(f.end)): one \(f.kind.rawValue) read as a whole")
            } else {
                out.append(f)
            }
        }
        return out
    }

    static let verifyInstructions = """
    You are shown part of a podcast transcript with one section marked. Say what the marked section is, taken as a whole.

    Reply with one line like these examples:
    kind=advertisement
    kind=content

    kind is one of:
    advertisement: a paid read for a company's product, by a host or a produced commercial.
    selfPromotion: the show or its hosts promoting their own tour dates, merch, Patreon, specials or bonus episodes.
    crossPromotion: a plug for another podcast, a network or an app.
    closing: credits or theme after the hosts have said goodbye.
    opening: theme, network announcement or welcome before the conversation starts.
    content: the conversation itself, including jokes about a sponsor or a product mentioned in passing.
    """

    /// The marked-section question the old detector used as its second look,
    /// asked of each span. The sentence labels can drift into the
    /// conversation next to an ad — the labeller answers in blocks — and a
    /// span of conversation reads as conversation when it is shown whole.
    func verify(_ finding: SegmentFinding, sentences: [Sentence], log: inout [String],
                strict: Bool = false) async -> SegmentFinding? {
        let before = sentences[max(0, finding.firstSentence - 8)..<finding.firstSentence].map(\.text).joined(separator: " ")
        let after = sentences[min(sentences.count, finding.lastSentence + 1)..<min(sentences.count, finding.lastSentence + 9)]
            .map(\.text).joined(separator: " ")
        var marked = sentences[finding.firstSentence...finding.lastSentence].map(\.text).joined(separator: " ")
        let words = marked.split(separator: " ")
        if words.count > 300 { marked = words.prefix(170).joined(separator: " ") + " … " + words.suffix(110).joined(separator: " ") }
        let prompt = "BEFORE:\n\(before.isEmpty ? "(start of episode)" : before)\n\nMARKED SECTION:\n\(marked)\n\nAFTER:\n\(after.isEmpty ? "(end of episode)" : after)"
        guard let reply = await AdDetector.ask(prompt, instructions: Self.verifyInstructions, log: &log,
                                               label: "verify \(Self.clock(finding.start))") else { return finding }
        let kind = AdDetector.fields(reply)["kind"] ?? ""
        let tag = "verify \(Self.clock(finding.start))–\(Self.clock(finding.end)) \(finding.kind.rawValue) → \(kind)"
        if strict {
            let wanted: String
            switch finding.kind {
            case .ad: wanted = "advertisement"
            case .selfPromo: wanted = "selfpromotion"
            case .crossPromo: wanted = "crosspromotion"
            case .intro: wanted = "opening"
            case .outro: wanted = "closing"
            }
            return kind.hasPrefix(wanted) ? finding : nil
        }
        if kind.hasPrefix("content") {
            // Unanimous labels on something long: a real read the question
            // misjudged is likelier than a long stretch of conversation every
            // sentence of which was called an ad.
            if finding.confidence >= 90, finding.end - finding.start >= 20 {
                log.append(tag + " — kept: labels unanimous"); return finding
            }
            log.append(tag + " — dropped"); return nil
        }
        // A different kind of promotion: unless the sentence labels were
        // near-unanimous, the reading of the whole section wins. Measured on
        // MSSP 633: the labels called a stretch of Matt's tour dates an ad
        // (83%), the section question called it self-promotion, and keeping
        // the labels' kind let it be joined onto the BlueChew read.
        var out = finding
        let asked: SegmentKind? = kind.hasPrefix("advertisement") ? .ad
            : kind.hasPrefix("selfpromotion") ? .selfPromo
            : kind.hasPrefix("crosspromotion") ? .crossPromo
            : kind.hasPrefix("closing") ? .outro
            : kind.hasPrefix("opening") ? .intro : nil
        if let asked, asked != finding.kind, finding.confidence < 90 {
            out.kind = asked
            if asked != .ad { out.sponsor = "" }
            log.append(tag + " — kept as \(asked.rawValue)")
        } else {
            log.append(tag + " — kept")
        }
        return out
    }

    /// The section question, answered with a kind (nil for conversation).
    func classify(_ finding: SegmentFinding, sentences: [Sentence], log: inout [String]) async -> SegmentKind? {
        let before = sentences[max(0, finding.firstSentence - 8)..<finding.firstSentence].map(\.text).joined(separator: " ")
        let after = sentences[min(sentences.count, finding.lastSentence + 1)..<min(sentences.count, finding.lastSentence + 9)]
            .map(\.text).joined(separator: " ")
        let marked = sentences[finding.firstSentence...finding.lastSentence].map(\.text).joined(separator: " ")
        let prompt = "BEFORE:\n\(before.isEmpty ? "(start of episode)" : before)\n\nMARKED SECTION:\n\(marked)\n\nAFTER:\n\(after.isEmpty ? "(end of episode)" : after)"
        guard let reply = await AdDetector.ask(prompt, instructions: Self.verifyInstructions, log: &log,
                                               label: "classify") else { return nil }
        let kind = AdDetector.fields(reply)["kind"] ?? ""
        if kind.hasPrefix("advertisement") { return .ad }
        if kind.hasPrefix("selfpromotion") { return .selfPromo }
        if kind.hasPrefix("crosspromotion") { return .crossPromo }
        if kind.hasPrefix("closing") { return .outro }
        if kind.hasPrefix("opening") { return .intro }
        return nil
    }

    // MARK: 4. Edges

    static let edgeInstructions = """
    You decide whether one sentence of a podcast belongs to a marked segment or to the show's own conversation around it.
    Reply with one word: inside or outside.
    Lead-ins and lead-outs like "here we go", "let's take a break", "and we're back" or the hosts' own jokes before a segment are outside. Anything that is still about the segment's product or offer is inside.
    """

    private static func describe(_ finding: SegmentFinding) -> String {
        switch finding.kind {
        case .ad: return finding.sponsor.isEmpty ? "an advertisement" : "an advertisement for \(AdDetector.scrub(finding.sponsor))"
        case .selfPromo: return "the show promoting its own tour dates, merch, Patreon or specials"
        case .crossPromo: return "a promotion for another show, network or app"
        case .intro: return "the opening before the conversation starts"
        case .outro: return "the closing after the hosts say goodbye"
        }
    }

    /// Moves each edge to where focused questions about single sentences put
    /// it. The batch labels get the shape right but can place a change several
    /// sentences early or late — they answer in blocks — which is exactly the
    /// error the listener hears.
    ///
    /// Each edge is walked: if the sentence at the edge is inside, outward
    /// while it stays inside; if it is outside, inward until it isn't. One
    /// stray answer doesn't end a walk: it needs two in a row.
    func refine(_ finding: SegmentFinding, sentences: [Sentence], others: [SegmentFinding],
                log: inout [String]) async -> SegmentFinding {
        var out = finding
        let first = finding.firstSentence, last = finding.lastSentence
        let floor = (others.filter { $0.lastSentence < first }.map(\.lastSentence).max() ?? -1) + 1
        let ceiling = (others.filter { $0.firstSentence > last }.map(\.firstSentence).min() ?? sentences.count) - 1
        // Described by its middle, not its edges: an edge that has wandered
        // into the conversation would otherwise describe the conversation as
        // part of the segment, and every question would agree with it.
        let middle = (first + last) / 2
        let core = sentences[max(first, middle - 1)...min(last, middle + 1)].map(\.text).joined(separator: " ")
        var description = Self.describe(finding)
        // The offer — a web address, a code, the small print — is usually
        // where a read ends. Naming it lets "What's he doing back there?"
        // after "Visit the website for full terms" be heard as the show again.
        if let offer = sentences[first...last].last(where: { s in
            let lower = s.text.lowercased()
            return Self.strongCues.contains { lower.contains($0) } || lower.contains("terms") || lower.contains("apply")
        }) {
            description += ". Its offer or small print: \"\(offer.text.prefix(160))\""
        }
        var asked = 0, agreed = 0
        // Lines that name what an ad sells, or open one, are inside however
        // the question comes out: "Gentlemen, let's take a quick moment and
        // talk about GLD" was answered "outside" as a lead-in, and the walk
        // went on inward past the whole introduction of the product.
        // Only what the span repeats or its sponsor's name: a name said once
        // in a lead-in ("Make it, Ringo, make it") would otherwise anchor
        // the lead-in.
        let brand = finding.kind == .ad
            ? Self.brandWords(finding, sentences: sentences, rare: Self.rareWords(sentences), properNouns: false) : []
        func anchored(_ i: Int) -> Bool {
            guard finding.kind == .ad, i >= 0, i < sentences.count else { return false }
            return Self.opensAnAd(sentences[i].text) || Self.mentions(sentences[i], brand)
        }
        // A tour-date list runs to thirty short lines with asides between.
        let reach = finding.kind == .selfPromo ? 30 : 15

        let lessons = self.lessons
        var lessonNote = ""
        if !lessons.outside.isEmpty || !lessons.inside.isEmpty {
            lessonNote = "\nOn this show the listener has marked"
            if !lessons.outside.isEmpty { lessonNote += " these as outside: " + lessons.outside.suffix(3).map { "\"\($0)\"" }.joined(separator: ", ") + "." }
            if !lessons.inside.isEmpty { lessonNote += " These as inside: " + lessons.inside.suffix(3).map { "\"\($0)\"" }.joined(separator: ", ") + "." }
        }
        func inside(_ i: Int, log: inout [String]) async -> Bool? {
            guard i >= 0, i < sentences.count else { return nil }
            // The listener's own edges first: a line they have already
            // cut away, or pulled in, on this show is answered without asking.
            if Self.lessonMatch(sentences[i].text, lessons.outside) { asked += 1; return false }
            if Self.lessonMatch(sentences[i].text, lessons.inside) { asked += 1; return true }
            let before = sentences[max(0, i - 2)..<i].map(\.text).joined(separator: " ")
            let after = sentences[min(sentences.count, i + 1)..<min(sentences.count, i + 3)].map(\.text).joined(separator: " ")
            let prompt = """
            SEGMENT: \(description), for example: "\(core.prefix(260))".
            BEFORE: \(before.isEmpty ? "(start)" : before)
            SENTENCE: \(sentences[i].text)
            AFTER: \(after.isEmpty ? "(end)" : after)
            Is SENTENCE inside the segment or outside it?\(lessonNote)
            """
            guard let reply = await AdDetector.ask(prompt, instructions: Self.edgeInstructions,
                                                   log: &log, label: "edge", maxTokens: 6) else { return nil }
            asked += 1
            let word = reply.lowercased()
            if word.hasPrefix("inside") { return true }
            if word.hasPrefix("outside") { return false }
            return nil
        }

        /// Walks from `edge` in `outward` direction. Returns the index of the
        /// last sentence that is inside.
        func walk(from edge: Int, outward: Int, limitOut: Int, limitIn: Int, log: inout [String]) async -> Int {
            let answer: Bool? = anchored(edge) ? true : await inside(edge, log: &log)
            guard let here = answer else { return edge }
            if here {
                // Outward, a sentence joins only when the next one out is
                // inside too, or it is the last before a stop — so a single
                // "inside" for a line of conversation can't carry the edge.
                var lastInside = edge, i = edge + outward, pending: Int?
                while (outward < 0 ? i >= limitOut : i <= limitOut), abs(i - edge) <= reach {
                    guard let a = await inside(i, log: &log) else { break }
                    if a {
                        if let p = pending { lastInside = p; agreed += 1 }
                        pending = i
                    } else {
                        if pending != nil { pending = nil; break }
                        break
                    }
                    i += outward
                }
                if let p = pending, p == edge + outward { lastInside = p }
                return lastInside
            } else {
                var i = edge - outward, misses = 0
                while (outward < 0 ? i <= limitIn : i >= limitIn), abs(i - edge) <= 15 {
                    if anchored(i) { return i }
                    guard let a = await inside(i, log: &log) else { break }
                    if a {
                        // Confirm with the next one in, so one stray "inside"
                        // in the conversation doesn't set the edge.
                        if let next = await inside(i - outward, log: &log), next { agreed += 2; return i }
                        misses = 0
                    } else { agreed += 1; misses += 1 }
                    i -= outward
                }
                return edge
            }
        }

        if finding.kind != .intro {
            let k = await walk(from: first, outward: -1, limitOut: floor, limitIn: last, log: &log)
            out.firstSentence = k
            out.start = sentences[k].start
        }
        if finding.kind != .outro {
            let k = await walk(from: last, outward: 1, limitOut: ceiling, limitIn: out.firstSentence, log: &log)
            out.lastSentence = max(out.firstSentence, k)
            out.end = sentences[out.lastSentence].end
        }
        if asked > 0 {
            let agreement = min(100, Int(100 * Double(agreed) / Double(asked)))
            out.startConfidence = min(finding.startConfidence, max(agreement, 40))
            out.endConfidence = min(finding.endConfidence, max(agreement, 40))
        }
        if out.start != finding.start || out.end != finding.end {
            log.append("edges \(Self.clock(finding.start))–\(Self.clock(finding.end)) → \(Self.clock(out.start))–\(Self.clock(out.end)) after \(asked) questions")
        }
        return out
    }

    // MARK: 6. The words

    /// Words of the episode that are rare enough to identify something: said
    /// no more than ten times in the whole episode.
    static func rareWords(_ sentences: [Sentence]) -> Set<String> {
        var counts: [String: Int] = [:]
        for s in sentences {
            for w in AdDetector.normalise(s.text).split(separator: " ") where w.count >= 4 { counts[String(w), default: 0] += 1 }
        }
        return Set(counts.filter { $0.value <= 10 && !common.contains($0.key) && !adWords.contains($0.key) }.keys)
    }

    /// What a read is selling, in its own words: the words it repeats, the
    /// names it capitalises and the sponsor's name — minus anything the
    /// episode says everywhere.
    static func brandWords(_ f: SegmentFinding, sentences: [Sentence], rare: Set<String>,
                           properNouns: Bool = true) -> Set<String> {
        let lines = sentences[f.firstSentence...f.lastSentence]
        var words = salient(lines).intersection(rare)
        for line in lines where properNouns {
            let tokens = line.text.split(separator: " ")
            for t in tokens.dropFirst() {
                let raw = t.trimmingCharacters(in: .punctuationCharacters)
                guard raw.count >= 4, raw.first?.isUppercase == true, !raw.contains("'") else { continue }
                let w = AdDetector.normalise(raw)
                if rare.contains(w) { words.insert(w) }
            }
        }
        for w in AdDetector.normalise(f.sponsor).split(separator: " ") where w.count >= 3 { words.insert(String(w)) }
        return words
    }

    static func mentions(_ sentence: Sentence, _ words: Set<String>) -> Bool {
        let plain = AdDetector.normalise(sentence.text)
        return plain.split(separator: " ").contains { w in
            words.contains { b in b.count >= 5 ? w.contains(b) : w.hasPrefix(b) }
        }
    }

    /// The small print a read closes on.
    static let smallPrint = ["terms", "apply", "responsibly", "21 plus", "must be 21", "details", "restrictions",
                             "safety information", "not available", "eligible"]

    /// Two pieces of one read that the edge questions left a line or two
    /// apart — "Oh, mama, do I love twisted tea?… All right? None of this
    /// chemical stuff… The party pack comes with…" — are one read when
    /// neither names a different sponsor and they share words the episode
    /// rarely says.
    static func mergeReads(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) -> [SegmentFinding] {
        let rare = rareWords(sentences)
        func words(_ f: SegmentFinding) -> Set<String> {
            Set(sentences[f.firstSentence...f.lastSentence].flatMap { AdDetector.normalise($0.text).split(separator: " ").map(String.init) })
                .intersection(rare)
        }
        var out: [SegmentFinding] = []
        for f in findings.sorted(by: { $0.start < $1.start }) {
            guard var previous = out.last, previous.kind == f.kind, f.kind == .ad,
                  f.start - previous.end <= 120, !opensAnAd(sentences[f.firstSentence].text) else { out.append(f); continue }
            let named = !previous.sponsor.isEmpty && !f.sponsor.isEmpty
            let same: Bool
            if f.start - previous.end <= 6 {
                same = named ? sameSponsor(previous, f, sentences: sentences) : words(previous).intersection(words(f)).count >= 2
            } else {
                // Further apart: a host-read with a two-minute riff in the
                // middle ("…thank Ridge Wallet… they're giving away a
                // Lamborghini… a velociraptor… go to ridge.com"). One read
                // when the second part names what the first sells and, over
                // a minute apart, the riff between names it too.
                let brand = brandWords(previous, sentences: sentences, rare: rare)
                let between = (previous.lastSentence + 1)..<f.firstSentence
                same = (!named || sameSponsor(previous, f, sentences: sentences))
                    && sentences[f.firstSentence...f.lastSentence].contains { mentions($0, brand) }
                    && (f.start - previous.end <= 60 || between.contains { mentions(sentences[$0], brand) })
            }
            guard same else { out.append(f); continue }
            previous.end = f.end
            previous.lastSentence = f.lastSentence
            previous.endConfidence = f.endConfidence
            previous.confidence = (previous.confidence + f.confidence) / 2
            if previous.sponsor.isEmpty { previous.sponsor = f.sponsor }
            out[out.count - 1] = previous
            log.append("merged \(clock(previous.start))–\(clock(f.end)): one read")
        }
        return out
    }

    static let pointsBack = ["that kind of", "do that", "for that", "that's why", "that's where", "like that",
                             "for this kind", "that's exactly"]
    static let setUps = ["sometimes", "you ever", "have you ever", "do you ever", "ever ", "picture this",
                         "imagine", "raise your hand"]
    static let thanks = ["thank you", "enjoy the show", "see you there", "please come", "come out"]

    private static let promoLead = ["come watch", "come see", "come out", "tickets", "tour", "stand up", "standup",
                                    "on sale", "live show", "january", "february", "march", "april", "may ",
                                    "june", "july", "august", "september", "october", "november", "december"]

    /// Edges the words decide, without asking:
    /// - an ad reaches back and on to lines that name what it sells, with at
    ///   most three lines between ("Twisted tea is made for that kind of
    ///   hang… number one on my list… destroy twisted teas… Oh, mama, do I
    ///   love twisted tea?"), and on to the small print it closes with;
    /// - a plug for the hosts' own dates reaches on to the web addresses read
    ///   after the asides, and back to "please come watch me do stand up".
    static func grow(_ findings: [SegmentFinding], sentences: [Sentence], votes: [[SentenceLabel: Int]],
                     log: inout [String]) -> [SegmentFinding] {
        let rare = rareWords(sentences)
        var out = findings.sorted { $0.start < $1.start }
        for n in out.indices {
            var f = out[n]
            let floor = n > 0 ? out[n - 1].lastSentence + 1 : 0
            let ceiling = n + 1 < out.count ? out[n + 1].firstSentence - 1 : sentences.count - 1
            switch f.kind {
            case .ad, .crossPromo:
                let brand = brandWords(f, sentences: sentences, rare: rare)
                guard !brand.isEmpty else { break }
                var i = f.firstSentence - 1, gap = 0
                while i >= floor, gap <= 3, sentences[f.firstSentence].start - sentences[i].start <= 45 {
                    if mentions(sentences[i], brand) {
                        f.firstSentence = i; f.start = sentences[i].start; gap = 0
                    } else { gap += 1 }
                    i -= 1
                }
                i = f.lastSentence + 1; gap = 0
                while i <= ceiling, gap <= 3, sentences[i].start - sentences[f.lastSentence].end <= 30 {
                    let lower = sentences[i].text.lowercased()
                    if mentions(sentences[i], brand) || smallPrint.contains(where: { lower.contains($0) })
                        || [".com", "promo", "use code", "use the code"].contains(where: { lower.contains($0) }) {
                        f.lastSentence = i; f.end = sentences[i].end; gap = 0
                    } else { gap += 1 }
                    i += 1
                }
                // A read that opens by pointing back — "Twisted tea is made
                // for that kind of hang", "your customers do that to you too"
                // — began with the set-up it points at: the question or the
                // "sometimes…" a line or three before.
                let opening = sentences[f.firstSentence...min(f.lastSentence, f.firstSentence + 1)]
                    .map { $0.text.lowercased() }.joined(separator: " ")
                if Self.pointsBack.contains(where: { opening.contains($0) }) {
                    var j = f.firstSentence - 1, steps = 0
                    while j >= floor, steps < 3, sentences[f.firstSentence].start - sentences[j].start <= 12 {
                        let t = sentences[j].text.lowercased().trimmingCharacters(in: .whitespaces)
                        if t.hasSuffix("?") || Self.setUps.contains(where: { t.hasPrefix($0) }) {
                            f.firstSentence = j; f.start = sentences[j].start; break
                        }
                        j -= 1; steps += 1
                    }
                }
            case .selfPromo where f.end - f.start >= 10:
                // On, to each web address read within a minute that the
                // labels didn't call conversation.
                var i = f.lastSentence + 1
                while i <= ceiling, sentences[i].start - sentences[f.lastSentence].end <= 60 {
                    let lower = sentences[i].text.lowercased()
                    let v = i < votes.count ? votes[i] : [:]
                    let promo = (v[.advertisement] ?? 0) + (v[.selfPromotion] ?? 0) + (v[.networkPromotion] ?? 0)
                    if [".com", "dot com", "tickets"].contains(where: { lower.contains($0) }), promo >= (v[.content] ?? 0) {
                        f.lastSentence = i; f.end = sentences[i].end
                    }
                    i += 1
                }
                // And the thanks that close it: "Thank you, thank you… Enjoy
                // the show."
                i = f.lastSentence + 1
                while i <= ceiling, sentences[i].start - sentences[f.lastSentence].end <= 4 {
                    let lower = sentences[i].text.lowercased()
                    guard Self.thanks.contains(where: { lower.contains($0) }) else { break }
                    f.lastSentence = i; f.end = sentences[i].end
                    i += 1
                }
                i = f.firstSentence - 1
                var steps = 0
                while i >= floor, steps < 3, sentences[f.firstSentence].start - sentences[i].start <= 10 {
                    let lower = sentences[i].text.lowercased()
                    if promoLead.contains(where: { lower.contains($0) }) { f.firstSentence = i; f.start = sentences[i].start }
                    i -= 1; steps += 1
                }
            default: break
            }
            if f.start != out[n].start || f.end != out[n].end {
                log.append("grew \(f.kind.rawValue) \(clock(out[n].start))–\(clock(out[n].end)) → \(clock(f.start))–\(clock(f.end))")
            }
            out[n] = f
        }
        return out
    }

    /// Last: spans swallowed by a grown neighbour go, overlaps are split, and
    /// a short "ad" that never offers anything — no address, code, download
    /// or small print, and no ad beside it — was a joke about a product.
    static func settle(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) -> [SegmentFinding] {
        var out: [SegmentFinding] = []
        for f in findings.sorted(by: { $0.start < $1.start }) {
            if var previous = out.last, f.firstSentence <= previous.lastSentence {
                if f.lastSentence <= previous.lastSentence { log.append("\(clock(f.start)) \(f.kind.rawValue) inside a grown span"); continue }
                previous.lastSentence = f.firstSentence - 1
                previous.end = sentences[previous.lastSentence].end
                out[out.count - 1] = previous
            }
            out.append(f)
        }
        // A line or three of "Do it. Make it, Ringo, make it." between a
        // plug and the ad after it belong to the plug.
        for n in out.indices.dropLast() where [.crossPromo, .selfPromo, .outro].contains(out[n].kind) && out[n + 1].kind == .ad {
            let between = (out[n].lastSentence + 1)..<out[n + 1].firstSentence
            guard !between.isEmpty, between.count <= 3, out[n + 1].start - out[n].end <= 10,
                  between.allSatisfy({ sentences[$0].text.split(separator: " ").count <= 6 }) else { continue }
            out[n].lastSentence = between.upperBound - 1
            out[n].end = sentences[out[n].lastSentence].end
            log.append("\(clock(out[n].start)) \(out[n].kind.rawValue) takes the lines before the next ad")
        }
        let offers = ["brought to you", "sponsored", "sponsor", "terms", "apply", "download", "visit", "subscribe",
                      "sign up", "free trial", "offer", "code", ".com", "dot com", " slash ", "responsibly",
                      "for supporting", "support for", "go to", "head to", "percent off", "% off"] + smallPrint
        return out.enumerated().filter { n, f in
            // Any length: a minute of the hosts joking about how they'll die
            // is not an advertisement, however sure the labels were.
            guard f.kind == .ad else { return true }
            let text = sentences[f.firstSentence...f.lastSentence].map(\.text).joined(separator: " ").lowercased()
            if offers.contains(where: { text.contains($0) }) { return true }
            let beside = (n > 0 && out[n - 1].kind == .ad && f.start - out[n - 1].end <= 5)
                || (n + 1 < out.count && out[n + 1].kind == .ad && out[n + 1].start - f.end <= 5)
            if beside { return true }
            log.append("\(clock(f.start)) ad dropped: offers nothing")
            return false
        }.map(\.1)
    }

    /// One run of a label, split where one ad ends and another begins.
    private static func spans(from first: Int, to last: Int, label: SentenceLabel, kind: SegmentKind,
                              sentences: [Sentence], votes: [[SentenceLabel: Int]],
                              path: [SentenceLabel]) -> [SegmentFinding] {
        // Back-to-back ads are separate cuts: the listener can keep one and not
        // the other, and each is its own thing to review.
        var cuts: [Int] = [first]
        if label == .advertisement {
            let openers = ["brought to you by", "sponsored by", "support for this", "this episode is",
                           "today's episode is", "this message is"]
            for index in stride(from: first + 1, through: last, by: 1) {
                let lower = sentences[index].text.lowercased()
                if openers.contains(where: { lower.contains($0) }), index - cuts.last! >= 3 {
                    cuts.append(index)
                }
            }
        }
        cuts.append(last + 1)
        var out: [SegmentFinding] = []
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            let range = a...(b - 1)
            var agree = 0, total = 0
            for index in range {
                let v = votes[index]
                agree += v[label] ?? 0
                total += v.values.reduce(0, +)
            }
            let confidence = total > 0 ? Int(100 * Double(agree) / Double(total)) : 0
            func edge(inside: Int, outside: Int?) -> Int {
                let v = votes[inside]
                let t = v.values.reduce(0, +)
                var c = t > 0 ? Double(v[label] ?? 0) / Double(t) : 0
                if let outside {
                    let o = votes[outside]
                    let ot = o.values.reduce(0, +)
                    c *= ot > 0 ? Double(ot - (o[label] ?? 0)) / Double(ot) : 0.7
                }
                return Int(c * 100)
            }
            let name = sponsorName(in: sentences[range].map(\.text).joined(separator: " "))
            out.append(SegmentFinding(kind: kind,
                                      start: sentences[range.lowerBound].start,
                                      end: sentences[range.upperBound].end,
                                      sponsor: label == .advertisement ? name : "",
                                      confidence: confidence,
                                      startConfidence: edge(inside: range.lowerBound,
                                                            outside: range.lowerBound > 0 ? range.lowerBound - 1 : nil),
                                      endConfidence: edge(inside: range.upperBound,
                                                          outside: range.upperBound + 1 < sentences.count ? range.upperBound + 1 : nil),
                                      firstSentence: range.lowerBound, lastSentence: range.upperBound))
        }
        return out
    }

    /// The sponsor, from the words an ad names itself with.
    static func sponsorName(in text: String) -> String {
        for pattern in [#"brought to you by ([A-Z][\w'&\-]*(?: [A-Z][\w'&\-]*){0,2})"#,
                        #"sponsored by ([A-Z][\w'&\-]*(?: [A-Z][\w'&\-]*){0,2})"#,
                        #"(?:go to|visit|at) ([a-z0-9\-]+)\s?(?:\.|dot )com"#] {
            if let match = text.firstMatch(of: try! Regex(pattern)), let name = match.output[1].substring {
                return String(name)
            }
        }
        return ""
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
}

// MARK: - In the app

extension AdDetector {
    /// The sentence detector, finished the way the app needs it: pulled in
    /// by the listener's padding, snapped to measured pauses, bookends taken
    /// to the ends of the file, and the sponsors it heard handed back for the
    /// show to remember.
    ///
    /// Back-to-back ads stay separate here — the old window detector fused
    /// anything of one kind within six seconds, which is how Tremfaya and
    /// Vuori became one cut.
    func detectSentences(segments: [TranscriptSegment],
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
                         hints: [ClosedRange<Double>] = [],
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> DetectionResult {
        guard !segments.isEmpty else { return DetectionResult() }
        let (findings, log) = try await SegmentDetector().detect(
            segments: segments, knownSponsors: knownSponsors, corrections: corrections,
            globalCorrections: globalCorrections, showTitle: showTitle, episodeTitle: episodeTitle,
            showNotes: showNotes, minimumConfidence: minimumConfidence, hints: hints, progress: progress)
        let duration = audioDuration > 0 ? audioDuration : (segments.last?.end ?? 0)
        let detected = findings.map { f -> DetectedSegment in
            var s = DetectedSegment(start: f.start + padding, end: f.end - padding,
                                    kind: f.kind, sponsor: f.sponsor, confidence: f.confidence)
            s = Self.snap(s, to: silences)
            return s
        }
        let finished = Self.extendBookends(detected, duration: duration)
            .filter { $0.end > $0.start + 1 }
        let sponsors = findings.filter { $0.kind == .ad && !$0.sponsor.isEmpty }.map(\.sponsor)
        return DetectionResult(segments: finished, sponsors: Array(Set(sponsors)).sorted(), log: log)
    }
}
