import XCTest
import SwiftData
import UIKit
import ImageIO
@testable import PodSkipper

@MainActor
final class ChapterServiceTests: XCTestCase {
    private var container: ModelContainer!
    private var defaults: UserDefaults!
    private var suite: String!
    private var episode: Episode!
    private var context: ModelContext { container.mainContext }

    override func setUpWithError() throws {
        suite = "ChapterTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        episode = Episode(guid: UUID().uuidString, title: "Test Episode", episodeDescription: "",
                          audioURL: "https://example.invalid/audio.mp3", publishedAt: .now, duration: 600)
        context.insert(episode)
        try context.save()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        container = nil
        super.tearDown()
    }

    func testTimestampParsingRejectsAmbiguousAndNonfiniteTimes() throws {
        XCTAssertEqual(try ChapterService.seconds(" 75.25 "), 75.25)
        XCTAssertEqual(try ChapterService.seconds("1:02.5"), 62.5)
        XCTAssertEqual(try ChapterService.seconds("1:02:03.5"), 3723.5)
        for bad in ["", "nan", "inf", "-1", "1:60", "1:60:00", "1::2", "1.5:02", "1:2:3:4"] {
            XCTAssertThrowsError(try ChapterService.seconds(bad), bad)
        }
        for seconds in [0.0, 5, 75.25, 3723.125] {
            XCTAssertEqual(try ChapterService.seconds(ChapterService.timeText(seconds)), seconds, accuracy: 0.001)
        }
    }

    func testEditValidationLeavesExistingChapterUnchanged() throws {
        let chapter = try ChapterService.save(.init(title: "Intro", time: "0"), for: episode, context: context, defaults: defaults)
        for draft in [ChapterService.Draft(title: "", time: "30"),
                      .init(title: "End", time: "600"),
                      .init(title: "Invalid", time: "30", imageURL: "file:///private/data"),
                      .init(title: "Invalid", time: "30", linkURL: "javascript:alert(1)"),
                      .init(title: "Duplicate", time: "0")] {
            XCTAssertThrowsError(try ChapterService.save(draft, for: episode, context: context, defaults: defaults))
        }
        XCTAssertEqual(episode.chapters.count, 1)
        XCTAssertEqual(chapter.title, "Intro")
        XCTAssertEqual(chapter.start, 0)
    }

    func testTitleTimeArtworkAndLinkEditKeepStableIdentity() throws {
        let chapter = try ChapterService.save(.init(title: "Intro", time: "0"), for: episode, context: context, defaults: defaults)
        let id = chapter.persistentModelID
        try ChapterService.save(.init(title: "  Main topic  ", time: "1:02.5",
             imageURL: " https://example.invalid/chapter.png ", linkURL: "https://example.invalid/notes"),
             for: episode, editing: chapter, context: context, defaults: defaults)
        let otherContext = ModelContext(container)
        let saved = try XCTUnwrap(otherContext.fetch(FetchDescriptor<Chapter>()).first)
        XCTAssertEqual(saved.persistentModelID, id)
        XCTAssertEqual(saved.start, 62.5)
        XCTAssertEqual(saved.title, "Main topic")
        XCTAssertEqual(saved.imageURL, "https://example.invalid/chapter.png")
        XCTAssertEqual(saved.linkURL, "https://example.invalid/notes")
        XCTAssertTrue(ChapterService.hasLocalEdits(episode.guid, defaults: UserDefaults(suiteName: suite)!))
    }

    func testDeletingLastChapterKeepsLocalIntentAcrossLaterImport() throws {
        let chapter = try ChapterService.save(.init(title: "Intro", time: "0"), for: episode, context: context, defaults: defaults)
        try ChapterService.delete(chapter, from: episode, context: context, defaults: defaults)
        XCTAssertTrue(episode.chapters.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Chapter>()).isEmpty)
        let restoredPreferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertEqual(try ChapterService.importEntries([.init(start: 0, title: "Publisher Intro")],
            for: episode, context: context, defaults: restoredPreferences), 0)
        XCTAssertTrue(episode.chapters.isEmpty)
        XCTAssertEqual(episode.title, "Test Episode")
    }

    func testImportFiltersBadTimesDuplicatesAndPreservesExistingContent() throws {
        let entries: [ChapterService.Entry] = [
            .init(start: 90, title: "Topic", imageURL: "https://example.invalid/art.png"),
            .init(start: -1, title: "Negative"), .init(start: .nan, title: "Invalid"),
            .init(start: 600, title: "End"), .init(start: 0, title: ""), .init(start: 90, title: "Duplicate")]
        XCTAssertEqual(try ChapterService.importEntries(entries, for: episode, context: context, defaults: defaults), 2)
        XCTAssertEqual(episode.chapters.sorted { $0.start < $1.start }.map(\.start), [0, 90])
        XCTAssertEqual(try ChapterService.importEntries([.init(start: 0, title: "Changed feed")],
            for: episode, context: context, defaults: defaults), 0)
        XCTAssertEqual(episode.chapters.first { $0.start == 0 }?.title, "Chapter 1")
        XCTAssertFalse(ChapterService.hasLocalEdits(episode.guid, defaults: defaults))
    }

    func testJSONPreservesArtworkAndLinksAndExcludesSilentMarkers() throws {
        let data = Data(#"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Intro"},{"startTime":60,"title":"Topic","img":"https://example.invalid/art.jpg","url":"https://example.invalid/topic"},{"startTime":70,"toc":false,"img":"https://example.invalid/silent.jpg"}]}"#.utf8)
        let entries = try ChapterService.parseJSON(data)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[1].imageURL, "https://example.invalid/art.jpg")
        XCTAssertEqual(entries[1].linkURL, "https://example.invalid/topic")
        XCTAssertThrowsError(try ChapterService.parseJSON(Data(#"{"version":"9.0","chapters":[]}"#.utf8)))
        XCTAssertThrowsError(try ChapterService.parseJSON(Data("invalid".utf8)))
    }

    func testRSSNamespaceAliasesCarryInlineAndJSONChapterSources() throws {
        let xml = """
        <rss xmlns:pc="https://podcastindex.org/namespace/1.0" xmlns:chap="http://podlove.org/simple-chapters">
        <channel><title>Show</title><item><guid>chapter-fixture</guid><title>Episode</title>
        <enclosure url="https://example.invalid/episode.mp3" type="audio/mpeg"/>
        <pc:chapters url="https://example.invalid/chapters.json" type="application/json+chapters"/>
        <chap:chapters><chap:chapter start="00:00:00" title="Intro"/>
        <chap:chapter start="00:01:30.5" title="Topic" image="https://example.invalid/art.jpg" href="https://example.invalid/topic"/>
        <chap:chapter start="-1" title="Invalid"/></chap:chapters>
        </item></channel></rss>
        """
        let item = try XCTUnwrap(FeedParser.parse(Data(xml.utf8)).items.first)
        XCTAssertEqual(item.chaptersURL, "https://example.invalid/chapters.json")
        XCTAssertEqual(item.chapters.count, 2)
        let stored = Episode(item: item)
        context.insert(stored)
        try context.save()
        XCTAssertEqual(stored.chapters.count, 2)
        XCTAssertEqual(stored.chapters.sorted { $0.start < $1.start }[1].start, 90.5)
        XCTAssertEqual(stored.chapters.first { $0.start > 0 }?.imageURL, "https://example.invalid/art.jpg")
    }

    func testAutomaticDownloadRemovalNeverTargetsUnplayedQueuedOrCurrentEpisode() {
        XCTAssertFalse(DownloadManager.canAutomaticallyRemove(episode, currentGUID: nil))
        episode.isPlayed = true
        XCTAssertTrue(DownloadManager.canAutomaticallyRemove(episode, currentGUID: nil))
        episode.isInQueue = true
        XCTAssertFalse(DownloadManager.canAutomaticallyRemove(episode, currentGUID: nil))
        episode.isInQueue = false
        XCTAssertFalse(DownloadManager.canAutomaticallyRemove(episode, currentGUID: episode.guid))
        XCTAssertTrue(DownloadManager.canAutomaticallyRemove(episode, currentGUID: "another-episode"))
    }

    func testRemovingVideoNamesBothAudioFilesAndKeepsTranscriptAndCorrections() {
        episode.localFilename = "legacy-video.mp4"
        episode.extractedAudioFilename = "extracted-track.m4a"
        episode.transcriptText = "Saved transcript"
        let correction = AdSegment(start: 20, end: 30, sponsor: "Locked correction", confidence: 100)
        correction.episode = episode
        context.insert(correction)
        var deleted: [String] = []
        XCTAssertEqual(DownloadManager.remove(episode, deleteFile: { deleted.append($0) }), 1)
        XCTAssertEqual(Set(deleted), ["legacy-video.mp4", "extracted-track.m4a"])
        XCTAssertNil(episode.localFilename)
        XCTAssertNil(episode.extractedAudioFilename)
        XCTAssertEqual(episode.transcriptText, "Saved transcript")
        XCTAssertTrue(episode.adSegments.contains { $0 === correction })
        episode.localFilename = "one-file.m4a"
        episode.extractedAudioFilename = "one-file.m4a"
        deleted = []
        XCTAssertEqual(DownloadManager.remove(episode, deleteFile: { deleted.append($0) }), 1)
        XCTAssertEqual(deleted, ["one-file.m4a"])
    }

    func testEmbeddedArtworkIsBoundedAndStoredAsPortableReference() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2_000, height: 1_200), format: format)
        let image = renderer.image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_000, height: 1_200))
        }
        let bytes = try XCTUnwrap(image.pngData())
        let reference = try XCTUnwrap(ChapterService.storeEmbeddedArtwork(bytes, directory: directory))
        let url = try XCTUnwrap(ChapterService.embeddedArtworkURL(reference, directory: directory))
        let saved = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(saved.count, 512 * 1_024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(saved as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), 400)
        XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int), 400)
        XCTAssertEqual(try ChapterService.storeEmbeddedArtwork(bytes, directory: directory), reference)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        XCTAssertFalse(reference.contains(directory.path))

        let chapter = Chapter(start: 0, title: "Embedded", imageURL: reference)
        chapter.episode = episode
        context.insert(chapter)
        try ChapterService.save(.init(title: "Retained art", time: "0", imageURL: reference),
            for: episode, editing: chapter, context: context, defaults: defaults)
        XCTAssertEqual(chapter.imageURL, reference)
    }

    func testOversizedMalformedArtworkAndInvalidLocalReferencesAreRejected() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(ChapterService.boundedArtwork(Data()))
        XCTAssertNil(ChapterService.boundedArtwork(Data("not an image".utf8)))
        XCTAssertNil(ChapterService.boundedArtwork(Data(repeating: 0, count: 20 * 1_024 * 1_024 + 1)))
        XCTAssertNil(try ChapterService.storeEmbeddedArtwork(Data("not an image".utf8), directory: directory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        for reference in ["chapter-artwork:../../secret.jpg", "file:///private/secret.jpg", "chapter-artwork:short.jpg"] {
            XCTAssertNil(ChapterService.embeddedArtworkURL(reference, directory: directory))
        }
    }
}
