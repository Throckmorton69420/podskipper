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
    /// Pass 35 (his request): an export of chosen parts over a chosen time.
    /// Same keys as before (the Mac tools read them), plus `schema` and a
    /// `scope` block saying what was left out, so a partial file says so.
    struct Scope: Sendable, Equatable {
        enum Part: String, CaseIterable, Sendable, Identifiable {
            case device, background, timings, modelTests, crashes, dailyReports, playback, libraryRecovery, corrections, cleanups
            var id: Self { self }
            var title: String {
                switch self {
                case .device: "Device & capabilities"
                case .background: "Background work and events"
                case .timings: "Episodes processed (timings)"
                case .modelTests: "Model tests"
                case .crashes: "iOS crash, hang and disk reports"
                case .dailyReports: "iOS daily reports"
                case .playback: "Playback and sound output"
                case .libraryRecovery: "Library open failures"
                case .corrections: "Your corrections (counts)"
                case .cleanups: "Storage cleanups (what was removed)"
                }
            }
        }
        var parts: Set<Part> = Set(Part.allCases)
        var from: Date? = nil
        var to: Date? = nil
        /// Model tests of these engines only (nil = all).
        var engines: Set<String>? = nil
        /// Pass 36: these model-test runs only (nil = all that match).
        var runs: Set<UUID>? = nil

        static let everything = Scope()
        var isPartial: Bool { parts != Set(Part.allCases) || from != nil || to != nil || engines != nil || runs != nil }
        func includes(_ date: Date) -> Bool { (from.map { date >= $0 } ?? true) && (to.map { date <= $0 } ?? true) }
    }

    @MainActor static func exportFile(edits: [(show: String, episode: String, edits: EditCounts)] = [],
                                      scope: Scope = .everything) async throws -> URL {
        let iso = ISO8601DateFormatter()
        let reportFiles = MetricsSubscriber.savedReports().filter { report in
            scope.includes(report.date)
                && (report.kind == "daily" ? scope.parts.contains(.dailyReports) : scope.parts.contains(.crashes))
        }
        // Read on the main actor (they are its state), encoded off it.
        let timings = scope.parts.contains(.timings) ? TimingLog.shared.entries.filter { scope.includes($0.date) } : []
        let tests = scope.parts.contains(.modelTests)
            ? ModelBench.shared.history.filter { scope.includes($0.date) && (scope.engines?.contains($0.engine) ?? true)
                && (scope.runs?.contains($0.runID) ?? true) } : []
        let trace = scope.parts.contains(.playback) ? PlaybackTrace.shared.entries.filter { scope.includes($0.date) } : []
        let recovery = scope.parts.contains(.libraryRecovery) ? LibraryRecoveryLog.load().filter { scope.includes($0.date) } : []
        let cleanups = scope.parts.contains(.cleanups) ? CleanupLog.load().filter { scope.includes($0.date) } : []
        // Pass 36 (his 13 Oct export: a seven-day period, but the background
        // events reached back two days and the playback trace less): what
        // each capped log really covers, so a period longer than what is kept
        // is never presented as complete.
        func coverage(_ dates: [Date], limit: Int) -> [String: Any] {
            let oldest = dates.min()
            let reachesStart = scope.from.map { start in oldest.map { $0 <= start } ?? false } ?? false
            let complete = dates.count < limit || reachesStart
            var entry: [String: Any] = ["kept": dates.count, "keptAtMost": limit, "complete": complete]
            if let oldest { entry["oldestKept"] = iso.string(from: oldest) }
            if !complete { entry["note"] = "Only the newest \(limit) entries are kept on the iPhone; the requested period starts before the oldest one." }
            return entry
        }
        var coverageBlock: [String: Any] = [:]
        if scope.parts.contains(.background) { coverageBlock["background"] = coverage(BackgroundLog.shared.events.map(\.date), limit: BackgroundLog.limit) }
        if scope.parts.contains(.playback) { coverageBlock["playback"] = coverage(PlaybackTrace.shared.entries.map(\.date), limit: PlaybackTrace.limit) }
        if scope.parts.contains(.timings) { coverageBlock["timings"] = coverage(TimingLog.shared.entries.map(\.date), limit: TimingLog.limit) }
        if scope.parts.contains(.cleanups) { coverageBlock["cleanups"] = coverage(CleanupLog.load().map(\.date), limit: CleanupLog.limit) }
        let everyPartComplete = coverageBlock.values.allSatisfy { (($0 as? [String: Any])?["complete"] as? Bool) ?? true }
        let events = scope.parts.contains(.background) ? BackgroundLog.shared.events.filter { scope.includes($0.date) } : []
        let facts = Dictionary(BackgroundWork.facts, uniquingKeysWith: { a, _ in a })
        let refusal = BackgroundWork.shared.lastRefusal ?? ""
        let info = Bundle.main.infoDictionary ?? [:]
        let app = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
        let editRows = scope.parts.contains(.corrections) ? edits.map { e -> [String: Any] in
            ["show": e.show, "episode": e.episode, "detected": e.edits.detected,
             "confirmed": e.edits.confirmed, "rejected": e.edits.rejected, "moved": e.edits.moved,
             "added": e.edits.added, "locked": e.edits.locked]
        } : []
        let device = deviceModel, os = UIDevice.current.systemVersion, build = BuildInfo.commit
        let resources = scope.parts.contains(.device) ? DeviceResources.measure().dictionary : [:]
        let scopeBlock: [String: Any] = [
            "parts": scope.parts.map(\.rawValue).sorted(),
            "from": scope.from.map { iso.string(from: $0) } ?? "", "to": scope.to.map { iso.string(from: $0) } ?? "",
            "engines": scope.engines.map { Array($0).sorted() } ?? [], "partial": scope.isPartial,
            "runs": scope.runs.map { $0.map(\.uuidString).sorted() } ?? [],
            "coverage": coverageBlock, "complete": !scope.isPartial && everyPartComplete,
        ]
        let editRowsCopy = editRows
        let eventRows = events.map { ["date": iso.string(from: $0.date), "text": $0.text] }
        let url: URL = try await Task.detached(priority: .userInitiated) {
            var reports: [[String: Any]] = []
            for file in reportFiles {
                if let data = try? Data(contentsOf: file.url), let json = try? JSONSerialization.jsonObject(with: data) {
                    reports.append(["kind": file.kind, "file": file.url.lastPathComponent, "report": json])
                }
            }
            func json<T: Encodable>(_ value: T) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(value))) ?? [] }
            var root: [String: Any] = [
                "schema": 2, "scope": scopeBlock,
                "exportedAt": ISO8601DateFormatter().string(from: .now), "app": app, "build": build,
                "device": device, "os": os,
                "timings": json(timings), "modelTests": json(tests), "edits": editRowsCopy,
                "metricKit": reports, "playbackTrace": json(trace), "libraryRecovery": json(recovery),
                "cleanups": json(cleanups),
            ]
            if !resources.isEmpty { root["resources"] = resources }
            root["background"] = ["facts": scope.parts.contains(.background) || scope.parts.contains(.device) ? facts : [:],
                                  "lastRefusal": refusal, "events": eventRows] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory
                .appending(path: "PodSkipper-diagnostics\(scope.isPartial ? "-partial" : "")-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url)
            return url
        }.value
        return url
    }
}

/// Every episode the phone has found ads in: what it cut, where, why, and
/// the transcript it worked from. Asked for (23 Sep) so the phone's own
/// results can be scored on the Mac instead of re-running them in the lab.
enum DetectionExport {
    /// Pass 35: which parts of each episode's record go in. Everything by
    /// default; a partial file says so in `scope`.
    struct Parts: Sendable, Equatable {
        var transcript = true
        var readerSegments = true
        var attempts = true
        var corrections = true
        var showLessons = true
        static let all = Parts()
    }

    @MainActor static func file(episodes: [Episode], parts: Parts = .all,
                                scopeNote: [String: Any] = [:]) async throws -> URL {
        let iso = ISO8601DateFormatter()
        var rows: [[String: Any]] = []
        for episode in episodes {
            let blob = parts.transcript ? episode.transcriptBlob() : nil
            var transcript: Any = NSNull()
            if let blob {
                transcript = (try? JSONSerialization.jsonObject(with: blob)) ?? blob.base64EncodedString()
            }
            let segments = episode.adSegments.sorted { $0.start < $1.start }.map { s -> [String: Any] in
                ["start": s.start, "end": s.end, "kind": s.kindRaw, "sponsor": s.sponsor,
                 "confidence": s.confidence, "verdict": s.userVerdict.rawValue, "origin": s.origin,
                 "delivery": s.deliveryRaw, "detail": s.detailRaw, "comedyBit": s.isComedyBit,
                 "insertedAtDownload": s.insertedAtDownload,
                 // Which stage found it (pass 20): "origin" said "detected"
                 // for all of them.
                 "stage": s.insertedAtDownload ? "ad-free comparison"
                    : s.evidenceText.contains(SegmentEvidence.repeatedAudio.rawValue) ? "fingerprint"
                    : s.evidenceText.hasPrefix("On-device model") ? "on-device model"
                    : s.origin == "detected" ? "model or rule" : s.origin,
                 "evidence": s.evidenceText,
                 "detectedStart": s.detectedStart, "detectedEnd": s.detectedEnd, "detectedKind": s.detectedKindRaw,
                 "locked": s.isLocked, "contains": s.containsRaw,
                 "mergedFrom": (s.mergedFromData.flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? []]
            }
            // Task 05: the reader's own answer beside the final cuts, so the
            // two finders can be compared on the Mac.
            var readerSegments: Any = NSNull()
            if parts.readerSegments, let data = episode.readerSegmentsData {
                readerSegments = (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
            }
            rows.append([
                "show": episode.podcast?.title ?? "", "title": episode.title, "guid": episode.guid,
                "audioURL": episode.audioURL, "published": iso.string(from: episode.publishedAt),
                "duration": episode.duration, "detectorVersion": episode.detectorVersion,
                "processedAt": episode.lastProcessedAt.map { iso.string(from: $0) } ?? "",
                "segments": segments, "readerSegments": readerSegments,
                "modelVersion": episode.modelVersion, "needsFullModelRead": episode.needsFullModelRead,
                "modelPending": episode.modelPending, "finder": episode.finderNote,
                // Pass 30: every attempt on this episode (reader, Apple
                // Intelligence, each MLX or Core AI model), newest first,
                // with what each proposed, what the cut check kept and
                // what was saved.
                "attempts": parts.attempts ? FinderAttemptLog.shared.exportRows(for: episode.guid) : [],
                // Pass 31: what he settled on this episode, with what the
                // detector first said and its grade, and what the show has
                // learned from him (passages, edge and bridge lessons).
                "corrections": parts.corrections ? ((episode.correctionLogData.flatMap { try? JSONSerialization.jsonObject(with: $0) }) ?? []) : [],
                "grade": CorrectionLedger.episodeGrade(episode).map { ["score": $0.score, "letter": $0.letter, "settled": $0.count] as [String: Any] } ?? NSNull(),
                "showLessons": (parts.showLessons ? (episode.podcast?.corrections ?? []) : []).map { c -> [String: Any] in
                    ["kind": c.kind ?? "notAnAd", "boundary": c.boundary ?? "", "words": String(c.excerpt.prefix(120)),
                     "added": iso.string(from: c.addedAt)]
                },
                "transcript": transcript,
            ])
            await Task.yield()
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let root: [String: Any] = [
            "exportedAt": iso.string(from: .now),
            "app": "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))",
            "build": BuildInfo.commit,
            "timings": (try? JSONSerialization.jsonObject(with: JSONEncoder.iso.encode(TimingLog.shared.entries))) ?? [],
            "episodes": rows,
            "schema": 2,
            "scope": scopeNote.merging(["parts": ["transcript": parts.transcript, "readerSegments": parts.readerSegments,
                                                  "attempts": parts.attempts, "corrections": parts.corrections,
                                                  "showLessons": parts.showLessons],
                                        "episodes": rows.count]) { a, _ in a },
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PodSkipper-results\((scopeNote["partial"] as? Bool) == true || parts != .all ? "-partial" : "")-\(Int(Date().timeIntervalSince1970)).json")
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
