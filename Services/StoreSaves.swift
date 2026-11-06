import Foundation
import Observation
import SwiftData

/// Pass 58 (L21, and the standing rule that save failures are never
/// swallowed): the 92 places that saved with `try?` now save through
/// `saveOrReport()`. Behaviour is otherwise unchanged — a failed save on the
/// main context keeps its changes in memory and SwiftData tries again with
/// its next save — but the failure is no longer silent: it is written to the
/// background log (in every Diagnostics export) with where it happened and
/// the store's own words, and the Library shows a plain line while it lasts.
extension ModelContext {
    @discardableResult
    func saveOrReport(_ fileID: StaticString = #fileID, _ line: UInt = #line) -> Bool {
        do {
            try save()
            return true
        } catch {
            let place = "\(fileID):\(line)"
            let words = error.localizedDescription
            Task { @MainActor in StoreSaveProblems.shared.record(words, at: place) }
            return false
        }
    }
}

@MainActor
@Observable
final class StoreSaveProblems {
    static let shared = StoreSaveProblems()

    /// Failed saves since launch.
    private(set) var count = 0
    private(set) var lastAt: Date?

    /// One log line per place per ten minutes: a full disk fails every save,
    /// and the log keeps 1,500 lines.
    @ObservationIgnored private var lastLogged: [String: Date] = [:]
    @ObservationIgnored var now: () -> Date = { .now }

    /// Shown in the Library while a failure is recent.
    var isRecent: Bool { lastAt.map { now().timeIntervalSince($0) < 600 } ?? false }

    func record(_ words: String, at place: String) {
        count += 1
        lastAt = now()
        if let last = lastLogged[place], now().timeIntervalSince(last) < 600 { return }
        lastLogged[place] = now()
        BackgroundLog.shared.note("A change couldn't be saved (\(place)): \(words)")
    }
}
