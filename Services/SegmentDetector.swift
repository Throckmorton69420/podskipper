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
    /// Plain-English facts behind it, for the review screen. See
    /// `SegmentEvidence`.
    var evidence: [String] = []
    /// Stitched in at download: found by the ad-free comparison (or, in the
    /// lab, a repeated-ad fingerprint). Its edges are exact; nothing moves them.
    var insertedAtDownload = false
    /// Audio that plays again — in the show's other episodes or twice in
    /// this one (`AdPrints`). Its edges are exact too.
    var repeatedAudio = false
    /// `CutDetail` raw value, or "".
    var detail = ""

    /// Under this, the listener is asked to look rather than told it is right.
    var needsReview: Bool { confidence < 70 || min(startConfidence, endConfidence) < 50 }
}

actor SegmentDetector {

    /// The last run's votes, for the detection lab's trace. Never read in the app.
    nonisolated(unsafe) static var lastVotes: [[SentenceLabel: Int]] = []

    /// The costs that trade speed against care, in one place so the lab can
    /// measure them (see `Tools/DetectionLab`). The defaults are what the app
    /// runs; each was chosen by measurement on the regression episodes.
    struct Tuning: Sendable {
        /// Sentences per labelling question, and how far apart questions
        /// start. A step equal to the size labels each sentence once.
        var labelSize = 12
        var labelStep = 6
        /// Seconds read either side of a window the screen flagged, and of a
        /// sentence holding a web address or code.
        var hitPad: Double = 60
        var cuePad: Double = 30
        /// Edges whose labels were at least this clear are not walked
        /// sentence by sentence. 101 walks every edge.
        var walkBelow = 101
        /// Independent questions asked at once (screening, labelling).
        var parallel = 3
    }
    nonisolated(unsafe) static var tuning = Tuning()

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
                // A transcript made before word times were kept stays in its
                // recognizer chunks. Splitting them at sentence ends with times
                // shared out by length was tried in pass 15 and measured worse
                // on both lab episodes without word times: Legion of Skanks lost
                // most of two host-reads and Conan lost a pre-roll. The labels
                // are asked twelve sentences at a time, and shorter sentences
                // meant each question saw too little of the break.
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
        "welcome to", "goodbye", "see you next", "you've been listening to", "you have been listening to",
        "you are listening to", "you're listening to"
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
                inserted: [ClosedRange<Double>] = [],
                produced: [AdPrints.Produced] = [],
                progress: (@Sendable (Double) -> Void)? = nil) async throws -> (findings: [SegmentFinding], log: [String]) {
        if let reason = AdDetector.availability() { throw AdDetectorError.modelUnavailable(reason) }
        let edgeLessons = corrections.filter { $0.boundary != nil }
        lessons = (edgeLessons.filter { $0.boundary?.hasPrefix("inside") == true }.map { AdDetector.normalise($0.excerpt) },
                   edgeLessons.filter { $0.boundary?.hasPrefix("outside") == true }.map { AdDetector.normalise($0.excerpt) })
        // Stretches the ad-free copy doesn't have are ads already, to the
        // frame. The model reads the episode as the host uploaded it: those
        // sentences are taken out before anything else happens, so they are
        // never read, never context for a question, and never make the
        // conversation next to them look like the ad it borders (measured on
        // MSSP 633: with them left in as context, 47 s of talk before a break
        // was called an ad).
        let allSentences = Self.sentences(from: segments)
        func isInserted(_ s: Sentence) -> Bool {
            let middle = (s.start + s.end) / 2
            return inserted.contains { $0.contains(middle) }
        }
        let sentences = inserted.isEmpty ? allSentences : allSentences.filter { !isInserted($0) }
        guard !sentences.isEmpty else { return ([], []) }
        var log: [String] = ["sentences: \(sentences.count)"]
        let noteSponsors = AdDetector.sponsorsFromNotes(showNotes)
        let names = (knownSponsors + noteSponsors).map(AdDetector.normalise).filter { $0.count >= 3 }
        let readable = sentences
        if !inserted.isEmpty {
            log.append("inserted at download: \(inserted.map { "\(Self.clock($0.lowerBound))–\(Self.clock($0.upperBound))" }), "
                       + "\(allSentences.count - sentences.count) sentences not read")
        }

        // 1. Where to look.
        var hits = await screen(readable, names: names, episodeTitle: episodeTitle, log: &log) {
            progress?(0.35 * $0)
        }
        // Audio that plays again is produced; what sits beside it is often
        // the rest of the break (the first of two Mountain Dew reads on Your
        // Mom's House), so it is read closely too.
        hits += produced.map { $0.start...$0.end }
        // Outside evidence (SponsorBlock, for a show with a YouTube upload):
        // somewhere to look, never a cut by itself.
        if !hints.isEmpty {
            log.append("hints: \(hints.map { "\(Self.clock($0.lowerBound))–\(Self.clock($0.upperBound))" })")
            hits += hints
        }
        let ranges = Self.subtract(Self.lookRanges(hits: hits, sentences: sentences), inserted)
        let covered = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        log.append("reading \(ranges.count) stretches, \(Int(covered)) s of \(Int(sentences.last!.end)) s")
        for range in ranges { log.append("read \(Self.clock(range.lowerBound))–\(Self.clock(range.upperBound))") }

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
        for (n, finding) in findings.enumerated() {
            if let kept = await verify(finding, sentences: sentences, log: &log) { verified.append(kept) }
            progress?(0.65 + 0.05 * Double(n + 1) / Double(max(1, findings.count)))
        }
        findings = await joinParts(verified, sentences: sentences, log: &log)

        // Screening said a window was promotional and the sentence labels
        // produced nothing there: the labels are close to a coin toss on
        // chatty stretches (tour dates read between jokes), and the question
        // about a whole section is not. So the window becomes a span, the
        // section question says what kind it is, and the edges are walked.
        for (h, hit) in hits.enumerated() where !findings.contains(where: { $0.start < hit.upperBound && $0.end > hit.lowerBound }) {
            progress?(0.70 + 0.05 * Double(h + 1) / Double(max(1, hits.count)))
            guard let first = sentences.firstIndex(where: { $0.end > hit.lowerBound }),
                  let last = sentences.lastIndex(where: { $0.start < hit.upperBound }), first < last else { continue }
            let probe = SegmentFinding(kind: .ad, start: sentences[first].start, end: sentences[last].end,
                                       sponsor: "", confidence: 50, startConfidence: 30, endConfidence: 30,
                                       firstSentence: first, lastSentence: last)
            // The window's own words must sell something. The section
            // question sees the read next door as context and said "ad" for
            // the chat right after a Babbel read on 2 Bears (41 s cut).
            let sells = Self.strongCues + ["sponsor", "in stores", "near you", "download", "sign up", "free trial",
                                           "visit", "go to", "head to", "offer", "code"]
            let selling = (first...last).filter { i in
                let lower = sentences[i].text.lowercased()
                return sells.contains { lower.contains($0) }
            }
            guard let firstSelling = selling.first else { continue }
            // …and not only in the first seconds right after a read already
            // found: that is the read's own last line inside the window.
            let readJustBefore = findings.contains { $0.kind == .ad && $0.end <= probe.start + 1 && probe.start - $0.end <= 10 }
            if readJustBefore, sentences[selling.last ?? firstSelling].start < probe.start + 10 { continue }
            if let kind = await classify(probe, sentences: sentences, log: &log), kind == .ad {
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
            progress?(0.75 + 0.17 * Double(n + 1) / Double(max(1, findings.count)))
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
            else if out.kind == .ad, again.firstSentence > out.firstSentence, again.firstSentence <= out.lastSentence {
                // …except to start at the product itself. The second walk
                // put 2 Bears' DraftKings read at "The football season is
                // heating up… with DraftKings", and the 21 s of Thai-food
                // talk before it — not one line naming what the read sells,
                // none opening a read — stayed cut (pass 19).
                let brand = Self.brandWords(out, sentences: sentences, rare: Self.rareWords(sentences))
                let givenUp = out.firstSentence..<again.firstSentence
                if Self.mentions(sentences[again.firstSentence], brand) || Self.opensAnAd(sentences[again.firstSentence].text),
                   !givenUp.contains(where: { Self.mentions(sentences[$0], brand) || Self.opensAnAd(sentences[$0].text) }) {
                    log.append("\(Self.clock(out.start)) ad starts at its product, \(Self.clock(again.start))")
                    out.firstSentence = again.firstSentence
                    out.start = again.start
                }
            }
            if again.lastSentence > out.lastSentence { out.lastSentence = again.lastSentence; out.end = again.end }
            findings[n] = out
        }
        progress?(0.95)
        findings = Self.settle(findings, sentences: sentences, log: &log)
        findings = Self.joinPlugs(findings, sentences: sentences, log: &log)
        findings = await fillBreaks(findings, sentences: sentences, log: &log)
        findings = await sponsorEcho(findings, sentences: sentences, log: &log)
        progress?(0.97)
        findings = Self.plugs(findings, sentences: sentences, log: &log)
        findings = Self.credits(findings, sentences: sentences, log: &log)
        if !produced.isEmpty {
            findings = await withProduced(findings, produced: produced.filter { p in
                !inserted.contains { $0.lowerBound <= p.start + 1 && $0.upperBound >= p.end - 1 }
            }, sentences: sentences, log: &log)
        }
        findings = Self.afterTheClosing(findings, sentences: sentences, log: &log)
        if !inserted.isEmpty {
            findings = Self.withInserted(findings, inserted: inserted, sentences: sentences, all: allSentences, log: &log)
        }
        findings = Self.bridgeQuiet(findings, all: allSentences, log: &log)
        // Why each one is here, in plain English, for the review screen.
        let facts = SegmentEvidence.facts(sentences, knownSponsors: names,
                                               notesSponsors: noteSponsors.map(AdDetector.normalise),
                                               duration: sentences.last?.end ?? 0)
        for n in findings.indices {
            let range = findings[n].firstSentence...findings[n].lastSentence
            var found = range.reduce(into: Set<SegmentEvidence>()) { $0.formUnion(facts[$1]) }
            if findings[n].confidence >= 90, !findings[n].insertedAtDownload { found.insert(.bothReadingsAgree) }
            if findings[n].repeatedAudio { found.insert(.repeatedAudio) }
            if findings[n].insertedAtDownload { found = [.insertedAtDownload] }
            findings[n].evidence = found.map(\.rawValue).sorted()
            if findings[n].detail.isEmpty {
                let text = sentences[range].map(\.text).joined(separator: " ")
                findings[n].detail = CutDetail.classify(kind: findings[n].kind, text: text)?.rawValue ?? ""
            }
        }
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
        // Which windows are worth a question.
        //
        // Asking about every window covers everything and costs four hundred
        // seconds an episode, which is not a thing to do on a phone. Measured
        // on Matt and Shane 633, widening this filter also moved answers
        // downstream and lost two cuts the narrow filter gets right, so it
        // stays as it was: the words, the show's sponsors, the first two
        // minutes and the last three.
        let windows = Self.windows(sentences)
        let starting = windows.indices.filter { i in
            let lower = windows[i].text.lowercased()
            let plain = AdDetector.normalise(lower)
            return Self.cues.contains(where: { lower.contains($0) })
                || names.contains(where: { plain.contains($0) })
                || windows[i].start < 120 || windows[i].end > (sentences.last?.end ?? 0) - 180
        }
        log.append("windows: \(windows.count), asked about: \(starting.count)")
        var hits: [ClosedRange<Double>] = []
        let prompts = starting.map { i -> String in
            let w = windows[i]
            let before = i > 0 ? windows[i - 1].text.split(separator: " ").suffix(50).joined(separator: " ") : ""
            let after = i + 1 < windows.count ? windows[i + 1].text.split(separator: " ").prefix(50).joined(separator: " ") : ""
            return "CONTEXT BEFORE:\n\(before.isEmpty ? "(start of episode)" : before)\n\nPASSAGE:\n\(w.text)\n\nCONTEXT AFTER:\n\(after.isEmpty ? "(end of episode)" : after)"
        }
        let replies = await AdDetector.askAll(prompts, instructions: AdDetector.windowInstructions,
                                              label: "window", maxTokens: 60, width: Self.tuning.parallel,
                                              log: &log, progress: progress)
        for (n, i) in starting.enumerated() {
            guard let reply = replies[n] else { continue }
            let w = windows[i]
            let kind = AdDetector.fields(reply)["kind"] ?? "content"
            if !kind.hasPrefix("content") { hits.append(w.start...w.end) }
        }
        log.append("windows that looked promotional: \(hits.count)")
        for hit in hits { log.append("hit \(Self.clock(hit.lowerBound))–\(Self.clock(hit.upperBound))") }
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
        let pad = tuning.hitPad, cuePad = tuning.cuePad
        var ranges = hits.map { max(0, $0.lowerBound - pad)...min(last.end, $0.upperBound + pad) }
        // Lines with an ad's or a plug's own words are read with their
        // neighbours even when the window question passed over them: a tour
        // date list read after a sponsor was missed that way.
        for sentence in sentences {
            let lower = sentence.text.lowercased()
            if strongCues.contains(where: { lower.contains($0) }) {
                ranges.append(max(0, sentence.start - cuePad)...min(last.end, sentence.end + cuePad))
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
        let batches = Self.batches(sentences, ranges: ranges, size: Self.tuning.labelSize, step: Self.tuning.labelStep)
        log.append("sentence batches: \(batches.count)")
        var votes = [[SentenceLabel: Int]](repeating: [:], count: sentences.count)
        let prompts = batches.map { Self.prompt($0, sentences: sentences, showTitle: showTitle) }
        let replies = await AdDetector.askAll(prompts, instructions: instructions, label: "batch",
                                              maxTokens: 120, width: Self.tuning.parallel, log: &log,
                                              progress: progress)
        for (n, batch) in batches.enumerated() {
            guard let reply = replies[n] else { continue }
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
            // question says otherwise. (Majority by seconds across the whole
            // group was tried in pass 17: it lost Ultra on LoS 952 and cut
            // "Let's do the Patreon" on MSSP 633. Reverted.)
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

    /// What an opening says about itself.
    static let identCues = ["you are listening to", "you're listening to", "welcome to", "this is the",
                            "network", "coming up on", "from the", "presents"]

    static func opensAnAd(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["brought to you by", "sponsored by", "support for this", "this episode is", "today's episode is",
                "this message is", "this podcast is", "take a quick moment and", "for supporting the show",
                "our awesome sponsors", "one of our sponsors", "talk to you for a second about",
                "want to talk to you about", "want to tell you about", "let's talk about"].contains { lower.contains($0) }
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
            // Except the hosts' "own promotion" of nothing: Bad Friends acting
            // out an usher's welcome ("welcome to the Magic Johnson Theater…
            // please enjoy the film… exits are here") was unanimous and cut,
            // with not one request, plug topic or offer in it (pass 19).
            let lower = marked.lowercased()
            let promotesSomething = Self.plugCalls.contains { lower.contains($0) }
                || Self.plugTopics.contains { lower.contains($0) } || Self.offerCues.contains { lower.contains($0) }
            if finding.kind == .selfPromo, !promotesSomething {
                log.append(tag + " — dropped: promotes nothing"); return nil
            }
            if finding.confidence >= 90, finding.end - finding.start >= 20 {
                log.append(tag + " — kept: labels unanimous"); return finding
            }
            // A network ident at the top of the episode reads as conversation
            // when you only see the words — "You are listening to the Gas
            // Digital Network" is a sentence like any other — but it is the
            // opening, and the old detector found it. Keep it when it is at
            // the top and says so.
            if finding.start < 150, finding.kind == .intro || finding.kind == .crossPromo || finding.kind == .ad {
                let text = sentences[finding.firstSentence...finding.lastSentence]
                    .map(\.text).joined(separator: " ").lowercased()
                if Self.identCues.contains(where: { text.contains($0) }) {
                    var out = finding
                    out.kind = .intro
                    out.sponsor = ""
                    log.append(tag + " — kept as the opening: it names the show or network")
                    return out
                }
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

        // A clear edge — the labels either side agreed — is left where the
        // labels put it; only the unclear ones are walked, a question per
        // sentence. Most of the detector's cost was here.
        let walkBelow = Self.tuning.walkBelow
        if finding.kind != .intro, finding.startConfidence < walkBelow {
            let k = await walk(from: first, outward: -1, limitOut: floor, limitIn: last, log: &log)
            out.firstSentence = k
            out.start = sentences[k].start
        }
        if finding.kind != .outro, finding.endConfidence < walkBelow {
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
        if plain.split(separator: " ").contains(where: { w in
            words.contains { b in b.count >= 5 ? w.contains(b) : w.hasPrefix(b) }
        }) { return true }
        // A brand the recognizer writes as two words: "nocd.com" read out as
        // "no CD" (Bad Friends' NOCD read was heard for 74 s because of it).
        let joined = plain.replacingOccurrences(of: " ", with: "")
        return words.contains { $0.count >= 4 && joined.contains($0) }
    }

    /// The small print a read closes on.
    // "details" alone was here, and "and then give real details" in a story
    // about lying kept a minute of Conan as an ad (pass 17).
    static let smallPrint = ["terms", "apply", "responsibly", "21 plus", "must be 21", "offer details", "for details",
                             "more details", "restrictions",
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

    /// Openers that only ever start a paid read ("let's talk about" is
    /// conversation as often as not, so it isn't here).
    static let strongOpeners = ["brought to you by", "sponsored by", "support for this", "presented by",
                                "take a quick moment and", "take a quick moment to", "for supporting the show",
                                "for supporting today's show", "our awesome sponsors", "one of our sponsors",
                                "talk to you for a second about", "want to talk to you about"]

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
                // Then back over lines naming the sponsor itself, as long as
                // the last one named it within forty seconds: a
                // testimonial-style read ("because I have OCD… that's what I
                // love about NOCD…") names it every half minute, not every
                // line. Only the sponsor's own name: the read's other rare
                // words also turn up in the talk before it (a FanDuel read
                // grew a minute and a half into a chat about betting).
                let own = AdDetector.normalise(f.sponsor).replacingOccurrences(of: " ", with: "")
                if own.count >= 4 {
                    let startedAt = f.start
                    var j = f.firstSentence - 1
                    while j >= floor, sentences[f.firstSentence].start - sentences[j].start <= 40,
                          startedAt - sentences[j].start <= 150 {
                        if mentions(sentences[j], [own]) { f.firstSentence = j; f.start = sentences[j].start }
                        j -= 1
                    }
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
                // A host read starts at its hand-off, not where the labels
                // first agree: "let's take a quick moment and thank Ridge
                // Wallet… (a minute about the sweepstakes and a velociraptor)…
                // go to ridge.com". The labels caught only the offer at the
                // end of each Legion of Skanks read, 40–80 s late (pass 17).
                // Back to a strong opener within ninety seconds that names
                // what this read sells.
                if f.kind == .ad {
                    var j = f.firstSentence - 1
                    while j >= floor, sentences[f.firstSentence].start - sentences[j].start <= 90 {
                        let lower = sentences[j].text.lowercased()
                        let opener = Self.strongOpeners.contains { lower.contains($0) }
                        let names = mentions(sentences[j], brand)
                            || (!f.sponsor.isEmpty && AdDetector.normalise(lower).replacingOccurrences(of: " ", with: "")
                                .contains(AdDetector.normalise(f.sponsor).replacingOccurrences(of: " ", with: "")))
                        // Naming it isn't needed close by: the recognizer spells
                        // brands its own way ("Takeolder.com" for Take Ultra).
                        if opener && (names || sentences[f.firstSentence].start - sentences[j].start <= 75) {
                            f.firstSentence = j; f.start = sentences[j].start
                            break
                        }
                        // Another read's opener first: this one began after it.
                        if opener { break }
                        j -= 1
                    }
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

    /// Two reads with a stretch between them that offers something too — a
    /// third read the labels lost in the middle of a long break. Conan's
    /// 12:07–15:33 break came out as two pieces with a 24-second hole, and
    /// Legion of Skanks' three back-to-back host-reads had 80 seconds missing
    /// between the first and the second. One question per hole.
    func fillBreaks(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) async -> [SegmentFinding] {
        guard findings.count >= 2 else { return findings }
        var out = findings
        for (a, b) in zip(findings, findings.dropFirst()) {
            let gap = b.start - a.end
            // Both sides must be paid reads, and close together: a hole in
            // the middle of one break. Filling the gap between a read and the
            // hosts' own plug is how the tour dates became part of BlueChew.
            guard gap > 1, gap <= 45, a.kind == .ad, b.kind == .ad,
                  a.lastSentence + 1 < b.firstSentence else { continue }
            let range = (a.lastSentence + 1)...(b.firstSentence - 1)
            let text = sentences[range].map(\.text).joined(separator: " ").lowercased()
            let offers = Self.strongCues.contains { text.contains($0) }
                || Self.opensAnAd(text) || text.contains("promo code") || text.contains("use code")
            guard offers else { continue }
            let probe = SegmentFinding(kind: .ad, start: sentences[range.lowerBound].start,
                                       end: sentences[range.upperBound].end, sponsor: "", confidence: 50,
                                       startConfidence: 40, endConfidence: 40,
                                       firstSentence: range.lowerBound, lastSentence: range.upperBound)
            if let kind = await classify(probe, sentences: sentences, log: &log), kind == .ad {
                var found = probe
                found.kind = kind
                found.sponsor = kind == .ad ? Self.sponsorName(in: text) : ""
                log.append("filled the break \(Self.clock(found.start))–\(Self.clock(found.end)) as \(kind.rawValue)")
                out.append(found)
            } else {
                log.append("gap \(Self.clock(probe.start))–\(Self.clock(probe.end)): the show, left alone")
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Words that sell: an address, a code, an offer, the small print.
    static let offerCues: [String] = ["brought to you", "sponsored", "sponsor", "terms", "apply", "download", "visit", "subscribe",
                      "sign up", "free trial", "offer", "code", ".com", "dot com", " slash ", "responsibly",
                      "for supporting", "support for", "go to", "head to", "percent off", "% off",
                      // A shop-shelf product sells without a website or a
                      // code: "Look for Mountain Dew in stores near you" (Your
                      // Mom's House, 2 Bears) was dropped as offering nothing.
                      "in stores", "near you", "available at", "available now", "available wherever",
                      "look for", "pick up a", "pick one up", "order now", "shop now", "learn more"] + smallPrint

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
        let offers = Self.offerCues
        return out.enumerated().filter { n, f in
            // Any length: a minute of the hosts joking about how they'll die
            // is not an advertisement, however sure the labels were.
            guard f.kind == .ad else { return true }
            let text = sentences[f.firstSentence...f.lastSentence].map(\.text).joined(separator: " ").lowercased()
            if offers.contains(where: { text.contains($0) }) { return true }
            // A sponsor named three times in twenty seconds or more is being
            // sold, offer or not: 2 Bears introducing "our partners in
            // business, Mountain Dew" and the spot they made for them.
            if f.end - f.start >= 20 {
                let original = sentences[f.firstSentence...f.lastSentence].map(\.text).joined(separator: " ")
                var names = original.matches(of: try! Regex(#"[A-Z][a-z]+ [A-Z][a-z]+"#)).map { String(original[$0.range]) }
                if !f.sponsor.isEmpty { names.append(f.sponsor) }
                let joined = AdDetector.normalise(text).replacingOccurrences(of: " ", with: "")
                let named = Set(names).contains { name in
                    let key = AdDetector.normalise(name).replacingOccurrences(of: " ", with: "")
                    return key.count >= 5 && joined.components(separatedBy: key).count - 1 >= 3
                }
                if named { return true }
            }
            // Beside another read it can be that read's tail — but only a
            // short one: 23 s of gym-flooring talk after Legion of Skanks'
            // mid-roll was kept this way.
            // A longer one only if it names what its neighbour sells (the body
            // of 2 Bears' Factor read, whose web address came after it).
            let neighbours = [n > 0 ? out[n - 1] : nil, n + 1 < out.count ? out[n + 1] : nil].compactMap { $0 }
                .filter { $0.kind == .ad && (abs($0.start - f.end) <= 5 || abs(f.start - $0.end) <= 5) }
            if !neighbours.isEmpty {
                if f.end - f.start <= 15 { return true }
                let joined = AdDetector.normalise(text).replacingOccurrences(of: " ", with: "")
                let shares = neighbours.contains { g in
                    let name = AdDetector.normalise(g.sponsor).replacingOccurrences(of: " ", with: "")
                    // "factormeals" named as "Factor": the name's first word will do.
                    let head = AdDetector.normalise(g.sponsor).split(separator: " ").first.map(String.init) ?? ""
                    return (name.count >= 4 && joined.contains(name)) || (head.count >= 4 && joined.contains(head))
                        || (name.count >= 6 && joined.contains(String(name.prefix(6))))
                }
                if shares { return true }
            }
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
            // A new read opens on its own line or on the one after a greeting
            // ("What's up, Skanks? I want to talk to you for a second about
            // Brunt…"). Legion of Skanks reads three sponsors back to back,
            // and they came out as one cut (D2).
            for index in stride(from: first + 1, through: last, by: 1) {
                let here = sentences[index].text
                let next = index + 1 <= last ? sentences[index + 1].text : ""
                let opens = opensAnAd(here) || (here.split(separator: " ").count <= 4 && opensAnAd(next))
                if opens, index - cuts.last! >= 3 {
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

    /// A plugs segment — each host's dates and website in turn, the
    /// network subscription, the book — comes out of the labels in pieces,
    /// some called ads, with the asides between them left as conversation.
    /// Pieces of it less than half a minute apart, with web addresses or dates
    /// between them, are one self-promotion. A named sponsor's read is never
    /// part of it (MSSP 633: BlueChew then Matt's tour dates stay apart).
    static func joinPlugs(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) -> [SegmentFinding] {
        let cues = [".com", "dot com", "tickets", "tour", "dates", "on the road", "subscribe", "website",
                    "special", "this weekend", "comedy club", "promo code", "come see", "book"]
        func plug(_ f: SegmentFinding) -> Bool {
            guard f.kind == .selfPromo || (f.kind == .ad && f.sponsor.isEmpty) else { return false }
            let text = sentences[f.firstSentence...f.lastSentence].map(\.text).joined(separator: " ").lowercased()
            return f.kind == .selfPromo || ["tickets", "tour", "dates", "on the road", "comedy club", "subscribe"]
                .contains { text.contains($0) }
        }
        var out: [SegmentFinding] = []
        for f in findings.sorted(by: { $0.start < $1.start }) {
            if var previous = out.last, plug(previous), plug(f), f.start - previous.end <= 100,
               previous.kind == .selfPromo || f.kind == .selfPromo,
               !f.insertedAtDownload, !previous.insertedAtDownload {
                let between = (previous.lastSentence + 1)..<f.firstSentence
                let text = between.map { sentences[$0].text.lowercased() }.joined(separator: " ")
                let hits = cues.filter { text.contains($0) }.count
                // Close together, one cue will do; up to a minute and a half
                // apart (a second host's dates after the first's), it takes
                // three: that much talk between two plugs is only more plugs
                // when it is full of dates and addresses.
                if between.isEmpty || (f.start - previous.end <= 30 && hits >= 1) || hits >= 3 {
                    previous.kind = .selfPromo
                    previous.sponsor = ""
                    previous.end = f.end
                    previous.lastSentence = f.lastSentence
                    previous.endConfidence = f.endConfidence
                    previous.confidence = (previous.confidence + f.confidence) / 2
                    out[out.count - 1] = previous
                    log.append("joined plugs \(clock(previous.start))–\(clock(f.end)) as one selfPromo")
                    continue
                }
            }
            out.append(f)
        }
        return out
    }

    /// Time ranges minus the inserted spans.
    static func subtract(_ ranges: [ClosedRange<Double>], _ cut: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        guard !cut.isEmpty else { return ranges }
        var out: [ClosedRange<Double>] = []
        for range in ranges {
            var pieces = [range]
            for c in cut {
                pieces = pieces.flatMap { p -> [ClosedRange<Double>] in
                    guard p.lowerBound < c.upperBound, p.upperBound > c.lowerBound else { return [p] }
                    var left: [ClosedRange<Double>] = []
                    if p.lowerBound < c.lowerBound - 1 { left.append(p.lowerBound...c.lowerBound) }
                    if c.upperBound + 1 < p.upperBound { left.append(c.upperBound...p.upperBound) }
                    return left
                }
            }
            out += pieces
        }
        return out
    }

    /// D3: closing credits that end on an offer ("three free months of
    /// SiriusXM") read as an ad. A span in the last five minutes whose words
    /// are credits — produced by, theme song by, engineering — is the outro,
    /// class credits, whatever the labels said; and a short plug or offer
    /// right after it goes with it. The outro switch skips it by default.
    static func credits(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) -> [SegmentFinding] {
        guard let duration = sentences.last?.end else { return findings }
        var out = findings.sorted { $0.start < $1.start }
        // The same at the other end: a network ident and theme at the top
        // ("You are listening to the Gas Digital Network", then the theme)
        // is the opening, not an ad, when it offers nothing.
        for n in out.indices where out[n].start < 150 && out[n].kind == .ad && !out[n].insertedAtDownload {
            let text = sentences[out[n].firstSentence...out[n].lastSentence].map(\.text).joined(separator: " ").lowercased()
            let ident = ["you are listening to", "you're listening to", "welcome to"].contains { text.contains($0) }
            let offers = [".com", "dot com", "code", "visit", "terms", "download", "sign up", "percent", "% off"]
                .contains { text.contains($0) }
            if ident && !offers {
                out[n].kind = .intro
                out[n].sponsor = ""
                log.append("\(clock(out[n].start)) ad → intro: a network ident, offering nothing")
            }
        }
        for n in out.indices where out[n].end > duration - 300 && out[n].kind != .intro && !out[n].insertedAtDownload {
            let text = sentences[out[n].firstSentence...out[n].lastSentence].map(\.text).joined(separator: " ")
            guard CutDetail.creditLines(text) >= 2 else { continue }
            if out[n].kind != .outro { log.append("\(clock(out[n].start)) \(out[n].kind.rawValue) → outro: it is the credits") }
            out[n].kind = .outro
            out[n].sponsor = ""
            out[n].detail = CutDetail.credits.rawValue
        }
        var merged: [SegmentFinding] = []
        for f in out {
            if var previous = merged.last, previous.detail == CutDetail.credits.rawValue, !f.insertedAtDownload,
               f.start - previous.end <= 5, f.end - f.start <= 20 {
                previous.end = max(previous.end, f.end)
                previous.lastSentence = max(previous.lastSentence, f.lastSentence)
                merged[merged.count - 1] = previous
                log.append("\(clock(f.start)) \(f.kind.rawValue) goes with the credits before it")
                continue
            }
            merged.append(f)
        }
        return merged
    }

    /// The comparison's spans become cuts with exact edges, and anything the
    /// model found that runs into one is trimmed to where it starts or ends.
    static func withInserted(_ findings: [SegmentFinding], inserted: [ClosedRange<Double>], sentences: [Sentence],
                             all: [Sentence], log: inout [String]) -> [SegmentFinding] {
        var out: [SegmentFinding] = []
        for f in findings {
            // What is left of it outside every inserted span: nothing, one
            // piece, or two when a span sits in its middle (a fingerprinted
            // Progressive spot inside a model-found break, then Hyundai).
            var pieces = [(f.start, f.end)]
            for span in inserted {
                pieces = pieces.flatMap { a, b -> [(Double, Double)] in
                    guard a < span.upperBound, b > span.lowerBound else { return [(a, b)] }
                    var left: [(Double, Double)] = []
                    if a < span.lowerBound { left.append((a, span.lowerBound)) }
                    if span.upperBound < b { left.append((span.upperBound, b)) }
                    return left
                }
            }
            for (a, b) in pieces {
                // A whole finding keeps the usual floor. What's left beside
                // an inserted break is usually the plug that led into it
                // ("Watch new episodes on Spotify. Do it."), which is short.
                let whole = a == f.start && b == f.end
                guard b - a >= (whole && f.kind == .ad ? 10 : 2.5) else {
                    log.append("\(clock(a)) \(f.kind.rawValue) piece dropped: beside an inserted span")
                    continue
                }
                // A longer piece of an "ad" that sells nothing itself was the
                // show running into the break: the model read the lines each
                // side of the hole as one read. Legion of Skanks singing
                // "Forever young" before a Progressive spot was cut (pass 19).
                if !whole, f.kind == .ad, b - a >= 8 {
                    let text = sentences.filter { $0.end > a + 0.05 && $0.start < b - 0.05 }
                        .map { $0.text.lowercased() }.joined(separator: " ")
                    let sells = offerCues.contains { text.contains($0) } || plugCalls.contains { text.contains($0) }
                        || strongOpeners.contains { text.contains($0) } || opensAnAd(text)
                    if !sells {
                        log.append("\(clock(a)) ad piece dropped: beside an inserted span, sells nothing")
                        continue
                    }
                }
                var piece = f
                piece.start = a; piece.end = b
                if let i = sentences.firstIndex(where: { $0.end > a + 0.05 }),
                   let j = sentences.lastIndex(where: { $0.start < b - 0.05 }), i <= j {
                    piece.firstSentence = i; piece.lastSentence = j
                }
                out.append(piece)
            }
        }
        for span in inserted {
            // Its own words are only in the full transcript; its place in the
            // one the model read is where it would have been.
            let text = all.filter { $0.end > span.lowerBound + 0.05 && $0.start < span.upperBound - 0.05 }
                .map(\.text).joined(separator: " ")
            let first = min(sentences.count - 1, sentences.firstIndex { $0.start >= span.lowerBound } ?? sentences.count - 1)
            let last = first
            var f = SegmentFinding(kind: .ad, start: span.lowerBound, end: span.upperBound,
                                   sponsor: sponsorName(in: text), confidence: 100,
                                   startConfidence: 100, endConfidence: 100,
                                   firstSentence: first, lastSentence: last)
            f.insertedAtDownload = true
            out.append(f)
        }
        return out.sorted { $0.start < $1.start }
    }

    // MARK: After the closing

    /// Once the show's closing has played — its end music, found as the same
    /// recording in another episode — what is left of the file is post-roll:
    /// Whiskey Ginger ends on its outro, then Liquid IV, a Peacock trailer
    /// and a Disney+ spot, and only the first repeats from week to week. When
    /// under two and a half minutes remain after a closing cut and something
    /// in them is already cut or sells something, the rest goes too.
    static func afterTheClosing(_ findings: [SegmentFinding], sentences: [Sentence],
                                log: inout [String]) -> [SegmentFinding] {
        // The last produced recording in the final four minutes — the outro,
        // or a post-roll that runs every week (whatever the model called it).
        guard let end = sentences.last?.end,
              let closing = findings.last(where: { $0.repeatedAudio && $0.end > end - 240 }),
              end - closing.end <= 150, end - closing.end > 3 else { return findings }
        let tail = sentences.indices.filter { sentences[$0].start >= closing.end - 0.5 }
        guard let first = tail.first, let last = tail.last else { return findings }
        let sells = strongCues + ["sponsor", "streaming", "in stores", "near you", "download", "offer", "code"]
        let cutAlready = findings.contains { $0.start >= closing.end - 1 }
        let selling = tail.contains { i in sells.contains { sentences[i].text.lowercased().contains($0) } }
        guard cutAlready || selling else { return findings }
        var out = findings.filter { $0.start < closing.end - 1 }
        let post = SegmentFinding(kind: .ad, start: closing.end, end: end, sponsor: "", confidence: 70,
                                  startConfidence: 90, endConfidence: 100, firstSentence: first, lastSentence: last)
        log.append("after the closing: \(clock(closing.end))–\(clock(end)) is post-roll")
        out.append(post)
        return out.sorted { $0.start < $1.start }
    }

    // MARK: Plugs

    /// Asking the listener to do something: buy, come, follow, go to.
    static let plugCalls = ["ticket", "come see", "come out and see", ".com", "dot com", "on sale", "subscribe",
                            "patreon", "merch", "promo code", "follow me", "follow us", "follow him", "follow her",
                            "link in bio", "pre-order", "preorder", "buy my", "pick up my", "check out my",
                            "check out our", "go check out", "hit me up", "go to my", "come watch", "tune in",
                            "like and subscribe", "comment and subscribe", "rate and review", "leave a review",
                            "go see the", "go see me", "comment down below", "comment below", "for tuning in",
                            "come over to"]
    /// What a plug says before it asks: when, where, with whom. ("May" is
    /// left out: "it may be" is everywhere.)
    static let plugLead = ["january", "february", "march", "april", "june", "july", "august", "september",
                           "october", "november", "december", "tour", "stand up", "stand-up", "standup",
                           "opening for", "opening up for", "headlin", "tickets", "come see", "i'll be in",
                           "i'm going to be in", "i'll be at", "live at", "sold out", "residency"]
    /// What a plug is about.
    static let plugTopics = ["tour", "special", "live show", "residency", "comedy club", "headlin", "book",
                             "album", "new episode", "youtube", "instagram", "tiktok", "twitter", "website",
                             "on the road", "cameo", "bonus"]
    /// What the last thing plugged sounds like.
    static let plugTrail = plugLead + plugCalls + plugTopics
        + ["netflix", "hulu", "stay tuned", "announcement", "coming soon", "coming very soon", "out now", "streaming"]

    /// The plugs segment — tour dates, a new special, the website, "come see
    /// me" — read as conversation to the model: it is the hosts talking, in
    /// their own words, between jokes. Legion of Skanks' two minutes of plugs
    /// and Your Mom's House's tour dates were heard in full (pass 18). Where
    /// lines asking the listener to do something cluster — at least two
    /// different requests, lines within 35 s of each other — that stretch is
    /// self-promotion, whatever the model said.
    static func plugs(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) -> [SegmentFinding] {
        struct Mark { var index: Int; var calls: Set<String>; var topics: Set<String> }
        var marks: [Mark] = []
        // Sentences already inside a paid read don't count: every read has a
        // web address and a code, and chaining from one would carry a cut
        // into the talk after it.
        let reads = findings.filter { $0.kind == .ad }
        for (i, s) in sentences.enumerated() where !reads.contains(where: { $0.start <= s.start && $0.end >= s.end }) {
            let lower = s.text.lowercased()
            let calls = Set(plugCalls.filter { lower.contains($0) })
            let topics = Set(plugTopics.filter { lower.contains($0) })
            if !calls.isEmpty || !topics.isEmpty { marks.append(Mark(index: i, calls: calls, topics: topics)) }
        }
        var clusters: [[Mark]] = []
        for m in marks {
            if let last = clusters.last?.last, sentences[m.index].start - sentences[last.index].end <= 35 {
                clusters[clusters.count - 1].append(m)
            } else {
                clusters.append([m])
            }
        }
        var out = findings
        for cluster in clusters {
            let calls = cluster.reduce(into: Set<String>()) { $0.formUnion($1.calls) }
            let topics = cluster.reduce(into: Set<String>()) { $0.formUnion($1.topics) }
            // Two different requests. One request and some tour talk was
            // looser, and cut a joke on Stavvy's World ("he's going to be
            // asking for tickets… tour with…") as a plug.
            guard calls.count >= 2,
                  var first = cluster.first?.index, var last = cluster.last?.index else { continue }
            // Back to what the plug is for: the date, the venue, who he's
            // opening for. The requests come at the end ("Go to
            // andrewsantino.com for those tickets"), and Whiskey Ginger's
            // twenty seconds about opening for Dave Chappelle on October 18th
            // were heard up to them (pass 19). Over lines saying when and
            // where, with at most two others between, within 25 s, never
            // into a cut already made.
            var j = first - 1, misses = 0
            while j >= 0, misses <= 2, sentences[first].start - sentences[j].start <= 25,
                  !out.contains(where: { $0.start <= sentences[j].start + 0.3 && $0.end >= sentences[j].end - 0.3 }) {
                let lower = sentences[j].text.lowercased()
                if plugLead.contains(where: { lower.contains($0) }) { first = j; misses = 0 } else { misses += 1 }
                j -= 1
            }
            // And on, the same way, to the last thing plugged: Legion of
            // Skanks' plugs ended "watch the Kevin Hart Roast, it's still on
            // Netflix… before I do Philly in December… an announcement…
            // stay tuned" and those 19 s were heard (pass 19). Lines already
            // cut are passed over, not counted.
            var k = last + 1
            misses = 0
            while k < sentences.count, misses <= 2, sentences[k].start - sentences[last].end <= 25 {
                if out.contains(where: { $0.start <= sentences[k].start + 0.3 && $0.end >= sentences[k].end - 0.3 }) { k += 1; continue }
                let lower = sentences[k].text.lowercased()
                if plugTrail.contains(where: { lower.contains($0) }) { last = k; misses = 0 } else { misses += 1 }
                k += 1
            }
            let start = sentences[first].start, end = sentences[last].end
            guard end - start >= 5 else { continue }
            // Already cut in full: nothing to add. Cut in part (Legion of
            // Skanks' plugs came out as three pieces with 85 s between them):
            // the whole stretch goes, merged with the pieces below.
            if out.contains(where: { $0.start <= start + 1 && $0.end >= end - 1 }) { continue }
            let f = SegmentFinding(kind: .selfPromo, start: start, end: end, sponsor: "", confidence: 65,
                                   startConfidence: 50, endConfidence: 50, firstSentence: first, lastSentence: last)
            log.append("plugs \(clock(start))–\(clock(end)): \(calls.sorted().joined(separator: ", ")) · \(topics.sorted().joined(separator: ", "))")
            out.append(f)
        }
        // Where it overlaps a smaller cut, the two are one stretch.
        out.sort { $0.start < $1.start }
        var merged: [SegmentFinding] = []
        for f in out {
            if var previous = merged.last, f.start < previous.end {
                if f.end > previous.end { previous.end = f.end; previous.lastSentence = f.lastSentence }
                merged[merged.count - 1] = previous
            } else {
                merged.append(f)
            }
        }
        return merged
    }

    /// Stage 2 (research §5): audio that plays again is produced material —
    /// a theme, a bumper, a promo, a produced ad, a read recorded once and
    /// used in several episodes. Conversation never repeats. So:
    /// - a repeat that overlaps a cut already found widens it to the
    ///   recording's exact edges;
    /// - one found in another episode of the show is cut: what it is comes
    ///   from one question about its words, or, if it has none or the
    ///   answer is "conversation", from where it is (opening, closing, or
    ///   an ad in the middle) — except a short one in the middle the model
    ///   calls conversation, which may be a segment's jingle;
    /// - one only repeated within this episode is cut only if the model says
    ///   it is promotional (a clip teased at the start and played later is
    ///   the show).
    func withProduced(_ findings: [SegmentFinding], produced: [AdPrints.Produced],
                      sentences: [Sentence], log: inout [String]) async -> [SegmentFinding] {
        guard let duration = sentences.last?.end else { return findings }
        var out = findings.sorted { $0.start < $1.start }
        var leftovers: [AdPrints.Produced] = []
        // A recording he said is not an ad (a negative in the library):
        // nothing found by fingerprint is cut over it.
        let negatives = produced.filter(\.negative)
        func vetoed(_ p: AdPrints.Produced) -> Bool {
            negatives.contains { n in min(n.end, p.end) - max(n.start, p.start) > 0.5 * (p.end - p.start) }
        }
        for p in produced where p.end - p.start >= 8 && !p.negative && !vetoed(p) {
            let length = p.end - p.start
            let first = sentences.firstIndex { $0.end > p.start + 0.3 }
            let last = sentences.lastIndex { $0.start < p.end - 0.3 }
            if let n = out.firstIndex(where: { f in
                let shared = min(f.end, p.end) - max(f.start, p.start)
                return shared > 0.5 * length || shared > 0.5 * (f.end - f.start)
            }) {
                if p.start < out[n].start { out[n].start = p.start; if let first { out[n].firstSentence = min(out[n].firstSentence, first) } }
                if p.end > out[n].end { out[n].end = p.end; if let last { out[n].lastSentence = max(out[n].lastSentence, last) } }
                out[n].repeatedAudio = true
                log.append("repeat \(Self.clock(p.start))–\(Self.clock(p.end)) widens \(out[n].kind.rawValue)")
                continue
            }
            let opening = p.start < min(600, duration * 0.2)
            let closing = p.end > duration - 600
            var said: SegmentKind?
            // Music alone has no sentence inside it: the first sentence after
            // it comes later than the last one before it. Point at one
            // sentence, never at an inverted range (it crashed the lab on
            // The Adam Friedland Show's theme).
            var lo = min(first ?? last ?? 0, last ?? first ?? 0), hi = lo
            if let first, let last, first <= last { lo = first; hi = last }
            var anchor = SegmentFinding(kind: .ad, start: p.start, end: p.end, sponsor: "", confidence: 85,
                                        startConfidence: 100, endConfidence: 100,
                                        firstSentence: lo, lastSentence: hi)
            if let known = p.known.flatMap(SegmentKind.init(rawValue:)) {
                // Known from the library: what it was on the show it was
                // learned from. No question.
                said = known
            } else if let first, let last, first <= last {
                said = await classify(anchor, sentences: sentences, log: &log)
            }
            let kind: SegmentKind?
            if let said {
                kind = said
            } else if p.acrossEpisodes {
                kind = opening ? .intro : closing ? .outro : (length >= 20 ? .ad : nil)
            } else if p.start > duration - 300 {
                // A song's chorus heard twice in the last five minutes is
                // the closing song (Your Mom's House ends on one).
                kind = .outro
            } else {
                kind = nil
            }
            guard let kind else {
                log.append("repeat \(Self.clock(p.start))–\(Self.clock(p.end)) left: reads as the show")
                if p.acrossEpisodes { leftovers.append(p) }
                continue
            }
            anchor.kind = kind
            anchor.repeatedAudio = true
            if kind == .ad, let first, let last, first <= last {
                anchor.sponsor = Self.sponsorName(in: sentences[first...last].map(\.text).joined(separator: " "))
            }
            // Pieces of other cuts it covers go; it has the exact edges.
            out.removeAll { $0.start >= p.start - 1 && $0.end <= p.end + 1 }
            log.append("repeat \(Self.clock(p.start))–\(Self.clock(p.end)) \(p.known != nil ? "known from the library" : p.acrossEpisodes ? "in another episode" : "twice here") → \(kind.rawValue)")
            out.append(anchor)
            out.sort { $0.start < $1.start }
        }
        // A piece of a recording from another episode, left because on its
        // own it read as the show, that runs straight on (≤5 s) from a cut
        // made from a recording is the same recording interrupted — the
        // hosts talking over their own theme. Your Mom's House's theme came
        // back as 18:52–19:03 and 19:06–19:39, and the first ten seconds
        // were heard (pass 19).
        for p in leftovers {
            guard let n = out.firstIndex(where: { f in
                f.repeatedAudio && ((0...5).contains(f.start - p.end) || (0...5).contains(p.start - f.end))
            }) else { continue }
            if p.start < out[n].start {
                out[n].start = p.start
                if let first = sentences.firstIndex(where: { $0.end > p.start + 0.3 }) { out[n].firstSentence = min(out[n].firstSentence, first) }
            } else {
                out[n].end = p.end
                if let last = sentences.lastIndex(where: { $0.start < p.end - 0.3 }) { out[n].lastSentence = max(out[n].lastSentence, last) }
            }
            log.append("repeat \(Self.clock(p.start))–\(Self.clock(p.end)) joins the recording beside it")
        }
        // A cut widened over a neighbour's ground takes it.
        var tidy: [SegmentFinding] = []
        for f in out {
            if var previous = tidy.last, f.start < previous.end {
                if f.end <= previous.end { continue }
                if f.repeatedAudio && !previous.repeatedAudio { previous.end = f.start; tidy[tidy.count - 1] = previous }
                else { var g = f; g.start = previous.end; tidy.append(g); continue }
                if previous.end - previous.start < 2 { tidy.removeLast() }
            }
            tidy.append(f)
        }
        return tidy
    }

    /// What a read is called, for finding it named again: the sponsor's
    /// name if one was found, and any two-word name the read says at least
    /// twice ("Mountain Dew"). Joined and lower-cased, as `mentions` matches.
    static func sponsorKeys(_ f: SegmentFinding, sentences: [Sentence]) -> Set<String> {
        var keys = Set<String>()
        let own = AdDetector.normalise(f.sponsor).replacingOccurrences(of: " ", with: "")
        if own.count >= 4 { keys.insert(own) }
        let text = sentences[f.firstSentence...f.lastSentence].map(\.text).joined(separator: " ")
        var counts: [String: Int] = [:]
        for match in text.matches(of: try! Regex(#"[A-Z][a-z]+ [A-Z][a-z]+"#)) {
            let key = AdDetector.normalise(String(text[match.range])).replacingOccurrences(of: " ", with: "")
            if key.count >= 6 { counts[key, default: 0] += 1 }
        }
        keys.formUnion(counts.filter { $0.value >= 2 }.keys)
        return keys
    }

    /// A read whose sponsor is named again soon after it ends. 2 Bears
    /// introduced "our partners in business, Mountain Dew", played the
    /// commercial they had made for them — a minute and a half of music and
    /// dialogue, recorded once, with no offer in it — then "enjoy the
    /// outdoors with Mountain Dew… and thank you, Mountain Dew". The edge
    /// walk stopped where the commercial began, and 114 s of it was heard.
    /// When the name comes back within two and a half minutes (further than
    /// `grow` reaches), one question about the whole stretch up to that line
    /// decides whether it was all the read (pass 19).
    func sponsorEcho(_ findings: [SegmentFinding], sentences: [Sentence], log: inout [String]) async -> [SegmentFinding] {
        var out = findings.sorted { $0.start < $1.start }
        for n in out.indices where out[n].kind == .ad {
            let f = out[n]
            let keys = Self.sponsorKeys(f, sentences: sentences)
            let ceiling = n + 1 < out.count ? out[n + 1].firstSentence - 1 : sentences.count - 1
            guard !keys.isEmpty, f.lastSentence + 1 <= ceiling else { continue }
            var echo: Int?
            for i in (f.lastSentence + 1)...ceiling {
                if sentences[i].start - f.end > 150 { break }
                if Self.mentions(sentences[i], keys) { echo = i }
            }
            guard let echo, sentences[echo].start - f.end > 30 else { continue }
            let probe = SegmentFinding(kind: .ad, start: sentences[f.lastSentence + 1].start, end: sentences[echo].end,
                                       sponsor: f.sponsor, confidence: 50, startConfidence: 40, endConfidence: 40,
                                       firstSentence: f.lastSentence + 1, lastSentence: echo)
            if let kind = await classify(probe, sentences: sentences, log: &log), kind == .ad {
                out[n].end = sentences[echo].end
                out[n].lastSentence = echo
                log.append("sponsor named again: \(Self.clock(f.start))–\(Self.clock(f.end)) → \(Self.clock(out[n].end))")
            } else {
                log.append("sponsor named again at \(Self.clock(sentences[echo].start)): the stretch before it is the show")
            }
        }
        return out
    }

    /// Two cuts with nothing said between them, a few seconds apart, are one
    /// stretch: the music or silence between a closing song and the spot
    /// after it (Your Mom's House), or between two spots in a break. The gap
    /// goes to the cut before it; nothing with words in it is ever taken.
    static func bridgeQuiet(_ findings: [SegmentFinding], all: [Sentence], log: inout [String]) -> [SegmentFinding] {
        var out = findings.sorted { $0.start < $1.start }
        for n in out.indices.dropLast() {
            let gapStart = out[n].end, gapEnd = out[n + 1].start
            // Under two seconds is the player's business (it plays straight on).
            guard gapEnd - gapStart >= 2, gapEnd - gapStart <= 15 else { continue }
            let spoken = all.contains { $0.end > gapStart + 0.3 && $0.start < gapEnd - 0.3 }
            // Two pieces of one closing song or one plug, a line apart, are
            // one stretch too (the song's chorus came back as two repeats
            // four seconds apart). Not two ads: those are `mergeReads`' call.
            let samePiece = out[n].kind == out[n + 1].kind && out[n].kind != .ad && gapEnd - gapStart <= 5
            guard !spoken || samePiece else { continue }
            log.append("quiet \(clock(gapStart))–\(clock(gapEnd)) joins \(out[n].kind.rawValue) to the next cut")
            out[n].end = gapEnd
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
                         inserted: [ClosedRange<Double>] = [],
                         produced: [AdPrints.Produced] = [],
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> DetectionResult {
        guard !segments.isEmpty else { return DetectionResult() }
        let (findings, log) = try await SegmentDetector().detect(
            segments: segments, knownSponsors: knownSponsors, corrections: corrections,
            globalCorrections: globalCorrections, showTitle: showTitle, episodeTitle: episodeTitle,
            showNotes: showNotes, minimumConfidence: minimumConfidence, hints: hints, inserted: inserted,
            produced: produced, progress: progress)
        let duration = audioDuration > 0 ? audioDuration : (segments.last?.end ?? 0)
        let detected = findings.map { f -> DetectedSegment in
            // Frame-exact already: no padding, no snapping.
            if f.insertedAtDownload || f.repeatedAudio {
                return DetectedSegment(start: f.start, end: f.end, kind: f.kind, sponsor: f.sponsor,
                                       confidence: f.confidence, startConfidence: f.startConfidence,
                                       endConfidence: f.endConfidence, evidence: f.evidence,
                                       insertedAtDownload: f.insertedAtDownload, detail: f.detail)
            }
            var s = DetectedSegment(start: f.start + padding, end: f.end - padding,
                                    kind: f.kind, sponsor: f.sponsor, confidence: f.confidence,
                                    startConfidence: f.startConfidence, endConfidence: f.endConfidence,
                                    evidence: f.evidence, detail: f.detail)
            // Within a little under a second. The window detector snapped
            // within 2.5 s because its edges were that rough; these come from
            // word times, and a 2.5 s snap could move a good edge into the
            // show's last words or the ad's first.
            s = Self.snap(s, to: silences, tolerance: 0.8)
            return s
        }
        let finished = Self.extendBookends(detected, duration: duration)
            .filter { $0.end > $0.start + 1 }
        let sponsors = findings.filter { $0.kind == .ad && !$0.sponsor.isEmpty }.map(\.sponsor)
        return DetectionResult(segments: finished, sponsors: Array(Set(sponsors)).sorted(), log: log)
    }
}
