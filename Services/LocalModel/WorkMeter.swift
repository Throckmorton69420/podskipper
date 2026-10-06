import Foundation

/// Pass 31 (his 6 Oct report: model tests fly to ~99 % and then sit there,
/// and the time left is wrong).
///
/// The old bar gave reading the prompt 85 % of each part and writing the
/// answer the last 15 %, filled over 400 "pieces". On his iPhone reading is
/// ~10× faster per token than writing (Gemma 4 E4B: 194 tokens/s read,
/// 14 written), so the prompt raced to 85 % in seconds, and a model that
/// wrote 1,536 pieces (then retried) sat near 99 % for minutes.
///
/// "Pieces" are tokens: the word-fragments a model reads and writes. This
/// meter counts them as the real work they are. Every part's prompt tokens
/// are known before it is read, its answer has a hard cap, and how fast
/// this model reads and writes on this phone is measured; so the bar is
/// the share of the expected *time* done, and the time left is that time
/// minus what's been spent. When an answer runs longer than expected, the
/// expectation grows with it rather than the bar standing still.
struct WorkMeter: Sendable {
    struct Part: Sendable {
        var promptTokens: Int
        var expectedAnswer: Int
        var answerCap: Int
    }

    /// Tokens a second, measured on this phone for this model (or a guess).
    var readRate: Double
    var writeRate: Double
    /// Seconds to load the model, before the first part.
    var loadSeconds: Double
    private(set) var parts: [Part]
    private var index = 0
    private var readNow = 0
    private var writtenNow = 0
    /// Seconds already spent on the current part by an earlier try.
    private var spentOnTries = 0.0
    private var loaded = false

    init(parts: [Part], readRate: Double, writeRate: Double, loadSeconds: Double) {
        self.parts = parts
        self.readRate = max(5, readRate)
        self.writeRate = max(1, writeRate)
        self.loadSeconds = max(0, loadSeconds)
    }

    /// Seconds a part is expected to take, given what's known of it now.
    private func seconds(_ part: Part, written: Int?) -> Double {
        let answer = Swift.min(part.answerCap, Swift.max(part.expectedAnswer, (written ?? 0) + (written == nil ? 0 : 8)))
        return Double(part.promptTokens) / readRate + Double(answer) / writeRate
    }

    var expectedTotal: Double {
        var total = loadSeconds
        for (i, part) in parts.enumerated() {
            total += seconds(part, written: i == index ? writtenNow : nil)
        }
        return total
    }

    var done: Double {
        var spent = loaded ? loadSeconds : 0
        for part in parts.prefix(index) {
            // A finished part counts as exactly what was expected of it, so
            // the bar never jumps backwards.
            spent += seconds(part, written: nil)
        }
        guard index < parts.count else { return spent }
        return spent + spentOnTries + Double(readNow) / readRate + Double(writtenNow) / writeRate
    }

    var fraction: Double {
        let total = expectedTotal
        return total > 0 ? Swift.min(0.995, done / total) : 0
    }

    var secondsLeft: Double { Swift.max(0, expectedTotal - done) }

    mutating func modelLoaded() { loaded = true }

    mutating func reading(part i: Int, done tokens: Int) {
        if i != index { spentOnTries = 0 }
        index = i; readNow = Swift.min(tokens, parts.indices.contains(i) ? parts[i].promptTokens : tokens); writtenNow = 0
    }

    mutating func writing(part i: Int, written tokens: Int) {
        index = i
        if parts.indices.contains(i) { readNow = parts[i].promptTokens }
        writtenNow = tokens
    }

    /// The part is done: what it actually wrote becomes its expectation.
    mutating func finished(part i: Int, written: Int) {
        guard i >= index else { return }   // already settled
        if parts.indices.contains(i) {
            parts[i].expectedAnswer = written
        }
        index = i + 1; readNow = 0; writtenNow = 0; spentOnTries = 0
    }

    /// A retry reads the part again: the first try's time is kept as spent
    /// and the part is expected to take that much longer.
    mutating func retrying(part i: Int) {
        guard parts.indices.contains(i) else { return }
        let first = Double(readNow) / readRate + Double(writtenNow) / writeRate
        spentOnTries += first
        parts[i].promptTokens += Int(first * readRate)
        readNow = 0; writtenNow = 0
    }

    // MARK: Measured rates, per model, kept across launches

    private static let key = "workMeter.rates.v1"

    struct Rates: Codable, Sendable {
        var read: Double
        var write: Double
        var load: Double
        /// Median answer length this model writes, for the expectation.
        var answer: Double
    }

    static func rates(for model: String) -> Rates? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: Rates].self, from: data) else { return nil }
        return all[model]
    }

    /// Blends a new measurement in (newer counts more).
    static func remember(model: String, read: Double, write: Double, load: Double, answer: Double) {
        var all: [String: Rates] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Rates].self, from: data) { all = decoded }
        func blend(_ old: Double?, _ new: Double) -> Double {
            guard new > 0, new.isFinite else { return old ?? 0 }
            guard let old, old > 0 else { return new }
            return old * 0.4 + new * 0.6
        }
        let old = all[model]
        all[model] = Rates(read: blend(old?.read, read), write: blend(old?.write, write),
                           load: blend(old?.load, load), answer: blend(old?.answer, answer))
        UserDefaults.standard.set(try? JSONEncoder().encode(all), forKey: key)
    }
}

/// The meter, shared with the model's callbacks (which run off the actor).
final class WorkMeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var meter: WorkMeter

    init(_ meter: WorkMeter) { self.meter = meter }

    func update(_ change: (inout WorkMeter) -> Void) -> (fraction: Double, secondsLeft: Double) {
        lock.lock(); defer { lock.unlock() }
        change(&meter)
        return (meter.fraction, meter.secondsLeft)
    }

    var snapshot: WorkMeter { lock.lock(); defer { lock.unlock() }; return meter }
}
