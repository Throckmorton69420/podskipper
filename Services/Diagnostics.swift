import Foundation
import MetricKit
import UIKit
import os

/// What the phone itself reports, so "how fast is it on the phone" and "does
/// it run hot" are answered with numbers instead of descriptions (pass 16).
///
/// Two sources, both kept on the phone in Application Support/Diagnostics and
/// shared from Settings → Diagnostics:
///
/// - **Timings**, written by the app after every episode it processes: how
///   long the audio is, and how many seconds transcription, the sound
///   analysis and ad finding each took, with the thermal state and power
///   state at the time. Available immediately.
/// - **MetricKit reports**, written by iOS: a daily summary (battery use, CPU,
///   hangs, disk writes, launch time, and the `Processing` intervals below)
///   and diagnostics (crashes, hangs, CPU and disk-write exceptions) as they
///   happen. The first daily report arrives about a day after install.
enum Diagnostics {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appending(path: "Diagnostics", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// MetricKit's own log: intervals marked with it appear in the daily
    /// report with their CPU time, memory and count.
    static let metricLog = MXMetricManager.makeLogHandle(category: "Processing")

    /// A stretch of work, marked for MetricKit (and Instruments' signpost
    /// track) and timed. `begin` it, then `end()` it once — the seconds come
    /// back. `name` must be a literal: "Transcribe", "Analyze", "Detect".
    struct Interval {
        let name: StaticString
        let id: OSSignpostID
        let start = ContinuousClock.now

        static func begin(_ name: StaticString) -> Interval {
            let id = OSSignpostID(log: Diagnostics.metricLog)
            mxSignpost(.begin, log: Diagnostics.metricLog, name: name, signpostID: id)
            return Interval(name: name, id: id)
        }

        @discardableResult
        func end() -> Double {
            mxSignpost(.end, log: Diagnostics.metricLog, name: name, signpostID: id)
            let d = ContinuousClock.now - start
            return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        }
    }

    static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    /// e.g. "iPhone17,1" — the model identifier, which names the exact phone.
    static var deviceModel: String {
        // In the simulator uname says "arm64"; the simulated model is here.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated + " (simulator)"
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Everything in one JSON file, for sharing: the timings, the device,
    /// and every MetricKit report kept.
    @MainActor static func exportFile(edits: [(show: String, episode: String, edits: EditCounts)] = []) throws -> URL {
        var reports: [[String: Any]] = []
        for file in MetricsSubscriber.savedReports() {
            if let data = try? Data(contentsOf: file.url),
               let json = try? JSONSerialization.jsonObject(with: data) {
                reports.append(["kind": file.kind, "file": file.url.lastPathComponent, "report": json])
            }
        }
        let timings = (try? JSONSerialization.jsonObject(
            with: JSONEncoder.iso.encode(TimingLog.shared.entries))) ?? []
        let info = Bundle.main.infoDictionary ?? [:]
        let root: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: .now),
            "app": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "build": BuildInfo.commit,
            "device": deviceModel,
            "os": UIDevice.current.systemVersion,
            "timings": timings,
            // What he fixed, per processed episode (D7): the measure of
            // "rarely needs manual edits".
            "edits": edits.map { e -> [String: Any] in
                ["show": e.show, "episode": e.episode, "detected": e.edits.detected,
                 "confirmed": e.edits.confirmed, "rejected": e.edits.rejected, "moved": e.edits.moved,
                 "added": e.edits.added, "locked": e.edits.locked]
            },
            "metricKit": reports,
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PodSkipper-diagnostics-\(Int(Date().timeIntervalSince1970)).json")
        try data.write(to: url)
        return url
    }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}
