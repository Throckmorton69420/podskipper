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
enum CPUReading {
    /// The file, pinned to one commit of unsloth's conversion.
    static let repo = "unsloth/Qwen3.5-4B-GGUF"
    static let revision = "e87f176479d0855a907a41277aca2f8ee7a09523"
    static let file = "Qwen3.5-4B-Q4_0.gguf"
    static let bytes: Int64 = 2_583_221_408
    static let sha256 = "298fcb5fe7a77ccc79745ae24751560c5ac56874caff4bb39b1f2055bd72b8bb"
    /// The MLX model whose prompt plan it follows (same model, same family).
    static let twin: LocalModelSpec = .qwen35_4B
    static let engineSuffix = "#cpu"
    static var displayName: String { twin.name + " (CPU)" }

    static var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file)")! }
    static var folder: URL { URL.applicationSupportDirectory.appending(path: "Models/gguf", directoryHint: .isDirectory) }
    static var location: URL { folder.appending(path: file) }

    /// Whether this build carries the CPU engine (device builds; the
    /// simulator build leaves the package out — see Scripts/generate-project.sh).
    static var engineIncluded: Bool {
        #if canImport(LlamaCPU)
        return true
        #else
        return false
        #endif
    }

    static var isDownloaded: Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        return size == bytes
    }

    /// Settings switch ("Read in the Background"), on by default once the
    /// copy is downloaded: downloading it is the choice.
    static let settingKey = "cpuReading.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    static var isAvailable: Bool { engineIncluded && isEnabled && isDownloaded }

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

/// Downloads the CPU copy: one file, resumable, checked against its SHA-256.
/// Kept on this device only (excluded from backup).
@MainActor @Observable
final class CPUModelCopy {
    static let shared = CPUModelCopy()

    enum State: Equatable { case absent, downloading(Double), checking, ready, failed(String) }
    private(set) var state: State = CPUReading.isDownloaded ? .ready : .absent
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?
    private var resumeURL: URL { CPUReading.folder.appending(path: ".resume") }

    func refresh() { if case .downloading = state { return }; state = CPUReading.isDownloaded ? .ready : .absent }

    func download() {
        if case .downloading = state { return }
        try? FileManager.default.createDirectory(at: CPUReading.folder, withIntermediateDirectories: true)
        var folder = CPUReading.folder
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let staging = CPUReading.folder.appending(path: ".incoming")
        let resumeURL = self.resumeURL
        let done: @Sendable (URL?, URLResponse?, Error?) -> Void = { temp, response, error in
            if let error {
                if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                    try? data.write(to: resumeURL)
                }
                Task { @MainActor in CPUModelCopy.shared.failed(error) }
                return
            }
            guard let temp, (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                Task { @MainActor in CPUModelCopy.shared.failed(URLError(.badServerResponse)) }
                return
            }
            // The temporary file is gone once this returns: move it first.
            try? FileManager.default.removeItem(at: staging)
            do { try FileManager.default.moveItem(at: temp, to: staging) } catch {
                Task { @MainActor in CPUModelCopy.shared.failed(error) }
                return
            }
            try? FileManager.default.removeItem(at: resumeURL)
            Task.detached(priority: .utility) {
                do { try await Self.finish(staging) } catch {
                    await MainActor.run { CPUModelCopy.shared.failed(error) }
                }
            }
        }
        let session = URLSession.shared
        let task = (try? Data(contentsOf: resumeURL)).map { session.downloadTask(withResumeData: $0, completionHandler: done) }
            ?? session.downloadTask(with: CPUReading.url, completionHandler: done)
        state = .downloading(0)
        observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in if case .downloading = CPUModelCopy.shared.state { CPUModelCopy.shared.state = .downloading(value) } }
        }
        self.task = task
        task.resume()
    }

    func stop() {
        let resumeURL = self.resumeURL
        task?.cancel(byProducingResumeData: { data in
            if let data { try? data.write(to: resumeURL) }
        })
        task = nil
        state = .absent
    }

    func delete() {
        stop()
        try? FileManager.default.removeItem(at: CPUReading.location)
        try? FileManager.default.removeItem(at: resumeURL)
        state = .absent
    }

    private func failed(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        state = .failed(error.localizedDescription)
    }

    nonisolated private static func finish(_ temp: URL) async throws {
        await MainActor.run { CPUModelCopy.shared.state = .checking }
        let ok = try Self.matches(temp)
        guard ok else {
            try? FileManager.default.removeItem(at: temp)
            throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "The download didn't match the model's checksum; nothing was kept."])
        }
        try? FileManager.default.removeItem(at: CPUReading.location)
        try FileManager.default.moveItem(at: temp, to: CPUReading.location)
        await MainActor.run { CPUModelCopy.shared.state = .ready }
    }

    nonisolated static func matches(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == CPUReading.sha256
    }
}
