import XCTest
import AVFoundation
@testable import PodSkipper

@MainActor
final class ChapterPlaybackTests: XCTestCase {
    /// A chapter in the last half-second is still a valid start. Restarting
    /// the actual engine here used to contradict the requested chapter time.
    func testFinalSecondChapterStartUsesRequestedAudioFrames() throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chapter.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        try XCTUnwrap(buffer.floatChannelData)[0].initialize(repeating: 0, count: Int(buffer.frameLength))
        do {
            let output = try AVAudioFile(forWriting: file, settings: format.settings)
            try output.write(from: buffer)
        }
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.adopt(try AVAudioFile(forReading: file))
        XCTAssertEqual(engine.duration, 2, accuracy: 0.001)
        let requested = 1.75
        try engine.play(from: requested)
        engine.pause()
        // currentTime adds the node's sampleTime to the scheduled origin.
        // Its first render timestamp can lead audible output by one latency
        // interval (observed21ms in the simulator), even immediately on pause.
        let earliestAudiblePosition = max(1, requested - engine.outputLatency - 0.005)
        XCTAssertGreaterThanOrEqual(engine.currentTime, earliestAudiblePosition,
            "The start must remain near1.75s, allowing measured output latency\(engine.outputLatency)s")
        XCTAssertLessThan(engine.currentTime, 2,
                          "A final-second chapter start must not become an episode restart")
    }
}
