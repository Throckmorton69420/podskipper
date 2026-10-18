import XCTest
import AVFoundation
@testable import PodSkipper

/// Pass 42: sound that stopped while the player kept counting (his 18 Oct
/// phone, Bonsai 27B test at serious). These run the real `AudioEngine` in
/// the simulator; starving its reader is done with the test hook, which
/// stands in for a reading thread that gets no time.
@MainActor
final class Pass42AudioTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A quiet 440 Hz tone, so the file is not digital silence.
    private func tone(seconds: Double) throws -> AVAudioFile {
        let url = folder.appendingPathComponent("tone-\(seconds).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in 0..<Int(frames) {
            let v = Float(0.05 * sin(2 * Double.pi * 440 * Double(i) / 48_000))
            channels[0][i] = v; channels[1][i] = v
        }
        do {
            let out = try AVAudioFile(forWriting: url, settings: format.settings)
            try out.write(from: buffer)
        }
        return try AVAudioFile(forReading: url)
    }

    func testHealthyPlaybackKeepsAudioAheadAndCountsOn() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.adopt(try tone(seconds: 30))
        try engine.play(from: 2)
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(engine.health(), .fine)
        XCTAssertGreaterThan(engine.currentTime, 2.8)
        XCTAssertLessThan(engine.currentTime, 4.5)
        XCTAssertTrue(engine.stateDescription.contains("s ahead"), engine.stateDescription)
        // The reader keeps well more than a few seconds decoded.
        XCTAssertTrue(engine.stateDescription.contains("given to"), engine.stateDescription)
    }

    /// The failure he heard: the node runs out, the flags the old watchdog
    /// read stay true and the clock counts on. Now it is noticed, the
    /// position stays where sound stopped, and playing from there works.
    func testStarvedNodeIsNoticedAndPositionStaysWhereSoundStopped() async throws {
        let engine = AudioEngine(aheadSeconds: 2)
        defer { engine.stop() }
        engine.adopt(try tone(seconds: 60))
        try engine.play(from: 5)
        engine.holdsReadingForTesting = true
        try await Task.sleep(for: .milliseconds(4_500))

        XCTAssertTrue(engine.isRendering, "Engine and node still say playing: why the old watchdog missed it")
        guard case .starved(let heardUntil, let behind) = engine.health() else {
            return XCTFail("Expected starved, got \(engine.health()) · \(engine.stateDescription)")
        }
        XCTAssertGreaterThan(heardUntil, 5.4)
        XCTAssertLessThan(heardUntil, 8.2)
        XCTAssertGreaterThan(behind, AudioEngine.starvedAfter)
        XCTAssertEqual(engine.currentTime, heardUntil, accuracy: 0.01,
                       "The position must not run on over silence")

        engine.holdsReadingForTesting = false
        try engine.play(from: heardUntil)
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(engine.health(), .fine)
        XCTAssertGreaterThan(engine.currentTime, heardUntil + 0.6)
    }

    func testReachingTheEndIsNotStarvation() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.adopt(try tone(seconds: 3))
        var finished = false
        engine.onFinished = { finished = true }
        try engine.play(from: 1.5)
        try await Task.sleep(for: .milliseconds(2_600))
        XCTAssertTrue(finished)
        XCTAssertEqual(engine.health(), .fine)
        let began = Date()
        engine.stop()
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "Stopping after the end must not hang")
    }

    /// A pause keeps the queued audio: resume carries on without a gap
    /// being taken for starvation.
    func testPauseAndResumeKeepTheFeed() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }
        engine.adopt(try tone(seconds: 30))
        try engine.play(from: 0)
        try await Task.sleep(for: .milliseconds(600))
        engine.pause()
        let paused = engine.currentTime
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(engine.currentTime, paused, accuracy: 0.01)
        try engine.resume()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(engine.health(), .fine)
        XCTAssertGreaterThan(engine.currentTime, paused + 0.4)
    }

    func testRenderClockWatch() {
        var watch = RenderClockWatch()
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertNil(watch.observe(100, at: t))
        XCTAssertNil(watch.observe(100, at: t.addingTimeInterval(0.2)), "first still reading only starts the count")
        XCTAssertNil(watch.observe(100, at: t.addingTimeInterval(1.5)))
        XCTAssertEqual(watch.observe(100, at: t.addingTimeInterval(1.8)) ?? 0, 1.6, accuracy: 0.001)
        XCTAssertNil(watch.observe(200, at: t.addingTimeInterval(1.9)), "a moving clock clears it")
        XCTAssertNil(watch.observe(nil, at: t.addingTimeInterval(2)))
        XCTAssertNotNil(watch.observe(nil, at: t.addingTimeInterval(3.6)), "no render time at all counts as still")
    }

    func testRecoveryBudget() {
        var budget = SoundRecoveryBudget()
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(budget.take(at: t))
        XCTAssertTrue(budget.take(at: t.addingTimeInterval(10)))
        XCTAssertTrue(budget.take(at: t.addingTimeInterval(20)))
        XCTAssertFalse(budget.take(at: t.addingTimeInterval(30)), "a fourth in two minutes pauses instead")
        XCTAssertTrue(budget.take(at: t.addingTimeInterval(121)))
    }

    func testWorkNames() {
        XCTAssertEqual(PlaybackTrace.work("benchmark:prism-ml/Bonsai-27B-mlx-1bit"), "model test Bonsai-27B-mlx-1bit")
        XCTAssertEqual(PlaybackTrace.work("episode:abc"), "Find Ads")
        XCTAssertNil(PlaybackTrace.work(nil))
    }
}
