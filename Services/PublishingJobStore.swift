import Foundation
import Observation

/// Publishing uses the same stable episode GUID as processing. SwiftData IDs
/// are deliberately absent: restoring a library can change those IDs.
struct PublishingJob: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, offline, findingAds, publishing, done, failed, cancelled
        var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
        var isActive: Bool { self == .offline || self == .findingAds || self == .publishing }
    }
    var id = UUID()
    var guid: String
    var title: String
    var showTitle: String
    var order: Int
    var status: Status = .queued
    var attemptID: UUID?
    var attempts = 0
    var reason: String?
    var updatedAt = Date.now
}

/// Additive archive, written before a request becomes eligible to run. A
/// corrupt or newer archive is preserved, and blocks work instead of silently
/// replacing its queue. No durable publishing queue existed before version 1.
@MainActor
@Observable
final class PublishingJobStore {
    static let shared: PublishingJobStore = {
        let file = DemoData.isEnabled
            ? URL.temporaryDirectory.appending(path: "demo-publishing-\(UUID().uuidString).json")
            : URL.applicationSupportDirectory.appending(path: "Publishing/jobs-v1.json")
        return PublishingJobStore(file: file)
    }()

    private struct Archive: Codable { var version = 1; var jobs: [PublishingJob] }
    private(set) var records: [PublishingJob] = []
    private(set) var storageError: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var canWrite = true

    init(file: URL) {
        self.file = file
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard archive.version == 1,
                  Set(archive.jobs.map(\.guid)).count == archive.jobs.count,
                  Set(archive.jobs.map(\.id)).count == archive.jobs.count,
                  archive.jobs.allSatisfy({ $0.order >= 0 && $0.order <= Int.max - archive.jobs.count - 1 }) else {
                canWrite = false
                storageError = "Publishing history uses an unsupported format. Its file is preserved."
                return
            }
            records = archive.jobs.sorted { ($0.order, $0.guid) < ($1.order, $1.guid) }
            var restored = records
            for index in restored.indices where restored[index].status.isActive {
                restored[index].status = .queued
                restored[index].attemptID = nil
                restored[index].reason = "Resuming publishing after the app closed"
            }
            if restored != records { _ = save(restored) }
        } catch {
            canWrite = false
            storageError = "Publishing history could not be read. Its file is preserved."
        }
    }

    var pending: [PublishingJob] { records.filter { !$0.status.isFinished } }
    func record(_ id: UUID) -> PublishingJob? { records.first { $0.id == id } }

    @discardableResult
    func enqueue(_ requests: [(guid: String, title: String, showTitle: String)], allowRetry: Bool = true) -> Int {
        guard canWrite else { return 0 }
        var next = records
        // Order is relative, not an ever-growing sequence number. Compact it
        // without changing positions before appending, even for old archives
        // with large but valid ranks.
        for index in next.indices { next[index].order = index }
        var busy = Set(next.filter { !$0.status.isFinished }.map(\.guid))
        var order = next.count
        var count = 0
        for request in requests where busy.insert(request.guid).inserted {
            if !allowRetry, let existing = next.first(where: { $0.guid == request.guid }),
               existing.status == .cancelled || existing.status == .failed { continue }
            var job = PublishingJob(guid: request.guid, title: request.title,
                                    showTitle: request.showTitle, order: order)
            if let index = next.firstIndex(where: { $0.guid == request.guid }) {
                // Keep the record's identity, invalidate any previous attempt.
                job.id = next[index].id
                next.remove(at: index)
            }
            next.append(job); order += 1; count += 1
        }
        guard count > 0 else { return 0 }
        return save(next) ? count : 0
    }

    func begin(_ id: UUID) -> UUID? {
        guard let job = record(id), job.status == .queued else { return nil }
        let token = UUID()
        return update(id) { $0.attemptID = token; $0.attempts += 1; $0.reason = nil } ? token : nil
    }

    func isCurrent(_ id: UUID, token: UUID) -> Bool {
        guard let job = record(id) else { return false }
        return job.attemptID == token && !job.status.isFinished
    }

    @discardableResult
    func transition(_ id: UUID, token: UUID, status: PublishingJob.Status, reason: String? = nil) -> Bool {
        guard isCurrent(id, token: token) else { return false }
        return update(id) { $0.status = status; $0.reason = reason }
    }

    @discardableResult
    func cancel(_ id: UUID) -> Bool {
        guard let job = record(id), !job.status.isFinished else { return false }
        return update(id) { $0.status = .cancelled; $0.attemptID = nil; $0.reason = "Publishing cancelled by you" }
    }

    func interrupt(_ id: UUID, token: UUID) {
        guard isCurrent(id, token: token) else { return }
        _ = update(id) { $0.status = .queued; $0.attemptID = nil; $0.reason = "Publishing interrupted; ready to resume" }
    }

    func reorderWaiting(_ ids: [UUID]) {
        let waiting = records.filter { $0.status == .queued }
        guard Set(ids) == Set(waiting.map(\.id)), ids.count == waiting.count else { return }
        var next = records.filter { $0.status != .queued }
        for index in next.indices { next[index].order = index }
        var order = next.count
        for id in ids {
            guard var job = waiting.first(where: { $0.id == id }) else { return }
            job.order = order; order += 1; next.append(job)
        }
        _ = save(next.sorted { ($0.order, $0.guid) < ($1.order, $1.guid) })
    }

    func remove(_ id: UUID) {
        guard let job = record(id), job.status == .queued || job.status.isFinished else { return }
        _ = save(records.filter { $0.id != id })
    }
    func clearFinished() { _ = save(records.filter { !$0.status.isFinished }) }

    @discardableResult
    private func update(_ id: UUID, mutation: (inout PublishingJob) -> Void) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return false }
        var next = records; mutation(&next[index]); next[index].updatedAt = .now
        return save(next)
    }
    @discardableResult
    private func save(_ next: [PublishingJob]) -> Bool {
        guard canWrite else { return false }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Archive(jobs: next)).write(to: file, options: .atomic)
            records = next; storageError = nil
            return true
        } catch {
            storageError = "Couldn't save publishing history: " + error.localizedDescription
            return false
        }
    }
}
