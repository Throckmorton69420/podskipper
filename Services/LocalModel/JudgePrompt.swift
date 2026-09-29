import Foundation

// The ad-finding prompt, ported from Tools/DetectionLab/gemini_bench.py.
//
// RULES, the labels (KIND), the answer schema, the line format and the
// edge-snapping (`anchor`) are copied, not paraphrased: that wording is what
// was benchmarked, and a model's answers move when the words do. The schema
// is the plain JSON Schema the bench sends to open models (its
// `lower_schema(SCHEMA)`), and the system prompt is built the way the bench
// builds it for them: RULES, then "Answer with JSON only, matching this
// schema: " and the schema.

/// A label the model may give a part. Raw values are the bench's KIND keys.
enum JudgeLabel: String, CaseIterable, Codable, Sendable {
    case paidAd = "PAID_AD"
    case hostReadAd = "HOST_READ_AD"
    case networkPromo = "NETWORK_PROMO"
    case selfPromo = "SELF_PROMO"
    case guestPlug = "GUEST_PLUG"
    case intro = "INTRO"
    case outro = "OUTRO"
    case credits = "CREDITS"
    case recurringSegment = "RECURRING_SEGMENT"
    case mockAd = "MOCK_AD"

    /// The bench's KIND value: the app's segment kind by name, or nil for
    /// parts that are the show and must be kept.
    var kindName: String? {
        switch self {
        case .paidAd, .hostReadAd: return "ad"
        case .networkPromo:        return "crossPromo"
        case .selfPromo, .guestPlug: return "selfPromo"
        case .intro:               return "intro"
        case .outro:               return "outro"
        case .credits:             return "credits"
        case .recurringSegment, .mockAd: return nil
        }
    }

    /// The app's own kind. nil for the kept labels, and for CREDITS, which
    /// the bench names "credits" and the app has no kind for yet.
    var segmentKind: SegmentKind? { kindName.flatMap(SegmentKind.init(rawValue:)) }
}

/// Audio evidence the phone already has for a stretch of the episode.
struct EvidenceSpan: Sendable, Hashable {
    enum Kind: String, Sendable {
        /// Inserted by the host's ad server (not in the ad-free copy). «I»
        case inserted = "I"
        /// The same recording plays elsewhere. «R»
        case repeated = "R"
    }
    var start: Double
    var end: Double
    var kind: Kind
}

/// One part the model found, on the app's transcript lines.
struct JudgedPart: Sendable, Hashable {
    /// Indexes into the `lines` given to `judge`, inclusive.
    var firstLine: Int
    var lastLine: Int
    var label: JudgeLabel
    var sponsor: String
    var funny: Bool
    /// 0–100, as the model gave it.
    var confidence: Int
    var why: String

    /// Whether this is something to cut (an ad, promo, intro…) rather than a
    /// part that is the show and marked so it is kept.
    var isCut: Bool { label.kindName != nil }
}

enum JudgePrompt {
    static let rules = #"""
You mark the commercial and structural parts of one podcast episode for an ad-skipping app.
The transcript comes from speech recognition (spelling of names and brands can be wrong), one numbered line per
recognized sentence: "<line> <text>", with the time "[h:mm:ss]" shown on every 15th line. Read the whole episode first; judge every part by what it is doing
in context, never by keywords alone.

Labels (list only these; everything not listed is the show and is kept):
- PAID_AD: a sponsor's advertisement that is produced or pre-recorded: announcer or scripted copy, often inserted
  into the file (abrupt change of topic, voice or sound, back-to-back spots, the same copy replayed), pre-rolls at
  the very start, post-rolls at the very end.
- HOST_READ_AD: a host (or guest) reading or riffing a paid sponsorship in their own voice. It starts at the
  hand-off ("let's take a quick break", "this episode is brought to you by", "our friends at", "speaking of…")
  and ends at the last line about the product, its offer, code or web address, before the conversation truly
  returns. Riffs and jokes about the sponsor's product inside the read belong to the ad.
- NETWORK_PROMO: a promotion or trailer for another podcast or program that is not this show's own (network
  cross-promos, "if you like this show you'll love…", produced trailers).
- SELF_PROMO: the hosts promoting their own things: tour dates, tickets, specials, Patreon or bonus/premium feed,
  merch, their YouTube/socials, their other shows, "rate and review", live-show plugs.
- GUEST_PLUG: the guest's own work promoted: the guest's tour dates, special, book, podcast, socials, website
  (commonly at the start when introduced or at the end before goodbye).
- INTRO: the produced opening: theme music, stock opener or announcer intro. The hosts simply saying hello and
  starting to talk is the show, not INTRO.
- OUTRO: the produced closing: sign-off lines and theme after the conversation has ended.
- CREDITS: production credits (produced by, edited by, music by, executive producers).
- RECURRING_SEGMENT: a recurring produced bit of the show itself (a named segment, a jingle for a regular bit).
- MOCK_AD: a joke that imitates an ad, a fake or parody sponsor, or a bit about a brand that nobody is paying
  for. These are the show.

Hard rules:
1. Talking about a company, product, brand, price or website is NOT an ad by itself. People discuss brands
   constantly (restaurants, apps, drinks, cars, stores). An ad needs affirmative evidence of a paid relationship:
   a sponsorship hand-off, an offer or promo code, "go to …com/<show>", "use code", "terms apply", "sponsored by",
   copy that sells rather than converses, or a produced spot. When in doubt between an ad and the show, it is the show.
2. A story that mentions tickets, a show, a tour or a book in passing is the show. SELF_PROMO/GUEST_PLUG needs an
   actual ask or plug: dates and cities, "get tickets", "go see him", "link in the description", "subscribe to…".
3. A real paid read that is funny is still HOST_READ_AD; set funny=true when the hosts turn the read into a
   genuinely comedic bit. A fake sponsor or a parody is MOCK_AD.
4. Be exhaustive: check the very first and very last lines, every mid-roll break, and back-to-back sponsors.
   Give each sponsor its own entry, and each distinct plug its own entry.
5. Be tight: first_line is the first line of the part, last_line its last line. Don't swallow the conversation
   before or after. Paid spots rarely exceed 3 minutes each; a plug is usually under a minute.
6. Sponsors named in the show notes probably advertise in this episode; use that as a hint, not as proof.
8. Audio evidence marks: «I» = the podcast host's ad server inserted this audio (measured exactly: it is not in
   the ad-free copy) — almost always PAID_AD or NETWORK_PROMO. «R» = this exact recording also plays elsewhere
   (in another episode or twice in this one) — typical of produced ads, promos, intros and outros, but a cold-open
   tease that replays a later moment of the show is also «R» and is the show. Unmarked lines have no audio
   evidence either way; host-read ads are usually unmarked.
7. Include MOCK_AD and RECURRING_SEGMENT entries only when a reasonable listener might have mistaken them for an
   ad; they tell the app what NOT to cut.

"""#

    static let schema = #"{"type": "object", "properties": {"parts": {"type": "array", "items": {"type": "object", "properties": {"first_line": {"type": "integer"}, "last_line": {"type": "integer"}, "first_words": {"type": "string", "description": "the first 8 words of first_line, copied exactly"}, "last_words": {"type": "string", "description": "the first 8 words of last_line, copied exactly"}, "label": {"type": "string", "enum": ["PAID_AD", "HOST_READ_AD", "NETWORK_PROMO", "SELF_PROMO", "GUEST_PLUG", "INTRO", "OUTRO", "CREDITS", "RECURRING_SEGMENT", "MOCK_AD"]}, "sponsor": {"type": "string", "description": "brand or thing promoted, empty if none"}, "funny": {"type": "boolean"}, "confidence": {"type": "integer", "description": "0-100"}, "why": {"type": "string", "description": "one short sentence of evidence"}}, "required": ["first_line", "first_words", "last_line", "last_words", "label", "sponsor", "funny", "confidence", "why"], "additionalProperties": false}}}, "required": ["parts"], "additionalProperties": false}"#

    /// The system prompt, as the bench sends it to open models.
    static var system: String { rules + "\nAnswer with JSON only, matching this schema: " + schema }

    /// The bench's `short`: whole seconds as h:mm:ss.
    static func short(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
    }

    /// «I», «R» or «IR» when evidence covers more than half of the line.
    static func tag(_ line: TimedLine, _ spans: [EvidenceSpan]) -> String {
        let length = max(0.1, line.end - line.start)
        let kinds = Set(spans.filter { min($0.end, line.end) - max($0.start, line.start) > 0.5 * length }
            .map(\.kind.rawValue))
        return kinds.isEmpty ? "" : "«" + kinds.sorted().joined() + "» "
    }

    /// One transcript line: its number, a time on every 15th, the evidence
    /// marks, the text. Numbers are the line's index in the whole episode,
    /// so an answer means the same line whichever window it came from.
    static func line(_ index: Int, _ line: TimedLine, spans: [EvidenceSpan]) -> String {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if index % 15 == 0 {
            return "\(index) [\(short(line.start))] \(tag(line, spans))\(text)"
        }
        return "\(index) \(tag(line, spans))\(text)"
    }

    /// The user message for one window. The bench's header, with one added
    /// sentence saying which lines this window holds (it read whole episodes
    /// at once; a phone can't).
    static func user(show: String, title: String, notes: String, lines: [TimedLine],
                     window: Range<Int>, formatted: [String], corrections: String = "") -> String {
        let total = lines.count
        let length = short(lines.last?.end ?? 0)
        var text = "Show: \(show)\nEpisode: \(title)\nShow notes:\n\(String(notes.prefix(4000)))\n\n"
        // The listener's past verdicts on this show (task 05), before the
        // transcript; the rules above are left as benchmarked.
        if !corrections.isEmpty { text += corrections + "\n\n" }
        text += "Transcript (\(total) lines, \(length) long):\n"
        if window.count < total {
            text += "This is part of it: lines \(window.lowerBound)–\(window.upperBound - 1). "
            text += "Mark only parts inside these lines.\n"
        }
        text += formatted[window].joined(separator: "\n")
        return text
    }

    // MARK: Reading the answer

    /// A part as the model wrote it, before its edges are snapped.
    struct RawPart {
        var firstLine: Int
        var lastLine: Int
        var firstWords: String
        var lastWords: String
        var label: JudgeLabel
        var sponsor: String
        var funny: Bool
        var confidence: Int
        var why: String
    }

    /// The parts in an answer, or nil if it holds no readable JSON object
    /// with a "parts" list. Lenient like the bench's open-model path: any
    /// reasoning is dropped, then the text from the first "{" to the last
    /// "}" is read. A part with an unknown label is skipped, not guessed.
    static func parse(_ answer: String) -> [RawPart]? {
        var text = answer
        if let close = text.range(of: "</think>") { text = String(text[close.upperBound...]) }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let data = String(text[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = object["parts"] as? [Any] else { return nil }
        return parts.compactMap { item -> RawPart? in
            guard let part = item as? [String: Any],
                  let first = int(part["first_line"]), let last = int(part["last_line"]),
                  let label = (part["label"] as? String).flatMap(JudgeLabel.init(rawValue:)) else { return nil }
            return RawPart(firstLine: first, lastLine: last,
                           firstWords: part["first_words"] as? String ?? "",
                           lastWords: part["last_words"] as? String ?? "",
                           label: label,
                           sponsor: part["sponsor"] as? String ?? "",
                           funny: part["funny"] as? Bool ?? false,
                           confidence: int(part["confidence"]) ?? 0,
                           why: part["why"] as? String ?? "")
        }
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: return n.intValue
        case let s as String:   return Int(s.trimmingCharacters(in: .whitespaces))
        default:                return nil
        }
    }

    /// The bench's `to_detect`, without the formatting: clamp, snap both
    /// edges to the quoted words, drop a part whose end comes before its start.
    static func resolve(_ raw: RawPart, lines: [TimedLine]) -> JudgedPart? {
        guard !lines.isEmpty else { return nil }
        var a = max(0, raw.firstLine), b = min(lines.count - 1, raw.lastLine)
        a = anchor(lines, guess: min(a, lines.count - 1), words: raw.firstWords)
        b = anchor(lines, guess: max(b, 0), words: raw.lastWords)
        guard b >= a else { return nil }
        return JudgedPart(firstLine: a, lastLine: b, label: raw.label, sponsor: raw.sponsor,
                          funny: raw.funny, confidence: raw.confidence, why: raw.why)
    }

    // MARK: anchor()

    /// The bench's `anchor`: the line whose opening words match the model's
    /// quote, nearest its line number. Models copy text reliably but count
    /// lines badly in long input.
    static func anchor(_ lines: [TimedLine], guess: Int, words: String, window: Int = 250) -> Int {
        let want = opening(words)
        guard !want.isEmpty else { return guess }
        var best = guess, score = 0.0
        let low = max(0, guess - window), high = min(lines.count, guess + window + 1)
        guard low < high else { return guess }
        for i in low..<high {
            let have = opening(lines[i].text)
            let s = SequenceMatcher.ratio(want, have) - Double(abs(i - guess)) * 0.0005
            if s > score { best = i; score = s }
        }
        return score >= 0.6 ? best : guess
    }

    /// `" ".join(re.sub(r"[^a-z0-9 ]", "", s.lower()).split()[:8])`
    static func opening(_ text: String) -> [UInt8] {
        let kept = text.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == " "
        }
        let words = String(String.UnicodeScalarView(kept)).split(separator: " ").prefix(8)
        return Array(words.joined(separator: " ").utf8)
    }
}

/// Python's `difflib.SequenceMatcher(None, a, b).ratio()`, for the short
/// ASCII strings `anchor` compares. Same longest-match search and the same
/// tie-breaking, so the same score. difflib's "autojunk" only starts at 200
/// characters, which eight words rarely reach; it isn't ported.
enum SequenceMatcher {
    static func ratio(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1 }
        var b2j: [UInt8: [Int]] = [:]
        for (j, element) in b.enumerated() { b2j[element, default: []].append(j) }

        func longest(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
            var besti = alo, bestj = blo, bestsize = 0
            var j2len: [Int: Int] = [:]
            for i in alo..<ahi {
                var next: [Int: Int] = [:]
                for j in b2j[a[i]] ?? [] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    next[j] = k
                    if k > bestsize { besti = i - k + 1; bestj = j - k + 1; bestsize = k }
                }
                j2len = next
            }
            return (besti, bestj, bestsize)
        }

        var matches = 0
        var queue = [(0, a.count, 0, b.count)]
        while let range = queue.popLast() {
            let (alo, ahi, blo, bhi) = range
            guard alo < ahi, blo < bhi else { continue }
            let (i, j, k) = longest(alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            matches += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return 2.0 * Double(matches) / Double(total)
    }
}
