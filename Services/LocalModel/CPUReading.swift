import Foundation
import UIKit
import CryptoKit
import Observation

/// Pass 58 (his 5 Nov question: can a model like Qwen3.5 4B work the way the
/// Reader does — app closed, screen locked?): yes, on the CPU.
///
/// The Reader works off screen because it runs on the CPU and is small. The
/// MLX and Core AI models are part of the app too, but they read on the GPU,
/// and iOS refuses GPU work from an app that isn't on screen unless it is
/// signed with Background GPU Access (his builds aren't). Pass 27 tried MLX on
/// the CPU: it is built for the GPU (under 1 token/s on this Mac's CPU, Pass
/// 58) and iOS ended the app for using the CPU too long. llama.cpp's CPU code
/// reads the same Qwen3.5 4B at 39 tokens/s on two of this Mac's cores and
/// 76 on four (Pass 58 lab), so a CPU copy (GGUF, 4-bit, 2.6 GB) reads:
///
///  * off screen — while you listen, the screen locked or another app open:
///    paced (`CPUBudget`), using at most about half of one core averaged
///    over a minute, under iOS's background limit (it ends an app that keeps
///    the CPU busier than that for a minute);
///  * overnight — in the processing task that waits for a charger, where iOS
///    lifts that limit: as fast as the performance cores go.
///
/// On screen the GPU copy (MLX) still reads; this is only for when it can't.
/// The two copies are different files of one model (MLX 4-bit vs GGUF Q4_0),
/// so their answers can differ a little; the run says which one read.
/// Pass 62 (his 8 Nov request: the Instruct 6-bit on the CPU, and smaller,
/// faster CPU models): one CPU model of several, each a GGUF file pinned to a
/// commit and checked against its SHA-256, read by the same llama.cpp engine.
struct CPUModel: Sendable, Equatable, Identifiable, Hashable {
    /// How the conversation is written for this family.
    enum Chat: String, Sendable, Hashable {
        /// Qwen's ChatML with an empty think block (thinking off).
        case qwenNoThinking
        /// Liquid's ChatML: `<|startoftext|>` first, no think block.
        case liquid
        /// Pass 63: LFM3's ChatML — `<|startoftext|>` first and, with
        /// thinking off, an empty `<think></think>` opening the answer (its
        /// chat template's `enable_thinking: false`).
        case liquid3
    }

    /// Stable key (Settings, records).
    let id: String
    let name: String
    let repo: String
    let revision: String
    let file: String
    let bytes: Int64
    let sha256: String
    /// The MLX model whose prompt plan it follows (same model or family).
    let twin: LocalModelSpec
    let chat: Chat
    /// One line for the lists: what it is and how it did.
    let summary: String

    /// Results and records: the twin's id + "#cpu" (Pass 58's engine id for
    /// the first CPU copy, so its earlier results stay with it).
    var engineID: String { twin.id + CPUReading.engineSuffix }
    var identity: String { repo + " @ " + revision + " / " + file }
    var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")! }
    var location: URL { CPUReading.folder.appending(path: file) }

    /// Pass 64 (his 13 Nov export: three 0x8BADF00D watchdog kills, each a
    /// SwiftUI body on Compare Models or Settings asking this, blocked in
    /// the kernel on the file's size while Core AI wrote gigabytes): the
    /// answer comes from `CPUModelPresence`, read off the main thread. On the
    /// main thread it never touches the disk; elsewhere a model not read yet
    /// is read once.
    var isDownloaded: Bool {
        if CPUReading.isDemo { return CPUReading.demoDownloaded.contains(id) }
        return CPUModelPresence.shared.isPresent(self)
    }

    /// Where the engine reads the file: this iPhone's copy, or (Pass 64)
    /// the same file on an external drive he chose in External Model Library.
    var readLocation: URL { CPUModelPresence.shared.location(of: self) ?? location }

    /// The disk check itself (never on the main thread).
    nonisolated func fileOnDisk(in folders: [URL]) -> URL? {
        for folder in [CPUReading.folder] + folders {
            let url = folder.appending(path: file)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            if size == bytes { return url }
        }
        return nil
    }

    /// The prompt's shared start (rules + header) and the part's own text,
    /// tokenized apart so the engine can keep the start's state (Pass 62).
    func chatPrompt(system: String, header: String, rest: String) -> (head: String, tail: String) {
        switch chat {
        case .qwenNoThinking:
            return ("<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n" + header,
                    rest + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n")
        case .liquid:
            return ("<|startoftext|><|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n" + header,
                    rest + "<|im_end|>\n<|im_start|>assistant\n")
        case .liquid3:
            return ("<|startoftext|><|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n" + header,
                    rest + "<|im_end|>\n<|im_start|>assistant\n<think></think>")
        }
    }
}

/// Pass 64: which CPU models are on this iPhone (or on the external drive
/// he picked), read off the main thread and kept in memory. Views ask it
/// freely; a refresh runs after a download, a delete, an import, a change of
/// drive and at launch, and redraws what asked (`CPUModelCopy.presenceRevision`).
final class CPUModelPresence: @unchecked Sendable {
    static let shared = CPUModelPresence()
    private let lock = NSLock()
    private var found: [String: URL] = [:]
    private var scanned = false
    private var scanning = false

    /// Whether `model` is here. On the main thread: what was last read (and
    /// a read is started if none has been); elsewhere: read now if never read.
    func isPresent(_ model: CPUModel) -> Bool {
        if Thread.isMainThread {
            MainActor.assumeIsolated { _ = CPUModelCopy.shared.presenceRevision }
            let (known, done) = lock.withLock { (found[model.id], scanned) }
            if !done { refresh() }
            return known != nil
        }
        if let state = lock.withLock({ scanned ? Optional(found[model.id] != nil) : nil }) { return state }
        let url = model.fileOnDisk(in: ExternalModelLibrary.folders(kind: .gguf))
        lock.withLock { if let url { found[model.id] = url } }
        return url != nil
    }

    func location(of model: CPUModel) -> URL? { lock.withLock { found[model.id] } }

    /// Reads every catalog file's size off the main thread, then redraws.
    func refresh() {
        let start = lock.withLock { () -> Bool in
            if scanning { return false }
            scanning = true
            return true
        }
        guard start else { return }
        Task.detached(priority: .utility) {
            let folders = ExternalModelLibrary.folders(kind: .gguf)
            var out: [String: URL] = [:]
            for model in CPUReading.catalog { if let url = model.fileOnDisk(in: folders) { out[model.id] = url } }
            self.lock.withLock { self.found = out; self.scanned = true; self.scanning = false }
            await MainActor.run { CPUModelCopy.shared.presenceChanged() }
        }
    }

    /// Set at once after this app wrote or removed the file itself.
    func note(_ model: CPUModel, at url: URL?) {
        lock.withLock {
            if let url { found[model.id] = url } else { found[model.id] = nil }
        }
        Task { @MainActor in CPUModelCopy.shared.presenceChanged() }
    }
}

enum CPUReading {
    // MARK: The catalog (sizes and SHA-256 from Hugging Face's file list, 8 Nov 2026)

    /// Pass 58's CPU copy: Qwen3.5 4B, 4-bit (Q4_0, the fastest kind on the
    /// iPhone's CPU). The default.
    static let qwen35_4B_q4 = CPUModel(
        id: "qwen35-4b-q4_0", name: "Qwen3.5 4B (CPU)", repo: "unsloth/Qwen3.5-4B-GGUF",
        revision: "e87f176479d0855a907a41277aca2f8ee7a09523", file: "Qwen3.5-4B-Q4_0.gguf",
        bytes: 2_583_221_408, sha256: "298fcb5fe7a77ccc79745ae24751560c5ac56874caff4bb39b1f2055bd72b8bb",
        twin: .qwen35_4B, chat: .qwenNoThinking,
        summary: "The same model as Qwen3.5 4B under MLX, 4-bit. In the Mac lab (11 Nov) it scored 98% on Basic and 98% on Hard by itself. A 2.6 GB download.")
    /// Pass 62: Qwen3.5 4B at 6 bits (Q6_K) — the CPU twin of "Qwen3.5 4B
    /// Instruct (6-bit)" under MLX, which is the same base model at 6 bits
    /// with thinking off (ALTICDEV's conversion of Qwen/Qwen3.5-4B); asked
    /// the Instruct way (`listenerEdges`).
    static let qwen35_4B_q6 = CPUModel(
        id: "qwen35-4b-q6_k", name: "Qwen3.5 4B Instruct (6-bit) (CPU)", repo: "unsloth/Qwen3.5-4B-GGUF",
        revision: "e87f176479d0855a907a41277aca2f8ee7a09523", file: "Qwen3.5-4B-Q6_K.gguf",
        bytes: 3_525_956_768, sha256: "fdedd781c9ce676ab66b018ca247ff78e8a33c98098a822c1e2d5075e7718f66",
        twin: .qwen35_4B_instruct, chat: .qwenNoThinking,
        summary: "Qwen3.5 4B at 6 bits, asked as the Instruct build. Slower than the 4-bit copy; 98% on Hard by itself in the Mac lab (11 Nov). A 3.5 GB download.")
    /// Pass 62: smaller and faster for reading in the background.
    static let qwen35_2B_q4 = CPUModel(
        id: "qwen35-2b-q4_0", name: "Qwen3.5 2B (CPU)", repo: "unsloth/Qwen3.5-2B-GGUF",
        revision: "f6d5376be1edb4d416d56da11e5397a961aca8ae", file: "Qwen3.5-2B-Q4_0.gguf",
        bytes: 1_214_873_856, sha256: "cd70221bebaee0503e0f6717e174250cd7825aa88438b3aabec9ad55731d9bb1",
        twin: .qwen35_2B, chat: .qwenNoThinking,
        summary: "Half the size of the 4B and faster. On your phone (13 Nov) it answered every part with an empty list; that was the answer form, which allowed no spaces where it writes them. Fixed: in the Mac lab (13 Nov) it now finds ads by itself (34% on Basic, with some of the show cut; 93% with PodSkipper’s check). Test it again before choosing it. A 1.2 GB download.")
    static let lfm25_1_2B_q4 = CPUModel(
        id: "lfm25-1.2b-q4_0", name: "LFM2.5 1.2B (CPU)", repo: "LiquidAI/LFM2.5-1.2B-Instruct-GGUF",
        revision: "8ed288026e23958ad9dfa92d53ed773a8eee7125", file: "LFM2.5-1.2B-Instruct-Q4_0.gguf",
        bytes: 695_751_488, sha256: "2ea801949d760cdf1a2cc04a54262c22c3c0c54f0769d57760c9adeb0e59233f",
        twin: .lfm25_1_2B_cpu, chat: .liquid,
        summary: "Liquid AI’s 1.2B, built for phones’ processors: about 2.7 times as fast as the 4B, but weak at this: in the Mac lab (13 Nov) it found none of Basic’s ads by itself and marked a stretch of the show as an intro, which PodSkipper’s check now leaves alone. Not recommended. A 0.7 GB download.")

    /// Pass 63 (his 10 Nov request): Liquid's LFM3 1.7B, the 4-bit file
    /// Liquid trained to keep its accuracy at 4 bits (quantization-aware
    /// distillation). llama.cpp reads it from b11960; the app's is b12283
    /// (`Scripts/build-llama.sh`). Size and SHA-256 from Hugging Face's file
    /// list, 11 Nov 2026.
    static let lfm3_1_7B_q4 = CPUModel(
        id: "lfm3-1.7b-qad-q4_0", name: "Liquid LFM3 1.7B (CPU)", repo: "LiquidAI/LFM3-1.7B-GGUF",
        revision: "cd0c74c575b5c416f3011b5b4c298077f26ca8c2", file: "LFM3-1.7B-QAD-Q4_0.gguf",
        bytes: 1_049_615_680, sha256: "43a7d09a0e9cba91b63eb7052488b9564569bddfd65754d2e426465e572a7452",
        twin: .lfm3_1_7B_cpu, chat: .liquid3,
        summary: "Liquid AI’s newest small model (1.7B), in the 4-bit file Liquid trained for phones’ processors. In the Mac lab (11 Nov) it scored 94% on Basic by itself but found few of Hard’s ads (27%); with PodSkipper’s check, 96%. Test it before choosing it. A 1.0 GB download.")

    static let catalog: [CPUModel] = [qwen35_4B_q4, qwen35_4B_q6, qwen35_2B_q4, lfm3_1_7B_q4, lfm25_1_2B_q4]

    /// Pass 63, screenshot and UI-test runs only (`-CPUModelDemo` with the
    /// demo library): which CPU models count as downloaded, held in memory —
    /// nothing is fetched or deleted — so the rows can be shown before a
    /// download, with one, and after it is deleted.
    static let isDemo = DemoData.isEnabled && ProcessInfo.processInfo.arguments.contains("-CPUModelDemo")
    nonisolated(unsafe) static var demoDownloaded: Set<String> = []

    static func model(id: String?) -> CPUModel? { catalog.first { $0.id == id } }
    static func model(engineID: String) -> CPUModel? { catalog.first { $0.engineID == engineID } }

    // MARK: The one that reads in the background

    /// Pass 62: which CPU model reads off screen, and (Pass 63) on screen
    /// when CPU models are the chosen finder (Settings › Ad Skipping › CPU
    /// model library). Qwen3.5 4B 4-bit until he picks another.
    static let selectionKey = "cpuReading.model"
    static var selected: CPUModel {
        get { model(id: UserDefaults.standard.string(forKey: selectionKey)) ?? qwen35_4B_q4 }
        set { UserDefaults.standard.set(newValue.id, forKey: selectionKey) }
    }

    /// The chosen model (Pass 58's single copy, now the chosen one).
    static var repo: String { selected.repo }
    static var revision: String { selected.revision }
    static var file: String { selected.file }
    static var bytes: Int64 { selected.bytes }
    static var sha256: String { selected.sha256 }
    static var twin: LocalModelSpec { selected.twin }
    static let engineSuffix = "#cpu"
    static var displayName: String { selected.name }

    static var url: URL { selected.url }
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "Models/gguf", directoryHint: .isDirectory) }
    static var location: URL { selected.location }

    /// Whether this build carries the CPU engine (device builds; the
    /// simulator build leaves the package out — see Scripts/generate-project.sh).
    static var engineIncluded: Bool {
        #if canImport(LlamaCPU)
        return true
        #else
        return false
        #endif
    }

    static var isDownloaded: Bool { selected.isDownloaded }
    static var downloaded: [CPUModel] { catalog.filter(\.isDownloaded) }

    /// Settings › Ad Skipping › When Locked or in the Background: the CPU
    /// model reads (on, the default) or the episode waits for the screen.
    static let settingKey = "cpuReading.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    static var isAvailable: Bool { engineIncluded && isEnabled && isDownloaded }

    /// Pass 63: the chosen CPU model is the finder itself (Find Ads With ›
    /// CPU models) — Pass 62's "Use It on Screen Too" switch, now a choice
    /// he can see (`FinderRouting.migratePrimarySwitch`).
    static var isChosenFinder: Bool {
        UserDefaults.standard.string(forKey: "adFinder") == AdFinderChoice.cpu.rawValue
    }
    /// On this iPhone and runnable, whatever the background switch says:
    /// what a read with the CPU model as the chosen finder needs.
    static var isReady: Bool { engineIncluded && isDownloaded }

    /// Threads: the performance cores (2 on his iPhone 16 Pro); never the
    /// efficiency cores, which would slow the batch to their pace.
    static var threads: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(min(count, 4)) }
        return 2
    }
}

/// Keeps PodSkipper's CPU use, taken over the whole app, at or under a share
/// of one core: after each step it waits as long as that step's CPU time
/// needs at the allowed share. iOS's background limit is on the process's
/// average over about a minute (his Pass 27 report: ended after ~90 s of
/// MLX on the CPU), so a short busy step followed by a proportionate rest
/// stays under it whatever else the app is doing — the rest counts that too.
struct CPUBudget: Sendable, Equatable {
    enum Mode: String, Sendable { case paced, full }

    var mode: Mode
    /// CPU-seconds per wall second while paced (0.45 = 45 % of one core).
    var share: Double = 0.45
    /// The longest single rest, so a stall elsewhere can't park the read.
    var maxRest: Double = 90

    /// How long to rest after a step that took `wall` seconds and in which
    /// the app as a whole used `cpu` CPU-seconds.
    func rest(cpu: Double, wall: Double) -> Double {
        guard mode == .paced, share > 0, cpu > 0 else { return 0 }
        return min(maxRest, max(0, cpu / share - wall))
    }

    /// The app's CPU time so far, every thread counted.
    static func processCPUSeconds() -> Double {
        var spec = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &spec) == 0 else { return 0 }
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1e9
    }
}

/// Whether the overnight processing task now running was asked for with a
/// charger required — the only kind iOS lifts its CPU limit for (WWDC19 707).
enum OvernightWindow {
    private static let key = "overnight.requestNeedsPower"
    nonisolated(unsafe) private static var running = false

    static func noteRequest(needsPower: Bool) { UserDefaults.standard.set(needsPower, forKey: key) }
    static func began() { running = true }
    static func ended() { running = false }

    @MainActor static var allowsFullSpeed: Bool {
        guard running, UserDefaults.standard.bool(forKey: key) else { return false }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
    }
}

/// Downloads a CPU model: one file, resumable, checked against its SHA-256.
/// Kept on this device only (excluded from backup). Pass 62: one at a time,
/// any model of the catalog.
@MainActor @Observable
final class CPUModelCopy {
    static let shared = CPUModelCopy()

    enum State: Equatable { case absent, downloading(Double), checking, ready, failed(String) }
    /// The chosen model's state (Pass 58's single copy).
    var state: State { state(of: CPUReading.selected) }
    private(set) var states: [String: State] = [:]
    /// Pass 64 (his 13 Nov request): bytes so far, of how many, and how
    /// fast, for the download under way.
    private(set) var transfer: (done: Int64, total: Int64, bytesPerSecond: Double)?
    @ObservationIgnored private var meter = TransferMeter()
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private(set) var downloadingID: String?

    private func resumeURL(_ model: CPUModel) -> URL { CPUReading.folder.appending(path: ".resume-" + model.id) }

    /// Pass 64: bumped when `CPUModelPresence` has read the disk again, so
    /// every view that asked whether a CPU model is here redraws.
    private(set) var presenceRevision = 0
    func presenceChanged() {
        presenceRevision += 1
        for model in CPUReading.catalog where model.id != downloadingID {
            if let s = states[model.id], s != .absent, s != .ready { continue }
            states[model.id] = model.isDownloaded ? .ready : .absent
        }
    }

    func state(of model: CPUModel) -> State {
        if let s = states[model.id], s != .absent, s != .ready { return s }
        return model.isDownloaded ? .ready : .absent
    }

    func refresh() { CPUModelPresence.shared.refresh() }

    func download() { download(CPUReading.selected) }

    func download(_ model: CPUModel) {
        if downloadingID != nil { return }
        if CPUReading.isDemo {
            CPUReading.demoDownloaded.insert(model.id)
            states[model.id] = .ready
            return
        }
        try? FileManager.default.createDirectory(at: CPUReading.folder, withIntermediateDirectories: true)
        var folder = CPUReading.folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let staging = CPUReading.folder.appending(path: ".incoming-" + model.id)
        let resumeURL = self.resumeURL(model)
        let done: @Sendable (URL?, URLResponse?, Error?) -> Void = { temp, response, error in
            if let error {
                if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    try? data.write(to: resumeURL)
                }
                Task { @MainActor in CPUModelCopy.shared.failed(model, error) }
                return
            }
            guard let temp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                Task { @MainActor in CPUModelCopy.shared.failed(model, URLError(.badServerResponse)) }
                return
            }
            // The temporary file is gone once this returns: move it first.
            try? FileManager.default.removeItem(at: staging)
            do { try FileManager.default.moveItem(at: temp, to: staging) } catch {
                Task { @MainActor in CPUModelCopy.shared.failed(model, error) }
                return
            }
            try? FileManager.default.removeItem(at: resumeURL)
            Task.detached(priority: .utility) {
                do { try await Self.finish(staging, model: model) } catch {
                    await MainActor.run { CPUModelCopy.shared.failed(model, error) }
                }
            }
        }
        let session = URLSession.shared
        let task = (try? Data(contentsOf: resumeURL)).map { session.downloadTask(withResumeData: $0, completionHandler: done) }
            ?? session.downloadTask(with: model.url, completionHandler: done)
        states[model.id] = .downloading(0)
        downloadingID = model.id
        meter = TransferMeter()
        transfer = (0, model.bytes, 0)
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            let done = progress.completedUnitCount
            let total = progress.totalUnitCount > 0 ? progress.totalUnitCount : model.bytes
            Task { @MainActor in
                let copy = CPUModelCopy.shared
                if case .downloading = copy.states[model.id] { copy.states[model.id] = .downloading(value) }
                guard copy.downloadingID == model.id else { return }
                copy.meter.note(done: done)
                copy.transfer = (done, total, copy.meter.bytesPerSecond)
            }
        }
        self.task = task
        task.resume()
    }

    func stop() {
        guard let id = downloadingID, let model = CPUReading.model(id: id) else { return }
        let resumeURL = self.resumeURL(model)
        task?.cancel(byProducingResumeData: { data in
            if let data { try? data.write(to: resumeURL) }
        })
        task = nil
        downloadingID = nil
        transfer = nil
        states[model.id] = .absent
    }

    func delete() { delete(CPUReading.selected) }

    func delete(_ model: CPUModel) {
        if CPUReading.isDemo {
            CPUReading.demoDownloaded.remove(model.id)
            states[model.id] = .absent
            return
        }
        if downloadingID == model.id { stop() }
        try? FileManager.default.removeItem(at: model.location)
        try? FileManager.default.removeItem(at: resumeURL(model))
        states[model.id] = .absent
        CPUModelPresence.shared.note(model, at: nil)
        // A copy on the external drive still counts.
        CPUModelPresence.shared.refresh()
    }

    private func failed(_ model: CPUModel, _ error: Error) {
        if downloadingID == model.id { downloadingID = nil; task = nil; transfer = nil }
        if (error as? URLError)?.code == .cancelled { return }
        states[model.id] = .failed(error.localizedDescription)
    }

    private func finished(_ model: CPUModel) {
        if downloadingID == model.id { downloadingID = nil; task = nil; transfer = nil }
        states[model.id] = .ready
    }

    nonisolated private static func finish(_ temp: URL, model: CPUModel) async throws {
        await MainActor.run { CPUModelCopy.shared.states[model.id] = .checking }
        let ok = try Self.matches(temp, sha256: model.sha256)
        guard ok else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "The download didn't match the model's checksum; nothing was kept."])
        }
        try? FileManager.default.removeItem(at: model.location)
        try FileManager.default.moveItem(at: temp, to: model.location)
        CPUModelPresence.shared.note(model, at: model.location)
        await MainActor.run { CPUModelCopy.shared.finished(model) }
    }

    nonisolated static func matches(_ file: URL, sha256: String = CPUReading.sha256) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }
}
