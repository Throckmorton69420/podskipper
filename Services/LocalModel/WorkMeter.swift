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
    /// Pass 32: whether the rates came from an earlier run of this model on
    /// this phone. Until they do — or until this run has measured them
    /// itself — the time left is a guess and is shown as one.
    var ratesKnown: Bool
    private(set) var parts: [Part]
    private var index = 0
    private var readNow = 0
    private var writtenNow = 0
    /// Seconds already spent on the current part by an earlier try.
    private var spentOnTries = 0.0
    private var loaded = false
    /// Pass 32: this run's own reading and writing speed, measured as it goes.
    private var readClock: (at: Date, tokens: Int)?
    private var writeClock: (at: Date, tokens: Int)?
    private(set) var measuredLive = false

    init(parts: [Part], readRate: Double, writeRate: Double, loadSeconds: Double, ratesKnown: Bool = true) {
        self.parts = parts
        self.readRate = max(5, readRate)
        self.writeRate = max(1, writeRate)
        self.loadSeconds = max(0, loadSeconds)
        self.ratesKnown = ratesKnown
    }

    /// Pass 32 (his 7 Oct phone: the bar and the time left were still wrong,
    /// and sat "almost done" for minutes): an answer running past what this
    /// model usually writes used to be expected to end 8 tokens later, so the
    /// bar pinned near the end. Now it is expected to run half as long again
    /// (never past its cap), and the worst case — every answer to its cap —
    /// is known exactly and shown beside it.
    private func expectedAnswer(_ part: Part, written: Int?) -> Int {
        guard let written, written > part.expectedAnswer else { return Swift.min(part.answerCap, part.expectedAnswer) }
        return Swift.min(part.answerCap, Swift.max(written + 8, Int(Double(written) * 1.5)))
    }

    /// Seconds a part is expected to take, given what's known of it now.
    private func seconds(_ part: Part, written: Int?) -> Double {
        Double(part.promptTokens) / readRate + Double(expectedAnswer(part, written: written)) / writeRate
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

    /// Held below 97 % until the last answer is in: "almost done" is said
    /// only when it is. Never moves backwards (a bar that jumps back looks
    /// like flashing), so it is settled after every change.
    var fraction: Double { index >= parts.count ? 1 : shown }

    /// Pass 32: the bar measures against the expected time plus a fifth of
    /// the worst case, so the usual answer length doesn't carry it to the
    /// end; an answer that runs long still has bar left to fill.
    private var rawFraction: Double {
        let total = expectedTotal + 0.2 * Swift.max(0, done + worstSecondsLeft - expectedTotal)
        guard total > 0 else { return 0 }
        return Swift.min(0.97, done / total)
    }

    private var shown = 0.0

    private mutating func settle() { shown = Swift.max(shown, rawFraction) }

    var secondsLeft: Double { Swift.max(0, expectedTotal - done) }

    /// The most time left if every answer still to come runs to its cap.
    var worstSecondsLeft: Double {
        guard index < parts.count else { return 0 }
        var left = 0.0
        for (i, part) in parts.enumerated() where i >= index {
            let read = i == index ? Swift.max(0, part.promptTokens - readNow) : part.promptTokens
            let write = i == index ? Swift.max(0, part.answerCap - writtenNow) : part.answerCap
            left += Double(read) / readRate + Double(write) / writeRate
        }
        return left
    }

    /// Whether the time left rests on measured speeds and an answer of the
    /// usual length.
    var confident: Bool {
        guard ratesKnown || measuredLive else { return false }
        guard parts.indices.contains(index) else { return true }
        return writtenNow <= parts[index].expectedAnswer
    }

    mutating func modelLoaded() { loaded = true; settle() }

    /// `measured` false: the count is an estimate from the clock (Core AI
    /// says nothing while it reads), so it can't teach the meter a speed.
    mutating func reading(part i: Int, done tokens: Int, now: Date = .now, measured: Bool = true) {
        defer { settle() }
        if i != index { spentOnTries = 0; readClock = nil }
        index = i; readNow = Swift.min(tokens, parts.indices.contains(i) ? parts[i].promptTokens : tokens); writtenNow = 0
        guard measured else { return }
        let (clock, rate) = Self.measure(readClock, tokens: readNow, now: now, minimum: 96)
        readClock = clock
        if let rate { readRate = rate; measuredLive = true }
    }

    mutating func writing(part i: Int, written tokens: Int, now: Date = .now) {
        defer { settle() }
        if i != index { writeClock = nil }
        index = i
        if parts.indices.contains(i) { readNow = parts[i].promptTokens }
        writtenNow = tokens
        let (clock, rate) = Self.measure(writeClock, tokens: tokens, now: now, minimum: 12)
        writeClock = clock
        if let rate { writeRate = rate; measuredLive = true }
    }

    /// This run's own speed, once there is enough of it to go on (2 s and a
    /// few tokens since the clock started on this part).
    private static func measure(_ clock: (at: Date, tokens: Int)?, tokens: Int, now: Date,
                                minimum: Int) -> ((at: Date, tokens: Int)?, Double?) {
        guard let start = clock else { return ((now, tokens), nil) }
        let elapsed = now.timeIntervalSince(start.at)
        let moved = tokens - start.tokens
        guard elapsed >= 2, moved >= minimum else { return (start, nil) }
        let live = Double(moved) / elapsed
        guard live.isFinite, live > 0 else { return (start, nil) }
        return (start, live)
    }

    /// The part is done: what it actually wrote becomes its expectation.
    mutating func finished(part i: Int, written: Int) {
        guard i >= index else { return }   // already settled
        defer { settle() }
        if parts.indices.contains(i) {
            parts[i].expectedAnswer = written
            // The parts still to come are expected to write about as much.
            for j in parts.indices where j > i {
                parts[j].expectedAnswer = Swift.min(parts[j].answerCap, Swift.max(parts[j].expectedAnswer, written))
            }
        }
        index = i + 1; readNow = 0; writtenNow = 0; spentOnTries = 0; readClock = nil; writeClock = nil
    }

    /// A retry reads the part again: the first try's time is kept as spent
    /// and the part is expected to take that much longer.
    mutating func retrying(part i: Int) {
        guard parts.indices.contains(i) else { return }
        defer { settle() }
        let first = Double(readNow) / readRate + Double(writtenNow) / writeRate
        spentOnTries += first
        parts[i].promptTokens += Int(first * readRate)
        readNow = 0; writtenNow = 0; readClock = nil; writeClock = nil
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
        let reading = updateReading(change)
        return (reading.fraction, reading.secondsLeft)
    }

    /// Pass 32: everything the bar and the time-left line show.
    struct Reading: Sendable {
        var fraction: Double
        var secondsLeft: Double
        var worstSecondsLeft: Double
        var confident: Bool
        /// The speeds are measured (an earlier run, or this one), not guessed.
        var speedKnown: Bool
    }

    func updateReading(_ change: (inout WorkMeter) -> Void) -> Reading {
        lock.lock(); defer { lock.unlock() }
        change(&meter)
        return Reading(fraction: meter.fraction, secondsLeft: meter.secondsLeft,
                       worstSecondsLeft: meter.worstSecondsLeft, confident: meter.confident,
                       speedKnown: meter.ratesKnown || meter.measuredLive)
    }

    var snapshot: WorkMeter { lock.lock(); defer { lock.unlock() }; return meter }
}
