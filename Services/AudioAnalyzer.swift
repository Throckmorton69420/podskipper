import Foundation
import AVFoundation
import Accelerate

/// Measures an episode once, at processing time, so playback stays cheap.
///
/// Overcast computes Smart Speed live while you listen. Doing it from a
/// precomputed map is more accurate — we can see the whole silence before
/// deciding how much to cut, rather than guessing as it arrives — and it
/// costs nothing at play time.
enum AudioAnalyzer {

    struct Analysis {
        /// Stretches quiet enough to shorten.
        var silences: [ClosedRange<Double>]
        /// Multiplier that brings this episode to the target loudness.
        var normalizationGain: Double
        /// Measured average level, in dBFS, for display.
        var averageDB: Double
    }

    /// Everything is judged against this. -20 dBFS RMS is a common target for
    /// spoken word and sits comfortably below clipping.
    private static let targetDB: Double = -20

    /// Below this counts as silence.
    private static let silenceFloorDB: Double = -45

    /// Shorter gaps than this are natural speech rhythm, not dead air.
    private static let minimumSilence: Double = 0.32

    static func analyze(fileURL: URL,
                        progress: (@Sendable (Double) -> Void)? = nil) throws -> Analysis {

        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let totalFrames = file.length
        guard totalFrames > 0, sampleRate > 0 else {
            return Analysis(silences: [], normalizationGain: 1, averageDB: 0)
        }

        // 25 ms windows: fine enough to find the edges of a pause, coarse
        // enough that an hour of audio is a manageable number of readings.
        let windowFrames = AVAudioFrameCount(sampleRate * 0.025)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: windowFrames) else {
            return Analysis(silences: [], normalizationGain: 1, averageDB: 0)
        }

        var windowLevels: [Double] = []
        windowLevels.reserveCapacity(Int(Double(totalFrames) / Double(windowFrames)) + 1)
        var sumOfSquares: Double = 0
        var countedFrames: Double = 0
        var framesRead: AVAudioFramePosition = 0

        while framesRead < totalFrames {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: windowFrames)
            } catch where AudioFileEnd.isEnd(error, file: file) {
                break   // pass 31: shorter than its header says; measured to the real end
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }

            guard let channels = buffer.floatChannelData else { break }
            var windowSum: Double = 0
            let channelCount = Int(format.channelCount)
            for channel in 0..<channelCount {
                var meanSquare: Float = 0
                vDSP_measqv(channels[channel], 1, &meanSquare, vDSP_Length(frames))
                windowSum += Double(meanSquare)
            }
            let rms = (windowSum / Double(max(1, channelCount))).squareRoot()
            windowLevels.append(rms)

            sumOfSquares += windowSum / Double(max(1, channelCount)) * Double(frames)
            countedFrames += Double(frames)
            framesRead += AVAudioFramePosition(frames)

            if totalFrames > 0 {
                progress?(min(1, Double(framesRead) / Double(totalFrames)))
            }
        }

        // Overall loudness
        let overallRMS = countedFrames > 0 ? (sumOfSquares / countedFrames).squareRoot() : 0
        let averageDB = overallRMS > 0 ? 20 * log10(overallRMS) : -120
        var gain = 1.0
        if averageDB > -120 {
            gain = pow(10, (targetDB - averageDB) / 20)
            // Never boost so hard that a loud passage clips, never duck to nothing.
            gain = min(3.0, max(0.4, gain))
        }

        // Silence runs
        let windowSeconds = 0.025
        let floor = pow(10, silenceFloorDB / 20)
        var silences: [ClosedRange<Double>] = []
        var runStart: Int? = nil

        for (index, level) in windowLevels.enumerated() {
            if level < floor {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let seconds = Double(index - start) * windowSeconds
                if seconds >= minimumSilence {
                    silences.append(Double(start) * windowSeconds...Double(index) * windowSeconds)
                }
                runStart = nil
            }
        }
        if let start = runStart {
            let seconds = Double(windowLevels.count - start) * windowSeconds
            if seconds >= minimumSilence {
                // Swift won't let `...` begin a line, so the bounds are named.
                let from = Double(start) * windowSeconds
                let to = Double(windowLevels.count) * windowSeconds
                silences.append(from...to)
            }
        }

        progress?(1)
        return Analysis(silences: silences, normalizationGain: gain, averageDB: averageDB)
    }

    /// Turns raw silences into the ranges Smart Speed should actually jump.
    ///
    /// A pause is never removed completely — that makes speech sound spliced.
    /// We keep a beat at each end and cut the middle.
    static func smartSpeedJumps(from silences: [ClosedRange<Double>],
                                aggressiveness: Double,
                                keepAtLeast: Double = 0.14) -> [ClosedRange<Double>] {
        let amount = min(1, max(0, aggressiveness))
        return silences.compactMap { silence in
            let length = silence.upperBound - silence.lowerBound
            let keep = max(keepAtLeast, length * (1 - amount))
            let cut = length - keep
            guard cut > 0.08 else { return nil }
            let start = silence.lowerBound + keep / 2
            return start...(start + cut)
        }
    }
}

/// Pass 31 (his 6 Oct Diagnostics): three episodes failed with
/// "OSStatus error -39" — Core Audio's end-of-file error. An MP3's header
/// can promise more audio than the file holds (a variable-bit-rate file
/// whose length is an estimate, or one the server cut short), so the last
/// read fails. #201 failed twice within 2 s of starting: the saved
/// transcript resumed just before the end and hit the same wall. What was
/// read is the episode; reading stops there instead of failing the job.
enum AudioFileEnd {
    /// `kAudioFileEndOfFileError` ('eofErr').
    static let code = -39

    static func isEnd(_ error: Error, file: AVAudioFile) -> Bool {
        isEnd(error, position: file.framePosition, length: file.length)
    }

    static func isEnd(_ error: Error, position: AVAudioFramePosition, length: AVAudioFramePosition) -> Bool {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain, ns.code == code { return true }
        // Any other read error in the last 2 % is the same broken tail.
        return length > 0 && Double(position) >= Double(length) * 0.98
    }
}
