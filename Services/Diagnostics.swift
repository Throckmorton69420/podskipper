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
        /// Pass 36: these iOS report files only, by name (nil = all that match).
        var reports: Set<String>? = nil

        static let everything = Scope()
        var isPartial: Bool { parts != Set(Part.allCases) || from != nil || to != nil || engines != nil || runs != nil || reports != nil }
        func includes(_ date: Date) -> Bool { (from.map { date >= $0 } ?? true) && (to.map { date <= $0 } ?? true) }
    }

    @MainActor static func exportFile(edits: [(show: String, episode: String, edits: EditCounts)] = [],
                                      scope: Scope = .everything) async throws -> URL {
        let iso = ISO8601DateFormatter()
        let reportFiles = MetricsSubscriber.savedReports().filter { report in
            scope.includes(report.date)
                && (report.kind == "daily" ? scope.parts.contains(.dailyReports) : scope.parts.contains(.crashes))
                && (scope.reports?.contains(report.url.lastPathComponent) ?? true)
        }
        // Read on the main actor (they are its state), encoded off it.
        let timings = scope.parts.contains(.timings) ? TimingLog.shared.entries.filter { scope.includes($0.date) } : []
        let tests = scope.parts.contains(.modelTests)
            ? ModelBench.shared.history.filter { scope.includes($0.date) && (scope.engines?.contains($0.engine) ?? true)
                && (scope.runs?.contains($0.runID) ?? true) } : []
        // Pass 60: the PodSkipper test's runs on this iPhone (time spans and
        // kinds per episode; `podtest.py --phone` scores them on the Mac).
        let podTests = scope.parts.contains(.modelTests) && scope.engines == nil && scope.runs == nil
            ? PodTestRunner.shared.exportRuns(from: scope.from, to: scope.to) : []
        let podTestPack = PodTestRunner.shared.pack?.version ?? 0
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
        if scope.parts.contains(.crashes) || scope.parts.contains(.dailyReports) {
            // MetricsSubscriber keeps the newest 40 report files.
            coverageBlock["reportsFromIOS"] = coverage(MetricsSubscriber.savedReports().map(\.date), limit: 40)
        }
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
        // Pass 38: what the reader learned on this iPhone.
        let learning = scope.parts.contains(.device) ? await OnDeviceReaderLearner.shared.currentStatus() : nil
        let scopeBlock: [String: Any] = [
            "parts": scope.parts.map(\.rawValue).sorted(),
            "from": scope.from.map { iso.string(from: $0) } ?? "", "to": scope.to.map { iso.string(from: $0) } ?? "",
            "engines": scope.engines.map { Array($0).sorted() } ?? [], "partial": scope.isPartial,
            "runs": scope.runs.map { $0.map(\.uuidString).sorted() } ?? [],
            "reports": scope.reports.map { Array($0).sorted() } ?? [],
            "coverage": coverageBlock, "complete": !scope.isPartial && everyPartComplete,
        ]
        let editRowsCopy = editRows
        let eventRows = events.map { ["date": iso.string(from: $0.date), "text": $0.text] }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PodSkipper-diagnostics\(scope.isPartial ? "-partial" : "")-\(Int(Date().timeIntervalSince1970)).json")
        let background: [String: Any] = ["facts": scope.parts.contains(.background) || scope.parts.contains(.device) ? facts : [:],
                                         "lastRefusal": refusal, "events": eventRows]
        let rest: [String: Any] = ["app": app, "build": build, "device": device, "os": os, "schema": 2,
                                   "edits": editRowsCopy, "scope": scopeBlock, "background": background,
                                   "resources": resources]
        // Pass 62 (his exports kept closing PodSkipper): the file is written
        // as it is made, one part at a time, on a thread with a large stack —
        // nothing holds the whole file in memory, and nothing deep can run
        // the writer out of stack. iOS reports are copied in as saved.
        try await LargeStack.run {
            let out = try JSONFileWriter(url: url)
            do {
                try out.object { key in
                    try key("app") { try out.value(rest["app"]!) }
                    try key("background") { try out.value(rest["background"]!) }
                    try key("build") { try out.value(rest["build"]!) }
                    try key("cleanups") { try out.encodable(cleanups) }
                    try key("device") { try out.value(rest["device"]!) }
                    try key("edits") { try out.value(rest["edits"]!) }
                    try key("exportedAt") { try out.value(ISO8601DateFormatter().string(from: .now)) }
                    try key("libraryRecovery") { try out.encodable(recovery) }
                    try key("metricKit") {
                        try out.raw("[")
                        var first = true
                        for file in reportFiles {
                            guard let data = try? Data(contentsOf: file.url), RawJSON.isObject(data) else { continue }
                            if !first { try out.raw(",\n") }
                            first = false
                            try out.raw(RawJSON.entry(kind: file.kind, file: file.url.lastPathComponent, report: data))
                        }
                        try out.raw("]")
                    }
                    try key("modelTests") { try out.encodable(tests) }
                    try key("os") { try out.value(rest["os"]!) }
                    try key("playbackTrace") { try out.encodable(trace) }
                    if !podTests.isEmpty {
                        try key("podTest") {
                            try out.object { inner in
                                try inner("packVersion") { try out.value(podTestPack) }
                                try inner("runs") { try out.encodable(podTests) }
                            }
                        }
                    }
                    if let learning { try key("readerLearning") { try out.encodable(learning) } }
                    if !resources.isEmpty { try key("resources") { try out.value(resources) } }
                    try key("schema") { try out.value(2) }
                    try key("scope") { try out.value(scopeBlock) }
                    try key("timings") { try out.encodable(timings) }
                }
                try out.close()
            } catch {
                try? out.close()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
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

    /// Pass 62 (his results exports, ~100 MB, kept closing PodSkipper):
    /// written as it is made. Each episode's row is read on the main actor
    /// (it is the library's), turned into bytes there (small: everything but
    /// the transcript), and appended to the file off the main thread; the
    /// transcript goes in as stored, never parsed and written again. Memory
    /// holds one episode at a time, not the whole file twice over.
    @MainActor static func file(episodes: [Episode], parts: Parts = .all,
                                scopeNote: [String: Any] = [:]) async throws -> URL {
        let iso = ISO8601DateFormatter()
        let info = Bundle.main.infoDictionary ?? [:]
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PodSkipper-results\((scopeNote["partial"] as? Bool) == true || parts != .all ? "-partial" : "")-\(Int(Date().timeIntervalSince1970)).json")
        let sink = try JSONFileSink(url: url)
        do {
            let app = "\(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))"
            try await sink.append(Data("{\"app\":".utf8) + JSONFileWriter.bytes(app)
                                  + Data(",\"build\":".utf8) + JSONFileWriter.bytes(BuildInfo.commit)
                                  + Data(",\"episodes\":[".utf8))
            var count = 0
            for episode in episodes {
                try Task.checkCancellation()
                let row = try Self.row(episode, parts: parts, iso: iso)
                try await sink.append((count > 0 ? Data(",\n".utf8) : Data()) + row)
                count += 1
                await Task.yield()
            }
            let scope = scopeNote.merging(["parts": ["transcript": parts.transcript, "readerSegments": parts.readerSegments,
                                                     "attempts": parts.attempts, "corrections": parts.corrections,
                                                     "showLessons": parts.showLessons],
                                           "episodes": count]) { a, _ in a }
            let timings = try JSONEncoder.iso.encode(TimingLog.shared.entries)
            try await sink.append(Data("],\"exportedAt\":".utf8) + JSONFileWriter.bytes(iso.string(from: .now))
                                  + Data(",\"schema\":2,\"scope\":".utf8)
                                  + (try JSONSerialization.data(withJSONObject: scope, options: [.sortedKeys]))
                                  + Data(",\"timings\":".utf8) + timings + Data("}".utf8))
            try await sink.close()
        } catch {
            try? await sink.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// One episode's record as JSON bytes (keys sorted), its transcript
    /// copied in as stored.
    @MainActor static func row(_ episode: Episode, parts: Parts, iso: ISO8601DateFormatter) throws -> Data {
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
        let token = "pk-transcript-\(UUID().uuidString)"
        let row: [String: Any] = [
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
            "transcript": token,
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        var transcript = Data("null".utf8)
        if parts.transcript, let blob = episode.transcriptBlob() {
            transcript = RawJSON.isValue(blob) ? blob : JSONFileWriter.bytes(blob.base64EncodedString())
        }
        return RawJSON.splice(data, token: token, raw: transcript)
    }
}

/// Pass 61: JSON handled as bytes, for iOS reports nested too deeply for
/// JSONSerialization's recursive writer.
enum RawJSON {
    /// Deepest nesting of objects and arrays, by scanning the bytes (no
    /// recursion); nil when the brackets don't balance or a string isn't closed.
    static func depth(_ data: Data) -> Int? {
        var depth = 0, deepest = 0, inString = false, escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1; deepest = max(deepest, depth)
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth < 0 { return nil }
            default: break
            }
        }
        return depth == 0 && !inString ? deepest : nil
    }

    /// A whole JSON object (first non-space byte `{`, brackets balanced).
    static func isObject(_ data: Data) -> Bool {
        guard let first = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }), first == UInt8(ascii: "{") else { return false }
        return (depth(data) ?? 0) > 0
    }

    /// `{"file":…,"kind":…,"report":<report as saved>}` (keys sorted, as the rest of the file).
    static func entry(kind: String, file: String, report: Data) -> Data {
        func string(_ s: String) -> Data { (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8) }
        var out = Data("{\"file\":".utf8)
        out += string(file); out += Data(",\"kind\":".utf8); out += string(kind)
        out += Data(",\"report\":".utf8); out += report; out += Data("}".utf8)
        return out
    }

    /// Pass 62: a whole JSON array or object (balanced, first byte `[` or `{`).
    static func isValue(_ data: Data) -> Bool {
        guard let first = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }),
              first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else { return false }
        return (depth(data) ?? 0) > 0
    }

    /// Pass 62: replaces the string `"token"` in `json` with `raw` bytes.
    static func splice(_ json: Data, token: String, raw: Data) -> Data {
        guard let range = json.range(of: Data("\"\(token)\"".utf8)) else { return json }
        var out = json
        out.replaceSubrange(range, with: raw)
        return out
    }

    /// Replaces the string `"token"` in `json` with an array of `items`.
    static func splice(_ json: Data, token: String, with items: [Data]) -> Data {
        guard let range = json.range(of: Data("\"\(token)\"".utf8)) else { return json }
        var array = Data("[".utf8)
        for (i, item) in items.enumerated() {
            if i > 0 { array += Data(",\n".utf8) }
            array += item
        }
        array += Data("]".utf8)
        var out = json
        out.replaceSubrange(range, with: array)
        return out
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

/// Pass 62: JSON written to a file as it is made, buffered (1 MB), keys in
/// the order given (callers give them sorted, as the files always were).
final class JSONFileWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private var closed = false
    static let flushAt = 1 << 20

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
    }

    deinit { if !closed { try? handle.close() } }

    func raw(_ text: String) throws { try raw(Data(text.utf8)) }

    func raw(_ data: Data) throws {
        buffer.append(data)
        if buffer.count >= Self.flushAt { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    func close() throws {
        guard !closed else { return }
        try flush()
        try handle.close()
        closed = true
    }

    /// `{"a":…,"b":…}`: `body` names each key in turn and writes its value.
    func object(_ body: ((String, () throws -> Void) throws -> Void) throws -> Void) throws {
        try raw("{")
        var first = true
        try body { key, value in
            try raw((first ? "" : ",") + "\n")
            first = false
            try raw(Self.bytes(key))
            try raw(":")
            try value()
        }
        try raw("}")
    }

    /// A plain value (dictionary, array, string, number, bool, null).
    func value(_ value: Any) throws {
        try raw(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
    }

    /// An `Encodable` value, encoded straight to bytes (dates ISO 8601).
    func encodable<T: Encodable>(_ value: T) throws { try raw(try JSONEncoder.iso.encode(value)) }

    static func bytes(_ string: String) -> Data { (try? JSONEncoder().encode(string)) ?? Data("\"\"".utf8) }
}

/// Pass 62: appends to a file off the main thread, in order.
actor JSONFileSink {
    private let writer: JSONFileWriter
    init(url: URL) throws { writer = try JSONFileWriter(url: url) }
    func append(_ data: Data) throws { try writer.raw(data) }
    func close() throws { try writer.close() }
}

/// Pass 62: work on a thread of its own with a 16 MB stack (a Swift
/// concurrency thread has 512 KB — his 7 Nov crash reports show the export
/// overflowing one).
enum LargeStack {
    static let size = 16 << 20

    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<T, Error>) in
            let thread = Thread {
                do { done.resume(returning: try work()) } catch { done.resume(throwing: error) }
            }
            thread.stackSize = size
            thread.qualityOfService = .userInitiated
            thread.name = "PodSkipper.export"
            thread.start()
        }
    }
}
