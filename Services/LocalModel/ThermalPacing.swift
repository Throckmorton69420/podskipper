import Foundation

/// How a model read behaves when the phone is warm.
///
/// Pass 29 (his 5 Oct test): at "serious" the read used to stop and wait for
/// the phone to cool with no limit; "serious" lasted the whole session, so
/// nothing finished. It became a 20-second rest before every part.
///
/// Pass 40 (his 15 Oct request — "a sustainable running pace, not sprint,
/// stop, sprint"): the rest is gone by default. What the 20-second rests
/// measured on his iPhone 16 Pro (8839e72, per-part records): every part
/// after a rest still began at "serious", and reading speed after a rest
/// (64–117 tok/s) was no better than at "serious" without one; across his
/// three episodes they added 264 s to ~690 s of reading. iOS already slows a
/// hot chip itself (that is what "serious" means for speed); stopping on top
/// of that only adds time. The model's work per episode is fixed — the same
/// tokens must be read whatever the pace — so what lowers the heat a read
/// produces is reading fewer tokens (the shared prefix, no re-read on a
/// retry, no wasted answers), not pausing. So now:
/// - nominal / fair / serious: keep reading. iOS sets the pace.
/// - critical: pause (Apple: "reduce or stop all work"), between parts and
///   between the chunks of a part. It carries on once the phone has been out
///   of critical for `resumeTicks` seconds in a row, so a phone hovering at
///   the edge doesn't start and stop every second. Still critical after
///   `criticalLimit`, the model read gives up for now (`TooHot`); the
///   reader's cuts are saved and the model reads the episode again later.
/// - Comparison: Diagnostics › Speed can put back the old 20-second rest
///   (`Policy.restBetweenParts`), so the two can be measured on the same
///   episode on his phone. Each run records which one it used.
///
/// Every wait beats the job heartbeat so the "No progress" watchdog knows the
/// job is resting on purpose, and checks for cancellation every second so
/// Pause, Stop and Restart take effect at once.
enum ThermalPacing {
    struct TooHot: LocalizedError {
        var errorDescription: String? {
            "iPhone stayed too hot to run the ad model; the reader's cuts are kept and the model reads it again later"
        }
    }

    static let seriousRest: Duration = .seconds(20)
    nonisolated(unsafe) static var criticalLimit: TimeInterval = 5 * 60
    /// Seconds out of critical, in a row, before a paused read carries on.
    static let resumeTicks = 10

    enum Policy: String, CaseIterable, Sendable {
        /// Pass 40 default: read at the pace iOS allows; pause only when critical.
        case keepReading
        /// Before Pass 40: a 20-second rest before each part at serious.
        case restBetweenParts

        var label: String {
            switch self {
            case .keepReading: return "Keep reading"
            case .restBetweenParts: return "Rest 20 s before each part"
            }
        }
    }

    static let policyKey = "heat.policy"
    /// Test hook.
    nonisolated(unsafe) static var policyOverride: Policy?
    static var policy: Policy {
        policyOverride ?? UserDefaults.standard.string(forKey: policyKey).flatMap(Policy.init(rawValue:)) ?? .keepReading
    }

    /// Test hook: overrides the real thermal state.
    nonisolated(unsafe) static var stateOverride: ProcessInfo.ThermalState?

    static var state: ProcessInfo.ThermalState { stateOverride ?? ProcessInfo.processInfo.thermalState }

    /// Called before each part of a model read.
    // MARK: Pass 33 — waiting is not working

    /// His 9 Oct phone: while a test waited for the iPhone to cool, its bar
    /// ran forward. Progress and time left come from work done, and these
    /// say when no work is being done, so nothing counts a wait as work.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _coolingSince: Date?
    nonisolated(unsafe) private static var _cooledSeconds: Double = 0

    /// When the current cooling wait began, or nil while not waiting.
    static var coolingSince: Date? { lock.withLock { _coolingSince } }

    /// Seconds spent waiting to cool since the app started, including the
    /// wait under way: subtract two readings to get a run's waiting time.
    static func cooledSeconds(now: Date = .now) -> Double {
        lock.withLock { _cooledSeconds + (_coolingSince.map { now.timeIntervalSince($0) } ?? 0) }
    }

    private static func beginCooling() { lock.withLock { if _coolingSince == nil { _coolingSince = .now } } }
    private static func endCooling() {
        lock.withLock {
            if let since = _coolingSince { _cooledSeconds += Date.now.timeIntervalSince(since) }
            _coolingSince = nil
            _restUntil = nil
            _tooHot = false
        }
    }

    // MARK: Pass 39 — the wait, in words

    /// His 15 Oct request: when the read waits for the phone to cool, the
    /// activity bar and the steps say so and for how long, instead of
    /// showing the step as if it were working.
    nonisolated(unsafe) private static var _restUntil: Date?
    nonisolated(unsafe) private static var _tooHot = false

    struct Wait: Equatable {
        /// Waiting since.
        var since: Date
        /// A warm phone's rest between parts ends then; nil while too hot
        /// (it carries on when iOS says it has cooled).
        var resumesAt: Date?
        var tooHot: Bool
    }

    static var wait: Wait? {
        lock.withLock { _coolingSince.map { Wait(since: $0, resumesAt: _restUntil, tooHot: _tooHot) } }
    }

    /// "Waiting for iPhone to cool · 0:42 so far · carries on in 8 s".
    static func waitLine(now: Date = .now) -> String? {
        guard let wait else { return nil }
        var parts = [wait.tooHot ? "Paused: iPhone is too hot" : "Waiting for iPhone to cool",
                     clock(now.timeIntervalSince(wait.since)) + " so far"]
        if let resumes = wait.resumesAt, resumes > now {
            parts.append("carries on in \(Int(resumes.timeIntervalSince(now).rounded(.up))) s")
        } else if wait.tooHot {
            parts.append("carries on when it cools")
        }
        return parts.joined(separator: " · ")
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func beforePart(status: @escaping @Sendable (String) -> Void,
                           sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        try Task.checkCancellation()
        let current = state
        let rests = policy == .restBetweenParts
        if current == .critical || (current == .serious && rests) { beginCooling() }
        defer { endCooling() }
        switch current {
        case .critical:
            let started = Date()
            lock.withLock { _tooHot = true; _restUntil = nil }
            status("Paused: iPhone is too hot · carries on when it cools")
            var coolTicks = 0
            while coolTicks < resumeTicks {
                try Task.checkCancellation()
                if state == .critical {
                    coolTicks = 0
                    if Date().timeIntervalSince(started) > criticalLimit { throw TooHot() }
                } else {
                    coolTicks += 1
                }
                JobHeartbeat.shared.beat()
                status("Paused: iPhone is too hot · \(clock(Date().timeIntervalSince(started))) so far · carries on when it cools")
                try await sleep(.seconds(1))
            }
            lock.withLock { _tooHot = false }
            if state == .serious && rests { try await rest(status: status, sleep: sleep) }
        case .serious where rests:
            try await rest(status: status, sleep: sleep)
        default:
            break
        }
        try Task.checkCancellation()
    }

    /// Pass 40: called between the chunks of a part (prompt reading and
    /// answer writing run without returning to the read loop for up to a
    /// minute). Holds the work only while iOS says critical, with the same
    /// resume rule as `beforePart`; returns at once otherwise. Blocks the
    /// calling thread — it is the model's own, already busy for the whole
    /// part. Gives up holding after `criticalLimit`, so the next part's
    /// `beforePart` ends the read with `TooHot`.
    static func holdWhileCritical(sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        guard state == .critical, !Task.isCancelled else { return }
        beginCooling()
        lock.withLock { _tooHot = true; _restUntil = nil }
        defer { endCooling() }
        let started = Date()
        var coolTicks = 0
        while coolTicks < resumeTicks, !Task.isCancelled, Date().timeIntervalSince(started) <= criticalLimit {
            coolTicks = state == .critical ? 0 : coolTicks + 1
            JobHeartbeat.shared.beat()
            sleep(1)
        }
    }

    private static func rest(status: @escaping @Sendable (String) -> Void,
                             sleep: (Duration) async throws -> Void) async throws {
        let seconds = Int(seriousRest.components.seconds)
        lock.withLock { _restUntil = Date().addingTimeInterval(Double(seconds)) }
        for left in stride(from: seconds, to: 0, by: -1) {
            try Task.checkCancellation()
            // Cooled during the rest: no need to finish it.
            if state != .serious && state != .critical { return }
            status("Waiting for iPhone to cool · carries on in \(left) s")
            JobHeartbeat.shared.beat()
            try await sleep(.seconds(1))
        }
    }
}
