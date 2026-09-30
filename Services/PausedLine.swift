import Foundation

/// The line of his jobs while it is paused: the job that was running first,
/// then the ones that were waiting, in the order they were in.
///
/// Held apart from the pipeline's live line on purpose. While these are in
/// `waitingQueue` or `unfinishedJobs` the app treats work as outstanding — it
/// keeps the silent audio and the carry-on task alive and starts the next job
/// the moment one ends. Held here, nothing counts as outstanding, so both wind
/// down by themselves and nothing starts until he says so.
///
/// Plain values with no pipeline in them, so the rules can be tested alone.
struct PausedLine: Equatable {
    static let key = "pausedLine"

    private(set) var guids: [String]

    init(guids: [String] = []) { self.guids = guids }

    var isPaused: Bool { !guids.isEmpty }
    func contains(_ guid: String) -> Bool { guids.contains(guid) }

    /// The running job goes first, then the line as it stood. Anything already
    /// held keeps its place ahead of them.
    mutating func hold(running: String, waiting: [String]) {
        var next = guids
        for guid in [running] + waiting where !next.contains(guid) { next.append(guid) }
        guids = next
    }

    /// Everything held, in order, and the line is no longer paused.
    mutating func release() -> [String] {
        defer { guids = [] }
        return guids
    }

    /// One job he stopped instead of resuming.
    mutating func drop(_ guid: String) {
        guids.removeAll { $0 == guid }
    }

    // MARK: Kept across launches

    static func load(from defaults: UserDefaults = .standard) -> PausedLine {
        PausedLine(guids: defaults.stringArray(forKey: key) ?? [])
    }

    func save(to defaults: UserDefaults = .standard) {
        if guids.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(guids, forKey: Self.key) }
    }
}
