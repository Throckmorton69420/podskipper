import Foundation
import MetricKit
import Observation

/// Receives iOS's MetricKit reports and keeps the raw JSON on disk, newest 40.
///
/// Subscribed in `PodSkipperApp.init`, as early as possible: reports that
/// arrive before anyone is listening are only recoverable through
/// `pastPayloads`, which is read at the same moment. Each payload is written
/// to disk before anything else touches it — iOS delivers each one once.
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricsSubscriber()
    private static let keep = 40

    struct SavedReport: Identifiable {
        let url: URL
        let kind: String          // "daily" or "diagnostic"
        let date: Date
        var id: URL { url }
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

    private func save(_ json: Data, kind: String, stamp: Date) {
        let name = "\(kind)-\(Int(stamp.timeIntervalSince1970)).json"
        try? json.write(to: Diagnostics.folder.appending(path: name), options: .atomic)
        Self.prune()
    }

    private static func prune() {
        let all = savedReports()
        guard all.count > keep else { return }
        for old in all.dropFirst(keep) { try? FileManager.default.removeItem(at: old.url) }
    }

    /// Newest first.
    static func savedReports() -> [SavedReport] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Diagnostics.folder, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> SavedReport? in
            let name = url.deletingPathExtension().lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count == 2, ["daily", "diagnostic"].contains(String(parts[0])),
                  let seconds = Double(parts[1]) else { return nil }
            return SavedReport(url: url, kind: String(parts[0]),
                               date: Date(timeIntervalSince1970: seconds))
        }
        .sorted { $0.date > $1.date }
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
    private let url = Diagnostics.folder.appending(path: "timings.json")

    private init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([ProcessingTiming].self, from: data)) ?? []
        }
        // Screenshot runs only: two made-up rows, in memory, never saved,
        // so the Diagnostics screen can be photographed with content.
        if DemoData.isEnabled && entries.isEmpty {
            let base = ProcessingTiming(date: .now, show: "The Long Way Round",
                episode: "Crossing the Pennines on a Tandem Nobody Asked For",
                audioSeconds: 5880, transcribeSeconds: 312, analyzeSeconds: 9, detectSeconds: 178,
                thermalAtStart: "nominal", thermalAtEnd: "fair", lowPowerMode: false,
                onPower: true, foreground: false, device: "demo", build: "demo")
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
        let snapshot = entries
        let url = url
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder.iso.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: url)
    }

    /// Median seconds of work per hour of audio, over jobs that measured it.
    func median(_ value: KeyPath<ProcessingTiming, Double?>) -> Double? {
        let xs = entries.compactMap { $0[keyPath: value] }.sorted()
        guard !xs.isEmpty else { return nil }
        return xs[xs.count / 2]
    }
}
