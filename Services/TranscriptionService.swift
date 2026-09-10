import Foundation
import Speech
import AVFoundation

/// One chunk of transcript with the time range it came from.
struct TranscriptSegment: Sendable {
    let text: String
    let start: Double
    let end: Double
}

enum TranscriptionError: LocalizedError {
    case unsupportedLocale
    case assetInstallFailed(String)
    case fileUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            return "This language isn't supported by on-device transcription yet."
        case .assetInstallFailed(let m):
            return "Couldn't download the speech model: \(m)"
        case .fileUnreadable(let m):
            return "Couldn't read the audio file: \(m)"
        }
    }
}

/// Wraps Apple's SpeechAnalyzer (iOS 26+). Fully on-device: no network, no API key,
/// no per-minute cost. This is the piece that makes the whole app possible —
/// before iOS 26, SFSpeechRecognizer capped you at roughly a minute per request.
actor TranscriptionService {

    /// Transcribe a local audio file into timestamped segments.
    /// - Parameter progress: called with 0...1 as the file is consumed.
    func transcribe(fileURL: URL,
                    locale: Locale = Locale(identifier: "en-US"),
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptSegment] {

        // 1. Is this locale supported at all?
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscriptionError.unsupportedLocale
        }

        // 2. Build the transcriber. `.audioTimeRange` is what gives us timestamps —
        //    without it we get text with no idea where the ads are.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // 3. Make sure the on-device model is present. First run downloads it
        //    (a few hundred MB); after that this is a no-op.
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptionError.assetInstallFailed(error.localizedDescription)
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw TranscriptionError.fileUnreadable(error.localizedDescription)
        }
        let totalSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        // 4. Collect results as they stream in. The collector returns its
        //    array rather than writing into a captured variable — mutating a
        //    local from inside a Task is a data race.
        let collector = Task { () -> [TranscriptSegment] in
            var collected: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let attributed = result.text
                let plain = String(attributed.characters)
                guard !plain.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

                // Pull the time range off the attributed run.
                var start = 0.0, end = 0.0
                for run in attributed.runs {
                    if let range = run.audioTimeRange {
                        let s = range.start.seconds
                        let e = range.end.seconds
                        if start == 0 { start = s }
                        end = max(end, e)
                    }
                }
                collected.append(TranscriptSegment(text: plain, start: start, end: end))
                if totalSeconds > 0 { progress?(min(1, end / totalSeconds)) }
            }
            return collected
        }

        try await analyzer.analyzeSequence(from: audioFile)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let segments = try await collector.value

        progress?(1)
        return segments.sorted { $0.start < $1.start }
    }
}

// MARK: - Windowing

extension Array where Element == TranscriptSegment {

    /// Group segments into overlapping time windows for the classifier.
    ///
    /// Apple's on-device model has a 4,096-token context window, so a whole
    /// hour-long transcript can't be sent at once — it has to be sliced.
    /// Overlap matters: an ad read that straddles a boundary would otherwise
    /// look like half a sentence to the model on both sides.
    func windows(length: Double = 45, overlap: Double = 10) -> [TranscriptWindow] {
        guard let last = self.last else { return [] }
        var result: [TranscriptWindow] = []
        var cursor = 0.0
        let step = Swift.max(1, length - overlap)

        while cursor < last.end {
            let upper = cursor + length
            let inside = self.filter { $0.start < upper && $0.end > cursor }
            if !inside.isEmpty {
                let text = inside.map(\.text).joined(separator: " ")
                result.append(TranscriptWindow(
                    start: inside.first!.start,
                    end: inside.last!.end,
                    text: text
                ))
            }
            cursor += step
        }
        return result
    }
}

struct TranscriptWindow: Sendable {
    let start: Double
    let end: Double
    let text: String
}
