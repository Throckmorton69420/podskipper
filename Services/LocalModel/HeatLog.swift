import Foundation

/// Pass 40 (his 15 Oct request: "the exports don't say when the phone changed
/// state"). iOS tells an app only which of four heat states the phone is in —
/// nominal, fair, serious, critical — and posts
/// `ProcessInfo.thermalStateDidChangeNotification` when it changes. There is
/// no public temperature, clock speed, GPU load or throttling figure. So the
/// changes themselves, with their times, are what can be recorded: here, in
/// memory for each read's timeline, and as one line each in the background
/// log (exported in Diagnostics) so how long each state lasted can be read
/// afterwards. A change is rare (minutes apart), so observing costs nothing.
enum HeatLog {
    struct Change: Sendable, Equatable {
        var date: Date
        var state: ProcessInfo.ThermalState
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var changes: [Change] = []
    nonisolated(unsafe) private static var observer: NSObjectProtocol?
    static let limit = 400
    /// When observing began (this launch).
    nonisolated(unsafe) private(set) static var launchedAt = Date.now

    /// Once, at launch.
    static func start() {
        let first: Bool = lock.withLock {
            guard observer == nil else { return false }
            launchedAt = .now
            observer = NotificationCenter.default.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
                    record(ProcessInfo.processInfo.thermalState)
                }
            return true
        }
        if first { record(ProcessInfo.processInfo.thermalState, launch: true) }
    }

    /// Test hook and the observer's entry point.
    static func record(_ state: ProcessInfo.ThermalState, at date: Date = .now, launch: Bool = false) {
        let previous: Change? = lock.withLock {
            let last = changes.last
            if last?.state == state { return last }
            changes.append(Change(date: date, state: state))
            if changes.count > limit { changes.removeFirst(changes.count - limit) }
            return last
        }
        guard previous?.state != state || launch else { return }
        let line: String
        if launch {
            line = "Heat at launch: \(name(state))"
        } else if let previous {
            line = "Heat: \(name(previous.state)) → \(name(state)) after \(ThermalPacing.clock(date.timeIntervalSince(previous.date)))"
        } else {
            line = "Heat: \(name(state))"
        }
        Task { @MainActor in BackgroundLog.shared.note(line) }
    }

    static func reset() { lock.withLock { changes = [] } }

    /// The state at `date` (the last change at or before it), if known.
    static func state(at date: Date) -> ProcessInfo.ThermalState? {
        lock.withLock { changes.last { $0.date <= date }?.state }
    }

    /// What a read from `start` to `end` went through: the state it began
    /// in, then each change, with seconds from the start ("0 s fair",
    /// "+72 s serious"); and seconds spent in each state.
    static func timeline(from start: Date, to end: Date = .now) -> (lines: [String], seconds: [String: Double]) {
        let all = lock.withLock { changes }
        let opening = all.last { $0.date <= start }?.state ?? ProcessInfo.processInfo.thermalState
        var points = [Change(date: start, state: opening)]
        points += all.filter { $0.date > start && $0.date <= end }
        var seconds: [String: Double] = [:]
        for (i, point) in points.enumerated() {
            let until = i + 1 < points.count ? points[i + 1].date : end
            seconds[name(point.state), default: 0] += max(0, until.timeIntervalSince(point.date))
        }
        let lines = points.enumerated().map { i, point in
            (i == 0 ? "0 s " : "+\(Int(point.date.timeIntervalSince(start).rounded())) s ") + name(point.state)
        }
        return (lines, seconds)
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
