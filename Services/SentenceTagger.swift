import Accelerate
import Foundation

/// PodSkipper's own reader, full strength (pass 25).
///
/// Why it exists: locked and on battery, iOS stops Apple's on-device model
/// answering an app in the background (his 29 Sep Diagnostics: 28 answers,
/// then refusals, on every job). Everything that decided where the ads were
/// went through that model, so a locked job could only finish as a "quick
/// check". He wants one process — the real one — whether the phone is locked
/// or not, and everything kept on the phone.
///
/// So the part Apple's model did — reading every sentence in context and
/// saying whether it is the show, a paid read, the show's own plug, another
/// show's promo, the opening or the closing — is done here by a small
/// transformer (ELECTRA-small, 14 M parameters) fine-tuned on the Mac
/// (`Tools/DetectionLab/tagger.py`) on the lab's labelled episodes of his
/// shows and his phone's own results. It reads 512 word-pieces at a time,
/// each window starting halfway through the one before, and each sentence
/// takes its answer from the window it sits most centrally in, so every
/// sentence is judged with about a minute of the conversation either side.
///
/// It runs on the CPU with Accelerate (no graphics chip, which iOS refuses a
/// backgrounded app, and no system model iOS can throttle): a 72-minute
/// episode in about 3 s on the Mac, per reader. The app carries two readers
/// (the same training, two starting points) and averages them (`ensemble`).
/// Swift and Python agree to 1e-6 on every sentence (`LAB_TAGDUMP`).
struct SentenceTagger: @unchecked Sendable {

    /// C, A, S, N, I, O — `SentenceLabel.allCases`' order, and the order the
    /// head's outputs are written in.
    static let labels: [SentenceLabel] = [.content, .advertisement, .selfPromotion, .networkPromotion, .opening, .closing]

    struct Config: Decodable {
        var vocab_size: Int
        var hidden: Int
        var layers: Int
        var heads: Int
        var intermediate: Int
        var max_pos: Int
        var emb_size: Int
        var ln_eps: Float
        var nfeat: Int
        var mid: Int
        var sent_cap: Int
        var maxlen: Int
        var cls_id: Int
        var sep_id: Int
        var unk_id: Int
    }

    private struct TensorInfo: Decodable { var name: String; var shape: [Int]; var offset: Int }
    private struct Header: Decodable {
        var config: Config
        var tensors: [TensorInfo]
        var vocab_offset: Int
        var vocab_length: Int
    }

    let config: Config
    private let vocab: [String: Int32]
    private let t: [String: [Float]]

    /// Whether this build carries the reader's weights, without loading them
    /// (for Settings and Diagnostics, on the main thread).
    static var isBundled: Bool {
        Bundle.main.url(forResource: "TaggerWeights", withExtension: "bin") != nil
    }

    /// The app's readers (bundle resources `TaggerWeights.bin`,
    /// `TaggerWeights-2.bin`, …: the same reader trained twice from different
    /// starting points), loaded once, on first use. Their answers are
    /// averaged: in the lab two readers together missed less and cut less
    /// than either alone, because each is unsure in different places.
    /// `LAB_TAGGER` (paths joined by ":") points the detection lab at folds.
    static let ensemble: [SentenceTagger] = {
        if let paths = ProcessInfo.processInfo.environment["LAB_TAGGER"] {
            return paths.split(separator: ":").compactMap { SentenceTagger(url: URL(fileURLWithPath: String($0))) }
        }
        var urls: [URL] = []
        if let first = Bundle.main.url(forResource: "TaggerWeights", withExtension: "bin") { urls.append(first) }
        for n in 2...4 {
            if let more = Bundle.main.url(forResource: "TaggerWeights-\(n)", withExtension: "bin") { urls.append(more) }
        }
        return urls.compactMap { SentenceTagger(url: $0) }
    }()

    /// Every sentence's label probabilities, averaged over the readers, or
    /// nil when this build has none.
    static func probabilities(_ sentences: [Sentence]) -> [[Double]]? {
        let readers = ensemble
        guard !readers.isEmpty else { return nil }
        // The readers are independent: each on its own core.
        let results = Results(count: readers.count)
        DispatchQueue.concurrentPerform(iterations: readers.count) { r in
            results.set(r, readers[r].probabilities(sentences))
        }
        let all = results.values
        var sum = all[0]
        for p in all.dropFirst() {
            for i in sum.indices { for k in sum[i].indices { sum[i][k] += p[i][k] } }
        }
        let n = Double(readers.count)
        return sum.map { $0.map { $0 / n } }
    }

    /// Each reader's answer, filled in from several threads.
    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var slots: [[[Double]]]
        init(count: Int) { slots = Array(repeating: [], count: count) }
        func set(_ index: Int, _ value: [[Double]]) { lock.withLock { slots[index] = value } }
        var values: [[[Double]]] { lock.withLock { slots } }
    }

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count > 12,
              data.prefix(4) == Data("PSTG".utf8) else { return nil }
        func u32(_ at: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        }
        guard u32(4) == 1 else { return nil }
        let jsonLength = u32(8)
        guard data.count > 12 + jsonLength,
              let header = try? JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + jsonLength))) else { return nil }
        let blob = 12 + jsonLength
        var tensors: [String: [Float]] = [:]
        for info in header.tensors {
            let count = info.shape.reduce(1, *)
            let start = blob + info.offset, end = start + count * 2
            guard end <= data.count else { return nil }
            var out = [Float](repeating: 0, count: count)
            data.withUnsafeBytes { raw in
                let base = raw.baseAddress!.advanced(by: start)
                // Float16 in the file, Float32 to compute with.
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: 1,
                                        width: vImagePixelCount(count), rowBytes: count * 2)
                out.withUnsafeMutableBufferPointer { dst in
                    var d = vImage_Buffer(data: dst.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    vImageConvert_Planar16FtoPlanarF(&src, &d, 0)
                }
            }
            // Layer weights are kept transposed (in × out), the shape
            // `vDSP_mmul` multiplies by; embedding tables stay as they are.
            if info.shape.count == 2, !info.name.hasPrefix("embeddings.") {
                let rows = info.shape[0], cols = info.shape[1]
                var transposed = [Float](repeating: 0, count: count)
                vDSP_mtrans(out, 1, &transposed, 1, vDSP_Length(cols), vDSP_Length(rows))
                tensors[info.name] = transposed
            } else {
                tensors[info.name] = out
            }
        }
        let vStart = blob + header.vocab_offset, vEnd = vStart + header.vocab_length
        guard vEnd <= data.count, let text = String(data: data.subdata(in: vStart..<vEnd), encoding: .utf8) else { return nil }
        var vocab: [String: Int32] = [:]
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            vocab[String(line)] = Int32(i)
        }
        config = header.config
        self.vocab = vocab
        t = tensors
        guard t["embeddings.word_embeddings.weight"] != nil, t["mid.weight"] != nil, t["out.weight"] != nil else { return nil }
    }

    // MARK: Word-pieces
    //
    // BERT's uncased tokenizer, as the Python side's (Hugging Face's
    // BertTokenizerFast for ELECTRA): drop control characters, space out CJK
    // ideographs, strip accents, lower-case, split on white space and
    // punctuation, then the longest pieces of each word that are in the
    // vocabulary ("##" for a piece that continues a word).

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) { return true }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }

    private static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        s == " " || s == "\t" || s == "\n" || s == "\r" || s.properties.generalCategory == .spaceSeparator
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        if s == "\t" || s == "\n" || s == "\r" { return false }
        switch s.properties.generalCategory {
        case .control, .format, .privateUse, .unassigned, .surrogate: return true
        default: return false
        }
    }

    private static func isCJK(_ v: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x2A6DF).contains(v)
            || (0x2A700...0x2B73F).contains(v) || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }

    /// The words and punctuation marks of a sentence, normalised.
    static func basicTokens(_ text: String) -> [String] {
        var cleaned = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s.value == 0 || s.value == 0xFFFD || isControl(s) { continue }
            if isWhitespace(s) { cleaned.append(" "); continue }
            if isCJK(s.value) { cleaned.append(" "); cleaned.append(s); cleaned.append(" "); continue }
            cleaned.append(s)
        }
        // Accents off (NFD, then no combining marks), then lower case.
        let decomposed = String(cleaned).decomposedStringWithCanonicalMapping
        var plain = String.UnicodeScalarView()
        for s in decomposed.unicodeScalars where s.properties.generalCategory != .nonspacingMark { plain.append(s) }
        let lower = String(plain).lowercased()
        var out: [String] = []
        var current = String.UnicodeScalarView()
        func flush() { if !current.isEmpty { out.append(String(current)); current = String.UnicodeScalarView() } }
        for s in lower.unicodeScalars {
            if isWhitespace(s) { flush(); continue }
            if isPunctuation(s) { flush(); out.append(String(s)); continue }
            current.append(s)
        }
        flush()
        return out
    }

    /// Vocabulary ids of a sentence's word-pieces.
    func pieces(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        let unk = Int32(config.unk_id)
        for word in Self.basicTokens(text) {
            let chars = Array(word.unicodeScalars)
            if chars.count > 100 { ids.append(unk); continue }
            var start = 0
            var found: [Int32] = []
            var bad = false
            while start < chars.count {
                var end = chars.count
                var match: Int32?
                while start < end {
                    var piece = String(String.UnicodeScalarView(chars[start..<end]))
                    if start > 0 { piece = "##" + piece }
                    if let id = vocab[piece] { match = id; break }
                    end -= 1
                }
                guard let match else { bad = true; break }
                found.append(match)
                start = end
            }
            ids += bad ? [unk] : found
        }
        return ids
    }

    // MARK: What the words don't say

    /// Where the sentence falls in the episode, the pauses either side, its
    /// length and pace — as tagger.py's `side_features`.
    static func sideFeatures(_ sentences: [Sentence], count: Int) -> [[Float]] {
        guard let duration = sentences.last?.end else { return [] }
        func bucket(_ v: Double, _ edges: [Double]) -> Int { edges.firstIndex { v < $0 } ?? edges.count }
        return sentences.indices.map { i in
            let s = sentences[i]
            var f = [Float](repeating: 0, count: count)
            let n = Double(s.text.split(whereSeparator: { $0.isWhitespace }).count)
            f[0] = s.start < 120 ? 1 : 0
            f[1] = s.start < 600 ? 1 : 0
            f[2] = s.end > duration - 180 ? 1 : 0
            f[3] = s.end > duration - 600 ? 1 : 0
            let gb = i > 0 ? s.start - sentences[i - 1].end : 9
            let ga = i + 1 < sentences.count ? sentences[i + 1].start - s.end : 9
            f[4 + bucket(gb, [0.2, 0.5, 1.0, 2.0])] = 1
            f[9 + bucket(ga, [0.2, 0.5, 1.0, 2.0])] = 1
            let length = max(0.3, s.end - s.start)
            f[14 + bucket(n / length, [1.5, 2.5, 3.2, 4.0])] = 1
            f[19] = Float(min(1.0, n / 30.0))
            f[20] = Float(s.start / max(1.0, duration))
            f[21] = 1
            return f
        }
    }

    // MARK: Windows

    /// [first, last) sentence ranges of at most `room` word-pieces, each
    /// starting about halfway through the one before (tagger.py `windows`).
    static func windows(_ lengths: [Int], room: Int) -> [Range<Int>] {
        let n = lengths.count
        var out: [Range<Int>] = []
        var s = 0
        while s < n {
            var total = 0, e = s
            while e < n, total + lengths[e] <= room { total += lengths[e]; e += 1 }
            if e == s { e = s + 1 }
            out.append(s..<e)
            if e >= n { break }
            let half = Double(total) / 2
            var acc = 0, next = s
            while next < e, Double(acc + lengths[next]) <= half { acc += lengths[next]; next += 1 }
            s = max(s + 1, next)
        }
        return out
    }

    /// For every sentence, the window it sits most centrally in.
    static func centreWindow(_ windows: [Range<Int>], lengths: [Int]) -> [Int] {
        var best = [(window: Int, margin: Double)](repeating: (-1, -1), count: lengths.count)
        for (w, range) in windows.enumerated() {
            let total = Double(range.reduce(0) { $0 + lengths[$1] })
            var acc = 0.0
            for i in range {
                let L = Double(lengths[i])
                let margin = min(acc + L / 2, total - acc - L / 2)
                if margin > best[i].margin { best[i] = (w, margin) }
                acc += L
            }
        }
        return best.map(\.window)
    }

    // MARK: Reading

    /// The probability of each label (`SentenceTagger.labels` order) for
    /// every sentence, by this one reader.
    func probabilities(_ sentences: [Sentence]) -> [[Double]] {
        guard !sentences.isEmpty else { return [] }
        let cap = config.sent_cap
        let ids = sentences.map { s -> [Int32] in
            let p = pieces(s.text)
            return p.isEmpty ? [Int32(config.unk_id)] : Array(p.prefix(cap))
        }
        let lengths = ids.map(\.count)
        let side = Self.sideFeatures(sentences, count: config.nfeat)
        let wins = Self.windows(lengths, room: config.maxlen - 2)
        let centre = Self.centreWindow(wins, lengths: lengths)
        var out = [[Double]](repeating: [1, 0, 0, 0, 0, 0], count: sentences.count)
        for (w, range) in wins.enumerated() {
            let wanted = range.filter { centre[$0] == w }
            guard !wanted.isEmpty else { continue }
            var tokens: [Int32] = [Int32(config.cls_id)]
            var spans: [Int: Range<Int>] = [:]
            for i in range {
                spans[i] = tokens.count..<(tokens.count + ids[i].count)
                tokens += ids[i]
            }
            tokens.append(Int32(config.sep_id))
            let hidden = encode(tokens)
            for i in wanted {
                guard let span = spans[i] else { continue }
                out[i] = head(pool(hidden, span: span), side: side[i])
            }
        }
        return out
    }

    // MARK: The transformer (ELECTRA / BERT encoder), on the CPU

    private func tensor(_ name: String) -> [Float] { t[name] ?? [] }

    /// y[rows × outDim] = x[rows × inDim] · W + b, W kept in × out (see
    /// `init`).
    private static func linear(_ x: [Float], rows: Int, inDim: Int, weight: [Float], bias: [Float], outDim: Int) -> [Float] {
        var y = [Float](repeating: 0, count: rows * outDim)
        vDSP_mmul(x, 1, weight, 1, &y, 1, vDSP_Length(rows), vDSP_Length(outDim), vDSP_Length(inDim))
        y.withUnsafeMutableBufferPointer { yp in
            bias.withUnsafeBufferPointer { bp in
                for r in 0..<rows {
                    let row = yp.baseAddress! + r * outDim
                    vDSP_vadd(row, 1, bp.baseAddress!, 1, row, 1, vDSP_Length(outDim))
                }
            }
        }
        return y
    }

    private static func layerNorm(_ x: inout [Float], rows: Int, dim: Int, gamma: [Float], beta: [Float], eps: Float) {
        let n = vDSP_Length(dim)
        x.withUnsafeMutableBufferPointer { xp in
            gamma.withUnsafeBufferPointer { gp in
                beta.withUnsafeBufferPointer { bp in
                    for r in 0..<rows {
                        let row = xp.baseAddress! + r * dim
                        var mean: Float = 0
                        vDSP_meanv(row, 1, &mean, n)
                        var negative = -mean
                        vDSP_vsadd(row, 1, &negative, row, 1, n)
                        var squares: Float = 0
                        vDSP_svesq(row, 1, &squares, n)
                        var scale = 1 / (squares / Float(dim) + eps).squareRoot()
                        vDSP_vsmul(row, 1, &scale, row, 1, n)
                        vDSP_vma(row, 1, gp.baseAddress!, 1, bp.baseAddress!, 1, row, 1, n)
                    }
                }
            }
        }
    }

    /// GELU with the error function (as PyTorch's default), erf from
    /// Abramowitz & Stegun 7.1.26 (error under 1.5e-7).
    private static func gelu(_ x: inout [Float]) {
        let n = x.count
        var z = [Float](repeating: 0, count: n)
        var e = [Float](repeating: 0, count: n)
        for i in 0..<n { let u = x[i] * 0.707_106_78; z[i] = -u * u }
        var count = Int32(n)
        e.withUnsafeMutableBufferPointer { ep in z.withUnsafeBufferPointer { zp in vvexpf(ep.baseAddress!, zp.baseAddress!, &count) } }
        for i in 0..<n {
            let u = x[i] * 0.707_106_78
            let a = abs(u)
            let k = 1 / (1 + 0.327_591_1 * a)
            let poly = k * (0.254_829_592 + k * (-0.284_496_736 + k * (1.421_413_741 + k * (-1.453_152_027 + k * 1.061_405_429))))
            var erf = 1 - poly * e[i]
            if u < 0 { erf = -erf }
            x[i] = 0.5 * x[i] * (1 + erf)
        }
    }

    private static func softmaxRows(_ p: UnsafeMutablePointer<Float>, rows: Int, cols: Int) {
        let n = vDSP_Length(cols)
        var count = Int32(cols)
        for r in 0..<rows {
            let row = p + r * cols
            var top: Float = 0
            vDSP_maxv(row, 1, &top, n)
            var negative = -top
            vDSP_vsadd(row, 1, &negative, row, 1, n)
            vvexpf(row, row, &count)
            var total: Float = 0
            vDSP_sve(row, 1, &total, n)
            vDSP_vsdiv(row, 1, &total, row, 1, n)
        }
    }

    private func attention(q: [Float], k: [Float], v: [Float], rows T: Int) -> [Float] {
        let H = config.hidden, heads = config.heads, dh = H / heads
        var context = [Float](repeating: 0, count: T * H)
        var scores = [Float](repeating: 0, count: T * T)
        var qh = [Float](repeating: 0, count: T * dh), kh = qh, vh = qh, kt = qh, ch = qh
        var scale = 1 / Float(dh).squareRoot()
        let t = vDSP_Length(T), d = vDSP_Length(dh), h = vDSP_Length(H)
        for head in 0..<heads {
            // This head's columns, as contiguous T × dh matrices.
            q.withUnsafeBufferPointer { vDSP_mmov($0.baseAddress! + head * dh, &qh, d, t, h, d) }
            k.withUnsafeBufferPointer { vDSP_mmov($0.baseAddress! + head * dh, &kh, d, t, h, d) }
            v.withUnsafeBufferPointer { vDSP_mmov($0.baseAddress! + head * dh, &vh, d, t, h, d) }
            vDSP_mtrans(kh, 1, &kt, 1, d, t)
            vDSP_mmul(qh, 1, kt, 1, &scores, 1, t, t, d)
            scores.withUnsafeMutableBufferPointer { sp in
                vDSP_vsmul(sp.baseAddress!, 1, &scale, sp.baseAddress!, 1, vDSP_Length(T * T))
                Self.softmaxRows(sp.baseAddress!, rows: T, cols: T)
            }
            vDSP_mmul(scores, 1, vh, 1, &ch, 1, t, d, t)
            context.withUnsafeMutableBufferPointer { vDSP_mmov(ch, $0.baseAddress! + head * dh, d, t, d, h) }
        }
        return context
    }

    /// The last layer's state of every word-piece of one window.
    private func encode(_ tokens: [Int32]) -> [Float] {
        let T = tokens.count, E = config.emb_size, H = config.hidden, I = config.intermediate
        let eps = config.ln_eps
        let word = tensor("embeddings.word_embeddings.weight")
        let position = tensor("embeddings.position_embeddings.weight")
        let type = tensor("embeddings.token_type_embeddings.weight")
        var x = [Float](repeating: 0, count: T * E)
        for (i, id) in tokens.enumerated() {
            let w = Int(id) * E, p = min(i, config.max_pos - 1) * E
            for j in 0..<E { x[i * E + j] = word[w + j] + position[p + j] + type[j] }
        }
        Self.layerNorm(&x, rows: T, dim: E, gamma: tensor("embeddings.LayerNorm.weight"),
                       beta: tensor("embeddings.LayerNorm.bias"), eps: eps)
        if E != H || t["embeddings_project.weight"] != nil {
            x = Self.linear(x, rows: T, inDim: E, weight: tensor("embeddings_project.weight"),
                            bias: tensor("embeddings_project.bias"), outDim: H)
        }
        for l in 0..<config.layers {
            let p = "encoder.layer.\(l)."
            let q = Self.linear(x, rows: T, inDim: H, weight: tensor(p + "attention.self.query.weight"),
                                bias: tensor(p + "attention.self.query.bias"), outDim: H)
            let k = Self.linear(x, rows: T, inDim: H, weight: tensor(p + "attention.self.key.weight"),
                                bias: tensor(p + "attention.self.key.bias"), outDim: H)
            let v = Self.linear(x, rows: T, inDim: H, weight: tensor(p + "attention.self.value.weight"),
                                bias: tensor(p + "attention.self.value.bias"), outDim: H)
            let context = attention(q: q, k: k, v: v, rows: T)
            var a = Self.linear(context, rows: T, inDim: H, weight: tensor(p + "attention.output.dense.weight"),
                                bias: tensor(p + "attention.output.dense.bias"), outDim: H)
            a = vDSP.add(a, x)
            Self.layerNorm(&a, rows: T, dim: H, gamma: tensor(p + "attention.output.LayerNorm.weight"),
                           beta: tensor(p + "attention.output.LayerNorm.bias"), eps: eps)
            var inner = Self.linear(a, rows: T, inDim: H, weight: tensor(p + "intermediate.dense.weight"),
                                    bias: tensor(p + "intermediate.dense.bias"), outDim: I)
            Self.gelu(&inner)
            var o = Self.linear(inner, rows: T, inDim: I, weight: tensor(p + "output.dense.weight"),
                                bias: tensor(p + "output.dense.bias"), outDim: H)
            o = vDSP.add(o, a)
            Self.layerNorm(&o, rows: T, dim: H, gamma: tensor(p + "output.LayerNorm.weight"),
                           beta: tensor(p + "output.LayerNorm.bias"), eps: eps)
            x = o
        }
        return x
    }

    /// A sentence's summary: the mean of its word-pieces' last states.
    private func pool(_ hidden: [Float], span: Range<Int>) -> [Float] {
        let H = config.hidden
        var z = [Float](repeating: 0, count: H)
        for r in span { for j in 0..<H { z[j] += hidden[r * H + j] } }
        let n = Float(max(1, span.count))
        for j in 0..<H { z[j] /= n }
        return z
    }

    /// One sentence's label probabilities from its summary and side facts.
    private func head(_ pooled: [Float], side: [Float]) -> [Double] {
        let H = config.hidden, F = config.nfeat
        var z = pooled + [Float](repeating: 0, count: F)
        for j in 0..<F { z[H + j] = side[j] }
        var mid = Self.linear(z, rows: 1, inDim: H + F, weight: tensor("mid.weight"), bias: tensor("mid.bias"), outDim: config.mid)
        Self.gelu(&mid)
        let logits = Self.linear(mid, rows: 1, inDim: config.mid, weight: tensor("out.weight"),
                                 bias: tensor("out.bias"), outDim: Self.labels.count).map(Double.init)
        let top = logits.max() ?? 0
        let e = logits.map { exp($0 - top) }
        let total = e.reduce(0, +)
        return e.map { $0 / total }
    }
}
