import Foundation
import Network
import Observation
import os

/// Downloads the on-device ad model and keeps track of it.
///
/// The model is too big for the IPA (GitHub release files stop at 2 GB), so
/// the app fetches it once from Hugging Face. A background `URLSession`
/// keeps going while the phone is locked or the app is suspended, one file at
/// a time, resuming where it stopped. Wi-Fi only unless "Allow cellular" is
/// on. Files live in Application Support/Models/<repo>/, excluded from
/// iCloud backup and from the app's own backups (`BackupService`).
@MainActor
@Observable
final class ModelStore: NSObject {
    static let shared = ModelStore()

    /// The folder in Application Support. Read by `BackupService` too.
    nonisolated static let folderName = "Models"
    nonisolated static let sessionIdentifier =
        (Bundle.main.bundleIdentifier ?? "PodSkipper") + ".localmodel"

    enum Phase: Equatable {
        case notDownloaded
        case listing
        case downloading(done: Int64, total: Int64, bytesPerSecond: Double)
        /// Stopped for a reason he can act on, in words.
        case paused(String)
        case ready(sizeOnDisk: Int64)
        case failed(String)
    }

    private(set) var phase: Phase = .notDownloaded
    private(set) var selected: LocalModelSpec
    /// Another model left on disk after switching, so it can be deleted.
    private(set) var otherOnDisk: (spec: LocalModelSpec, bytes: Int64)?

    var allowCellular: Bool {
        didSet {
            UserDefaults.standard.set(allowCellular, forKey: Keys.cellular)
            networkRuleChanged()
        }
    }

    var isReady: Bool { if case .ready = phase { return true } else { return false } }

    /// A word or two for the Settings row.
    var shortStatus: String {
        switch phase {
        case .notDownloaded: return "Not downloaded"
        case .listing: return "Starting"
        case .downloading(let done, let total, _):
            return total > 0 ? "Downloading \(Int(Double(done) / Double(total) * 100))%" : "Downloading"
        case .paused: return "Paused"
        case .ready: return "Ready"
        case .failed: return "Needs attention"
        }
    }

    /// Whether any of the selected model's files are on the phone.
    var hasFiles: Bool { FileManager.default.fileExists(atPath: Self.folder(for: selected).path) }

    private enum Keys {
        static let selected = "localModel.selected"
        static let cellular = "localModel.allowCellular"
        static let autoStarted = "localModel.autoStarted"
        static let userPaused = "localModel.userPaused"
    }

    // MARK: Internals

    @ObservationIgnored private var session: URLSession!
    @ObservationIgnored private var currentTask: URLSessionDownloadTask?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var onWiFi = false
    @ObservationIgnored private var onAnyNetwork = false
    @ObservationIgnored private var running = false
    /// A download was asked for (at launch or by a tap) and isn't finished,
    /// so a returning connection should pick it up.
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var retries = 0
    @ObservationIgnored private var manifest: Manifest?
    /// Bytes of files already complete, plus the current file's bytes.
    @ObservationIgnored private var completedBytes: Int64 = 0
    @ObservationIgnored private var speedSamples: [(time: Date, bytes: Int64)] = []
    @ObservationIgnored private var lastPublished = Date.distantPast
    @ObservationIgnored private var backgroundEventsDone: (() -> Void)?
    @ObservationIgnored private var backgroundEventsArrived = false

    private var userPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.userPaused) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.userPaused) }
    }

    private override init() {
        selected = LocalModelSpec.named(UserDefaults.standard.string(forKey: Keys.selected))
        allowCellular = UserDefaults.standard.bool(forKey: Keys.cellular)
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Cellular is decided per request, so switching "Allow cellular"
        // doesn't need a new session.
        config.allowsCellularAccess = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let any = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(wifi: wifi, any: any) }
        }
        monitor.start(queue: DispatchQueue(label: "PodSkipper.localmodel.network", qos: .utility))
        refreshState()
    }

    // MARK: Folders

    nonisolated static var root: URL {
        URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    nonisolated static func folder(for spec: LocalModelSpec) -> URL {
        root.appending(path: spec.id, directoryHint: .isDirectory)
    }

    /// The folder `LocalJudge` loads from, when every file is there.
    var readyFolder: URL? { isReady ? Self.folder(for: selected) : nil }

    // MARK: What he can do

    /// Called once per launch. The first launch after this update starts the
    /// download by itself on Wi-Fi; after that, an unfinished download he
    /// didn't pause carries on.
    func startAtLaunch() {
        guard !isReady else { return }
        // "First launch" lasts until the download has really begun, so a
        // first launch away from Wi-Fi still counts.
        let first = !UserDefaults.standard.bool(forKey: Keys.autoStarted)
        guard first || (!userPaused && Self.hasPartialFiles(for: selected)) else { return }
        if let refusal = Self.memoryRefusal(for: selected) { phase = .failed(refusal); return }
        if first { userPaused = false }
        wanted = true
        Task { await run() }
    }

    func download() {
        // The experimental model is refused before gigabytes are spent on it.
        if let refusal = Self.memoryRefusal(for: selected) {
            phase = .failed(refusal)
            return
        }
        userPaused = false
        retries = 0
        wanted = true
        Task { await run() }
    }

    func pause() {
        userPaused = true
        wanted = false
        if let task = currentTask {
            task.cancel(byProducingResumeData: { data in
                Task { @MainActor in self.saveResumeData(data) }
            })
        }
        currentTask = nil
        running = false
        phase = .paused("Paused.")
    }

    /// Removes the selected model's files and frees the space.
    func delete() {
        pause()
        try? FileManager.default.removeItem(at: Self.folder(for: selected))
        manifest = nil
        userPaused = false
        wanted = false
        refreshState()
    }

    func deleteOther() {
        guard let other = otherOnDisk else { return }
        try? FileManager.default.removeItem(at: Self.folder(for: other.spec))
        refreshState()
    }

    func select(_ spec: LocalModelSpec) {
        guard spec != selected else { return }
        if currentTask != nil { pause() }
        selected = spec
        UserDefaults.standard.set(spec.id, forKey: Keys.selected)
        manifest = nil
        userPaused = false
        wanted = false
        refreshState()
    }

    /// For SwiftUI's `.backgroundTask(.urlSession(...))`: iOS relaunched the
    /// app because background downloads finished. The session already exists
    /// (it was made at launch); wait for it to hand over its events.
    func handleBackgroundEvents() async {
        if backgroundEventsArrived { backgroundEventsArrived = false; return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            backgroundEventsDone = { done.resume() }
        }
    }

    // MARK: State

    private func refreshState() {
        let fm = FileManager.default
        let other = LocalModelSpec.all.first { $0 != selected && fm.fileExists(atPath: Self.folder(for: $0).path) }
        otherOnDisk = other.map { ($0, Self.bytesOnDisk(Self.folder(for: $0))) }

        if let saved = manifest ?? Self.loadManifest(for: selected) {
            manifest = saved
            if saved.files.allSatisfy({ Self.isComplete($0, spec: selected) }) {
                phase = .ready(sizeOnDisk: Self.bytesOnDisk(Self.folder(for: selected)))
                return
            }
            let done = saved.files.reduce(Int64(0)) { $0 + Self.localSize($1, spec: selected) }
            phase = userPaused ? .paused("Paused.") : .downloading(done: done, total: saved.total, bytesPerSecond: 0)
            if !userPaused, !running, currentTask == nil { phase = .paused("Tap Download to continue.") }
            return
        }
        phase = .notDownloaded
    }

    private func pathChanged(wifi: Bool, any: Bool) {
        let wasAllowed = networkAllowed
        onWiFi = wifi
        onAnyNetwork = any
        if !wasAllowed, networkAllowed, wanted, !userPaused, !isReady {
            Task { await run() }
        } else if wasAllowed, !networkAllowed, let task = currentTask {
            task.cancel(byProducingResumeData: { data in Task { @MainActor in self.saveResumeData(data) } })
            currentTask = nil
            running = false
            phase = .paused(waitingReason)
        }
    }

    private var networkAllowed: Bool { onWiFi || (allowCellular && onAnyNetwork) }

    private var waitingReason: String {
        onAnyNetwork && !allowCellular ? "Waiting for Wi-Fi." : "Waiting for a connection."
    }

    private func networkRuleChanged() {
        // A running file restarts under the new rule, from where it got to.
        if let task = currentTask {
            task.cancel(byProducingResumeData: { data in
                Task { @MainActor in
                    self.saveResumeData(data)
                    self.currentTask = nil
                    self.running = false
                    await self.run()
                }
            })
        } else if wanted, !userPaused, !isReady, networkAllowed {
            Task { await run() }
        }
    }

    // MARK: The download loop

    private func run() async {
        guard !running, currentTask == nil else { return }
        running = true
        defer { running = false }
        let spec = selected

        // A file an earlier launch started may still be downloading in the
        // background; carry on with that one rather than start it twice.
        if let existing = await session.allTasks.compactMap({ $0 as? URLSessionDownloadTask })
            .first(where: { $0.state == .running || $0.state == .suspended }) {
            if existing.state == .suspended { existing.resume() }
            currentTask = existing
            if let manifest {
                completedBytes = manifest.files.filter { Self.isComplete($0, spec: spec) }.reduce(0) { $0 + $1.size }
                phase = .downloading(done: completedBytes, total: manifest.total, bytesPerSecond: 0)
            }
            return
        }

        guard networkAllowed else {
            phase = .paused(waitingReason)
            return
        }

        // 1. What to fetch: the repository's file list at the pinned commit.
        if manifest == nil {
            phase = .listing
            do {
                manifest = try await Self.fetchManifest(for: spec)
                if let manifest { Self.saveManifest(manifest, for: spec) }
                UserDefaults.standard.set(true, forKey: Keys.autoStarted)
            } catch {
                phase = NetworkStatus.isConnectivity(error)
                    ? .paused(waitingReason)
                    : .failed("Couldn't get the model's file list: \(error.localizedDescription)")
                return
            }
        }
        guard let manifest, spec == selected else { return }

        // 2. Room for it.
        let remaining = manifest.files.reduce(Int64(0)) { sum, file in
            sum + max(0, file.size - Self.localSize(file, spec: spec))
        }
        let free = (try? URL.applicationSupportDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? Int64.max
        if remaining + 500_000_000 > free {
            phase = .failed("Not enough free space: it needs \(Self.bytes(remaining + 500_000_000)) and \(Self.bytes(free)) is free.")
            return
        }

        // 3. The next file not yet complete.
        guard let file = manifest.files.first(where: { !Self.isComplete($0, spec: spec) }) else {
            try? Self.excludeFromBackup(Self.root)
            wanted = false
            refreshState()
            return
        }
        completedBytes = manifest.files.filter { Self.isComplete($0, spec: spec) }.reduce(0) { $0 + $1.size }
        speedSamples = []
        phase = .downloading(done: completedBytes, total: manifest.total, bytesPerSecond: 0)

        let task: URLSessionDownloadTask
        if let data = Self.resumeData(for: file, spec: spec) {
            task = session.downloadTask(withResumeData: data)
        } else {
            var request = URLRequest(url: Self.downloadURL(file, spec: spec, revision: manifest.revision))
            request.allowsCellularAccess = allowCellular
            task = session.downloadTask(with: request)
        }
        Self.clearResumeData(for: file, spec: spec)
        task.taskDescription = TaskTag(repo: spec.id, path: file.path, size: file.size).encoded
        currentTask = task
        task.resume()
    }

    fileprivate func progressed(written: Int64) {
        guard let manifest else { return }
        let done = completedBytes + written
        let now = Date.now
        speedSamples.append((now, done))
        speedSamples.removeAll { now.timeIntervalSince($0.time) > 5 }
        // The delegate reports many times a second; the screen needs two.
        guard now.timeIntervalSince(lastPublished) >= 0.5 else { return }
        lastPublished = now
        var speed = 0.0
        if let first = speedSamples.first, now.timeIntervalSince(first.time) > 0.5 {
            speed = Double(done - first.bytes) / now.timeIntervalSince(first.time)
        }
        phase = .downloading(done: done, total: manifest.total, bytesPerSecond: max(0, speed))
    }

    fileprivate func fileFinished(error: String?, taskID: Int) {
        guard currentTask == nil || currentTask?.taskIdentifier == taskID else { return }
        currentTask = nil
        if let error {
            phase = .failed(error)
            return
        }
        retries = 0
        Task { await run() }
    }

    fileprivate func taskFailed(_ error: Error, resumeData: Data?, taskID: Int) {
        // Cancelled by this class (pause, network rule): it already handled the
        // state and the resume data. Cancelled by iOS (the app was closed from
        // the app switcher): keep the resume data for next time.
        if (error as NSError).code == NSURLErrorCancelled {
            if currentTask == nil { saveResumeData(resumeData) }
            return
        }
        guard currentTask == nil || currentTask?.taskIdentifier == taskID else { return }
        currentTask = nil
        saveResumeData(resumeData)
        if userPaused { phase = .paused("Paused."); return }
        if NetworkStatus.isConnectivity(error) || !networkAllowed {
            phase = .paused(waitingReason)
            return
        }
        retries += 1
        if retries <= 3 {
            let wait = UInt64(retries * 10)
            phase = .paused("Connection trouble. Trying again in \(wait) seconds.")
            Task {
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                await self.run()
            }
        } else {
            phase = .failed("The download keeps failing: \(error.localizedDescription)")
        }
    }

    private func saveResumeData(_ data: Data?) {
        guard let data, let manifest,
              let file = manifest.files.first(where: { !Self.isComplete($0, spec: selected) }) else { return }
        try? FileManager.default.createDirectory(at: Self.folder(for: selected), withIntermediateDirectories: true)
        try? data.write(to: Self.resumeURL(for: file, spec: selected), options: .atomic)
    }

    fileprivate func backgroundEventsFinished() {
        if let done = backgroundEventsDone {
            backgroundEventsDone = nil
            done()
        } else {
            backgroundEventsArrived = true
        }
    }
}

// MARK: - URLSession delegate

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in self.progressed(written: totalBytesWritten) }
    }

    /// The file has to be moved before this returns: the system deletes it
    /// straight after.
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        guard let tag = TaskTag(downloadTask.taskDescription) else { return }
        let spec = LocalModelSpec.named(tag.repo)
        let destination = Self.folder(for: spec).appending(path: tag.path)
        let fm = FileManager.default
        var problem: String?
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            problem = "The server said \(http.statusCode) for \(tag.path)."
        } else {
            let size = (try? fm.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? -1
            if size != tag.size {
                problem = "\(tag.path) arrived the wrong size (\(size) bytes, expected \(tag.size)). Tap Download to try again."
            } else {
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: destination)
                    try fm.moveItem(at: location, to: destination)
                    try Self.excludeFromBackup(destination)
                } catch {
                    problem = "Couldn't save \(tag.path): \(error.localizedDescription)"
                }
            }
        }
        let id = downloadTask.taskIdentifier
        Task { @MainActor in self.fileFinished(error: problem, taskID: id) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let id = task.taskIdentifier
        Task { @MainActor in self.taskFailed(error, resumeData: resume, taskID: id) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.backgroundEventsFinished() }
    }
}

// MARK: - Files

extension ModelStore {
    struct Manifest: Codable, Sendable {
        struct File: Codable, Sendable, Hashable {
            var path: String
            var size: Int64
        }
        var repo: String
        var revision: String
        var files: [File]
        var total: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    /// Carried on each task, so the delegate knows where a file goes and how
    /// big it must be without asking the main actor.
    struct TaskTag: Codable {
        var repo: String
        var path: String
        var size: Int64

        var encoded: String {
            (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }

        init(repo: String, path: String, size: Int64) {
            self.repo = repo; self.path = path; self.size = size
        }

        init?(_ text: String?) {
            guard let data = text?.data(using: .utf8),
                  let tag = try? JSONDecoder().decode(TaskTag.self, from: data) else { return nil }
            self = tag
        }
    }

    /// The Hugging Face listing (`/api/models/<repo>` → `siblings`), at the
    /// pinned commit, keeping only what text generation reads.
    nonisolated static func fetchManifest(for spec: LocalModelSpec) async throws -> Manifest {
        let url = URL(string: "https://huggingface.co/api/models/\(spec.id)/revision/\(spec.revision)?blobs=true")!
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Hugging Face answered \(http.statusCode)."])
        }
        struct Listing: Decodable {
            struct Sibling: Decodable { var rfilename: String; var size: Int64? }
            var sha: String?
            var siblings: [Sibling]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let files = listing.siblings
            .filter { LocalModelSpec.isNeeded($0.rfilename) }
            .compactMap { sibling in sibling.size.map { Manifest.File(path: sibling.rfilename, size: $0) } }
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }),
              files.contains(where: { $0.path == "config.json" }),
              files.contains(where: { $0.path == "tokenizer.json" }) else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "The model's file list is missing files."])
        }
        // The weights first: iOS may hold back a download started while the
        // app is in the background, and only the small files are left by then.
        return Manifest(repo: spec.id, revision: listing.sha ?? spec.revision,
                        files: files.sorted { $0.size > $1.size })
    }

    nonisolated static func downloadURL(_ file: Manifest.File, spec: LocalModelSpec, revision: String) -> URL {
        URL(string: "https://huggingface.co/\(spec.id)/resolve/\(revision)/\(file.path)")!
    }

    nonisolated static func manifestURL(for spec: LocalModelSpec) -> URL {
        folder(for: spec).appending(path: ".download.json")
    }

    nonisolated static func loadManifest(for spec: LocalModelSpec) -> Manifest? {
        (try? Data(contentsOf: manifestURL(for: spec))).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }

    nonisolated static func saveManifest(_ manifest: Manifest, for spec: LocalModelSpec) {
        try? FileManager.default.createDirectory(at: folder(for: spec), withIntermediateDirectories: true)
        try? excludeFromBackup(root)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL(for: spec), options: .atomic)
        }
    }

    nonisolated static func resumeURL(for file: Manifest.File, spec: LocalModelSpec) -> URL {
        folder(for: spec).appending(path: "." + file.path + ".resume")
    }

    nonisolated static func resumeData(for file: Manifest.File, spec: LocalModelSpec) -> Data? {
        try? Data(contentsOf: resumeURL(for: file, spec: spec))
    }

    nonisolated static func clearResumeData(for file: Manifest.File, spec: LocalModelSpec) {
        try? FileManager.default.removeItem(at: resumeURL(for: file, spec: spec))
    }

    nonisolated static func localSize(_ file: Manifest.File, spec: LocalModelSpec) -> Int64 {
        let path = folder(for: spec).appending(path: file.path).path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    nonisolated static func isComplete(_ file: Manifest.File, spec: LocalModelSpec) -> Bool {
        localSize(file, spec: spec) == file.size
    }

    nonisolated static func hasPartialFiles(for spec: LocalModelSpec) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(for: spec).path)
    }

    nonisolated static func bytesOnDisk(_ folder: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        while let item = walker?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: keys)
            if values?.isDirectory != true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    nonisolated static func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Why an experimental model can't be used on this phone right now, or
    /// nil if it fits. `os_proc_available_memory()` is what iOS will let the
    /// app use before ending it.
    nonisolated static func memoryRefusal(for spec: LocalModelSpec) -> String? {
        guard spec.experimental else { return nil }
        let available = Int64(os_proc_available_memory())
        guard available < spec.memoryNeeded else { return nil }
        return "\(spec.name) won't fit in this iPhone's memory: it needs about \(gigabytes(spec.memoryNeeded)) free and only \(gigabytes(available)) is. Choose \(LocalModelSpec.preferred.name) instead."
    }

    nonisolated static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
