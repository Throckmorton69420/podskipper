import Accelerate
import Foundation

/// Pass 38 (his request): PodSkipper's reader keeps learning on this iPhone,
/// from two teachers, without the graphics chip.
///
/// The reader (`SentenceTagger`) is a 12-layer ELECTRA-small that turns every
/// sentence into a summary (256 numbers) plus 22 side facts, and a small head
/// (278 → 128 → 6, ~36,000 numbers per reader) that turns those into the six
/// labels. Only the head is trained here; the 14 M-parameter body stays as
/// shipped. A copy of each reader's head is trained with AdamW on:
///
/// - **His corrections** (gold, weight 5): every confirm, lock, edit, added
///   cut and "Not an Ad" in `CorrectionLedger` — the stretch he settled is
///   that label; where he set the edges (lock, edit, add), the 45 s either
///   side are the show.
/// - **Verified model reads** (silver, weight 1): an on-device model that
///   scores 70 % or more on the model test, whose cuts passed `ModelCutCheck`.
///   Inside its kept cuts is that label; far from any cut in what it read is
///   the show. A weaker model never teaches the reader.
///   Pass 43: only where models of two different families agree (or the
///   ad-free download proved a stretch stitched in). Measured on his 14
///   hand-labelled episodes (19 Oct export): one model's cuts were wrong on
///   13 % of the sentences they called ads, and a head trained on them cut
///   2.5× more of the show; agreed sentences were 98 % right, and 99.9 % of
///   what every model left well alone was the show. Promos keep the lab's
///   share of the weight, so the reader's ad/show balance holds, and
///   model reads together never outweigh the lab sentences replayed.
///
/// Training is anchored to the shipped head (`λ‖θ − θ₀‖²`) and replays a
/// sample of the labelled lab episodes (`ReaderAnchor.bin`, made by
/// `tagger.py anchor` with the shipped readers), so the head can't drift from
/// what the lab measured. Every new head is checked before it is used: on
/// lab sentences it never trained on, and on his own corrections from
/// episodes it never trained on. If either gets worse, the previous head is
/// kept (rolled back). All on the CPU with Accelerate, so it also runs when
/// the iPhone is locked.
actor OnDeviceReaderLearner {
    static let shared = OnDeviceReaderLearner()

    // MARK: Settings

    static let goldWeight: Float = 5
    static let silverWeight: Float = 1
    static let silverNegativeWeight: Float = 0.5
    /// The model-test score a model needs before its reads teach the reader.
    static let teacherScore = 0.70
    /// Seconds either side of a cut he placed by hand that are the show.
    static let edgeMargin = 45.0
    /// Model reads: the show at least this far from any cut.
    static let silverClearance = 60.0
    static let maxExamples = 6_000
    static let learningRate: Float = 1e-3
    static let anchorStrength: Float = 1e-2
    static let epochs = 8
    static let batch = 64
    /// A new head may be at most this much worse on the lab's sentences.
    static let anchorTolerance: Float = 0.01
    /// Pass 43: the show at least this far from any model's cut (agreement).
    static let agreedClearance = 30.0
    /// Pass 43: the promo share of the lab sentences replayed (`ReaderAnchor`:
    /// 634 of 1,606), kept for every episode's model-read labels.
    static let promoShare: Float = 0.395
    /// Pass 43: model reads, all together, weigh at most this share of the
    /// replayed lab sentences.
    static let silverShareOfAnchor: Float = 0.5
    /// Pass 43: the most show sentences one episode's model reads teach.
    static let showPerEpisode = 300
    /// Pass 43: after a head is rolled back, the next training waits for a
    /// new correction or this much more from model reads (his 19 Oct phone:
    /// 20 trainings in four hours, every one rolled back, on the same data).
    static let growthBeforeRetry = 0.2
    /// Pass 43: model-read labels from before agreement was required.
    /// Pass 46: from before agreement meant *independent* agreement. The
    /// cuts a model's read saved have been through `ModelCutCheck`, which
    /// keeps the Reader's own stretches where the model was silent and moves
    /// model edges to the Reader's; two families' saves then "agreed" on a
    /// stretch only the Reader had found (the 23 Oct #691: Tulsa King at
    /// 0:00, Reader-only in both the Qwen3 4B and the MiniCPM5 save), and the
    /// Reader was taught its own output. Now each model votes with what it
    /// proposed itself, where the check kept it; one vote a family.
    static let silverPolicy = 47
    /// Pass 47: his corrections teach only while they still say what the
    /// episode says (`goldLabels(…current:)`). His 28 Oct phone: a 21-minute
    /// "ad" he had added and later removed from a Whiskey Ginger episode was
    /// still in the correction ledger and taught 535 sentences of the show
    /// as an ad at five times a lab sentence's weight; with every other
    /// correction an ad or a plug, the head learned to call most things
    /// promos and every training since 22 Oct was rolled back (the lab's
    /// held-out sentences 0.088 → 0.381). Now: each sentence the kind of the
    /// cut over it today; the show he left in a reviewed episode keeps the
    /// lab's promo share; one episode at most `goldEpisodeCap` sentences'
    /// weight; everything learned together at most the replayed lab
    /// sentences; and the epoch kept is the last that stays within the lab
    /// check (`fit(…check:)`), not only the eighth.
    static let goldEpisodeCap: Float = 150
    /// Pass 47: the show at least this far from any cut or correction, in a
    /// reviewed episode.
    static let goldShowClearance = 60.0

    // MARK: Storage

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "Detection", directoryHint: .isDirectory)
    }
    static var headURL: URL { folder.appending(path: "UserTaggerHead.bin") }
    static var examplesURL: URL { folder.appending(path: "ReaderExamples.bin") }
    static var statusURL: URL { folder.appending(path: "ReaderLearning.json") }
    /// Pass 46: a learned head set aside, kept in case it is wanted again.
    static var setAsideURL: URL { folder.appending(path: "UserTaggerHead-set-aside.bin") }

    // MARK: Examples

    enum Source: UInt8, Codable, Sendable { case gold = 0, silver = 1, anchor = 2 }

    struct Example: Sendable {
        var episode: String
        var show: String
        var label: Int
        var weight: Float
        var source: Source
        /// One feature vector per reader, `inputs` long each.
        var features: [[Float]]
    }

    /// What the iPhone has learned, for Settings and Diagnostics.
    struct Status: Codable, Sendable, Equatable {
        var goldExamples = 0
        var silverExamples = 0
        var episodes = 0
        var trainedAt: Date?
        var inUse = false
        /// One plain line: what the last training did.
        var lastDecision: String = ""
        var anchorLossBefore: Float?
        var anchorLossAfter: Float?
        var heldOutLossBefore: Float?
        var heldOutLossAfter: Float?
        var history: [String] = []
        /// Pass 43: what the last training was given (corrections, model-read
        /// sentences), and what a rolled-back one was given — so the same
        /// data isn't trained on again.
        var trainedGold: Int?
        var trainedSilver: Int?
        var rolledBack: Bool?
        /// Pass 43: `silverPolicy` the stored model-read labels follow.
        var silverPolicy: Int?
        /// Pass 46: the readers the stored examples' features came from
        /// (`SentenceTagger.identities()`); examples for other readers are
        /// stale and are made again from the listener's corrections and the attempt log.
        var examplesReaders: [String]?
        /// Pass 46: what each episode taught, newest first.
        var evidence: [Evidence]?
        /// Pass 46: a learned head set aside (kept on disk, not used), and why.
        var setAside: String?
        /// Pass 46: the policy and readers the listener's corrections and the attempt
        /// log were last gathered for (`rebuild`).
        var rebuiltFor: String?

        var summary: String {
            guard goldExamples + silverExamples > 0 else {
                return "Nothing yet. The reader learns from your corrections, and from model reads where two different models agree."
            }
            var parts = ["\(goldExamples.formatted()) sentences from your corrections"]
            if silverExamples > 0 { parts.append("\(silverExamples.formatted()) where two models agreed") }
            parts.append("\(episodes) episode\(episodes == 1 ? "" : "s")")
            let what = parts.joined(separator: ", ")
            return inUse ? "Learned on this iPhone from \(what)." : "Collected \(what); still using the reader as shipped."
        }
    }

    /// Pass 46: one episode's teaching, for Settings and Diagnostics: who
    /// taught it, and how many sentences of each kind.
    struct Evidence: Codable, Sendable, Equatable {
        var episode: String
        var title: String
        var show: String
        /// "your corrections", "models agreed: minicpm + qwen", "ad-free download".
        var teacher: String
        var sentences: [String: Int]
        var date: Date
    }

    private var examples: [Example] = []
    private var loaded = false
    private(set) var status = Status()
    private var pending: [String: Task<Void, Never>] = [:]
    private var training: Task<Void, Never>?

    // MARK: Teachers

    /// A correction he made on one episode (`CorrectionLedger`), as the
    /// deltas then stand. Gathered after a pause, so a run of edits on one
    /// episode is learned once.
    struct GoldRequest: Sendable {
        var episode: String
        var show: String
        var title: String = ""
        var transcriptOnDisk: Bool
        var inlineTranscript: Data?
        var deltas: [CorrectionDelta]
        /// Pass 47: the episode's cuts as they are now (not ones he marked
        /// Not an Ad), so only corrections still in force teach.
        var current: [CurrentCut]
    }

    /// Pass 47: one of an episode's saved cuts, as it stands.
    struct CurrentCut: Sendable, Equatable {
        var start: Double
        var end: Double
        var kind: String

        /// Read where the episode's other fields are (CorrectionLedger).
        static func of(_ episode: Episode) -> [CurrentCut] {
            episode.adSegments.filter { $0.userVerdict != .notAnAd }
                .map { CurrentCut(start: $0.start, end: $0.end, kind: $0.kindRaw) }
        }
    }

    func noteCorrections(_ request: GoldRequest, after delay: Duration = .seconds(20)) {
        pending[request.episode]?.cancel()
        pending[request.episode] = Task(priority: .utility) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self.learnGold(request)
        }
    }

    /// A model's checked cuts on one episode.
    struct SilverRequest: Sendable {
        var episode: String
        var show: String
        var title: String = ""
        var lines: [TimedLine]
        /// Pass 46: this model's own proposals where the cut check kept
        /// them (`independent`), never the Reader's additions.
        var cuts: [(start: Double, end: Double, kind: SegmentKind)]
        /// The stretches it read (seconds); nil: the whole episode.
        var read: [ClosedRange<Double>]?
        var modelScore: Double?
        /// Pass 43: this model's family ("qwen", "minicpm", "apple"…).
        var family: String = ""
        /// Pass 43: the newest saved cuts of the other models that read this
        /// episode (`FinderAttemptLog`), and what the ad-free download proved
        /// stitched in.
        var others: [Teacher] = []
        var inserted: [ClosedRange<Double>] = []
        /// Pass 46: every stretch anything called promotional — the Reader,
        /// any read's saved cuts. Never taught as the show.
        var claimed: [ClosedRange<Double>] = []
    }

    /// Pass 46: what a model found by itself: each cut it proposed, where the
    /// cut check kept it (inside the saved cuts), with its own kind. What the
    /// check added from the Reader or moved to the Reader's edges is not the
    /// model's.
    nonisolated static func independent(proposed: [(start: Double, end: Double, kind: SegmentKind)],
                                        kept: [(start: Double, end: Double, kind: SegmentKind)])
        -> [(start: Double, end: Double, kind: SegmentKind)] {
        var out: [(start: Double, end: Double, kind: SegmentKind)] = []
        for p in proposed {
            for k in kept {
                let a = max(p.start, k.start), b = min(p.end, k.end)
                if b - a >= 3 { out.append((a, b, p.kind)) }
            }
        }
        return out
    }

    /// Pass 43: one model's cuts on an episode, as one vote. Pass 46: its
    /// own (`independent`), not what the check saved.
    struct Teacher: Sendable {
        var family: String
        var cuts: [(start: Double, end: Double, kind: SegmentKind)]
        /// nil: the whole episode.
        var read: [ClosedRange<Double>]?
    }

    /// Pass 43: models of one family (Qwen3 4B on Core AI and Qwen3.5 4B on
    /// MLX) share their blind spots, so they are one vote.
    nonisolated static func family(of name: String) -> String {
        let lower = name.lowercased()
        for family in ["qwen", "minicpm", "gemma", "llama", "granite", "lfm", "nemotron", "nanbeige", "bonsai",
                       "phi", "smollm", "mistral", "apple"] where lower.contains(family) { return family }
        return lower
    }

    func noteModelRead(_ request: SilverRequest) {
        guard let score = request.modelScore, score >= Self.teacherScore else { return }
        Task(priority: .utility) { await self.learnSilver(request) }
    }

    /// From synchronous code (the pipeline's cut check).
    nonisolated func noteModelReadDetached(_ request: SilverRequest) {
        guard let score = request.modelScore, score >= Self.teacherScore else { return }
        Task(priority: .utility) { await self.learnSilver(request) }
    }

    // MARK: Rebuild

    /// Pass 46: the listener's corrections and the models' saved reads, gathered again
    /// once for each policy and pair of readers. His corrections made before
    /// the learner existed (24 of them, from 7 Oct) never taught it — gold is made
    /// only when a correction changes — and model-read labels from an older
    /// policy, or for other readers, are gone. One training afterwards.
    nonisolated static func rebuildKey() -> String {
        "\(silverPolicy):" + SentenceTagger.identities().joined(separator: ",")
    }

    func needsRebuild() -> Bool {
        loadIfNeeded()
        return status.rebuiltFor != Self.rebuildKey()
    }

    func rebuild(gold: [GoldRequest], silver: [SilverRequest]) async {
        loadIfNeeded()
        let key = Self.rebuildKey()
        guard status.rebuiltFor != key else { return }
        let haveGold = Set(examples.filter { $0.source == .gold }.map(\.episode))
        let haveSilver = Set(examples.filter { $0.source == .silver }.map(\.episode))
        for request in gold where !haveGold.contains(request.episode) {
            if Task.isCancelled { return }
            await learnGold(request, retrainAfter: false)
        }
        for request in silver where !haveSilver.contains(request.episode) && !haveGold.contains(request.episode) {
            if Task.isCancelled { return }
            guard let score = request.modelScore, score >= Self.teacherScore else { continue }
            await learnSilver(request, retrainAfter: false)
        }
        status.rebuiltFor = key
        refreshCounts()
        saveStatus()
        retrain()
    }

    // MARK: Reset

    func reset() {
        for task in pending.values { task.cancel() }
        pending = [:]
        training?.cancel()
        examples = []
        status = Status(lastDecision: "Reset: using the reader as shipped.")
        status.silverPolicy = Self.silverPolicy
        status.rebuiltFor = Self.rebuildKey()
        LearnedReaderHeads.current = nil
        for url in [Self.headURL, Self.examplesURL] { try? FileManager.default.removeItem(at: url) }
        saveStatus()
    }

    func currentStatus() -> Status {
        loadIfNeeded()
        return status
    }

    /// At launch: the learned heads back in use (if they still match the
    /// shipped readers).
    func restore() {
        loadIfNeeded()
    }

    // MARK: Learning

    private func learnGold(_ request: GoldRequest, retrainAfter: Bool = true) async {
        loadIfNeeded()
        let data = request.transcriptOnDisk ? TranscriptStore.read(request.episode) : request.inlineTranscript
        guard let data, let lines = try? JSONDecoder().decode([TimedLine].self, from: data), !lines.isEmpty else { return }
        let sentences = SegmentDetector.sentences(from: lines.map {
            TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? [])
        })
        let labelled = Self.goldLabels(sentences: sentences, deltas: request.deltas, current: request.current)
        await replace(episode: request.episode, show: request.show, source: .gold, sentences: sentences, labelled: labelled,
                      title: request.title, teacher: "your corrections", retrainAfter: retrainAfter)
    }

    private func learnSilver(_ request: SilverRequest, retrainAfter: Bool = true) async {
        loadIfNeeded()
        // His own settled stretches on this episode outrank a model's.
        let sentences = SegmentDetector.sentences(from: request.lines.map {
            TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? [])
        })
        let teachers = [Teacher(family: request.family, cuts: request.cuts, read: request.read)]
            + request.others.filter { !$0.family.isEmpty }
        let labelled = Self.agreementLabels(sentences: sentences, teachers: teachers, inserted: request.inserted,
                                            claimed: request.claimed)
        guard !labelled.isEmpty else { return }
        let families = Set(teachers.map(\.family)).sorted()
        let teacher = families.count >= 2 ? "models agreed: " + families.joined(separator: " + ") : "ad-free download"
        await replace(episode: request.episode, show: request.show, source: .silver, sentences: sentences, labelled: labelled,
                      title: request.title, teacher: teacher, retrainAfter: retrainAfter)
    }

    /// Sentence index → (label, weight) from his corrections.
    ///
    /// Pass 47: only corrections still in force — a current cut covers at
    /// least half of it (a Not an Ad: under a fifth) — and each sentence
    /// inside takes the kind of the current cut over it (a stretch he
    /// settled can hold an ad, a plug and a promo; the delta names only the
    /// first). Sentences of a delta no current cut covers teach nothing.
    /// Where he set the edges, what lies just outside every cut is the
    /// show; and the show far from every cut in the episode he reviewed
    /// keeps promos at `promoShare` of the episode's weight. One episode
    /// weighs at most `goldEpisodeCap` sentences at gold weight.
    static func goldLabels(sentences: [Sentence], deltas: [CorrectionDelta],
                           current: [CurrentCut]) -> [Int: (label: Int, weight: Float)] {
        func mid(_ s: Sentence) -> Double { (s.start + s.end) / 2 }
        let live = deltas.filter { inForce($0, current: current) }
        var out: [Int: (Int, Float)] = [:]
        for delta in live {
            for (i, s) in sentences.enumerated() where (delta.start...delta.end).contains(mid(s)) {
                if delta.action == "notAnAd" { out[i] = (0, goldWeight); continue }
                let m = mid(s)
                guard let over = current.first(where: { $0.start <= m && m <= $0.end }),
                      let label = labelIndex(kind: over.kind), label != 0 else { continue }
                out[i] = (label, goldWeight)
            }
            // Edges he set himself: what lies just outside is the show.
            guard ["lock", "edit", "add"].contains(delta.action) else { continue }
            for (i, s) in sentences.enumerated() where out[i] == nil {
                let m = mid(s)
                let near = (m >= delta.start - edgeMargin && m < delta.start) || (m > delta.end && m <= delta.end + edgeMargin)
                if near, !current.contains(where: { $0.start <= m && m <= $0.end }) { out[i] = (0, goldWeight * 0.4) }
            }
        }
        guard !out.isEmpty else { return [:] }
        // The show he left alone, far from every cut and correction.
        let spans = current.map { ($0.start, $0.end) } + live.map { ($0.start, $0.end) }
        let far = sentences.indices.filter { i in
            out[i] == nil && spans.allSatisfy { mid(sentences[i]) < $0.0 - goldShowClearance || mid(sentences[i]) > $0.1 + goldShowClearance }
        }
        let promos = out.values.filter { $0.0 != 0 }.reduce(Float(0)) { $0 + $1.1 }
        let show = out.values.filter { $0.0 == 0 }.reduce(Float(0)) { $0 + $1.1 }
        let wanted = promos * (1 - promoShare) / promoShare - show
        if !far.isEmpty, wanted > 0 {
            let keep = min(far.count, showPerEpisode)
            let step = Double(far.count) / Double(keep)
            let each = min(goldWeight * 0.4, wanted / Float(keep))
            for k in 0..<keep { out[far[Int(Double(k) * step)]] = (0, each) }
        }
        let total = out.values.reduce(Float(0)) { $0 + $1.1 }
        let cap = goldEpisodeCap * goldWeight
        if total > cap {
            let scale = cap / total
            for (i, entry) in out { out[i] = (entry.0, entry.1 * scale) }
        }
        return out
    }

    /// Pass 47: a correction still says what the episode says now.
    static func inForce(_ delta: CorrectionDelta, current: [CurrentCut]) -> Bool {
        let length = max(delta.end - delta.start, 1e-3)
        let covered = current.reduce(0.0) { $0 + max(0, min(delta.end, $1.end) - max(delta.start, $1.start)) }
        return delta.action == "notAnAd" ? covered < 0.2 * length : covered >= 0.5 * length
    }

    /// Sentence index → (label, weight) from a model's checked cuts.
    static func silverLabels(sentences: [Sentence], cuts: [(start: Double, end: Double, kind: SegmentKind)],
                             read: [ClosedRange<Double>]?) -> [Int: (label: Int, weight: Float)] {
        var out: [Int: (Int, Float)] = [:]
        var negatives: [Int] = []
        for (i, s) in sentences.enumerated() {
            let m = (s.start + s.end) / 2
            if let cut = cuts.first(where: { $0.start <= m && m <= $0.end }), let label = labelIndex(kind: cut.kind.rawValue) {
                out[i] = (label, silverWeight)
                continue
            }
            let wasRead = read.map { $0.contains { $0.contains(m) } } ?? true
            let clear = cuts.allSatisfy { m < $0.start - silverClearance || m > $0.end + silverClearance }
            if wasRead, clear { negatives.append(i) }
        }
        // At most three of the show for every sentence of a cut (and 300 in all).
        let positives = out.count
        let keep = min(negatives.count, max(60, 3 * positives), 300)
        if keep > 0 {
            let step = Double(negatives.count) / Double(keep)
            for k in 0..<keep { out[negatives[Int(Double(k) * step)]] = (0, silverNegativeWeight) }
        }
        return out
    }

    /// Pass 43: sentence index → (label, weight) where independent models
    /// agree. A promo of kind k: cut by models of at least two families,
    /// most of them saying k — or stitched in, as the ad-free download
    /// showed. The show: read by a model, and every model's cuts at least
    /// `agreedClearance` away. Everything else teaches nothing.
    static func agreementLabels(sentences: [Sentence], teachers: [Teacher],
                                inserted: [ClosedRange<Double>],
                                claimed: [ClosedRange<Double>] = []) -> [Int: (label: Int, weight: Float)] {
        guard Set(teachers.map(\.family)).count >= 2 || !inserted.isEmpty else { return [:] }
        var out: [Int: (Int, Float)] = [:]
        var show: [Int] = []
        for (i, s) in sentences.enumerated() {
            let m = (s.start + s.end) / 2
            if inserted.contains(where: { $0.contains(m) }) {
                out[i] = (1, 2 * silverWeight)
                continue
            }
            // Pass 46: one vote a family (Core AI Qwen3 4B and MLX Qwen3.5 4B
            // are one), the first of it in `teachers` (this read, then the
            // newest others).
            var votes: [Int: Int] = [:]
            var families = Set<String>()
            for teacher in teachers where !families.contains(teacher.family) {
                guard let cut = teacher.cuts.first(where: { $0.start <= m && m <= $0.end }),
                      let label = labelIndex(kind: cut.kind.rawValue), label != 0 else { continue }
                votes[label, default: 0] += 1
                families.insert(teacher.family)
            }
            if families.count >= 2 {
                let total = votes.values.reduce(0, +)
                if let top = votes.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }), top.value * 2 > total {
                    out[i] = (top.key, silverWeight * (1 + 0.5 * Float(families.count - 2)))
                }
                continue
            }
            guard votes.isEmpty,
                  claimed.allSatisfy({ m < $0.lowerBound - agreedClearance || m > $0.upperBound + agreedClearance }),
                  teachers.contains(where: { $0.read.map { $0.contains { $0.contains(m) } } ?? true }),
                  teachers.allSatisfy({ $0.cuts.allSatisfy { m < $0.start - agreedClearance || m > $0.end + agreedClearance } })
            else { continue }
            show.append(i)
        }
        guard !show.isEmpty else { return out }
        // Evenly through the episode, at most `showPerEpisode`; together the
        // show keeps 1 − promoShare of the episode's weight.
        let keep = min(show.count, showPerEpisode)
        let step = Double(show.count) / Double(keep)
        let promos = out.values.reduce(Float(0)) { $0 + $1.1 }
        let total = promos > 0 ? promos * (1 - promoShare) / promoShare : Float(keep) * silverNegativeWeight
        for k in 0..<keep { out[show[Int(Double(k) * step)]] = (0, total / Float(keep)) }
        return out
    }

    /// The reader's label index for a segment kind name.
    static func labelIndex(kind: String) -> Int? {
        switch kind {
        case "show", "content": return 0
        case "ad": return 1
        case "selfPromo": return 2
        case "crossPromo": return 3
        case "intro": return 4
        case "outro", "credits": return 5
        default: return nil
        }
    }

    private func replace(episode: String, show: String, source: Source, sentences: [Sentence],
                         labelled: [Int: (label: Int, weight: Float)], title: String = "", teacher: String = "",
                         retrainAfter: Bool = true) async {
        let readers = SentenceTagger.ensemble
        guard !readers.isEmpty else { return }
        // The forward pass only over the windows that hold a labelled sentence.
        let needed = Set(labelled.keys)
        let lease: HeavyWorkCoordinator.Lease
        do {
            lease = try await HeavyWorkCoordinator.shared.acquire(owner: "Reader learning", priority: .maintenance)
        } catch { return }
        let features = readers.map { $0.features(sentences, only: needed) }
        await HeavyWorkCoordinator.shared.release(lease)
        var fresh: [Example] = []
        for (i, entry) in labelled.sorted(by: { $0.key < $1.key }) {
            let vectors = features.map { $0[i] }
            guard vectors.allSatisfy({ !$0.isEmpty }) else { continue }
            fresh.append(Example(episode: episode, show: show, label: entry.label, weight: entry.weight,
                                 source: source, features: vectors))
        }
        examples.removeAll { $0.episode == episode && $0.source == source }
        // Where he has spoken on an episode, a model's labels for it go.
        if source == .gold { examples.removeAll { $0.episode == episode && $0.source == .silver } }
        if source == .silver, examples.contains(where: { $0.episode == episode && $0.source == .gold }) { return }
        examples += fresh
        trimToCap()
        status.examplesReaders = readers.map(\.identity)
        // What it taught, by kind, for Settings and Diagnostics.
        let names = ["show", "ad", "selfPromo", "crossPromo", "intro", "outro"]
        var counts: [String: Int] = [:]
        for e in fresh { counts[names.indices.contains(e.label) ? names[e.label] : "\(e.label)", default: 0] += 1 }
        var ledger = (status.evidence ?? []).filter { !($0.episode == episode && ($0.teacher == "your corrections") == (source == .gold)) }
        if !fresh.isEmpty {
            ledger.insert(Evidence(episode: episode, title: title, show: show, teacher: teacher.isEmpty ? (source == .gold ? "your corrections" : "models agreed") : teacher,
                                   sentences: counts, date: .now), at: 0)
        }
        status.evidence = Array(ledger.prefix(60))
        refreshCounts()
        saveExamples()
        saveStatus()
        if retrainAfter { retrain() }
    }

    private func trimToCap() {
        guard examples.count > Self.maxExamples else { return }
        // Model reads go first, oldest first; his corrections last.
        let overflow = examples.count - Self.maxExamples
        var removed = 0
        examples.removeAll { example in
            guard removed < overflow, example.source == .silver else { return false }
            removed += 1
            return true
        }
        if examples.count > Self.maxExamples { examples.removeFirst(examples.count - Self.maxExamples) }
    }

    /// Pass 43: only on data it hasn't trained on (his 19 Oct phone retrained
    /// 20 times in four hours and rolled every one back), and after a rollback
    /// only with a new correction or 20 % more from model reads; a run of
    /// reads is gathered for 30 s and trained on once.
    private func retrain() {
        guard Self.shouldTrain(status: status, gold: examples.filter { $0.source == .gold }.count,
                               silver: examples.filter { $0.source == .silver }.count) else { return }
        training?.cancel()
        training = Task(priority: .utility) {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            await self.train()
        }
    }

    nonisolated static func shouldTrain(status: Status, gold: Int, silver: Int) -> Bool {
        guard gold + silver > 0 else { return false }
        guard let trainedGold = status.trainedGold, let trainedSilver = status.trainedSilver else { return true }
        if gold == trainedGold && silver == trainedSilver { return false }
        guard status.rolledBack == true, gold == trainedGold else { return true }
        return Double(silver) >= Double(trainedSilver) * (1 + growthBeforeRetry) + 1
    }

    // MARK: Training

    /// Splits: anchor sentences half replayed, half held out; his gold
    /// examples from one episode in five held out (when he has corrected at
    /// least three episodes).
    private func train() async {
        let readers = SentenceTagger.ensemble
        guard !readers.isEmpty, !examples.isEmpty else { return }
        let anchor = ReaderAnchor.load(readers: readers)
        let goldEpisodes = Set(examples.filter { $0.source == .gold }.map(\.episode))
        let heldOutEpisodes: Set<String> = goldEpisodes.count >= 3
            ? Set(goldEpisodes.filter { Self.stableHash($0) % 5 == 0 }) : []
        // Pass 43: one model-read episode in five checks the new head too.
        let silverEpisodes = Set(examples.filter { $0.source == .silver }.map(\.episode))
        let heldOutSilver: Set<String> = silverEpisodes.count >= 5
            ? Set(silverEpisodes.filter { Self.stableHash($0) % 5 == 0 }) : []
        var train = examples.filter { !heldOutEpisodes.contains($0.episode) && !heldOutSilver.contains($0.episode) }
        let heldOut = examples.filter { heldOutEpisodes.contains($0.episode) && $0.source == .gold }
        let heldOutAgreed = examples.filter { heldOutSilver.contains($0.episode) && $0.source == .silver }
        let anchorTrain = anchor.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        let anchorCheck = anchor.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
        // Pass 43: model reads never outweigh the lab sentences replayed.
        let silverTotal = train.filter { $0.source == .silver }.reduce(Float(0)) { $0 + $1.weight }
        let anchorTotal = anchorTrain.reduce(Float(0)) { $0 + $1.weight }
        if silverTotal > 0, anchorTotal > 0, silverTotal > anchorTotal * Self.silverShareOfAnchor {
            let scale = anchorTotal * Self.silverShareOfAnchor / silverTotal
            for i in train.indices where train[i].source == .silver { train[i].weight *= scale }
        }
        // Pass 47: everything learned together never outweighs the lab
        // sentences replayed (his corrections alone were ten times them).
        let learnedTotal = train.reduce(Float(0)) { $0 + $1.weight }
        if learnedTotal > 0, anchorTotal > 0, learnedTotal > anchorTotal {
            let scale = anchorTotal / learnedTotal
            for i in train.indices { train[i].weight *= scale }
        }

        var heads: [(base: String, head: ReaderHead)] = []
        var before: (anchor: Float, held: Float?) = (0, nil)
        var after: (anchor: Float, held: Float?) = (0, nil)
        var agreed: (before: Float, after: Float)? = nil
        let current = LearnedReaderHeads.current
        var noEpoch = false
        for (r, reader) in readers.enumerated() {
            let base = reader.baseHead
            let start = current?.head(for: r, base: reader.identity) ?? base
            let data = Self.batchable(train + anchorTrain, reader: r)
            let anchorData = Self.batchable(anchorCheck, reader: r)
            // Pass 47: the last epoch still within the lab check, not only
            // the eighth (none within: the start, which then rolls back) —
            // and within it for the promos and for the show separately. On
            // his 59 labelled episodes (lab, two folds) a head that kept the
            // overall loss in bounds had traded one for the other: one reader
            // better on promos and worse on the show, the other the reverse,
            // and twice the ads heard through the app's detector.
            let promoCheck = Self.batchable(anchorCheck.filter { $0.label != 0 }, reader: r)
            let showCheck = Self.batchable(anchorCheck.filter { $0.label == 0 }, reader: r)
            let limits = (all: Self.loss(start, anchorData) * (1 + Self.anchorTolerance) + 1e-4,
                          promo: Self.loss(start, promoCheck) * (1 + Self.anchorTolerance) + 1e-4,
                          show: Self.loss(start, showCheck) * (1 + Self.anchorTolerance) + 1e-4)
            let withinLab: (ReaderHead) -> Bool = { head in
                Self.loss(head, anchorData) <= limits.all
                    && (promoCheck.isEmpty || Self.loss(head, promoCheck) <= limits.promo)
                    && (showCheck.isEmpty || Self.loss(head, showCheck) <= limits.show)
            }
            var learned = Self.fit(start: start, base: base, data: data, keep: anchorData.isEmpty ? nil : withinLab)
            if !anchorData.isEmpty, !withinLab(learned) { learned = start }
            if learned == start { noEpoch = true }
            let heldData = Self.batchable(heldOut, reader: r)
            before.anchor += Self.loss(start, anchorData) / Float(readers.count)
            after.anchor += Self.loss(learned, anchorData) / Float(readers.count)
            if !heldData.isEmpty {
                before.held = (before.held ?? 0) + Self.loss(start, heldData) / Float(readers.count)
                after.held = (after.held ?? 0) + Self.loss(learned, heldData) / Float(readers.count)
            }
            let agreedData = Self.batchable(heldOutAgreed, reader: r)
            if !agreedData.isEmpty {
                let was = agreed ?? (0, 0)
                agreed = (was.before + Self.loss(start, agreedData) / Float(readers.count),
                          was.after + Self.loss(learned, agreedData) / Float(readers.count))
            }
            heads.append((reader.identity, learned))
            if Task.isCancelled { return }
        }
        let anchorOK = !noEpoch && (anchorCheck.isEmpty || after.anchor <= before.anchor * (1 + Self.anchorTolerance) + 1e-4)
        let heldOK = after.held.map { $0 <= (before.held ?? .infinity) + 1e-4 } ?? true
        let agreedOK = agreed.map { $0.after <= $0.before + 1e-4 } ?? true
        var next = status
        next.trainedGold = examples.filter { $0.source == .gold }.count
        next.trainedSilver = examples.filter { $0.source == .silver }.count
        next.rolledBack = !(anchorOK && heldOK && agreedOK)
        next.anchorLossBefore = anchorCheck.isEmpty ? nil : before.anchor
        next.anchorLossAfter = anchorCheck.isEmpty ? nil : after.anchor
        next.heldOutLossBefore = before.held
        next.heldOutLossAfter = after.held
        next.trainedAt = .now
        let when = Date.now.formatted(date: .abbreviated, time: .shortened)
        // Pass 46: what it learned from, in the same line.
        let goldCount = goldEpisodes.count
        let silverCount = silverEpisodes.count
        var from: [String] = []
        if goldCount > 0 { from.append("your corrections on \(goldCount) episode\(goldCount == 1 ? "" : "s")") }
        if silverCount > 0 { from.append("models agreeing on \(silverCount) episode\(silverCount == 1 ? "" : "s")") }
        let learnedFrom = from.isEmpty ? "" : " From " + from.joined(separator: " and ") + "."
        if anchorOK && heldOK && agreedOK {
            LearnedReaderHeads.current = LearnedReaderHeads.Heads(heads: heads)
            saveHeads(heads)
            next.inUse = true
            next.lastDecision = "Kept the new reader head (lab sentences \(Self.f(before.anchor)) → \(Self.f(after.anchor))"
                + (after.held.map { ", your held-out corrections \(Self.f(before.held ?? 0)) → \(Self.f($0))" } ?? "")
                + (agreed.map { ", held-out model agreement \(Self.f($0.before)) → \(Self.f($0.after))" } ?? "") + ")."
                + learnedFrom
            next.setAside = nil
        } else {
            next.lastDecision = "Rolled back: the new head was worse on "
                + (noEpoch ? "the lab's ads or the lab's show after every round of learning" : !anchorOK ? "the lab's sentences"
                   : !heldOK ? "your held-out corrections" : "episodes where models agreed that it didn't learn from")
                + ", so the previous one stays. It trains again after a new correction or more model reads." + learnedFrom
        }
        next.history = Array(([when + " · " + next.lastDecision] + next.history).prefix(20))
        status = next
        refreshCounts()
        saveStatus()
    }

    private static func f(_ x: Float) -> String { String(format: "%.3f", x) }

    static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % 1_000_003)
    }

    /// Features, one-hot targets and weights for one reader, laid out flat.
    struct Batchable {
        var x: [Float]
        var labels: [Int]
        var weights: [Float]
        var inputs: Int
        var count: Int { labels.count }
        var isEmpty: Bool { labels.isEmpty }
    }

    static func batchable(_ examples: [Example], reader: Int) -> Batchable {
        let usable = examples.filter { reader < $0.features.count }
        let inputs = usable.first?.features[reader].count ?? 0
        var x: [Float] = []
        x.reserveCapacity(usable.count * inputs)
        for e in usable { x += e.features[reader] }
        return Batchable(x: x, labels: usable.map(\.label), weights: usable.map(\.weight), inputs: inputs)
    }

    /// Weighted cross-entropy per weight.
    static func loss(_ head: ReaderHead, _ data: Batchable) -> Float {
        guard !data.isEmpty else { return 0 }
        let logits = head.logits(data.x, rows: data.count).logits
        var total: Float = 0, weight: Float = 0
        for i in 0..<data.count {
            let row = Array(logits[(i * head.outputs)..<((i + 1) * head.outputs)])
            let top = row.max() ?? 0
            let sum = row.reduce(0) { $0 + exp($1 - top) }
            total += data.weights[i] * (log(sum) + top - row[data.labels[i]])
            weight += data.weights[i]
        }
        return total / max(weight, 1e-6)
    }

    /// AdamW from `start`, pulled toward `base` (λ‖θ − θ₀‖²), mini-batches.
    /// Pass 47: with `keep`, the head returned is the last one after an
    /// epoch that `keep` accepts (the start if none does).
    static func fit(start: ReaderHead, base: ReaderHead, data: Batchable, epochs: Int = epochs,
                    learningRate: Float = learningRate, anchor: Float = anchorStrength, seed: UInt64 = 7,
                    keep: ((ReaderHead) -> Bool)? = nil) -> ReaderHead {
        guard !data.isEmpty else { return start }
        var head = start
        var kept = start
        var optimizer = Adam(sizes: [head.midWeight.count, head.midBias.count, head.outWeight.count, head.outBias.count])
        var order = Array(0..<data.count)
        var rng = SplitMix(seed: seed)
        for _ in 0..<epochs {
            order.shuffle(using: &rng)
            var i = 0
            while i < order.count {
                let pick = Array(order[i..<min(order.count, i + batch)])
                i += batch
                let g = gradients(head, base: base, data: data, rows: pick, anchor: anchor)
                optimizer.step(&head.midWeight, g.midWeight, slot: 0, rate: learningRate)
                optimizer.step(&head.midBias, g.midBias, slot: 1, rate: learningRate)
                optimizer.step(&head.outWeight, g.outWeight, slot: 2, rate: learningRate)
                optimizer.step(&head.outBias, g.outBias, slot: 3, rate: learningRate)
            }
            if let keep, keep(head) { kept = head }
        }
        return keep == nil ? head : kept
    }

    struct Gradients { var midWeight: [Float]; var midBias: [Float]; var outWeight: [Float]; var outBias: [Float] }

    /// Back-propagation through GELU and the two layers, with Accelerate.
    static func gradients(_ head: ReaderHead, base: ReaderHead, data: Batchable, rows: [Int], anchor: Float) -> Gradients {
        let n = rows.count, inDim = head.inputs, midDim = head.mid, outDim = head.outputs
        var x = [Float](repeating: 0, count: n * inDim)
        for (k, r) in rows.enumerated() {
            for j in 0..<inDim { x[k * inDim + j] = data.x[r * inDim + j] }
        }
        let forward = head.logits(x, rows: n)
        let total = rows.reduce(Float(0)) { $0 + data.weights[$1] }
        // dL/dlogits = w (softmax − onehot) / Σw
        var dLogits = [Float](repeating: 0, count: n * outDim)
        for k in 0..<n {
            let row = Array(forward.logits[(k * outDim)..<((k + 1) * outDim)])
            let top = row.max() ?? 0
            let e = row.map { exp($0 - top) }
            let s = e.reduce(0, +)
            let w = data.weights[rows[k]] / max(total, 1e-6)
            for c in 0..<outDim { dLogits[k * outDim + c] = w * (e[c] / s - (c == data.labels[rows[k]] ? 1 : 0)) }
        }
        // out layer: dW2 = hᵀ·dL (mid × out), db2 = Σ dL
        var dW2 = [Float](repeating: 0, count: midDim * outDim)
        vDSP_mmul(transpose(forward.hidden, rows: n, cols: midDim), 1, dLogits, 1, &dW2, 1,
                  vDSP_Length(midDim), vDSP_Length(outDim), vDSP_Length(n))
        var db2 = [Float](repeating: 0, count: outDim)
        for k in 0..<n { for c in 0..<outDim { db2[c] += dLogits[k * outDim + c] } }
        // dh = dL·W2ᵀ (n × mid), through GELU
        var dHidden = [Float](repeating: 0, count: n * midDim)
        vDSP_mmul(dLogits, 1, transpose(head.outWeight, rows: midDim, cols: outDim), 1, &dHidden, 1,
                  vDSP_Length(n), vDSP_Length(midDim), vDSP_Length(outDim))
        for i in 0..<(n * midDim) { dHidden[i] *= geluDerivative(forward.preActivation[i]) }
        // mid layer: dW1 = xᵀ·dh (in × mid), db1 = Σ dh
        var dW1 = [Float](repeating: 0, count: inDim * midDim)
        vDSP_mmul(transpose(x, rows: n, cols: inDim), 1, dHidden, 1, &dW1, 1,
                  vDSP_Length(inDim), vDSP_Length(midDim), vDSP_Length(n))
        var db1 = [Float](repeating: 0, count: midDim)
        for k in 0..<n { for j in 0..<midDim { db1[j] += dHidden[k * midDim + j] } }
        // The anchor: λ(θ − θ₀).
        func pull(_ g: inout [Float], _ now: [Float], _ start: [Float]) {
            for i in g.indices { g[i] += anchor * (now[i] - start[i]) }
        }
        pull(&dW1, head.midWeight, base.midWeight)
        pull(&db1, head.midBias, base.midBias)
        pull(&dW2, head.outWeight, base.outWeight)
        pull(&db2, head.outBias, base.outBias)
        return Gradients(midWeight: dW1, midBias: db1, outWeight: dW2, outBias: db2)
    }

    static func transpose(_ m: [Float], rows: Int, cols: Int) -> [Float] {
        var out = [Float](repeating: 0, count: rows * cols)
        vDSP_mtrans(m, 1, &out, 1, vDSP_Length(cols), vDSP_Length(rows))
        return out
    }

    /// d/dx of x·Φ(x) (the erf GELU the reader uses).
    static func geluDerivative(_ x: Float) -> Float {
        let cdf: Float = 0.5 * (1 + erf(x / Float(2).squareRoot()))
        let pdf = exp(-0.5 * x * x) / (2 * Float.pi).squareRoot()
        return cdf + x * pdf
    }

    struct Adam {
        var m: [[Float]]
        var v: [[Float]]
        var t: [Int]
        init(sizes: [Int]) {
            m = sizes.map { [Float](repeating: 0, count: $0) }
            v = sizes.map { [Float](repeating: 0, count: $0) }
            t = sizes.map { _ in 0 }
        }
        mutating func step(_ p: inout [Float], _ g: [Float], slot: Int, rate: Float,
                           beta1: Float = 0.9, beta2: Float = 0.999, eps: Float = 1e-8) {
            t[slot] += 1
            let c1 = 1 - pow(beta1, Float(t[slot])), c2 = 1 - pow(beta2, Float(t[slot]))
            for i in p.indices {
                m[slot][i] = beta1 * m[slot][i] + (1 - beta1) * g[i]
                v[slot][i] = beta2 * v[slot][i] + (1 - beta2) * g[i] * g[i]
                p[i] -= rate * (m[slot][i] / c1) / ((v[slot][i] / c2).squareRoot() + eps)
            }
        }
    }

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
    }

    // MARK: Files

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: Self.statusURL), let saved = try? JSONDecoder().decode(Status.self, from: data) {
            status = saved
        }
        examples = Self.readExamples(Self.examplesURL)
        // Pass 43: labels one model gave alone are wrong too often to teach
        // (13 % of its ad sentences on his labelled episodes); they go. What
        // was learned and checked from them stays in use.
        if status.silverPolicy != Self.silverPolicy {
            let before = examples.count
            examples.removeAll { $0.source == .silver }
            // Pass 47: his examples are made again from the corrections still
            // in force (`rebuild` makes only what is missing).
            if (status.silverPolicy ?? 0) < 47 { examples.removeAll { $0.source == .gold } }
            // Pass 46: a head trained only on model reads from before
            // independent agreement learned partly from the Reader's own
            // output. It is set aside — kept on disk, not used — and the
            // reader is as shipped until a head from checked evidence passes.
            if (status.silverPolicy ?? 0) < 46, examples.allSatisfy({ $0.source != .gold }),
               FileManager.default.fileExists(atPath: Self.headURL.path) {
                try? FileManager.default.removeItem(at: Self.setAsideURL)
                try? FileManager.default.moveItem(at: Self.headURL, to: Self.setAsideURL)
                status.setAside = "The head learned before \(Date.now.formatted(date: .abbreviated, time: .omitted)) came only from model reads that could repeat the reader's own finds; it is kept but not used."
                status.history = Array(([Date.now.formatted(date: .abbreviated, time: .shortened)
                    + " · Set aside the learned head: it learned from model reads that could repeat the reader's own finds. Using the reader as shipped until checked evidence teaches it."] + status.history).prefix(20))
                status.lastDecision = "Using the reader as shipped: the earlier learned head is set aside."
                status.evidence = (status.evidence ?? []).filter { $0.teacher == "your corrections" }
            }
            status.silverPolicy = Self.silverPolicy
            status.trainedGold = nil
            status.trainedSilver = nil
            status.rolledBack = nil
            if examples.count != before { saveExamples() }
            saveStatus()
        }
        let identities = SentenceTagger.identities()
        // Pass 46: examples carry features from the readers that made them;
        // for other readers they are stale (Pass 44 replaced both readers and
        // nothing checked). They go, and are made again by `rebuild`.
        if let made = status.examplesReaders, made != identities, !examples.isEmpty {
            examples.removeAll()
            status.evidence = []
            status.trainedGold = nil
            status.trainedSilver = nil
            saveExamples()
            saveStatus()
        }
        if let heads = Self.readHeads(Self.headURL),
           heads.count == identities.count,
           zip(heads, identities).allSatisfy({ $0.base == $1 }) {
            LearnedReaderHeads.current = LearnedReaderHeads.Heads(heads: heads)
            status.inUse = true
        } else {
            // Learned for other readers (a new build's): not used.
            if FileManager.default.fileExists(atPath: Self.headURL.path) {
                status.lastDecision = "This version's reader is new; what was learned for the old one isn't used."
            }
            status.inUse = false
            LearnedReaderHeads.current = nil
        }
        refreshCounts()
    }

    private func refreshCounts() {
        status.goldExamples = examples.filter { $0.source == .gold }.count
        status.silverExamples = examples.filter { $0.source == .silver }.count
        status.episodes = Set(examples.map(\.episode)).count
    }

    private func saveStatus() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(status) { try? data.write(to: Self.statusURL, options: .atomic) }
    }

    private func saveHeads(_ heads: [(base: String, head: ReaderHead)]) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? Self.encodeHeads(heads).write(to: Self.headURL, options: .atomic)
    }

    private func saveExamples() {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? Self.encodeExamples(examples).write(to: Self.examplesURL, options: .atomic)
    }

    /// "PSRH", version 1, JSON header length, header, then each head's
    /// float32 tensors (mid weight, mid bias, out weight, out bias).
    static func encodeHeads(_ heads: [(base: String, head: ReaderHead)]) -> Data {
        struct Entry: Codable { var base: String; var inputs: Int; var mid: Int; var outputs: Int }
        let header = (try? JSONEncoder().encode(heads.map { Entry(base: $0.base, inputs: $0.head.inputs, mid: $0.head.mid, outputs: $0.head.outputs) })) ?? Data()
        var data = Data("PSRH".utf8)
        data += withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) }
        data += withUnsafeBytes(of: UInt32(header.count).littleEndian) { Data($0) }
        data += header
        for (_, head) in heads {
            for tensor in [head.midWeight, head.midBias, head.outWeight, head.outBias] {
                data += tensor.withUnsafeBufferPointer { Data(buffer: $0) }
            }
        }
        return data
    }

    static func readHeads(_ url: URL) -> [(base: String, head: ReaderHead)]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decodeHeads(data)
    }

    static func decodeHeads(_ data: Data) -> [(base: String, head: ReaderHead)]? {
        struct Entry: Codable { var base: String; var inputs: Int; var mid: Int; var outputs: Int }
        guard data.count > 12, data.prefix(4) == Data("PSRH".utf8) else { return nil }
        let length = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard data.count >= 12 + length,
              let entries = try? JSONDecoder().decode([Entry].self, from: data.subdata(in: 12..<(12 + length))) else { return nil }
        var offset = 12 + length
        func floats(_ count: Int) -> [Float]? {
            let bytes = count * 4
            guard offset + bytes <= data.count else { return nil }
            let out = data.subdata(in: offset..<(offset + bytes)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            offset += bytes
            return out
        }
        var heads: [(base: String, head: ReaderHead)] = []
        for e in entries {
            guard let w1 = floats(e.inputs * e.mid), let b1 = floats(e.mid),
                  let w2 = floats(e.mid * e.outputs), let b2 = floats(e.outputs) else { return nil }
            heads.append((e.base, ReaderHead(inputs: e.inputs, mid: e.mid, outputs: e.outputs,
                                             midWeight: w1, midBias: b1, outWeight: w2, outBias: b2)))
        }
        return heads
    }

    /// "PSRX", version 1, JSON header (one entry per example), then every
    /// example's features as float16.
    static func encodeExamples(_ examples: [Example]) -> Data {
        struct Entry: Codable { var e: String; var s: String; var l: Int; var w: Float; var src: UInt8; var dims: [Int] }
        let header = (try? JSONEncoder().encode(examples.map {
            Entry(e: $0.episode, s: $0.show, l: $0.label, w: $0.weight, src: $0.source.rawValue, dims: $0.features.map(\.count))
        })) ?? Data()
        var data = Data("PSRX".utf8)
        data += withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) }
        data += withUnsafeBytes(of: UInt32(header.count).littleEndian) { Data($0) }
        data += header
        for e in examples {
            for f in e.features {
                let half = f.map { Float16($0) }
                data += half.withUnsafeBufferPointer { Data(buffer: $0) }
            }
        }
        return data
    }

    static func readExamples(_ url: URL) -> [Example] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decodeExamples(data)
    }

    static func decodeExamples(_ data: Data) -> [Example] {
        struct Entry: Codable { var e: String; var s: String; var l: Int; var w: Float; var src: UInt8; var dims: [Int] }
        guard data.count > 12, data.prefix(4) == Data("PSRX".utf8) else { return [] }
        let length = Int(data.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard data.count >= 12 + length,
              let entries = try? JSONDecoder().decode([Entry].self, from: data.subdata(in: 12..<(12 + length))) else { return [] }
        var offset = 12 + length
        var out: [Example] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            var features: [[Float]] = []
            for count in entry.dims {
                let bytes = count * 2
                guard offset + bytes <= data.count else { return out }
                let half = data.subdata(in: offset..<(offset + bytes)).withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
                features.append(half.map(Float.init))
                offset += bytes
            }
            out.append(Example(episode: entry.e, show: entry.s, label: entry.l, weight: entry.w,
                               source: Source(rawValue: entry.src) ?? .gold, features: features))
        }
        return out
    }
}

/// Pass 38: sentences from the lab's labelled episodes as the shipped
/// readers see them (`tagger.py anchor`), replayed and held out by the
/// on-device learner so a learned head stays close to what the lab measured.
/// Same file format as the learner's examples. Used only when it was made
/// with the readers this build ships (the header names their identities).
enum ReaderAnchor {
    struct Stamp: Codable { var readers: [String] }

    static func load(readers: [SentenceTagger]) -> [OnDeviceReaderLearner.Example] {
        guard let url = Bundle.main.url(forResource: "ReaderAnchor", withExtension: "bin"),
              let stampURL = Bundle.main.url(forResource: "ReaderAnchor", withExtension: "json"),
              let stamp = try? JSONDecoder().decode(Stamp.self, from: Data(contentsOf: stampURL)),
              stamp.readers == readers.map(\.identity),
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return [] }
        let examples = OnDeviceReaderLearner.decodeExamples(data)
        let inputs = readers.map { $0.config.hidden + $0.config.nfeat }
        return examples.filter { $0.features.count == readers.count && zip($0.features, inputs).allSatisfy { $0.count == $1 } }
            .map { var e = $0; e.source = .anchor; return e }
    }
}
