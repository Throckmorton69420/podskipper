import XCTest
@testable import PodSkipper

/// Pass 38: the reader's on-device learner (`OnDeviceReaderLearner`).
final class Pass38LearnerTests: XCTestCase {
    typealias Learner = OnDeviceReaderLearner

    private func randomHead(inputs: Int = 7, mid: Int = 5, outputs: Int = 6, seed: UInt64 = 3) -> ReaderHead {
        var rng = Learner.SplitMix(seed: seed)
        func values(_ n: Int, scale: Float) -> [Float] {
            (0..<n).map { _ in (Float(rng.next() % 2_000) / 1_000 - 1) * scale }
        }
        return ReaderHead(inputs: inputs, mid: mid, outputs: outputs,
                          midWeight: values(inputs * mid, scale: 0.6), midBias: values(mid, scale: 0.2),
                          outWeight: values(mid * outputs, scale: 0.6), outBias: values(outputs, scale: 0.2))
    }

    private func data(_ rows: Int, inputs: Int = 7, seed: UInt64 = 11) -> Learner.Batchable {
        var rng = Learner.SplitMix(seed: seed)
        let x = (0..<(rows * inputs)).map { _ in Float(rng.next() % 2_000) / 1_000 - 1 }
        let labels = (0..<rows).map { _ in Int(rng.next() % 6) }
        let weights = (0..<rows).map { _ in Float(1 + rng.next() % 5) }
        return Learner.Batchable(x: x, labels: labels, weights: weights, inputs: inputs)
    }

    /// The loss the gradients are of: weighted CE + λ/2 ‖θ − θ₀‖².
    private func objective(_ head: ReaderHead, base: ReaderHead, data: Learner.Batchable, anchor: Float) -> Double {
        var l = Double(Learner.loss(head, data))
        for (a, b) in [(head.midWeight, base.midWeight), (head.midBias, base.midBias),
                       (head.outWeight, base.outWeight), (head.outBias, base.outBias)] {
            l += Double(anchor) / 2 * zip(a, b).reduce(0) { $0 + Double(($1.0 - $1.1) * ($1.0 - $1.1)) }
        }
        return l
    }

    func testGradientsMatchFiniteDifferences() {
        let base = randomHead(seed: 5)
        var head = randomHead(seed: 9)
        let batch = data(12)
        let anchor: Float = 0.3
        let g = Learner.gradients(head, base: base, data: batch, rows: Array(0..<12), anchor: anchor)
        let eps: Float = 1e-3
        func check(_ path: WritableKeyPath<ReaderHead, [Float]>, _ analytic: [Float], name: String) {
            for i in stride(from: 0, to: analytic.count, by: max(1, analytic.count / 7)) {
                let saved = head[keyPath: path][i]
                head[keyPath: path][i] = saved + eps
                let up = objective(head, base: base, data: batch, anchor: anchor)
                head[keyPath: path][i] = saved - eps
                let down = objective(head, base: base, data: batch, anchor: anchor)
                head[keyPath: path][i] = saved
                let numeric = (up - down) / Double(2 * eps)
                XCTAssertEqual(Double(analytic[i]), numeric, accuracy: 2e-3 + 2e-2 * abs(numeric), "\(name)[\(i)]")
            }
        }
        check(\.midWeight, g.midWeight, name: "midWeight")
        check(\.midBias, g.midBias, name: "midBias")
        check(\.outWeight, g.outWeight, name: "outWeight")
        check(\.outBias, g.outBias, name: "outBias")
    }

    func testTrainingLearnsAndTheAnchorHoldsItNearTheShippedHead() {
        // Labels a fixed rule of the inputs: learnable.
        let base = randomHead(seed: 21)
        var batch = data(240, seed: 4)
        for r in 0..<batch.count { batch.labels[r] = batch.x[r * 7] > 0 ? 1 : 0 }
        let before = Learner.loss(base, batch)
        let learned = Learner.fit(start: base, base: base, data: batch, epochs: 30, learningRate: 0.01, anchor: 1e-4)
        XCTAssertLessThan(Learner.loss(learned, batch), before * 0.6, "it learns")
        // A strong anchor keeps it close to the shipped head.
        let held = Learner.fit(start: base, base: base, data: batch, epochs: 30, learningRate: 0.01, anchor: 50)
        func distance(_ a: ReaderHead) -> Float {
            zip(a.midWeight + a.outWeight, base.midWeight + base.outWeight).reduce(0) { $0 + abs($1.0 - $1.1) }
        }
        XCTAssertLessThan(distance(held), distance(learned) * 0.25)
    }

    func testHisCorrectionsBecomeSentenceLabels() {
        let sentences = (0..<40).map { Sentence(text: "s\($0)", start: Double($0) * 10, end: Double($0) * 10 + 9) }
        func delta(_ action: String, _ start: Double, _ end: Double, _ kind: String) -> CorrectionDelta {
            CorrectionDelta(date: .now, action: action, start: start, end: end, kind: kind, contains: [kind], predictions: [],
                            grade: CutGrade(recall: 1, precision: 1, labelAgreement: 1, fragments: 1, score: 100),
                            finder: "", absorbed: 0, key: "\(action)\(start)")
        }
        // Pass 47: the cuts as they stand now (the two he kept).
        let labels = Learner.goldLabels(sentences: sentences, deltas: [
            delta("lock", 100, 160, "ad"),        // sentences 10…15
            delta("notAnAd", 300, 330, "show"),   // 30…32
            delta("confirm", 200, 220, "selfPromo"),
        ], current: [.init(start: 100, end: 160, kind: "ad"), .init(start: 200, end: 220, kind: "selfPromo")])
        XCTAssertEqual(labels[12]?.label, 1)
        XCTAssertEqual(labels[12]?.weight, Learner.goldWeight)
        XCTAssertEqual(labels[31]?.label, 0, "Not an Ad is the show")
        XCTAssertEqual(labels[21]?.label, 2)
        // Edges he set (lock): 45 s either side are the show, lightly.
        XCTAssertEqual(labels[7]?.label, 0)
        XCTAssertEqual(labels[17]?.label, 0)
        XCTAssertLessThan(labels[7]?.weight ?? 9, Learner.goldWeight)
        // Pass 47: far from every cut in an episode he reviewed is the show,
        // lightly, so his ad-heavy corrections keep the lab's balance.
        XCTAssertEqual(labels[3]?.label, 0)
        XCTAssertLessThanOrEqual(labels[3]?.weight ?? 9, Learner.goldWeight * 0.4)
        // A confirm doesn't vouch for its surroundings.
        XCTAssertNil(labels[22], "just after the self-promo he only confirmed")
        XCTAssertNil(labels[23])
    }

    func testModelReadsTeachOnlyWhatTheyRead() {
        let sentences = (0..<120).map { Sentence(text: "s\($0)", start: Double($0) * 10, end: Double($0) * 10 + 9) }
        let labels = Learner.silverLabels(sentences: sentences, cuts: [(400, 460, .ad)], read: [300...700])
        XCTAssertEqual(labels[42]?.label, 1)
        XCTAssertEqual(labels[42]?.weight, Learner.silverWeight)
        for (i, entry) in labels where entry.label == 0 {
            let t = Double(i) * 10 + 4.5
            XCTAssertTrue((300...700).contains(t), "the show only where it read")
            XCTAssertTrue(t < 340 || t > 520, "and clear of its cut")
        }
        XCTAssertFalse(labels.values.contains { $0.label == 0 && $0.weight > Learner.silverNegativeWeight })
        XCTAssertNil(Learner.labelIndex(kind: "mystery"))
    }

    func testFilesRoundTrip() {
        let heads = [("a1", randomHead(seed: 1)), ("b2", randomHead(seed: 2))]
        let decoded = Learner.decodeHeads(Learner.encodeHeads(heads))
        XCTAssertEqual(decoded?.map(\.base), ["a1", "b2"])
        XCTAssertEqual(decoded?[1].head, heads[1].1)
        let examples = [Learner.Example(episode: "e", show: "s", label: 3, weight: 5, source: .gold,
                                        features: [[0.5, -1.25, 3], [2, 0.125, -0.5]])]
        let back = Learner.decodeExamples(Learner.encodeExamples(examples))
        XCTAssertEqual(back.first?.features, examples[0].features, "float16-exact values survive")
        XCTAssertEqual(back.first?.label, 3)
        XCTAssertEqual(back.first?.source, .gold)
        XCTAssertNil(Learner.decodeHeads(Data("nope".utf8)))
    }

    func testReaderUsesALearnedHeadOnlyForTheReaderItWasLearnedOn() throws {
        let readers = SentenceTagger.ensemble
        try XCTSkipIf(readers.isEmpty, "this build has no reader")
        XCTAssertEqual(SentenceTagger.identities(), readers.map(\.identity))
        let sentences = [Sentence(text: "This episode is brought to you by Quince.", start: 0, end: 3),
                         Sentence(text: "Go to quince dot com slash podcast for free shipping.", start: 3, end: 7),
                         Sentence(text: "Anyway, so my uncle had this boat.", start: 8, end: 11)]
        let reader = readers[0]
        // The refactor reads exactly as before: features through the shipped head.
        let plain = reader.probabilities(sentences)
        let manual = reader.features(sentences).map { reader.baseHead.probabilities($0) }
        XCTAssertEqual(plain, manual)
        // A head that says "show" for everything changes the answer only when it matches.
        var flat = reader.baseHead
        flat.outWeight = [Float](repeating: 0, count: flat.outWeight.count)
        flat.outBias = [8, 0, 0, 0, 0, 0]
        defer { LearnedReaderHeads.current = nil }
        LearnedReaderHeads.current = LearnedReaderHeads.Heads(heads: readers.map { ($0.identity, flat) })
        let learned = try XCTUnwrap(SentenceTagger.probabilities(sentences))
        XCTAssertGreaterThan(learned[0][0], 0.99)
        LearnedReaderHeads.current = LearnedReaderHeads.Heads(heads: readers.map { _ in ("another reader", flat) })
        let ignored = try XCTUnwrap(SentenceTagger.probabilities(sentences))
        XCTAssertEqual(ignored[0][0], SentenceTagger.probabilities(sentences)?[0][0])
        LearnedReaderHeads.current = nil
        XCTAssertLessThan(try XCTUnwrap(SentenceTagger.probabilities(sentences))[0][0], 0.99, "the shipped head finds the read")
    }

    /// The anchor set (`tagger.py anchor`) is the shipped readers' own view
    /// of 1,606 labelled lab sentences: the shipped heads label it well, which
    /// they couldn't if its features came from other readers.
    func testAnchorSetMatchesTheShippedReaders() throws {
        let readers = SentenceTagger.ensemble
        try XCTSkipIf(readers.isEmpty, "this build has no reader")
        let anchor = ReaderAnchor.load(readers: readers)
        XCTAssertGreaterThan(anchor.count, 1_000)
        XCTAssertTrue(anchor.allSatisfy { $0.source == .anchor })
        for (r, reader) in readers.enumerated() {
            let data = Learner.batchable(anchor, reader: r)
            let loss = Learner.loss(reader.baseHead, data)
            XCTAssertLessThan(loss, 0.6, "reader \(r): \(loss)")
            // Against chance (six labels): ln 6 ≈ 1.79.
            var scrambled = data
            scrambled.labels = scrambled.labels.map { ($0 + 1) % 6 }
            XCTAssertGreaterThan(Learner.loss(reader.baseHead, scrambled), 2 * loss)
        }
    }

    func testOnlyTheWindowsOfLabelledSentencesAreRead() throws {
        let reader = try XCTUnwrap(SentenceTagger.ensemble.first)
        let sentences = (0..<200).map { Sentence(text: "Sentence number \($0) about nothing in particular at all.", start: Double($0) * 4, end: Double($0) * 4 + 3) }
        let some = reader.features(sentences, only: [5, 150])
        XCTAssertEqual(some[5], reader.features(sentences)[5])
        XCTAssertTrue(some[100].isEmpty, "a window holding none of them is skipped")
    }
}
