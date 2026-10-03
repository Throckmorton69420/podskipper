import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class VideoAudioCleanupTests: XCTestCase {
    private var directory: URL!
    private var home: URL!
    private var defaults: UserDefaults!
    private var container: ModelContainer!
    private var ownership: [UUID] = []

    override func setUpWithError() throws {
        home = URL.temporaryDirectory.appending(path: "VideoCleanup-" + UUID().uuidString)
        directory = home.appending(path: "Episodes")
        defaults = UserDefaults(suiteName: home.lastPathComponent)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        for token in ownership { VideoAudio.release(token) }
        ownership.removeAll()
        defaults.removePersistentDomain(forName: home.lastPathComponent)
        try? FileManager.default.removeItem(at: home)
        container = nil
        super.tearDown()
    }

    private func write(_ name: String, _ text: String = "video") throws {
        try Data(text.utf8).write(to: directory.appending(path: name))
    }

    private func episode(_ name: String) -> Episode {
        let episode = Episode(guid: UUID().uuidString, title: "Saved video", episodeDescription: "Keep",
            audioURL: "https://example.invalid/video.mp4", publishedAt: .now, duration: 60)
        episode.localFilename = name
        container.mainContext.insert(episode)
        return episode
    }

    func testExtractionProtectsUnreferencedSourceAndAudioFromBothCleanupPaths() async throws {
        try write("work.mp4")
        let context = container.mainContext
        let output = try await VideoAudio.keepOnlyAudio(of: "work.mp4", in: directory,
            extract: { [self] _, audio in
                try write(audio, "audio")
                let videos = await VideoAudio.removeSavedVideos(context: context, in: directory,
                    protectedGUIDs: { [] }, retire: { _ in XCTFail("Active source must not be retired") })
                XCTAssertEqual(videos.kept, ["work.mp4"])
                let store = ProcessingJobStore(file: home.appending(path: "jobs.json"), defaults: defaults)
                let pipeline = ProcessingPipeline(jobs: store, resources: HeavyWorkCoordinator(), worker: { _, _ in })
                pipeline.configure(context: context, settings: AppSettings())
                let all = await pipeline.clearDownloads(in: directory, retire: { _ in XCTFail("Active files must not be retired") })
                XCTAssertEqual(all.files, 0)
                XCTAssertEqual(all.kept, 2)
                return audio
            }, retire: { XCTAssertEqual($0, "work.mp4") })
        XCTAssertEqual(output, "work-audio.m4a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appending(path: "work.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: output).path))
        XCTAssertFalse(VideoAudio.protectedFilenames.contains(output))
    }

    func testOwnershipIsRecheckedAfterDirectoryEnumeration() async throws {
        try write("saved.mp4"); try write("new-work.mp4")
        let saved = episode("saved.mp4")
        var owners = Set<String>()
        let result = await VideoAudio.removeSavedVideos(context: container.mainContext, in: directory,
            protectedGUIDs: { owners }, listFiles: { _ in
                await Task.yield()
                owners.insert(saved.guid)
                return ["saved.mp4", "new-work.mp4"]
            }, retire: { _ in XCTFail("Live files must not be retired") })
        XCTAssertEqual(result.kept, ["saved.mp4", "new-work.mp4"])
        XCTAssertTrue(result.deletion.removed.isEmpty)
        XCTAssertEqual(saved.localFilename, "saved.mp4")
    }

    func testOwnershipIsRecheckedBeforeEveryUnlink() async throws {
        try write("a.mp4"); try write("b.mp4")
        let first = episode("a.mp4"), next = episode("b.mp4")
        var owners = Set<String>()
        let result = await VideoAudio.removeSavedVideos(context: container.mainContext, in: directory,
            protectedGUIDs: { owners }, removeItem: { file in
                try FileManager.default.removeItem(at: file)
                owners.insert(next.guid)
            }, retire: { _ in })
        XCTAssertEqual(result.deletion.removed, ["a.mp4"])
        XCTAssertEqual(result.kept, ["b.mp4"])
        XCTAssertNil(first.localFilename)
        XCTAssertEqual(next.localFilename, "b.mp4")
    }

    func testFailedDeletionPreservesReferenceAndIndexWhileAudioSurvivesSuccess() async throws {
        try write("bad.mp4"); try write("good.mp4"); try write("good-audio.m4a", "audio")
        let bad = episode("bad.mp4"), good = episode("good.mp4")
        good.extractedAudioFilename = "good-audio.m4a"
        good.transcriptData = Data("keep transcript".utf8)
        good.isPlayed = true
        var index: Set<String> = ["bad.mp4", "good.mp4", "good-audio.m4a"]
        let result = await VideoAudio.removeSavedVideos(context: container.mainContext, in: directory,
            protectedGUIDs: { [] }, removeItem: { file in
                if file.lastPathComponent == "bad.mp4" {
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
                }
                try FileManager.default.removeItem(at: file)
            }, retire: { index.remove($0) })
        XCTAssertEqual(result.deletion.failed, ["bad.mp4"])
        XCTAssertEqual(result.deletion.removed, ["good.mp4"])
        XCTAssertEqual(result.deletion.bytes, 5)
        XCTAssertEqual(index, ["bad.mp4", "good-audio.m4a"])
        XCTAssertEqual(bad.localFilename, "bad.mp4")
        XCTAssertEqual(good.localFilename, "good-audio.m4a")
        XCTAssertEqual(good.extractedAudioFilename, "good-audio.m4a")
        XCTAssertEqual(good.transcriptData, Data("keep transcript".utf8))
        XCTAssertTrue(good.isPlayed)
        XCTAssertFalse(result.saveFailed)
    }

    func testAbsentSourceRetiresStaleReferenceWithoutClaimingFreedBytes() async throws {
        let episode = episode("missing.mp4")
        episode.extractedAudioFilename = "missing-audio.m4a"
        var retired = Set<String>()
        let result = await VideoAudio.removeSavedVideos(context: container.mainContext, in: directory,
            protectedGUIDs: { [] }, retire: { retired.insert($0) })
        XCTAssertEqual(result.deletion.absent, ["missing.mp4"])
        XCTAssertEqual(retired, ["missing.mp4"])
        XCTAssertEqual(result.deletion.bytes, 0)
        XCTAssertNil(episode.localFilename)
        XCTAssertNil(episode.extractedAudioFilename)
    }

    func testInvalidPathsLinksAndFoldersCannotDeleteOutsideData() async throws {
        let outside = directory.deletingLastPathComponent().appending(path: UUID().uuidString + ".mp4")
        try Data("keep".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "link.mp4"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: directory.appending(path: "folder.mp4"), withIntermediateDirectories: true)
        let invalid = episode("../" + outside.lastPathComponent)
        for name in [invalid.localFilename!, outside.path, "link.mp4", "folder.mp4"] {
            do {
                _ = try await VideoAudio.keepOnlyAudio(of: name, in: directory,
                    extract: { _, _ in XCTFail("Invalid source must not reach exporter"); return "" },
                    retire: { _ in XCTFail("Invalid source must not retire its index") })
                XCTFail("Invalid source must be rejected")
            } catch is VideoAudio.SourceError { } catch { XCTFail("Unexpected error: \(error)") }
        }
        let result = await VideoAudio.removeSavedVideos(context: container.mainContext, in: directory,
            protectedGUIDs: { [] }, retire: { _ in XCTFail("Invalid entries must stay indexed") })
        XCTAssertEqual(result.deletion.failed, [invalid.localFilename!, "link.mp4", "folder.mp4"])
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertEqual(invalid.localFilename, "../" + outside.lastPathComponent)
    }

    func testCancelledExtractionRetainsOwnershipUntilExporterAndCleanupUnwind() async throws {
        try write("cancel.mp4")
        let started = expectation(description: "Exporter started")
        var finish: CheckedContinuation<String, Never>?
        var retired = false
        let task = Task { @MainActor [self] in
            try await VideoAudio.keepOnlyAudio(of: "cancel.mp4", in: directory,
                extract: { _, _ in
                    await withCheckedContinuation { continuation in finish = continuation; started.fulfill() }
                }, removeItem: { file in
                    XCTAssertTrue(VideoAudio.protectedFilenames.contains("cancel.mp4"))
                    try FileManager.default.removeItem(at: file)
                }, retire: { _ in retired = true })
        }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        XCTAssertTrue(VideoAudio.protectedFilenames.contains("cancel.mp4"))
        finish?.resume(returning: "cancel-audio.m4a")
        do { _ = try await task.value; XCTFail("Cancelled response must not become a success") }
        catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(retired)
        XCTAssertFalse(VideoAudio.protectedFilenames.contains("cancel.mp4"))
    }

    func testExtractionFailureStillDeletesOnlyTheSource() async throws {
        try write("failed.mp4"); try write("unrelated.m4a", "keep")
        var retired = Set<String>()
        do {
            _ = try await VideoAudio.keepOnlyAudio(of: "failed.mp4", in: directory,
                extract: { _, _ in throw MediaExtractor.ExtractionError.noAudioTrack }, retire: { retired.insert($0) })
            XCTFail("Extraction should fail")
        } catch is MediaExtractor.ExtractionError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(retired, ["failed.mp4"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "unrelated.m4a").path))
        XCTAssertFalse(VideoAudio.protectedFilenames.contains("failed.mp4"))
    }

    func testFailedTemporaryUnlinkKeepsIndexAndReportsRetryWork() async throws {
        try write("failed-unlink.mp4")
        var retired = false
        let audio = try await VideoAudio.keepOnlyAudio(of: "failed-unlink.mp4", in: directory,
            extract: { _, audio in audio }, removeItem: { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }, retire: { _ in retired = true })
        XCTAssertEqual(audio, "failed-unlink-audio.m4a")
        XCTAssertFalse(retired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "failed-unlink.mp4").path))
        XCTAssertFalse(VideoAudio.protectedFilenames.contains("failed-unlink.mp4"))
    }

    func testOverlappingOwnersDoNotReleaseEachOthersFilesOrEpisode() {
        let first = VideoAudio.protect(guid: "shared", names: ["same.mp4"])
        let second = VideoAudio.protect(guid: "shared", names: ["same.mp4", "same-audio.m4a"])
        ownership = [first, second]
        VideoAudio.release(first)
        XCTAssertTrue(VideoAudio.protectedGUIDs.contains("shared"))
        XCTAssertTrue(VideoAudio.protectedFilenames.contains("same.mp4"))
        VideoAudio.release(second)
        XCTAssertFalse(VideoAudio.protectedGUIDs.contains("shared"))
        XCTAssertFalse(VideoAudio.protectedFilenames.contains("same.mp4"))
    }

    func testEnumerationFailurePreservesAllReferences() async throws {
        try write("kept.mp4")
        let episode = episode("kept.mp4")
        let result = await VideoAudio.removeSavedVideos(context: container.mainContext, in: directory,
            protectedGUIDs: { [] }, listFiles: { _ in throw CocoaError(.fileReadNoPermission) },
            retire: { _ in XCTFail("Unread files must not be retired") })
        XCTAssertTrue(result.scanFailed)
        XCTAssertEqual(episode.localFilename, "kept.mp4")
        XCTAssertTrue(result.deletion.retired.isEmpty)
    }
}
