import XCTest
@testable import PodSkipper

@MainActor
final class PlaybackRequestTests: XCTestCase {
    private func episode(_ guid: String) -> Episode {
        Episode(guid: guid, title: guid, episodeDescription: "", audioURL: "https://example.test/audio.mp3",
                publishedAt: .now, duration: 100)
    }

    func testCountdownPlaysOnlyTheMostRecentEpisode() async throws {
        let request = PlaybackRequest()
        var played: [String] = []
        request.ask(for: episode("replaced"), reason: .tapped, countdownSeconds: 1,
                    playNow: { played.append($0.guid) }, processFirst: { _ in XCTFail() })
        request.ask(for: episode("requested"), reason: .tapped, countdownSeconds: 1,
                    playNow: { played.append($0.guid) }, processFirst: { _ in XCTFail() })
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(played, ["requested"])
        XCTAssertNil(request.pending)
    }

    func testDismissalCancelsCountdownAndInvalidatesProcessingIntent() async throws {
        let request = PlaybackRequest()
        let intent = request.beginIntent()
        request.ask(for: episode("cancelled"), reason: .autoplay, countdownSeconds: 1, intent: intent,
                    playNow: { _ in XCTFail("A dismissed request must not play") }, processFirst: { _ in XCTFail() })
        request.dismiss(cancels: true)
        XCTAssertFalse(request.isCurrent(intent))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertNil(request.pending)
    }

    func testProcessingChoiceKeepsIntentUntilAnotherRequest() {
        let request = PlaybackRequest()
        let intent = request.beginIntent()
        var processed: String?
        request.ask(for: episode("chapter"), reason: .tapped, countdownSeconds: 20, intent: intent,
                    playNow: { _ in XCTFail() }, processFirst: { processed = $0.guid })
        request.chooseProcessFirst()
        XCTAssertEqual(processed, "chapter")
        XCTAssertTrue(request.isCurrent(intent))
        XCTAssertNil(request.pending)
        _ = request.beginIntent()
        XCTAssertFalse(request.isCurrent(intent))
    }

    func testChapterPositionBypassesResumeIntroAndCompletedResumeReset() {
        XCTAssertEqual(PlaybackStart.resolve(requested: 98, saved: 40, duration: 100, intro: 25), 98)
        XCTAssertEqual(PlaybackStart.resolve(requested: 0, saved: 40, duration: 100, intro: 25), 0)
        XCTAssertEqual(PlaybackStart.resolve(requested: -10, saved: 40, duration: 100, intro: 25), 0)
        XCTAssertEqual(PlaybackStart.resolve(requested: nil, saved: 99, duration: 100, intro: 25), 0)
        XCTAssertEqual(PlaybackStart.resolve(requested: nil, saved: 0, duration: 100, intro: 25), 25)
        XCTAssertEqual(PlaybackStart.resolve(requested: .infinity, saved: .nan, duration: 100, intro: 0), 0)
    }

    func testAvailableExtractedAudioSurvivesMissingVideoAndStaleAudioFallsBack() {
        let name = "playback-" + UUID().uuidString + ".wav"
        FileIndex.loadIfNeeded()
        FileIndex.insert(name)
        defer { FileIndex.remove(name) }
        let e = episode("video")
        e.localFilename = "missing-video-" + UUID().uuidString + ".mp4"
        e.extractedAudioFilename = name
        XCTAssertTrue(e.isDownloaded)
        XCTAssertEqual(e.analysableFileURL?.lastPathComponent, name)
        FileIndex.remove(name)
        XCTAssertFalse(e.isDownloaded)
        XCTAssertNil(e.analysableFileURL)
        e.localFilename = name
        FileIndex.insert(name)
        XCTAssertTrue(e.isDownloaded)
        XCTAssertEqual(e.analysableFileURL?.lastPathComponent, name)
    }
}
