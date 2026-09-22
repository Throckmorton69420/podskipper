import Foundation
import NaturalLanguage

/// What the listener's thumbs actually teach, beyond one prompt.
///
/// The instructions already carry a show's most recent corrections as worked
/// examples, but a small model reads examples loosely and there is room for
/// only a few. This is the part that does not depend on the model agreeing:
/// every corrected passage is turned into a sentence embedding on the device,
/// and a new cut that reads like something the listener rejected is not made,
/// while one that reads like something they confirmed is kept without being
/// second-guessed.
///
/// Sponsor reads repeat almost word for word from week to week, and so do the
/// passages a detector keeps getting wrong on a given show — which is why
/// nearest-neighbour memory works here where it would not in general.
struct FeedbackMemory {

    enum Match: Equatable {
        case none
        case rejected(Double)
        case confirmed(Double)
    }

    /// Cosine similarity at or above which two passages count as the same
    /// read. Measured in the detection lab on two real episodes: the same
    /// Progressive spot in two places scored 0.96, two SkinnyPop reads with
    /// different scripts 0.82, and every pair of unrelated passages —
    /// conversation against conversation, ad against a different ad,
    /// conversation against an ad — between 0.51 and 0.77.
    static let threshold = 0.81

    private let embedding: NLEmbedding?
    private let rejected: [[Double]]
    private let confirmed: [[Double]]

    init(corrections all: [DetectionCorrection]) {
        // Edge lessons are a few words at a boundary, not examples of a
        // promotion: matched against a whole cut they would reject it.
        let corrections = all.filter { $0.boundary == nil }
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        self.embedding = embedding
        guard let embedding else { rejected = []; confirmed = []; return }
        rejected = corrections.filter { $0.segmentKind == nil }
            .flatMap { Self.chunks($0.excerpt) }
            .compactMap { embedding.vector(for: $0) }
        confirmed = corrections.filter { $0.segmentKind != nil }
            .flatMap { Self.chunks($0.excerpt) }
            .compactMap { embedding.vector(for: $0) }
    }

    var isEmpty: Bool { rejected.isEmpty && confirmed.isEmpty }

    func match(_ text: String) -> Match {
        guard let embedding, !isEmpty else { return .none }
        let vectors = Self.chunks(text).prefix(8).compactMap { embedding.vector(for: $0) }
        guard !vectors.isEmpty else { return .none }

        func best(_ memory: [[Double]]) -> Double {
            var top = 0.0
            for v in vectors { for m in memory { top = max(top, Self.cosine(v, m)) } }
            return top
        }
        let r = best(rejected)
        let c = best(confirmed)
        if r >= Self.threshold, r >= c { return .rejected((r * 100).rounded() / 100) }
        if c >= Self.threshold { return .confirmed((c * 100).rounded() / 100) }
        return .none
    }

    /// Thirty-word pieces. A stored correction is a few hundred characters; a
    /// cut can be minutes long, so both are compared piece by piece.
    static func chunks(_ text: String, size: Int = 30) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        return stride(from: 0, to: words.count, by: size).map {
            words[$0..<min(words.count, $0 + size)].joined(separator: " ")
        }.filter { $0.split(separator: " ").count >= 8 }
    }

    /// Highest similarity between any piece of one text and any piece of the
    /// other. Used by the detection lab to choose `threshold`.
    static func bestSimilarity(_ a: [String], _ b: [String]) -> Double {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return 0 }
        let va = a.compactMap { embedding.vector(for: $0) }
        let vb = b.compactMap { embedding.vector(for: $0) }
        var top = 0.0
        for x in va { for y in vb { top = max(top, cosine(x, y)) } }
        return top
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }
}
