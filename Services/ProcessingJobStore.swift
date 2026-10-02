import Foundation
import Observation

struct ProcessingEngineSelection: Codable, Equatable, Sendable {
    var engine: String
    var modelID: String?
    var modelName: String?
    /// Missing in older records means enabled, preserving their chosen engine.
    var enabled: Bool? = nil
}

struct ProcessingJob: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable {
        case queued, running, interrupted, paused, stopped, failed, completed
    }
    var id = UUID()
    var guid: String
    var title = ""
    var origin = "user"
    var order: Int
    var status: Status
    var stage = "idle"
    var stageFraction = 0.0
    var completedStages: [String] = []
    /// Existing transcript and detection checkpoint files remain the source of
    /// stage data; this stable key links the record to those reusable files.
    var checkpointKey: String
    var selection: ProcessingEngineSelection?
    var reason: String?
    var retryAfter: Date?
    var updatedAt = Date.now
}

/// One durable record per episode, with additive migration from the old lists.
/// UI and legacy callers consume projections of these records. Transitions are
/// written atomically before returning; progress is flushed at most every 2 s.
@MainActor
@Observable
final class ProcessingJobStore {
    static let shared: ProcessingJobStore = {
        let file = DemoData.isEnabled
            ? URL.temporaryDirectory.appending(path: "demo-jobs-\(UUID().uuidString).json")
            : URL.applicationSupportDirectory.appending(path: "Processing/jobs-v1.json")
        let defaults = DemoData.isEnabled ? UserDefaults(suiteName: "ProcessingJobDemo." + UUID().uuidString)! : .standard
        return ProcessingJobStore(file: file, defaults: defaults)
    }()

    private struct Archive: Codable {
        var version = 1
        var jobs: [String: ProcessingJob]
    }
    private(set) var records: [String: ProcessingJob] = [:]
    private(set) var storageError: String?
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastProgressSave = Date.distantPast
    @ObservationIgnored private var canWrite = true

    init(file: URL, defaults: UserDefaults) {
        self.file = file; self.defaults = defaults
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard archive.version == 1 else {
                    canWrite = false
                    storageError = "Processing history uses a newer format. Its file is preserved; update PodSkipper before starting work."
                    return
                }
                records = archive.jobs
                // A running task cannot survive a process launch. Never call it
                // completed or convert a user's explicit pause into an OS pause.
                for guid in Array(records.keys) where records[guid]?.status == .running {
                    records[guid]?.status = .interrupted
                    records[guid]?.reason = "The app closed before this task finished"
                }
                persist()
            } catch {
                canWrite = false
                storageError = "Processing history could not be read. Its file is preserved; restore a backup before starting work."
            }
        } else {
            migrateLegacy()
            persist()
        }
    }

    func record(_ guid: String) -> ProcessingJob? { records[guid] }
    private var ordered: [ProcessingJob] { records.values.sorted { ($0.order, $0.guid) < ($1.order, $1.guid) } }
    var waiting: [String] { ordered.filter { $0.status == .queued }.map(\.guid) }
    var paused: [String] { ordered.filter { $0.status == .paused }.map(\.guid) }
    var stopped: Set<String> { Set(records.values.filter { $0.status == .stopped }.map(\.guid)) }
    var outstanding: [String] {
        ordered.filter { $0.origin == "user" && [.queued, .running, .interrupted].contains($0.status) }.map(\.guid)
    }

    func setWaitingOrder(_ guids: [String]) {
        guard canWrite else { return }
        var seen = Set<String>()
        let unique = guids.filter { seen.insert($0).inserted }
        for guid in waiting where !seen.contains(guid) {
            records[guid]?.status = .interrupted
        }
        let base = (records.values.filter { !seen.contains($0.guid) }.map(\.order).max() ?? -1) + 1
        for (offset, guid) in unique.enumerated() {
            var job = records[guid] ?? make(guid, status: .queued)
            // Stop is sticky. Only permitRetry, from an explicit user action,
            // makes this episode eligible for a new request.
            guard job.status != .stopped else { continue }
            if job.status == .completed { job.selection = nil; job.id = UUID() }
            job.status = .queued; job.origin = "user"; job.order = base + offset
            job.reason = nil; job.updatedAt = .now
            records[guid] = job
        }
        persist()
    }

    func setOutstanding(_ guid: String, _ on: Bool) {
        guard canWrite else { return }
        if on {
            if records[guid] == nil { records[guid] = make(guid, status: .interrupted) }
        } else if let status = records[guid]?.status, [.queued, .running, .interrupted].contains(status) {
            records[guid]?.status = .stopped
            records[guid]?.reason = "Removed from processing"
        }
        persist()
    }

    func permitRetry(_ guid: String) {
        guard canWrite, records[guid]?.status == .stopped || records[guid]?.status == .failed else { return }
        records[guid]?.status = .interrupted
        records[guid]?.id = UUID()
        records[guid]?.selection = nil
        records[guid]?.reason = nil
        persist()
    }

    func deferRetry(_ guid: String, until: Date?) {
        guard canWrite, records[guid] != nil else { return }
        records[guid]?.retryAfter = until
        persist()
    }

    func clearRetryDelays() {
        guard canWrite else { return }
        for guid in Array(records.keys) where records[guid]?.retryAfter != nil {
            records[guid]?.retryAfter = nil
        }
        persist()
    }

    func begin(_ guid: String, title: String, origin: String,
               selection: ProcessingEngineSelection) -> ProcessingJob? {
        guard canWrite, records[guid]?.status != .stopped, records[guid]?.status != .paused else { return nil }
        var job = records[guid] ?? make(guid, status: .running)
        if job.status == .completed { job.selection = nil }
        job.id = UUID() // new attempt: late callbacks from an older worker are rejected
        job.status = .running; job.title = title; job.origin = origin
        job.selection = job.selection ?? selection
        job.reason = nil; job.retryAfter = nil; job.updatedAt = .now
        records[guid] = job
        persist()
        return storageError == nil ? job : nil
    }

    func progress(_ guid: String, id: UUID, stage: String, fraction: Double) {
        guard canWrite, records[guid]?.id == id, records[guid]?.status == .running else { return }
        let old = records[guid]?.stage
        if let old, old != "idle", old != stage, records[guid]?.stageFraction == 1,
           records[guid]?.completedStages.contains(old) == false {
            records[guid]?.completedStages.append(old)
        }
        records[guid]?.stage = stage
        records[guid]?.stageFraction = min(1, max(0, fraction))
        records[guid]?.updatedAt = .now
        if old != stage || Date.now.timeIntervalSince(lastProgressSave) >= 2 {
            lastProgressSave = .now; persist()
        }
    }

    @discardableResult
    func finish(_ guid: String, id: UUID, status: ProcessingJob.Status, reason: String? = nil) -> Bool {
        guard canWrite, records[guid]?.id == id, records[guid]?.status == .running else { return false }
        records[guid]?.status = status; records[guid]?.reason = reason
        records[guid]?.updatedAt = .now
        if status == .completed { records[guid]?.stageFraction = 1 }
        persist()
        return true
    }

    func stop(_ guid: String) {
        guard canWrite else { return }
        var job = records[guid] ?? make(guid, status: .stopped)
        job.status = .stopped; job.reason = "Stopped by you"; job.updatedAt = .now
        records[guid] = job
        persist()
    }

    func replacePaused(_ guids: [String]) {
        guard canWrite else { return }
        let kept = Set(guids)
        for guid in paused where !kept.contains(guid) {
            records[guid]?.status = .interrupted
            records[guid]?.reason = "Resumed by you"
        }
        pause(guids)
    }

    func pause(_ guids: [String]) {
        guard canWrite else { return }
        let start = (records.values.map(\.order).max() ?? -1) + 1
        for (offset, guid) in guids.enumerated() {
            var job = records[guid] ?? make(guid, status: .paused)
            guard job.status != .stopped else { continue }
            job.status = .paused; job.order = start + offset
            job.reason = "Paused by you"; job.updatedAt = .now
            records[guid] = job
        }
        persist()
    }

    /// Explicit transcript cleanup invalidates cached stage projections without
    /// changing a user's pause/stop, queue position or captured engine.
    @discardableResult
    func invalidateTranscriptCheckpoint(_ guid: String, keepDownloadStage: Bool = true) -> Bool {
        guard canWrite else { return false }
        guard var job = records[guid] else { return true }
        guard job.status != .running else { return false }
        let previous = job
        job.id = UUID()
        job.completedStages = job.completedStages.filter { keepDownloadStage && $0 == "downloading" }
        job.stage = "idle"
        job.stageFraction = 0
        job.updatedAt = .now
        records[guid] = job
        persist()
        if storageError != nil {
            records[guid] = previous
            return false
        }
        return true
    }

    func flush() { persist() }

    private func make(_ guid: String, status: ProcessingJob.Status) -> ProcessingJob {
        ProcessingJob(guid: guid, order: (records.values.map(\.order).max() ?? -1) + 1,
                      status: status, checkpointKey: guid)
    }

    private func migrateLegacy() {
        let unfinished = defaults.stringArray(forKey: "unfinishedUserJobs") ?? []
        let held = defaults.stringArray(forKey: PausedLine.key) ?? []
        let stopped = defaults.stringArray(forKey: "stoppedByUser") ?? []
        for guid in unfinished where records[guid] == nil { records[guid] = make(guid, status: .interrupted) }
        // Explicit pause wins over unfinished; explicit stop wins over both.
        let heldStart = (records.values.map(\.order).max() ?? -1) + 1
        for (offset, guid) in held.enumerated() {
            var job = records[guid] ?? make(guid, status: .paused)
            job.status = .paused; job.order = heldStart + offset; job.reason = "Paused by you"
            records[guid] = job
        }
        for guid in stopped {
            var job = records[guid] ?? make(guid, status: .stopped)
            job.status = .stopped; job.reason = "Stopped by you"
            records[guid] = job
        }
    }

    private func persist() {
        guard canWrite else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Archive(jobs: records)).write(to: file, options: .atomic)
            storageError = nil
            // Compatibility projections are maintained until all clients and
            // older backup versions have moved to the record format.
            defaults.set(outstanding, forKey: "unfinishedUserJobs")
            defaults.set(paused, forKey: PausedLine.key)
            defaults.set(Array(stopped).sorted(), forKey: "stoppedByUser")
        } catch {
            storageError = "Couldn't save processing history: " + error.localizedDescription
        }
    }
}
