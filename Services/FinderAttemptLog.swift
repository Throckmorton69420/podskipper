import Foundation

/// Pass 30 (his question, 5 Oct): every time ads are found in an episode —
/// by the reader, Apple Intelligence, an MLX model or a Core AI model — the
/// attempt is kept with what it found, so the results export shows each
/// method side by side instead of only the latest cuts.
struct FinderAttempt: Codable, Identifiable, Sendable, Equatable {
    struct Part: Codable, Sendable, Equatable {
        var firstLine: Int
        var lastLine: Int
        var start: Double
        var end: Double
        var label: String
        var sponsor: String
        var confidence: Int
        var why: String
    }

    var id = UUID()
    var date: Date
    var guid: String
    var show: String
    var episode: String
    /// "PodSkipper reader", "Apple Intelligence", "MLX · Qwen3.5 4B",
    /// "Core AI · Qwen3 4B".
    var method: String
    var run: ModelFinder.Run
    var seconds: Double
    var audioSeconds: Double
    var foreground: Bool
    var thermalAtStart: String
    var thermalAtEnd: String
    var build: String
    /// The reader's cuts for this attempt (it always runs first).
    var readerCuts: [ModelFinder.StoredCut]
    /// What the model proposed, before the cut check (empty for the reader).
    var proposedCuts: [ModelFinder.StoredCut]
    /// The model's parts as it labelled them, including what it said to keep.
    var parts: [Part]
    /// What was saved on the episode by this attempt.
    var savedCuts: [ModelFinder.StoredCut]
    /// The start of the model's last answer, as written.
    var answerSample: String

    var savedSeconds: Double { savedCuts.reduce(0) { $0 + ($1.end - $1.start) } }
}

@MainActor
final class FinderAttemptLog {
    static let shared = FinderAttemptLog()
    static let limit = 150
    private(set) var entries: [FinderAttempt] = []
    private let file: DiagnosticLogFile

    init(url: URL = Diagnostics.folder.appending(path: "finder-attempts.json")) {
        file = DiagnosticLogFile(url: url, operations: .live)
        if let data = try? file.read() {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([FinderAttempt].self, from: data)) ?? []
        }
    }

    func record(_ attempt: FinderAttempt) {
        entries.insert(attempt, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        let snapshot = entries
        file.enqueue({ try JSONEncoder.iso.encode(snapshot) }) { _ in }
    }

    /// Newest first.
    func attempts(for guid: String) -> [FinderAttempt] { entries.filter { $0.guid == guid } }

    /// Nil clears everything; otherwise attempts older than the cutoff.
    func prune(before cutoff: Date?) async -> DiagnosticLogCleanupResult {
        let retained = entries.filter { cutoff != nil && $0.date >= cutoff! }
        let removed = entries.count - retained.count
        entries = retained
        var result: DiagnosticLogCleanupResult
        if retained.isEmpty {
            result = await file.replace(nil)
        } else {
            result = await file.replace({ try JSONEncoder.iso.encode(retained) })
        }
        if result.failures.isEmpty { result.removedEntries = removed }
        return result
    }

    func flush() async { await file.flush() }

    /// The attempts for one episode as plain JSON objects for the export.
    func exportRows(for guid: String) -> [Any] {
        attempts(for: guid).compactMap { attempt in
            guard let data = try? JSONEncoder.iso.encode(attempt) else { return nil }
            return try? JSONSerialization.jsonObject(with: data)
        }
    }
}
