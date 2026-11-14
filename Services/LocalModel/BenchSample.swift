import Foundation

/// The standard tests every ad finder takes (pass 27g, his request: rank
/// the models, keep each one's results, add a harder test, and run Apple
/// Intelligence and the reader through the same tests).
///
/// Pass 63 (his 10 Nov report): version 4 (`BenchScript`). **Basic** is a
/// quick check of the fundamentals, read in one go. **Hard** is a whole
/// made-up episode with real timing, read the way Find Ads reads an episode:
/// the Reader first, then the model on the stretches the app would show it,
/// then PodSkipper's cut check — and both the model's own answer and the
/// checked one are scored. The score is `PodTestScore.Quality`: ads cut,
/// show kept, edges and kinds. They are still made up: the PodSkipper Test,
/// on his own episodes, is the measure of real quality.
enum BenchSample: String, Codable, CaseIterable, Sendable {
    case basic, hard

    var title: String { self == .basic ? "Basic" : "Hard" }
    /// Increment whenever the sample text, timing or expected truth changes.
    /// Pass 63: version 4 — real timing, word times and pauses; Hard through
    /// the app's own steps; the four-part score. Pass 64: version 5 — Basic
    /// the fundamentals only (no trap: what overlapped Hard is gone), Hard
    /// with a comedy riff in an ad's voice and a break that ends with no
    /// "we're back"; results before it are kept as an earlier sample.
    var version: Int { 5 }

    /// One line on what the sample is for.
    var purpose: String {
        switch self {
        case .basic: "a 5-minute check of the fundamentals — an intro, three ads and the credits — read in one go."
        case .hard: "a 21-minute episode with every kind of break, ads back to back, an exit with no “we’re back”, and traps (a comedy riff in an ad’s voice, a joke ad, tour talk), read the way Find Ads reads yours."
        }
    }

    /// Whether a model reads it through the app's own steps (the Reader
    /// first, then the stretches Find Ads would show the model).
    var usesFocus: Bool { self == .hard }

    /// What a labelled stretch is, as the checks count it.
    enum Category: String, Codable, Sendable, CaseIterable {
        case ad, plug, network, introOutro

        /// The category of a cut of this kind (`SegmentKind` raw values).
        init?(kind: String) {
            switch kind {
            case "ad": self = .ad
            case "selfPromo": self = .plug
            case "crossPromo": self = .network
            case "intro", "outro", "credits": self = .introOutro
            default: return nil
            }
        }

        /// A `SegmentKind` raw value of this category.
        var cutKind: String {
            switch self {
            case .ad: "ad"
            case .plug: "selfPromo"
            case .network: "crossPromo"
            case .introOutro: "intro"
            }
        }
    }

    struct Region: Sendable {
        var category: Category
        var lines: ClosedRange<Int>
    }

    var script: BenchScript { self == .basic ? .basic : .hard }

    /// The stretches that should be cut.
    var regions: [Region] { script.breaks.map { Region(category: $0.category, lines: $0.lines) } }

    /// Lines where cutting or keeping are both right: a break's hand-off and
    /// return, the hosts wandering off inside a read.
    var either: Set<Int> { script.either }

    /// Show lines a careless reader cuts: talk about a brand nobody paid
    /// for, a joke ad, stories that only sound like a plug.
    var traps: [(name: String, lines: ClosedRange<Int>)] { script.traps.map { ($0.name, $0.lines) } }

    var show: String { script.show }
    var episode: String { script.episode }
    var notes: String { script.notes }
    var duration: Double { script.duration }
    var silences: [ClosedRange<Double>] { script.silences }

    var lines: [TimedLine] {
        script.lines.map { TimedLine(text: $0.text, start: $0.start, end: $0.end, words: $0.words) }
    }

    /// The sample as the recognizer's chunks, each word with its time.
    var transcript: [TranscriptSegment] {
        script.lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words) }
    }

    /// The lines that should be cut.
    var expectedCut: Set<Int> { Set(regions.flatMap { Array($0.lines) }) }

    /// Lines whose middle a cut covers.
    func linesCut(_ cuts: [PodTestCut]) -> [Int: String] {
        var out: [Int: String] = [:]
        for (i, line) in script.lines.enumerated() {
            let middle = (line.start + line.end) / 2
            if let cut = cuts.first(where: { middle >= $0.start && middle <= $0.end }) { out[i] = cut.kind }
        }
        return out
    }

    /// Everything the sample says about a finder's cuts.
    func report(cuts: [PodTestCut]) -> BenchReport {
        let script = self.script
        let quality = PodTestScore.quality(script.episodeForScoring, cuts: cuts, constants: BenchScript.constants)
        let taken = linesCut(cuts)
        var c = BenchChecks()
        for region in regions {
            let inside = region.lines.filter { taken[$0] != nil }
            c.skippableLines += region.lines.count
            c.skippableLinesCut += inside.count
            let found = Double(inside.count) >= Double(region.lines.count) / 2
            c.add(region.category, found: found)
            guard found else { continue }
            let kinds = inside.compactMap { taken[$0].flatMap(Category.init(kind:)) }
            let named = Dictionary(grouping: kinds, by: { $0 }).max { $0.value.count < $1.value.count }?.key
            c.kindsChecked += 1
            if named == region.category { c.kindsRight += 1 }
        }
        c.showLinesCut = Set(taken.keys).subtracting(expectedCut).subtracting(either).count
        c.trapsCut = traps.filter { trap in trap.lines.contains { taken[$0] != nil } }.map(\.name)
        c.score = quality.score
        return BenchReport(checks: c, quality: quality)
    }

    /// Pass 63: `PodTestScore.Quality`'s score (0–1) of cutting these lines.
    func score(cut: Set<Int>) -> Double {
        report(cuts: script.cuts(cut)).quality.score
    }

    /// Each stretch checked by kind. `cut` is every line cut, with the kind
    /// of the cut that took it (nil when the cut named none).
    func checks(cut: [Int: Category?]) -> BenchChecks {
        var kinds: [Int: String] = [:]
        for (line, category) in cut { if let category { kinds[line] = category.cutKind } }
        return report(cuts: script.cuts(Set(cut.keys), kinds: kinds)).checks
    }
}

/// Pass 63: one answer to a sample, checked and scored.
struct BenchReport: Sendable, Equatable {
    var checks: BenchChecks
    var quality: PodTestScore.Quality

    var line: String {
        "Score \(PodTestScore.Quality.percent(quality.score)) · " + quality.summary + " · " + checks.summary
    }
}

/// Pass 54: what one answer to a sample got right and wrong, kind by kind.
struct BenchChecks: Codable, Sendable, Equatable {
    var ads = 0, adsFound = 0
    var plugs = 0, plugsFound = 0
    var network = 0, networkFound = 0
    var introOutro = 0, introOutroFound = 0
    var kindsChecked = 0, kindsRight = 0
    var skippableLines = 0, skippableLinesCut = 0
    var showLinesCut = 0
    var trapsCut: [String] = []
    var score = 0.0

    mutating func add(_ category: BenchSample.Category, found: Bool) {
        let one = found ? 1 : 0
        switch category {
        case .ad: ads += 1; adsFound += one
        case .plug: plugs += 1; plugsFound += one
        case .network: network += 1; networkFound += one
        case .introOutro: introOutro += 1; introOutroFound += one
        }
    }

    /// "Ad 1/1 · plugs 2/2 · other shows 1/1 · intro and credits 1/2 · named
    /// right 4/5 · 0 show lines cut", then any trap it fell for.
    var summary: String {
        var parts = ["ad\(ads == 1 ? "" : "s") \(adsFound)/\(ads)"]
        if plugs > 0 { parts.append("plugs \(plugsFound)/\(plugs)") }
        if network > 0 { parts.append("other shows \(networkFound)/\(network)") }
        if introOutro > 0 { parts.append("intro and credits \(introOutroFound)/\(introOutro)") }
        if kindsChecked > 0 { parts.append("named right \(kindsRight)/\(kindsChecked)") }
        parts.append(showLinesCut == 1 ? "1 show line cut" : "\(showLinesCut) show lines cut")
        var text = parts.joined(separator: " · ")
        text = text.prefix(1).uppercased() + text.dropFirst()
        if !trapsCut.isEmpty { text += " · cut " + trapsCut.joined(separator: " and ") }
        return text
    }
}
