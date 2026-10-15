import Foundation

/// How a model read behaves when the phone is warm (pass 29, his 5 Oct test).
///
/// Before: at "serious" the read stopped and waited for the phone to cool,
/// with no limit. On his phone "serious" lasted the whole session, so the job
/// sat on "Waiting for iPhone to cool" holding the model, the shared heavy-work
/// slot and the line behind it, and every other job and model test waited too.
///
/// Apple's guidance for `ProcessInfo.ThermalState`: at serious, reduce work;
/// at critical, stop. So now:
/// - nominal / fair: read at full pace.
/// - serious: keep reading, with a short rest between parts so the chip cools
///   a little each time. Slower, but it finishes.
/// - critical: pause, up to `criticalLimit`. Still critical after that, the
///   model read gives up for now (`TooHot`); the reader's cuts are saved and
///   the model reads the episode again later. Nothing waits forever.
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
        if current == .serious || current == .critical { beginCooling() }
        defer { endCooling() }
        switch current {
        case .critical:
            let started = Date()
            lock.withLock { _tooHot = true; _restUntil = nil }
            status("Paused: iPhone is too hot · carries on when it cools")
            while state == .critical {
                try Task.checkCancellation()
                if Date().timeIntervalSince(started) > criticalLimit { throw TooHot() }
                JobHeartbeat.shared.beat()
                status("Paused: iPhone is too hot · \(clock(Date().timeIntervalSince(started))) so far · carries on when it cools")
                try await sleep(.seconds(1))
            }
            lock.withLock { _tooHot = false }
            if state == .serious { try await rest(status: status, sleep: sleep) }
        case .serious:
            try await rest(status: status, sleep: sleep)
        default:
            break
        }
        try Task.checkCancellation()
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
