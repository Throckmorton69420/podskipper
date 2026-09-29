import Foundation
import Network
import Observation
import os

/// Downloads the on-device ad model and keeps track of it.
///
/// The model is too big for the IPA (GitHub release files stop at 2 GB), so
/// the app fetches it once from Hugging Face. Background `URLSession`s keep
/// going while the phone is locked or the app is suspended, one file at a
/// time, resuming where they stopped. Files live in Application
/// Support/Models/<repo>/, excluded from iCloud backup and from the app's
/// own backups (`BackupService`).
///
/// Wi-Fi only unless "Allow cellular" is on. That is enforced by the
/// session, not by the app watching the network: there are two sessions, one
/// that may not use cellular at all, and a download moves between them when
/// the switch changes. (A resumed download keeps its original request, so a
/// per-request rule could not be taken back.)
///
/// Everything that touches the disk runs off the main thread; the main
/// actor only holds the state the screen shows.
@MainActor
@Observable
final class ModelStore: NSObject {
    static let shared = ModelStore()

    /// The folder in Application Support. Read by `BackupService` too.
    nonisolated static let folderName = "Models"
    nonisolated static let wifiSessionID = (Bundle.main.bundleIdentifier ?? "PodSkipper") + ".localmodel.wifi"
    nonisolated static let cellularSessionID = (Bundle.main.bundleIdentifier ?? "PodSkipper") + ".localmodel.cellular"

    enum Phase: Equatable {
        case notDownloaded
        case listing
        case downloading(done: Int64, total: Int64, bytesPerSecond: Double)
        /// Stopped for a reason he can act on, in words.
        case paused(String)
        case ready(sizeOnDisk: Int64)
        case failed(String)
    }

    struct OtherModel: Equatable, Sendable {
        var spec: LocalModelSpec
        var bytes: Int64
    }

    private(set) var phase: Phase = .notDownloaded
    private(set) var selected: LocalModelSpec
    /// Another model left on disk after switching, so it can be deleted.
    private(set) var otherOnDisk: OtherModel?
    /// Whether any of the selected model's files are on the phone.
    private(set) var hasFiles = false
    /// Said under the status when the phone had less free memory than the
    /// model needs while it reads.
    private(set) var memoryNote: String?

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

    private enum Keys {
        static let selected = "localModel.selected"
        static let cellular = "localModel.allowCellular"
        static let autoStarted = "localModel.autoStarted"
        static let userPaused = "localModel.userPaused"
    }

    // MARK: Internals

    @ObservationIgnored private var wifiSession: URLSession!
    @ObservationIgnored private var cellularSession: URLSession!
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
    /// Bytes of the files already complete.
    @ObservationIgnored private var completedBytes: Int64 = 0
    @ObservationIgnored private var speedSamples: [(time: Date, bytes: Int64)] = []
    @ObservationIgnored private var lastPublished = Date.distantPast
    @ObservationIgnored private var backgroundEventsDone: [String: () -> Void] = [:]
    @ObservationIgnored private var backgroundEventsArrived: Set<String> = []

    private var userPaused: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.userPaused) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.userPaused) }
    }

    private override init() {
        selected = LocalModelSpec.named(UserDefaults.standard.string(forKey: Keys.selected))
        allowCellular = UserDefaults.standard.bool(forKey: Keys.cellular)
        super.init()
        wifiSession = makeSession(Self.wifiSessionID, cellular: false)
        cellularSession = makeSession(Self.cellularSessionID, cellular: true)
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.status == .satisfied
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
            let any = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(wifi: wifi, any: any) }
        }
        monitor.start(queue: DispatchQueue(label: "PodSkipper.localmodel.network", qos: .utility))
        refreshState()
    }

    private func makeSession(_ identifier: String, cellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = cellular
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// The session the switch allows.
    private var session: URLSession { allowCellular ? cellularSession : wifiSession }

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

    /// Called once per launch, a few seconds after the first screen is up.
    /// The first launch after this update starts the download by itself on
    /// Wi-Fi; after that, an unfinished download he didn't pause carries on.
    func startAtLaunch() async {
        // What's on disk decides; read it (off the main thread) before choosing.
        let disk = await Self.readDisk(for: selected, manifest: manifest)
        apply(disk, spec: selected)
        guard !isReady else { return }
        // "First launch" lasts until the download has really begun, so a
        // first launch away from Wi-Fi still counts.
        let first = !UserDefaults.standard.bool(forKey: Keys.autoStarted)
        guard first || (!userPaused && disk.manifest != nil) else { return }
        guard checkMemoryBeforeDownload() else { return }
        if first { userPaused = false }
        wanted = true
        await run()
    }

    func download() {
        guard checkMemoryBeforeDownload() else { return }
        userPaused = false
        retries = 0
        wanted = true
        Task { await run() }
    }

    func pause() {
        userPaused = true
        wanted = false
        if let task = currentTask {
            Task { await Self.stopKeepingProgress(task) }
        }
        currentTask = nil
        running = false
        if case .ready = phase { return }
        phase = .paused("Paused.")
    }

    /// Removes the selected model's files and frees the space.
    func delete() {
        let folder = Self.folder(for: selected)
        let task = currentTask
        currentTask = nil
        wanted = false
        manifest = nil
        userPaused = false
        hasFiles = false
        memoryNote = nil
        phase = .notDownloaded
        Task.detached(priority: .utility) {
            // No resume data to keep: the files it would belong to go too.
            task?.cancel()
            try? FileManager.default.removeItem(at: folder)
            await ModelStore.shared.refreshState()
        }
    }

    func deleteOther() {
        guard let other = otherOnDisk else { return }
        otherOnDisk = nil
        let folder = Self.folder(for: other.spec)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
            await ModelStore.shared.refreshState()
        }
    }

    func select(_ spec: LocalModelSpec) {
        guard spec != selected else { return }
        if currentTask != nil { pause() }
        selected = spec
        UserDefaults.standard.set(spec.id, forKey: Keys.selected)
        manifest = nil
        userPaused = false
        wanted = false
        memoryNote = nil
        phase = .notDownloaded
        refreshState()
    }

    /// For SwiftUI's `.backgroundTask(.urlSession(...))`: iOS relaunched the
    /// app because a background download finished. The sessions are made
    /// with the store; wait for this one to hand over its events.
    func handleBackgroundEvents(_ identifier: String) async {
        if backgroundEventsArrived.remove(identifier) != nil { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            backgroundEventsDone[identifier] = { done.resume() }
        }
    }

    /// The memory check before downloading. The experimental model is
    /// refused before gigabytes are spent on it; for the others a short free
    /// moment isn't a reason to refuse, so it only says so.
    private func checkMemoryBeforeDownload() -> Bool {
        let available = Int64(os_proc_available_memory())
        let spec = selected
        guard available < spec.memoryNeeded else {
            memoryNote = nil
            return true
        }
        if spec.experimental {
            phase = .failed(Self.memoryRefusal(spec: spec, available: available))
            return false
        }
        memoryNote = "This iPhone had \(Self.gigabytes(available)) free just now, and \(spec.name) needs about \(Self.gigabytes(spec.memoryNeeded)) while it reads. Closing other apps first helps."
        return true
    }

    // MARK: State

    /// Reads the disk off the main thread, then shows what it found.
    private func refreshState() {
        let spec = selected
        let known = manifest
        Task {
            let disk = await Self.readDisk(for: spec, manifest: known)
            apply(disk, spec: spec)
        }
    }

    private func apply(_ disk: DiskState, spec: LocalModelSpec) {
        guard spec == selected else { return }
        otherOnDisk = disk.other
        hasFiles = disk.hasFiles
        if manifest == nil { manifest = disk.manifest }
        // A download under way owns the status.
        guard currentTask == nil, !running else { return }
        guard let saved = disk.manifest else {
            if case .failed = phase { return }
            phase = .notDownloaded
            return
        }
        if disk.nextFile == nil {
            let wasReady = isReady
            phase = .ready(sizeOnDisk: disk.sizeOnDisk)
            wanted = false
            // Episodes read while locked can be read in full now (task 05).
            if !wasReady { ProcessingPipeline.shared.catchUpModelReads() }
            return
        }
        if case .failed = phase { return }
        if userPaused {
            phase = .paused("Paused.")
        } else if wanted {
            phase = .downloading(done: disk.doneBytes, total: saved.total, bytesPerSecond: 0)
        } else {
            phase = .paused("Tap Download to continue.")
        }
    }

    private func pathChanged(wifi: Bool, any: Bool) {
        let wasAllowed = networkAllowed
        onWiFi = wifi
        onAnyNetwork = any
        if !wasAllowed, networkAllowed, wanted, !userPaused, !isReady, currentTask == nil {
            Task { await run() }
        } else if wasAllowed, !networkAllowed, currentTask != nil {
            // The session waits by itself for an allowed network; say so.
            phase = .paused(waitingReason)
        }
    }

    private var networkAllowed: Bool { onWiFi || (allowCellular && onAnyNetwork) }

    private var waitingReason: String {
        onAnyNetwork && !allowCellular ? "Waiting for Wi-Fi." : "Waiting for a connection."
    }

    /// The switch changed: move a running file to the session with the new
    /// rule, from where it got to.
    private func networkRuleChanged() {
        if let task = currentTask {
            Task {
                // Where it got to is saved before `run` looks for it.
                await Self.stopKeepingProgress(task)
                if currentTask === task { currentTask = nil }
                await run()
            }
        } else if wanted, !userPaused, !isReady, networkAllowed {
            Task { await run() }
        }
    }

    // MARK: The download loop

    private func run() async {
        guard wanted, !running, currentTask == nil else { return }
        running = true
        defer { running = false }
        let spec = selected

        // A file an earlier launch started may still be downloading in the
        // background; carry on with that one rather than start it twice.
        if let existing = await existingTask() {
            guard wanted, currentTask == nil else { return }
            if existing.state == .suspended { existing.resume() }
            currentTask = existing
            if let manifest {
                let disk = await Self.readDisk(for: spec, manifest: manifest)
                completedBytes = disk.doneBytes
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
            if let saved = await Self.readDisk(for: spec, manifest: nil).manifest {
                manifest = saved
            } else {
                phase = .listing
                do {
                    let listed = try await Self.fetchManifest(for: spec)
                    await Self.saveManifest(listed, for: spec)
                    manifest = listed
                    UserDefaults.standard.set(true, forKey: Keys.autoStarted)
                } catch {
                    phase = NetworkStatus.isConnectivity(error)
                        ? .paused(waitingReason)
                        : .failed("Couldn't get the model's file list: \(error.localizedDescription)")
                    return
                }
            }
        }
        guard let manifest, spec == selected else { return }

        // 2. What's there, and room for the rest (read off the main thread).
        let disk = await Self.readDisk(for: spec, manifest: manifest)
        // Paused, deleted or switched while the disk was read.
        guard spec == selected, wanted, currentTask == nil else { return }
        if disk.remainingBytes + 500_000_000 > disk.freeBytes {
            phase = .failed("Not enough free space: it needs \(Self.bytes(disk.remainingBytes + 500_000_000)) and \(Self.bytes(disk.freeBytes)) is free.")
            return
        }

        // 3. The next file not yet complete.
        guard let file = disk.nextFile else {
            wanted = false
            hasFiles = true
            phase = .ready(sizeOnDisk: disk.sizeOnDisk)
            ProcessingPipeline.shared.catchUpModelReads()
            return
        }
        completedBytes = disk.doneBytes
        speedSamples = []
        hasFiles = true
        phase = .downloading(done: completedBytes, total: manifest.total, bytesPerSecond: 0)

        let task: URLSessionDownloadTask
        if let data = disk.resumeData {
            task = session.downloadTask(withResumeData: data)
        } else {
            task = session.downloadTask(with: Self.downloadURL(file, spec: spec, revision: manifest.revision))
        }
        task.taskDescription = TaskTag(repo: spec.id, path: file.path, size: file.size).encoded
        currentTask = task
        task.resume()
        let resumeFile = Self.resumeURL(for: file, spec: spec)
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: resumeFile) }
    }

    /// A running or waiting download from either session.
    private func existingTask() async -> URLSessionDownloadTask? {
        for candidate in [wifiSession!, cellularSession!] {
            let tasks = await candidate.allTasks.compactMap { $0 as? URLSessionDownloadTask }
            guard let task = tasks.first(where: { $0.state == .running || $0.state == .suspended }) else { continue }
            // One left in the session the switch no longer picks: stop it
            // (keeping where it got to) and let `run` start it in the right one.
            if candidate !== session {
                await Self.stopKeepingProgress(task)
                continue
            }
            return task
        }
        return nil
    }

    /// Tasks are told apart by object, not `taskIdentifier`: the two
    /// sessions number their tasks separately.
    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        currentTask.map { ObjectIdentifier($0) } == id
    }

    fileprivate func progressed(written: Int64, task id: ObjectIdentifier) {
        guard isCurrent(id), let manifest else { return }
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

    fileprivate func fileFinished(error: String?, task id: ObjectIdentifier) {
        guard currentTask == nil || isCurrent(id) else { return }
        currentTask = nil
        if let error {
            phase = .failed(error)
            return
        }
        retries = 0
        guard !userPaused else { refreshState(); return }
        // Also after iOS woke the app in the background for this file, when
        // nothing at launch said a download was wanted.
        wanted = true
        Task { await run() }
    }

    /// The resume data was already saved on the session's queue.
    fileprivate func taskFailed(_ error: Error, task id: ObjectIdentifier) {
        // Cancelled by this class (pause, delete, the cellular switch): it
        // already set the state. Cancelled by iOS (the app was closed from
        // the app switcher): the next launch carries on.
        if (error as NSError).code == NSURLErrorCancelled { return }
        guard currentTask == nil || isCurrent(id) else { return }
        currentTask = nil
        if userPaused { phase = .paused("Paused."); return }
        wanted = true
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

    fileprivate func backgroundEventsFinished(_ identifier: String) {
        if let done = backgroundEventsDone.removeValue(forKey: identifier) {
            done()
        } else {
            backgroundEventsArrived.insert(identifier)
        }
    }
}

// MARK: - URLSession delegate

extension ModelStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let id = ObjectIdentifier(downloadTask)
        Task { @MainActor in self.progressed(written: totalBytesWritten, task: id) }
    }

    /// The file has to be moved before this returns: the system deletes it
    /// straight after. This runs on the session's own queue, not the main
    /// thread.
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
            // Every file is checked against the size the listing gave.
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
        let id = ObjectIdentifier(downloadTask)
        let error = problem
        Task { @MainActor in self.fileFinished(error: error, task: id) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Self.saveResumeData((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data, for: task)
        let id = ObjectIdentifier(task)
        Task { @MainActor in self.taskFailed(error, task: id) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let identifier = session.configuration.identifier ?? ""
        Task { @MainActor in self.backgroundEventsFinished(identifier) }
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

    /// What is on disk for one model, read in one go off the main thread.
    struct DiskState: Sendable {
        var manifest: Manifest?
        /// The first file not yet complete, or nil when all are.
        var nextFile: Manifest.File?
        var resumeData: Data?
        var doneBytes: Int64 = 0
        var remainingBytes: Int64 = 0
        var sizeOnDisk: Int64 = 0
        var freeBytes: Int64 = .max
        var hasFiles = false
        var other: OtherModel?
    }

    /// `nonisolated async`: runs on the shared background executor, never
    /// the main thread.
    nonisolated static func readDisk(for spec: LocalModelSpec, manifest known: Manifest?) async -> DiskState {
        let fm = FileManager.default
        var disk = DiskState()
        let modelFolder = Self.folder(for: spec)
        disk.hasFiles = fm.fileExists(atPath: modelFolder.path)
        if let other = LocalModelSpec.all.first(where: { $0 != spec && fm.fileExists(atPath: Self.folder(for: $0).path) }) {
            disk.other = OtherModel(spec: other, bytes: bytesOnDisk(Self.folder(for: other)))
        }
        disk.manifest = known ?? loadManifest(for: spec)
        guard let manifest = disk.manifest else { return disk }
        for file in manifest.files {
            if localSize(file, spec: spec) == file.size {
                disk.doneBytes += file.size
            } else {
                disk.remainingBytes += file.size
                if disk.nextFile == nil { disk.nextFile = file }
            }
        }
        if let next = disk.nextFile { disk.resumeData = try? Data(contentsOf: resumeURL(for: next, spec: spec)) }
        disk.sizeOnDisk = bytesOnDisk(modelFolder)
        disk.freeBytes = (try? URL.applicationSupportDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? .max
        return disk
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

    nonisolated static func saveManifest(_ manifest: Manifest, for spec: LocalModelSpec) async {
        try? FileManager.default.createDirectory(at: folder(for: spec), withIntermediateDirectories: true)
        try? excludeFromBackup(root)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL(for: spec), options: .atomic)
        }
    }

    nonisolated static func resumeURL(for file: Manifest.File, spec: LocalModelSpec) -> URL {
        folder(for: spec).appending(path: "." + file.path + ".resume")
    }

    /// Stops a download and saves where it got to; returns once it's saved,
    /// so a restart straight after finds it.
    nonisolated static func stopKeepingProgress(_ task: URLSessionDownloadTask) async {
        let data = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
            task.cancel(byProducingResumeData: { done.resume(returning: $0) })
        }
        saveResumeData(data, for: task)
    }

    /// Saved next to the file the task was fetching (from its tag, not from
    /// what is selected now). Never on the main thread. It doesn't create
    /// the folder: after Delete there is none, and none should come back.
    nonisolated static func saveResumeData(_ data: Data?, for task: URLSessionTask) {
        guard let data, let tag = TaskTag(task.taskDescription) else { return }
        let file = Manifest.File(path: tag.path, size: tag.size)
        try? data.write(to: resumeURL(for: file, spec: LocalModelSpec.named(tag.repo)), options: .atomic)
    }

    nonisolated static func localSize(_ file: Manifest.File, spec: LocalModelSpec) -> Int64 {
        let path = folder(for: spec).appending(path: file.path).path
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
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

    /// The plain refusal for the experimental model.
    nonisolated static func memoryRefusal(spec: LocalModelSpec, available: Int64) -> String {
        "\(spec.name) won't fit in this iPhone's memory: it needs about \(gigabytes(spec.memoryNeeded)) free and only \(gigabytes(available)) is. Choose \(LocalModelSpec.preferred.name) instead."
    }

    nonisolated static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
