import Foundation
import MetricKit
import Observation

struct DiagnosticLogCleanupResult: Sendable {
    var removedEntries = 0
    var removedFiles = 0
    var freedBytes: Int64 = 0
    var failures: [String] = []
}

enum DiagnosticLogError: LocalizedError {
    case duplicateEntries, notRegularFile
    var errorDescription: String? {
        switch self {
        case .duplicateEntries: return "The saved log has repeated entry identities; its file was kept."
        case .notRegularFile: return "This log path is a directory or symbolic link; it was kept."
        }
    }
}

/// One ordered file writer. Invalidating skips snapshots still waiting in
/// the queue; an already-running write finishes before cleanup on that same
/// queue, so it cannot recreate a file after a successful cleanup.
final class DiagnosticLogFile: @unchecked Sendable {
    struct Operations: Sendable {
        var read: @Sendable (URL) throws -> Data?
        var write: @Sendable (Data, URL) throws -> Void
        var remove: @Sendable (URL) throws -> Void
        var exists: @Sendable (URL) -> Bool
        var size: @Sendable (URL) throws -> Int64
        var list: @Sendable (URL) throws -> [URL] = {
            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
        }
        var regularFile: @Sendable (URL) throws -> Bool = {
            let values = try $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        static let live = Operations(read: { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url)
        }, write: { data, url in try data.write(to: url, options: .atomic) }, remove: { url in
            try FileManager.default.removeItem(at: url)
        }, exists: {
            FileManager.default.fileExists(atPath: $0.path)
                || (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) != nil
        }, size: {
            // URL resource values can retain a pre-rewrite size. Read fresh
            // attributes after atomic replacement to report actual bytes.
            let attributes = try FileManager.default.attributesOfItem(atPath: $0.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        })
    }
    let url: URL
    let operations: Operations
    private let queue = DispatchQueue(label: "PodSkipper.diagnostics.writer", qos: .utility)
    private let lock = NSLock()
    private var generation = UUID()

    init(url: URL, operations: Operations = .live) { self.url = url; self.operations = operations }
    private func validateExistingFile() throws {
        if operations.exists(url), try !operations.regularFile(url) { throw DiagnosticLogError.notRegularFile }
    }
    func read() throws -> Data? { try validateExistingFile(); return try operations.read(url) }
    func invalidate() { lock.withLock { generation = UUID() } }
    func enqueue(_ encode: @escaping @Sendable () throws -> Data,
                 completion: @escaping @Sendable (String?) -> Void) {
        let token = lock.withLock { generation = UUID(); return generation }
        queue.async { [self] in
            guard lock.withLock({ generation == token }) else { return }
            do { try validateExistingFile(); try operations.write(try encode(), url); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
    func replace(_ encode: (@Sendable () throws -> Data)?) async -> DiagnosticLogCleanupResult {
        invalidate()
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                var result = DiagnosticLogCleanupResult()
                let existed = operations.exists(url)
                let before = (try? operations.size(url)) ?? 0
                do {
                    try validateExistingFile()
                    if let encode { try operations.write(try encode(), url) }
                    else if existed { try operations.remove(url); result.removedFiles = 1 }
                    let after = operations.exists(url) ? ((try? operations.size(url)) ?? before) : 0
                    result.freedBytes = max(0, before - after)
                } catch { result.failures = [url.lastPathComponent + ": " + error.localizedDescription] }
                continuation.resume(returning: result)
            }
        }
    }
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

/// Receives iOS's MetricKit reports and keeps the raw JSON on disk, newest 40.
///
/// Subscribed in `PodSkipperApp.init`, as early as possible: reports that
/// arrive before anyone is listening are only recoverable through
/// `pastPayloads`, which is read at the same moment. Each payload is written
/// to disk before anything else touches it — iOS delivers each one once.
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsSubscriber()
    private static let keep = 40

    struct SavedReport: Identifiable, Sendable {
        let url: URL
        let kind: String          // "daily" or "diagnostic"
        let date: Date
        var id: URL { url }
    }

    private let folder: URL
    private let operations: DiagnosticLogFile.Operations
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "PodSkipper.diagnostics.reports", qos: .utility)
    private let lock = NSLock()
    private var error: String?
    private var deletedBefore: Date?
    private var deletedNames: Set<String>
    private static let cutoffKey = "diagnostics.metrics.deletedBefore"
    private static let namesKey = "diagnostics.metrics.deletedNames"
    var storageError: String? { lock.withLock { error } }

    init(folder: URL = Diagnostics.folder, operations: DiagnosticLogFile.Operations = .live,
         defaults: UserDefaults = .standard) {
        self.folder = folder; self.operations = operations; self.defaults = defaults
        deletedBefore = defaults.object(forKey: Self.cutoffKey) as? Date
        deletedNames = Set(defaults.stringArray(forKey: Self.namesKey) ?? [])
        super.init()
    }

    func subscribe() {
        let manager = MXMetricManager.shared
        manager.add(self)
        // Anything delivered while the app wasn't listening. Saving twice is
        // harmless: the file name is the report's own time span.
        didReceive(manager.pastPayloads)
        didReceive(manager.pastDiagnosticPayloads)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            save(p.jsonRepresentation(), kind: "daily", stamp: p.timeStampEnd)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            save(p.jsonRepresentation(), kind: "diagnostic", stamp: p.timeStampEnd)
        }
    }

    func save(_ json: Data, kind: String, stamp: Date) {
        guard ["daily", "diagnostic"].contains(kind), stamp.timeIntervalSince1970.isFinite,
              stamp.timeIntervalSince1970 >= 0, stamp.timeIntervalSince1970 < Double(Int.max) / 2 else { return }
        let name = "\(kind)-\(Int(stamp.timeIntervalSince1970)).json"
        queue.async { [self] in
            // MetricKit re-delivers its past payloads on launch. A report
            // explicitly removed here must not be recreated by that replay.
            guard !deletedNames.contains(name), deletedBefore == nil || stamp >= deletedBefore! else { return }
            do {
                try operations.write(json, folder.appending(path: name))
                let all = try reportFiles()
                for old in all.dropFirst(Self.keep) { try operations.remove(old.url) }
                lock.withLock { error = nil }
            } catch { lock.withLock { self.error = error.localizedDescription } }
        }
    }

    func prune(before cutoff: Date?) async -> DiagnosticLogCleanupResult {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var result = DiagnosticLogCleanupResult()
                do {
                    let selected = try reportFiles().filter { cutoff == nil || $0.date < cutoff! }
                    let boundary = cutoff ?? .now
                    if deletedBefore == nil || boundary > deletedBefore! { deletedBefore = boundary }
                    deletedNames.formUnion(selected.map { $0.url.lastPathComponent })
                    // Record cleanup before unlinking, so queued/replayed
                    // payloads cannot undo even a partially interrupted clear.
                    defaults.set(deletedBefore, forKey: Self.cutoffKey)
                    defaults.set(Array(deletedNames).sorted(), forKey: Self.namesKey)
                    for report in selected {
                        let bytes = (try? operations.size(report.url)) ?? 0
                        do {
                            try operations.remove(report.url)
                            result.removedFiles += 1; result.freedBytes += bytes
                        } catch { result.failures.append(report.url.lastPathComponent + ": " + error.localizedDescription) }
                    }
                    lock.withLock { error = result.failures.isEmpty ? nil : result.failures.joined(separator: "; ") }
                } catch {
                    result.failures.append(error.localizedDescription)
                    lock.withLock { self.error = error.localizedDescription }
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Newest first.
    static func savedReports() -> [SavedReport] {
        (try? shared.reportFiles()) ?? []
    }

    func reportFiles() throws -> [SavedReport] {
        let files = try operations.list(folder)
        return files.compactMap { url -> SavedReport? in
            guard url.isFileURL, url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                  url.pathExtension == "json", (try? operations.regularFile(url)) == true else { return nil }
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count == 2, ["daily", "diagnostic"].contains(String(parts[0])),
                  let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0,
                  seconds < Double(Int.max) / 2 else { return nil }
            return SavedReport(url: url, kind: String(parts[0]),
                               date: Date(timeIntervalSince1970: seconds))
        }
        .sorted { $0.date > $1.date }
    }

    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}

/// One processed episode: how long each stage took on this phone.
struct ProcessingTiming: Codable, Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var show: String
    var episode: String
    /// Length of the audio, seconds.
    var audioSeconds: Double
    /// Nil when an existing transcript was reused (no transcription ran).
    var transcribeSeconds: Double?
    var analyzeSeconds: Double?
    var detectSeconds: Double
    var thermalAtStart: String
    var thermalAtEnd: String
    var lowPowerMode: Bool
    /// Plugged in (charging or full) when the job finished.
    var onPower: Bool
    var foreground: Bool
    var device: String
    var build: String
    /// The ad-free comparison for this job (pass 17), when one was tried.
    var adFree: AdFreeCopy.Outcome? = nil
    /// Which ad finder made the cuts, and whether this was a re-label of a
    /// stored transcript (no transcription, no download).
    var detectorVersion: Int? = nil
    var relabel: Bool? = nil
    /// Stage 0 of the research plan, as a check (pass 19): Apple's catalog
    /// gives each episode's clean length, so file length minus clean length
    /// is how many seconds were stitched in at download. Against that, the
    /// seconds the ad finder cut in total — if it cut much less, stitched
    /// ads were missed.
    var stitchedSeconds: Double? = nil
    var cutSeconds: Double? = nil
    /// Pass 23: questions not put to Apple's model because iOS was refusing
    /// it (locked, on battery) — a quick check, done on the fast reader.
    var skippedQuestions: Int? = nil
    /// Task 05: who found the ads ("model" or "reader"), how (a full read
    /// or a fast one while locked), and what it cost. Nil before task 05.
    var finder: ModelFinder.Run? = nil

    private func perHour(_ s: Double?) -> Double? {
        guard let s, audioSeconds > 60 else { return nil }
        return s / (audioSeconds / 3600)
    }
    /// Seconds of work per hour of audio.
    var transcribePerHour: Double? { perHour(transcribeSeconds) }
    var detectPerHour: Double? { perHour(detectSeconds) }
}

/// The timing log, newest first, last 200 jobs, as a small JSON file.
@MainActor @Observable
final class TimingLog {
    static let shared = TimingLog()
    private(set) var entries: [ProcessingTiming] = []
    private(set) var storageError: String?
    @ObservationIgnored private let file: DiagnosticLogFile
    @ObservationIgnored private var unreadable = false
    @ObservationIgnored private var pruning = false
    @ObservationIgnored private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var writeID = UUID()

    init(url: URL = Diagnostics.folder.appending(path: "timings.json"),
         operations: DiagnosticLogFile.Operations = .live, demo: Bool = DemoData.isEnabled) {
        file = DiagnosticLogFile(url: url, operations: operations)
        do {
            if let data = try file.read() {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode([ProcessingTiming].self, from: data)
                guard Set(decoded.map(\.id)).count == decoded.count else { throw DiagnosticLogError.duplicateEntries }
                entries = decoded
            }
        } catch { unreadable = true; storageError = "Could not read timings: " + error.localizedDescription }
        // Screenshot runs only: two made-up rows, in memory, never saved,
        // so the Diagnostics screen can be photographed with content.
        if demo && entries.isEmpty && !unreadable {
            let base = ProcessingTiming(date: .now, show: "The Long Way Round",
                episode: "Crossing the Pennines on a Tandem Nobody Asked For",
                audioSeconds: 5880, transcribeSeconds: 312, analyzeSeconds: 9, detectSeconds: 178,
                thermalAtStart: "nominal", thermalAtEnd: "fair", lowPowerMode: false,
                onPower: true, foreground: false, device: "demo", build: "demo",
                adFree: AdFreeCopy.Outcome(show: "The Long Way Round", episode: "demo", host: "demo",
                                           source: "simplecast", requests: 104, bytes: 632_842, seconds: 6.6,
                                           inserted: [InsertedSpan(start: 0, end: 98), InsertedSpan(start: 1516, end: 1781)]),
                detectorVersion: AdDetector.version)
            var second = base
            second.id = UUID()
            second.episode = "Quiet Hours, episode 12"; second.show = "Quiet Hours"
            second.transcribeSeconds = nil; second.detectSeconds = 95; second.audioSeconds = 3100
            second.onPower = false; second.foreground = true; second.thermalAtEnd = "nominal"
            entries = [base, second]
        }
    }

    func record(_ entry: ProcessingTiming) {
        entries.insert(entry, at: 0)
        if entries.count > 200 { entries.removeLast(entries.count - 200) }
        if !pruning && !unreadable { persist() }
    }

    func clear() {
        Task { _ = await prune(before: nil) }
    }

    /// Nil clears all current entries; a cutoff uses each job's report date.
    /// New records arriving during cleanup are buffered and saved afterward.
    func prune(before cutoff: Date?) async -> DiagnosticLogCleanupResult {
        while pruning { await withCheckedContinuation { cleanupWaiters.append($0) } }
        if unreadable && cutoff != nil {
            return DiagnosticLogCleanupResult(failures: [storageError ?? "The timings log could not be read; clear all logs to remove it."])
        }
        pruning = true
        writeID = UUID()
        let removed = Set(entries.filter { cutoff == nil || $0.date < cutoff! }.map(\.id))
        let retained = entries.filter { !removed.contains($0.id) }
        let encode: (@Sendable () throws -> Data)?
        if retained.isEmpty { encode = nil }
        else { encode = { try JSONEncoder.iso.encode(retained) } }
        var result = await file.replace(encode)
        if result.failures.isEmpty {
            entries.removeAll { removed.contains($0.id) }
            unreadable = false
            storageError = nil
            result.removedEntries = removed.count
        } else { storageError = result.failures.joined(separator: "; ") }
        pruning = false
        // On failure this keeps old rows; on success it includes only retained
        // rows plus anything recorded while the file operation was running.
        if !unreadable && (!entries.isEmpty || !result.failures.isEmpty) { persist() }
        let waiting = cleanupWaiters; cleanupWaiters = []
        for waiter in waiting { waiter.resume() }
        await file.flush()
        return result
    }

    private func persist() {
        let snapshot = entries, token = UUID()
        writeID = token
        file.enqueue({ try JSONEncoder.iso.encode(snapshot) }) { [weak self] error in
            Task { @MainActor in
                guard let self, self.writeID == token else { return }
                self.storageError = error
            }
        }
    }

    func flush() async { await file.flush() }

    /// Median seconds of work per hour of audio, over jobs that measured it.
    func median(_ value: KeyPath<ProcessingTiming, Double?>) -> Double? {
        let xs = entries.compactMap { $0[keyPath: value] }.sorted()
        guard !xs.isEmpty else { return nil }
        return xs[xs.count / 2]
    }
}
