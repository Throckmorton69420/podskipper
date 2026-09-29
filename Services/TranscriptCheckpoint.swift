import Foundation
import Speech
import AVFoundation

/// What a transcription had finished when it was stopped, so the next try
/// carries on instead of starting over.
///
/// 29 Sep: iOS kept ending the background window part way through a long
/// episode (nine attempts, each ~4.5 minutes), and each attempt began again
/// at zero, so the episode never finished. A checkpoint is written at least
/// every minute of audio and when the job is cancelled; the next call with
/// the same key starts from a little before where it got to.
struct TranscriptCheckpoint: Codable {
    struct Line: Codable {
        var text: String
        var start: Double
        var end: Double
        var words: [TranscriptWord]
    }

    var key: String
    /// The audio file, "~/…" relative to the app's home folder: the absolute
    /// path changes when the app is reinstalled or restored.
    var filePath: String
    /// Size of the audio file when this was saved. A different size means a
    /// different file (re-downloaded, replaced), so the lines don't belong.
    var fileSize: Int64
    var savedAt: Date
    /// Audio time, in seconds, that the saved lines reach.
    var reached: Double
    var lines: [Line]

    var segments: [TranscriptSegment] {
        lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words) }
    }
}

enum TranscriptCheckpointStore {
    /// Older than this, a checkpoint is thrown away rather than trusted.
    static let maxAge: TimeInterval = 7 * 24 * 3600

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "TranscriptCheckpoints", directoryHint: .isDirectory)
    }

    static func url(_ key: String) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return folder.appending(path: String(hash, radix: 16) + ".json")
    }

    /// "~/Library/…" for a file in the app's own space, else the full path.
    static func relativePath(_ file: URL) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        let path = file.resolvingSymlinksInPath().path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func absoluteURL(_ stored: String) -> URL {
        stored.hasPrefix("~/")
            ? URL(fileURLWithPath: NSHomeDirectory() + stored.dropFirst())
            : URL(fileURLWithPath: stored)
    }

    static func fileSize(_ file: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
    }

    /// The checkpoint for this key and file, if it is recent and was made
    /// from this same file. Anything else found under the key is deleted.
    static func load(key: String, file: URL) -> TranscriptCheckpoint? {
        let location = url(key)
        guard let data = try? Data(contentsOf: location) else { return nil }
        guard let saved = try? JSONDecoder().decode(TranscriptCheckpoint.self, from: data),
              saved.key == key,
              Date.now.timeIntervalSince(saved.savedAt) < maxAge,
              let size = fileSize(file), size == saved.fileSize else {
            try? FileManager.default.removeItem(at: location)
            return nil
        }
        return saved
    }

    static func save(_ checkpoint: TranscriptCheckpoint) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(checkpoint) else { return }
        try? data.write(to: url(checkpoint.key), options: .atomic)
    }

    static func delete(key: String) {
        try? FileManager.default.removeItem(at: url(key))
    }

    /// Removes checkpoints older than seven days, unreadable ones, and ones
    /// whose audio file is gone.
    static func sweep() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let saved = (try? Data(contentsOf: file))
                .flatMap { try? JSONDecoder().decode(TranscriptCheckpoint.self, from: $0) }
            let keep = saved.map {
                Date.now.timeIntervalSince($0.savedAt) < maxAge
                    && fm.fileExists(atPath: absoluteURL($0.filePath).path)
            } ?? false
            if !keep { try? fm.removeItem(at: file) }
        }
    }
}

// MARK: - Resumable transcription

/// Everything transcribed so far, shared between the task collecting results
/// and the cancellation handler, which has to save it without awaiting.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [TranscriptSegment]
    private var fresh: [TranscriptSegment] = []
    private var lastSaved: Double

    init(kept: [TranscriptSegment], reached: Double) {
        self.kept = kept
        self.lastSaved = reached
    }

    /// Adds a line, dropping one that repeats what the saved lines already
    /// cover (the few seconds transcribed twice around the resume point).
    /// Returns true when another minute of audio has passed since the last
    /// save.
    func add(_ segment: TranscriptSegment) -> Bool {
        lock.withLock {
            let coveredTo = kept.last?.end ?? 0
            if !kept.isEmpty, segment.start < coveredTo - 0.25 { return false }
            fresh.append(segment)
            return segment.end - lastSaved >= 60
        }
    }

    var all: [TranscriptSegment] { lock.withLock { kept + fresh } }

    func checkpoint(key: String, file: URL, size: Int64) -> TranscriptCheckpoint {
        lock.withLock {
            let lines = (kept + fresh).map {
                TranscriptCheckpoint.Line(text: $0.text, start: $0.start, end: $0.end, words: $0.words)
            }
            let reached = lines.map(\.end).max() ?? 0
            lastSaved = reached
            return TranscriptCheckpoint(key: key,
                                        filePath: TranscriptCheckpointStore.relativePath(file),
                                        fileSize: size, savedAt: .now, reached: reached, lines: lines)
        }
    }
}

private final class HandedFlag: @unchecked Sendable { var value = false }

/// Reads an audio file from a given frame, converted to the analyzer's
/// format, as `AnalyzerInput`s. Pulled one chunk at a time as the analyzer
/// asks, so a long episode is never held in memory whole.
private final class FileAnalyzerInput: AsyncSequence, AsyncIteratorProtocol, @unchecked Sendable {
    typealias Element = AnalyzerInput

    private let file: AVAudioFile
    private let target: AVAudioFormat
    private let converter: AVAudioConverter?
    private let chunk: AVAudioFrameCount = 32_768
    private var startTime: CMTime?
    private var reachedEnd = false
    private var flushed = false

    init(file: AVAudioFile, from frame: AVAudioFramePosition, target: AVAudioFormat) throws {
        self.file = file
        self.target = target
        file.framePosition = max(0, min(frame, file.length))
        if file.processingFormat == target {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: file.processingFormat, to: target) else {
                throw TranscriptionError.fileUnreadable("can't convert this audio for transcription")
            }
            converter = made
        }
        // The first buffer carries the real time it starts at; the rest follow
        // on from it.
        startTime = CMTime(value: file.framePosition,
                           timescale: CMTimeScale(file.processingFormat.sampleRate))
    }

    func makeAsyncIterator() -> FileAnalyzerInput { self }

    func next() async throws -> AnalyzerInput? {
        while true {
            try Task.checkCancellation()
            guard let buffer = try nextBuffer() else { return nil }
            guard buffer.frameLength > 0 else { continue }
            let input = AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
            startTime = nil
            return input
        }
    }

    /// The next converted buffer; empty if the converter needs more input
    /// first, nil at the end.
    private func nextBuffer() throws -> AVAudioPCMBuffer? {
        if flushed { return nil }
        var source: AVAudioPCMBuffer?
        if !reachedEnd {
            guard let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else {
                throw TranscriptionError.fileUnreadable("out of memory")
            }
            try file.read(into: read, frameCount: chunk)
            if read.frameLength == 0 { reachedEnd = true } else { source = read }
        }

        guard let converter else {
            if let source { return source }
            flushed = true
            return nil
        }

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(chunk) * ratio) + 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw TranscriptionError.fileUnreadable("out of memory")
        }
        // A reference rather than a captured `var`: the converter's input
        // block is an Objective-C block and may be treated as concurrent.
        let handed = HandedFlag()
        let atEnd = reachedEnd
        let pending = source
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if let pending, !handed.value {
                handed.value = true
                state.pointee = .haveData
                return pending
            }
            state.pointee = atEnd ? .endOfStream : .noDataNow
            return nil
        }
        if status == .error {
            throw TranscriptionError.fileUnreadable(error?.localizedDescription ?? "conversion failed")
        }
        if atEnd, status == .endOfStream || out.frameLength == 0 {
            flushed = true
            return out.frameLength > 0 ? out : nil
        }
        return out
    }
}

extension TranscriptionService {

    /// Like `transcribe(fileURL:)`, but survives being stopped part way.
    ///
    /// Saves what it has transcribed to a small checkpoint (Application
    /// Support/TranscriptCheckpoints) at least every minute of audio, and
    /// when cancelled or when it fails. Called again with the same
    /// `checkpointKey` (the episode's guid is the natural key), it keeps the
    /// saved lines and transcribes only from about 5 seconds before where
    /// they stopped, dropping lines it hears twice. On success the checkpoint
    /// is deleted and the whole transcript comes back, sorted by time — the
    /// same shape as `transcribe(fileURL:)`.
    ///
    /// A checkpoint older than seven days, or made from a different file, is
    /// ignored and deleted.
    func transcribe(fileURL: URL,
                    checkpointKey: String,
                    locale: Locale = Locale(identifier: "en-US"),
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptSegment] {
        TranscriptCheckpointStore.sweep()

        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscriptionError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.assetInstallFailed(error.localizedDescription)
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.fileUnreadable(error.localizedDescription)
        }
        let sampleRate = audioFile.processingFormat.sampleRate
        let totalSeconds = Double(audioFile.length) / sampleRate
        let fileSize = TranscriptCheckpointStore.fileSize(fileURL) ?? 0

        // Where to pick up. Back up about 5 seconds from where the saved
        // lines reach, and further to the start of the line that was being
        // said then, so the new run begins on a line boundary: that line and
        // anything after it is dropped from the saved ones and heard again.
        var kept: [TranscriptSegment] = []
        var resumeAt = 0.0
        if let saved = TranscriptCheckpointStore.load(key: checkpointKey, file: fileURL), saved.reached > 10 {
            let ordered = saved.segments.sorted { $0.start < $1.start }
            let target = max(0, saved.reached - 5)
            let boundary = ordered.first(where: { $0.end > target })?.start ?? target
            resumeAt = max(0, min(target, boundary))
            kept = ordered.filter { $0.end <= resumeAt + 0.01 }
            if resumeAt < 1 { kept = []; resumeAt = 0 }
        }

        let box = ResumeBox(kept: kept, reached: resumeAt)
        let key = checkpointKey
        let saveNow: @Sendable () -> Void = {
            TranscriptCheckpointStore.save(box.checkpoint(key: key, file: fileURL, size: fileSize))
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> Void in
            for try await result in transcriber.results {
                let attributed = result.text
                let plain = String(attributed.characters)
                guard !plain.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                var start = 0.0, end = 0.0
                var words: [TranscriptWord] = []
                for run in attributed.runs {
                    if let range = run.audioTimeRange {
                        let s = range.start.seconds
                        let e = range.end.seconds
                        if start == 0 { start = s }
                        end = max(end, e)
                        let token = String(attributed[run.range].characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !token.isEmpty, s.isFinite, e.isFinite {
                            words.append(TranscriptWord(text: token, start: s, end: e))
                        }
                    }
                }
                if box.add(TranscriptSegment(text: plain, start: start, end: end, words: words)) {
                    saveNow()
                }
                if totalSeconds > 0 { progress?(min(1, end / totalSeconds)) }
            }
        }

        do {
            try await withTaskCancellationHandler {
                if resumeAt == 0 {
                    // From the start: the same call `transcribe(fileURL:)` uses.
                    _ = try await analyzer.analyzeSequence(from: audioFile)
                } else {
                    // The analyzer doesn't convert buffers itself, so read
                    // from the resume point and convert to its format.
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                        throw TranscriptionError.assetInstallFailed("no audio format available")
                    }
                    let input = try FileAnalyzerInput(file: audioFile,
                                                      from: AVAudioFramePosition(resumeAt * sampleRate),
                                                      target: format)
                    if totalSeconds > 0 { progress?(min(1, resumeAt / totalSeconds)) }
                    _ = try await analyzer.analyzeSequence(input)
                }
                try Task.checkCancellation()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await collector.value
                try Task.checkCancellation()
            } onCancel: {
                saveNow()
                collector.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            // Keep what was done for the next try, whatever stopped this one.
            saveNow()
            throw error
        }

        TranscriptCheckpointStore.delete(key: checkpointKey)
        progress?(1)
        return box.all.sorted { $0.start < $1.start }
    }
}
