import XCTest
import SwiftData
@testable import PodSkipper

@MainActor
final class StorageCleanupTests: XCTestCase {
    private var home: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var container: ModelContainer!

    override func setUpWithError() throws {
        suite = "CleanupTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        home = URL.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
        container = nil
        super.tearDown()
    }

    private func write(_ contents: String, at file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
    }

    private func episode() -> Episode {
        let episode = Episode(guid: UUID().uuidString, title: "Kept episode", episodeDescription: "Kept information",
                              audioURL: "https://example.invalid/audio.mp3", publishedAt: .now, duration: 60)
        container.mainContext.insert(episode)
        return episode
    }

    private var permissionFailure: NSError { NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }

    func testNamedDownloadDeletionCannotEscapeOrDeleteDirectoriesOrLinks() throws {
        let directory = home.appending(path: "Episodes")
        let outside = home.appending(path: "important.json")
        try write("keep", at: outside)
        try FileManager.default.createDirectory(at: directory.appending(path: "folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appending(path: "linked.mp3"), withDestinationURL: outside)
        var retired = Set<String>()
        let result = FileStore.deleteNamedFiles(["../important.json", outside.path, "folder", "linked.mp3", ".", ".."],
                                               in: directory, retire: { retired.insert($0) })
        XCTAssertEqual(result.failed.count, 6)
        XCTAssertTrue(retired.isEmpty)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "folder").path))
        let linkedDirectory = home.appending(path: "linked-directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: home)
        XCTAssertEqual(FileStore.deleteNamedFiles(["important.json"], in: linkedDirectory, retire: { _ in }).failed, ["important.json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testFailedAudioAndCompanionDeletionKeepOnlyTheirIndexEntriesAndReferences() throws {
        let directory = home.appending(path: "Episodes")
        try write("video", at: directory.appending(path: "legacy.mp4"))
        try write("audio", at: directory.appending(path: "legacy-audio.m4a"))
        let episode = episode()
        episode.localFilename = "legacy.mp4"
        var index: Set<String> = ["legacy.mp4", "legacy-audio.m4a"]
        let failure = permissionFailure
        let result = DownloadManager.removeFiles(episode, protectedGUIDs: [], directory: directory,
            removeItem: { file in
                if file.lastPathComponent == "legacy-audio.m4a" { throw failure }
                try FileManager.default.removeItem(at: file)
            }, retire: { index.remove($0) })
        XCTAssertEqual(result.removed, ["legacy.mp4"])
        XCTAssertEqual(result.failed, ["legacy-audio.m4a"])
        XCTAssertEqual(result.bytes, 5)
        XCTAssertEqual(index, ["legacy-audio.m4a"])
        // Keep the source reference until its companion can also be removed.
        XCTAssertEqual(episode.localFilename, "legacy.mp4")
        let retry = DownloadManager.removeFiles(episode, protectedGUIDs: [], directory: directory, retire: { index.remove($0) })
        XCTAssertEqual(retry.absent, ["legacy.mp4"])
        XCTAssertEqual(retry.removed, ["legacy-audio.m4a"])
        XCTAssertNil(episode.localFilename)
        XCTAssertTrue(index.isEmpty)
    }

    func testRemovalKeepsFailedEpisodeReferenceAndTranscriptCorrections() {
        let episode = episode()
        episode.localFilename = "original.mp4"
        episode.extractedAudioFilename = "track.m4a"
        episode.transcriptData = Data("saved".utf8)
        episode.isPlayed = true
        episode.playbackPosition = 20
        let cut = AdSegment(start: 10, end: 15, confidence: 100)
        cut.episode = episode
        container.mainContext.insert(cut)
        XCTAssertEqual(DownloadManager.remove(episode, deleteFile: { $0 != "track.m4a" }, protectedGUIDs: []), 0)
        XCTAssertNil(episode.localFilename)
        XCTAssertEqual(episode.extractedAudioFilename, "track.m4a")
        XCTAssertEqual(episode.transcriptData, Data("saved".utf8))
        XCTAssertTrue(episode.isPlayed)
        XCTAssertEqual(episode.playbackPosition, 20)
        XCTAssertEqual(episode.adSegments.first?.start, 10)
    }

    func testStorageSelectionIncludesInlineAndExtractedOnlyEpisodes() throws {
        let inline = episode(), extracted = episode(), text = episode(), empty = episode()
        inline.transcriptData = Data("inline".utf8)
        extracted.extractedAudioFilename = "only.m4a"
        text.transcriptText = "legacy text"
        try container.mainContext.save()
        let selected = Set(try container.mainContext.fetch(StorageCleanup.descriptor()).map(\.guid))
        XCTAssertEqual(selected, [inline.guid, extracted.guid, text.guid])
        XCTAssertFalse(selected.contains(empty.guid))
        XCTAssertEqual(StorageCleanup.inlineTranscriptBytes(inline), 6)
        XCTAssertEqual(StorageCleanup.inlineTranscriptBytes(text), 11)
    }

    func testExplicitTranscriptDeletionClearsResumeDataAndKeepsOtherCategories() throws {
        let episode = episode()
        episode.transcriptOnDisk = true
        episode.transcriptData = Data("inline".utf8)
        episode.transcriptText = "text"
        episode.localFilename = "kept.mp3"
        episode.isPlayed = true
        let transcript = home.appending(path: "Transcripts/transcript.json")
        let checkpoints = [home.appending(path: "Resume/text.json"), home.appending(path: "Answers/answers.json")]
        let unrelated = home.appending(path: "Answers/other.json")
        try write("transcript", at: transcript)
        for file in checkpoints { try write("checkpoint", at: file) }
        try write("keep", at: unrelated)
        var invalidated = [String]()
        let result = StorageCleanup.deleteTranscript(episode, transcriptURL: transcript, checkpointURLs: checkpoints,
            protectedGUIDs: [], invalidate: { invalidated.append($0); return true })
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(invalidated, [episode.guid])
        XCTAssertFalse(episode.hasTranscript)
        XCTAssertNil(episode.transcriptText)
        XCTAssertEqual(episode.localFilename, "kept.mp3")
        XCTAssertTrue(episode.isPlayed)
        XCTAssertEqual(episode.title, "Kept episode")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        for file in [transcript] + checkpoints { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testFailedCheckpointDeletionPreservesTranscriptAndProgress() throws {
        let episode = episode()
        episode.transcriptOnDisk = true
        episode.transcriptData = Data("inline".utf8)
        let transcript = home.appending(path: "transcript.json"), checkpoint = home.appending(path: "checkpoint.json")
        try write("keep transcript", at: transcript)
        try write("keep resume", at: checkpoint)
        var invalidated = false
        let failure = permissionFailure
        let result = StorageCleanup.deleteTranscript(episode, transcriptURL: transcript, checkpointURLs: [checkpoint],
            protectedGUIDs: [], removeItem: { _ in throw failure }, invalidate: { _ in invalidated = true; return true })
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failed, 1)
        XCTAssertFalse(invalidated)
        XCTAssertTrue(episode.hasTranscript)
        XCTAssertEqual(try String(contentsOf: transcript, encoding: .utf8), "keep transcript")
    }

    func testLiveOrQueuedOwnershipPreventsAnyCategoryDeletion() {
        let episode = episode()
        episode.localFilename = "kept.mp3"
        episode.transcriptData = Data("keep".utf8)
        var deletions = 0
        XCTAssertEqual(DownloadManager.remove(episode, deleteFile: { _ in deletions += 1; return true },
                                             protectedGUIDs: [episode.guid]), 0)
        let result = StorageCleanup.deleteTranscript(episode, checkpointURLs: [], protectedGUIDs: [episode.guid],
                                                     removeItem: { _ in deletions += 1 })
        XCTAssertTrue(result.kept)
        XCTAssertEqual(deletions, 0)
        XCTAssertEqual(episode.localFilename, "kept.mp3")
        XCTAssertTrue(episode.hasTranscript)
        let owners = ProcessingPipeline.cleanupProtectedGUIDs(active: ["playing", nil], queued: ["waiting"],
            owners: ["catchup:feed:guid", "maintenance:m", "video:v", "styles:s", "benchmark:reader"])
        XCTAssertEqual(owners, ["playing", "waiting", "feed:guid", "m", "v", "s"])
    }

    func testGlobalCleanupRetainsFailedAndQueuedFilesAndRetiresMissingReference() async throws {
        let directory = home.appending(path: "Episodes")
        let good = episode(), failed = episode(), queued = episode(), absent = episode()
        good.localFilename = "good.mp3"; failed.localFilename = "failed.mp3"
        queued.extractedAudioFilename = "queued.m4a"; absent.localFilename = "absent.mp3"
        try write("good", at: directory.appending(path: "good.mp3"))
        try write("failed", at: directory.appending(path: "failed.mp3"))
        try write("queued", at: directory.appending(path: "queued.m4a"))
        let store = ProcessingJobStore(file: home.appending(path: "processing.json"), defaults: defaults)
        store.setWaitingOrder([queued.guid])
        let pipeline = ProcessingPipeline(jobs: store, resources: HeavyWorkCoordinator(), worker: { _, _ in })
        pipeline.configure(context: container.mainContext, settings: AppSettings())
        let result = await pipeline.clearDownloads(in: directory, removeItem: { file in
            if file.lastPathComponent == "failed.mp3" {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
            }
            try FileManager.default.removeItem(at: file)
        }, retire: { _ in })
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(result.bytes, 4)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.kept, 1)
        XCTAssertNil(good.localFilename)
        XCTAssertNil(absent.localFilename)
        XCTAssertEqual(failed.localFilename, "failed.mp3")
        XCTAssertEqual(queued.extractedAudioFilename, "queued.m4a")
    }

    func testStoredBackupCleanupKeepsUnrelatedTrashAndExternalCopies() throws {
        let documents = home.appending(path: "Documents"), temporary = home.appending(path: "Temporary")
        let locations = BackupService.Locations(appSupport: home.appending(path: "Support"), documents: documents,
            restoreRoot: home.appending(path: "Library/Restore"), checkpoints: home.appending(path: "Checkpoints"),
            defaults: defaults, domain: suite)
        let backup = documents.appending(path: ".Trash/wrapper/deleted.podskipper")
        let history = documents.appending(path: ".Trashes/PodSkipper Listening History 2026-10-02.csv")
        let unrelated = documents.appending(path: ".Trash/wrapper/important.txt")
        let external = URL.temporaryDirectory.appending(path: "External-" + UUID().uuidString + ".podskipper")
        defer { try? FileManager.default.removeItem(at: external) }
        for file in [backup, history, unrelated, external] { try write("keep or delete", at: file) }
        let before = BackupService.stored(locations: locations, temporaryDirectory: temporary)
        XCTAssertEqual(Set(before.trashed), [backup, history])
        _ = BackupService.deleteStoredBackupData(locations: locations, temporaryDirectory: temporary, log: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "keep or delete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.deletingLastPathComponent().path))
    }

    func testGlobalCleanupKeepsQueuedFilenameIntroducedAfterInitialSnapshot() async throws {
        let directory = home.appending(path: "Episodes")
        let trigger = episode(), prepared = episode()
        trigger.localFilename = "a-trigger.mp3"
        // A download completion has moved the bytes before its MainActor
        // continuation stores the filename. The initial episode fetch omits it.
        try write("trigger", at: directory.appending(path: "a-trigger.mp3"))
        try write("prepared audio", at: directory.appending(path: "z-prepared.mp3"))
        let store = ProcessingJobStore(file: home.appending(path: "processing.json"), defaults: defaults)
        store.setWaitingOrder([prepared.guid])
        let pipeline = ProcessingPipeline(jobs: store, resources: HeavyWorkCoordinator(), worker: { _, _ in })
        pipeline.configure(context: container.mainContext, settings: AppSettings())
        let completeDownload: @MainActor @Sendable () -> Void = { prepared.localFilename = "z-prepared.mp3" }
        let result = await pipeline.clearDownloads(in: directory, removeItem: { file in
            try FileManager.default.removeItem(at: file)
            if file.lastPathComponent == "a-trigger.mp3" {
                MainActor.assumeIsolated { completeDownload() }
            }
        }, retire: { _ in })
        XCTAssertEqual(result.files, 1)
        XCTAssertEqual(result.kept, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(prepared.localFilename, "z-prepared.mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appending(path: "z-prepared.mp3").path))
    }

    func testStoredCleanupCannotRemoveAFileMarkedForBackupOrRestore() throws {
        let documents = home.appending(path: "Documents"), temporary = home.appending(path: "Temporary")
        let locations = BackupService.Locations(appSupport: home.appending(path: "Support"), documents: documents,
            restoreRoot: home.appending(path: "Library/Restore"), checkpoints: home.appending(path: "Checkpoints"),
            defaults: defaults, domain: suite)
        let backup = documents.appending(path: "copied.podskipper")
        try write("copied backup", at: backup)
        BackupService.markInUse(backup)
        BackupService.markInUse(backup)
        BackupService.unmarkInUse(backup) // a second reader still owns it
        XCTAssertEqual(BackupService.deleteStoredBackupData(locations: locations, temporaryDirectory: temporary, log: { _ in }), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        BackupService.unmarkInUse(backup)
        _ = BackupService.deleteStoredBackupData(locations: locations, temporaryDirectory: temporary, log: { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}
