import Foundation

/// PodSkipper's own sentence reader (pass 23): what each sentence of an
/// episode is doing, from its words and its neighbours', without Apple
/// Intelligence.
///
/// Why it exists: on his phone, locked and on battery, iOS refuses almost
/// every question to Apple's on-device model (29 Sep: 165 refusals in twelve
/// minutes and 0 % progress on one episode; the same job moved 43 % → 89 % in
/// seven minutes with the app open). Nothing an app can do lifts that. He
/// chose to keep everything on the phone, so the part of finding ads that
/// has to keep going while the phone is locked runs on this instead: a
/// logistic regression over hashed words of the sentence, the two sentences
/// either side and the 45 seconds around it, plus its length, the pauses
/// around it and where it falls in the episode. It reads a two-hour episode
/// in well under a second on the CPU, and iOS doesn't limit it.
///
/// It is trained on the Mac (`Tools/DetectionLab/fastreader.py export`) from
/// the lab's labelled episodes of his shows and, weighted lower, the cuts his
/// phone's detector made. Leave-one-episode-out on the 17 lab fixtures, it
/// ranks promotional sentences above conversation with an AUC of about 0.98.
///
/// What it's used for (`SegmentDetector`):
/// 1. Where to look — instead of a model question for every 45-second
///    window (60–120 questions an episode).
/// 2. A vote on every sentence, alongside the model's labels where the model
///    read, so an unanswered question no longer means "conversation".
/// 3. The whole answer when iOS won't let the model answer: the job finishes
///    locked, and the episode is checked again with Apple's model later.
///
/// The features and the hash here must match `fastreader.py` exactly: the
/// weights are indexed by them.
struct FastReader: Sendable {

    /// C, A, S, N, I, O — the order `SentenceLabel.allCases` has and the
    /// order the weights are written in.
    static let labels: [SentenceLabel] = [.content, .advertisement, .selfPromotion, .networkPromotion, .opening, .closing]

    private let dim: Int
    private let classes: Int
    private let bias: [Float]
    /// Class-major, Float16 in the file: weight(k, i) = weights[k * dim + i].
    private let weights: Data

    /// The app's copy (bundle resource `FastReaderWeights.bin`, from
    /// `Resources/Detection`), loaded once.
    static let shared: FastReader? = {
        if let path = ProcessInfo.processInfo.environment["LAB_FAST"] {
            return FastReader(url: URL(fileURLWithPath: path))
        }
        guard let url = Bundle.main.url(forResource: "FastReaderWeights", withExtension: "bin") else { return nil }
        return FastReader(url: url)
    }()

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 16,
              data.prefix(4) == Data("PSFR".utf8) else { return nil }
        func u32(_ at: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        }
        let version = u32(4), dim = u32(8), classes = u32(12)
        guard version == 1, classes == Self.labels.count, dim > 0,
              data.count == 16 + classes * 4 + classes * dim * 2 else { return nil }
        self.dim = dim
        self.classes = classes
        bias = (0..<classes).map { k in
            data.withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 16 + k * 4, as: UInt32.self))) }
        }
        weights = data.subdata(in: (16 + classes * 4)..<data.count)
    }

    // MARK: Words

    /// Lower case, ".com" and "dot com" as one word, digits as 0, then runs
    /// of a–z, 0 and the apostrophe. The same as `tokens` in fastreader.py.
    static func tokens(_ text: String) -> [String] {
        let t = text.lowercased()
            .replacingOccurrences(of: ".com", with: " dotcom ")
            .replacingOccurrences(of: "dot com", with: " dotcom ")
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in t.unicodeScalars {
            let v = scalar.value
            if (v >= 97 && v <= 122) || v == 39 {
                current.append(scalar)
            } else if v >= 48 && v <= 57 {
                current.append("0")
            } else if !current.isEmpty {
                out.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// FNV-1a, 32 bits, over the UTF-8 bytes.
    static func fnv(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811C_9DC5
        for b in s.utf8 {
            h ^= UInt32(b)
            h = h &* 0x0100_0193
        }
        return h
    }

    private static func bucket(_ v: Double, _ edges: [Double]) -> Int {
        edges.firstIndex { v < $0 } ?? edges.count
    }

    /// Every feature name of sentence `i`, as fastreader.py's `features`.
    static func features(_ sentences: [Sentence], tokens: [[String]], at i: Int, duration: Double) -> Set<String> {
        let s = sentences[i]
        let me = tokens[i]
        var f = Set<String>()
        for w in me { f.insert("s|" + w) }
        if me.count >= 2 { for j in 0..<(me.count - 1) { f.insert("b|" + me[j] + " " + me[j + 1]) } }
        for k in 1...2 {
            if i - k >= 0 { for w in tokens[i - k] { f.insert("p|" + w) } }
            if i + k < sentences.count { for w in tokens[i + k] { f.insert("n|" + w) } }
        }
        var j = i - 3
        while j >= 0, s.start - sentences[j].end < 45 {
            for w in tokens[j] { f.insert("w|" + w) }
            j -= 1
        }
        j = i + 3
        while j < sentences.count, sentences[j].start - s.end < 45 {
            for w in tokens[j] { f.insert("w|" + w) }
            j += 1
        }
        let n = me.count
        f.insert("len|\(bucket(Double(n), [2, 3, 6, 11, 21]))")
        let gapBefore = i > 0 ? s.start - sentences[i - 1].end : 9
        let gapAfter = i + 1 < sentences.count ? sentences[i + 1].start - s.end : 9
        f.insert("gb|\(bucket(gapBefore, [0.2, 0.5, 1.0, 2.0]))")
        f.insert("ga|\(bucket(gapAfter, [0.2, 0.5, 1.0, 2.0]))")
        let length = max(0.3, s.end - s.start)
        f.insert("rate|\(bucket(Double(n) / length, [1.5, 2.5, 3.2, 4.0]))")
        if s.start < 120 { f.insert("pos|start2") }
        if s.start < 600 { f.insert("pos|start10") }
        if s.end > duration - 180 { f.insert("pos|end3") }
        if s.end > duration - 600 { f.insert("pos|end10") }
        f.insert("bias")
        return f
    }

    // MARK: Reading

    /// The probability of each label (`FastReader.labels` order) for every
    /// sentence.
    func probabilities(_ sentences: [Sentence]) -> [[Double]] {
        guard !sentences.isEmpty else { return [] }
        let duration = sentences.last?.end ?? 0
        let tokens = sentences.map { Self.tokens($0.text) }
        let dim = self.dim, classes = self.classes, bias = self.bias
        return weights.withUnsafeBytes { raw -> [[Double]] in
            let w = raw.bindMemory(to: UInt16.self)
            return sentences.indices.map { i in
                var z = bias.map(Double.init)
                for name in Self.features(sentences, tokens: tokens, at: i, duration: duration) {
                    let h = Self.fnv(name)
                    let index = Int(h % UInt32(dim))
                    let sign: Double = (h >> 20) & 1 == 0 ? 1 : -1
                    for k in 0..<classes {
                        z[k] += sign * Double(Float16(bitPattern: UInt16(littleEndian: w[k * dim + index])))
                    }
                }
                let top = z.max() ?? 0
                let e = z.map { exp($0 - top) }
                let total = e.reduce(0, +)
                return e.map { $0 / total }
            }
        }
    }
}
