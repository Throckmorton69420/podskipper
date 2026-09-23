import Foundation
import CryptoKit

/// The answers the language model has given for one episode so far, kept on
/// disk until its ads are saved.
///
/// Finding ads is a few hundred short questions. If iOS stops the app half
/// way — the screen locked and the background time ran out, the phone got
/// hot — the job starts again later, and without this it asked every
/// question again: the same minutes of work, the same battery, twice. The
/// answers are the same whenever they are asked (greedy decoding), so the
/// ones already given are simply reused. Deleted once the episode is done.
final class DetectionCheckpoint: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var answers: [String: String]
    private var unsaved = 0

    init(guid: String) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DetectionCheckpoints", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent(Self.digest(guid) + ".json")
        answers = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    /// How many answers were already there when the job started.
    var reused: Int { lock.withLock { answers.count } }

    /// The pair `AdDetector.replyCache` takes.
    var cache: (get: (String) -> String?, set: (String, String) -> Void) {
        (get: { [self] key in lock.withLock { answers[Self.digest(key)] } },
         set: { [self] key, value in
             let flush: Bool = lock.withLock {
                 answers[Self.digest(key)] = value
                 unsaved += 1
                 return unsaved >= 8
             }
             if flush { save() }
         })
    }

    func save() {
        let data: Data? = lock.withLock {
            unsaved = 0
            return try? JSONEncoder().encode(answers)
        }
        try? data?.write(to: url, options: .atomic)
    }

    /// The episode's ads are saved; the answers are no longer needed.
    func discard() {
        lock.withLock { answers = [:]; unsaved = 0 }
        try? FileManager.default.removeItem(at: url)
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
