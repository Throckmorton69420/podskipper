import XCTest
import SQLite3
@testable import PodSkipper

final class BackupServiceTests: XCTestCase {
    private var home: URL!
    private var suite: String!
    private var locations: BackupService.Locations!
    override func setUpWithError() throws {
        suite = "BackupTests." + UUID().uuidString
        home = URL.temporaryDirectory.appending(path: suite)
        locations = .init(appSupport: home.appending(path: "Support"), documents: home.appending(path: "Documents"),
                          restoreRoot: home.appending(path: "Library/Restore"), checkpoints: home.appending(path: "Checkpoints"),
                          defaults: UserDefaults(suiteName: suite)!, domain: suite)
        locations.defaults.set("original", forKey: "setting")
        try write("transcript", to: locations.appSupport.appending(path: "Transcripts/a.json"))
        try write("answers", to: locations.checkpoints.appending(path: "a.json"))
        try write("audio", to: locations.appSupport.appending(path: "Episodes/a.mp3"))
        try write("downloaded-model", to: locations.appSupport.appending(path: ModelStore.folderName + "/weights.bin"))
        try write("core-model", to: locations.appSupport.appending(path: "CoreAIKit/Models/weights.bin"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(locations.appSupport.appending(path: "default.store").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE history(value TEXT); INSERT INTO history VALUES('original');", nil, nil, nil), SQLITE_OK)
    }
    override func tearDown() {
        locations.defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }
    private func write(_ value: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: file)
    }
    private func manifest(audio: Bool = false) -> BackupService.Manifest {
        .init(createdAt: .now, build: "test", bundleID: suite, shows: 1, episodes: 1, includesAudio: audio)
    }

    func testArchiveStageRestoreRoundTripKeepsCheckpointsAndDownloadCaches() async throws {
        let backup = try await BackupService.make(manifest: manifest(audio: true), locations: locations) { _, _ in }
        XCTAssertTrue(BackupService.hasBackupName(backup))
        let staged = try await BackupService.stage(backup, locations: locations) { _, _ in }
        XCTAssertEqual(staged.formatVersion, 2)
        XCTAssertTrue(staged.files?.keys.contains("AppSupport/Episodes/a.mp3") == true)
        XCTAssertFalse(staged.files?.keys.contains(where: { $0.contains("weights.bin") }) == true)
        try write("changed", to: locations.appSupport.appending(path: "Transcripts/a.json"))
        try write("unrelated", to: locations.appSupport.appending(path: "extra.txt"))
        locations.defaults.set("changed", forKey: "setting")
        try BackupService.applyPendingRestore(locations: locations)
        XCTAssertEqual(try String(contentsOf: locations.appSupport.appending(path: "Transcripts/a.json"), encoding: .utf8), "transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.appSupport.appending(path: "extra.txt").path))
        XCTAssertEqual(try String(contentsOf: locations.checkpoints.appending(path: "a.json"), encoding: .utf8), "answers")
        XCTAssertEqual(locations.defaults.string(forKey: "setting"), "original")
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.appSupport.appending(path: ModelStore.folderName + "/weights.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locations.appSupport.appending(path: "CoreAIKit/Models/weights.bin").path))
        try BackupService.validateDatabase(locations.appSupport.appending(path: "default.store"))
    }

    func testCorruptAndInsufficientSpaceLeaveExistingPendingRestoreIntact() async throws {
        let backup = try await BackupService.make(manifest: manifest(), locations: locations) { _, _ in }
        _ = try await BackupService.stage(backup, locations: locations) { _, _ in }
        let originalStage = try Data(contentsOf: locations.staged.appending(path: "manifest.json"))
        let corrupt = home.appending(path: "broken.podskipper")
        try write("not an archive", to: corrupt)
        for (file, capacity) in [(corrupt, Int64.max), (backup, Int64(0))] {
            do {
                _ = try await BackupService.stage(file, locations: locations, availableCapacity: capacity) { _, _ in }
                XCTFail("An invalid restore was staged")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: locations.staged.appending(path: "manifest.json")), originalStage)
            XCTAssertTrue(FileManager.default.fileExists(atPath: locations.ready.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: locations.staged.appending(path: "AppSupport/Episodes/a.mp3").path))
    }

    func testRetentionKeepsNewestAndExternalCopyAndIndividualDeleteIsScoped() async throws {
        var made: [URL] = []
        for _ in 0..<3 { made.append(try await BackupService.make(manifest: manifest(), locations: locations) { _, _ in }) }
        XCTAssertEqual(Set(made).count, 3, "Making two backups in one minute cannot overwrite either one")
        let external = home.appending(path: "external-copy.podskipper")
        try FileManager.default.copyItem(at: made[0], to: external)
        let kept = BackupService.removeOldBackups(keeping: 2, justMade: made[2], locations: locations)
        XCTAssertEqual(kept.removed, 1)
        XCTAssertEqual(BackupService.existingBackups(locations: locations).count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: made[2].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertThrowsError(try BackupService.deleteBackup(external, locations: locations))
        try BackupService.deleteBackup(made[2], locations: locations)
        XCTAssertEqual(BackupService.existingBackups(locations: locations).count, 1)
    }

    func testCorruptLedgerCannotAuthorizeRetentionOrBeOverwritten() async throws {
        let backup = try await BackupService.make(manifest: manifest(), locations: locations) { _, _ in }
        let corrupt = Data("broken ownership record".utf8)
        try corrupt.write(to: locations.ledger)
        let next = try await BackupService.make(manifest: manifest(), locations: locations) { _, _ in }
        XCTAssertEqual(BackupService.removeOldBackups(keeping: 1, justMade: next, locations: locations).removed, 0)
        XCTAssertEqual(try Data(contentsOf: locations.ledger), corrupt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    func testLegacyArchiveWithoutInventoryStillRestores() async throws {
        let backup = try await BackupService.make(manifest: manifest(), locations: locations) { _, _ in }
        let tree = home.appending(path: "Legacy")
        try BackupService.extract(backup, into: tree, report: .init()) { _ in }
        let manifestFile = tree.appending(path: "manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
        for key in ["formatVersion", "files", "checksums"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: manifestFile)
        let legacy = home.appending(path: "legacy.podskipper")
        try BackupService.archive(tree, to: legacy, compress: true) { _ in }
        let result = try await BackupService.stage(legacy, locations: locations) { _, _ in }
        XCTAssertNil(result.formatVersion)
        try BackupService.applyPendingRestore(locations: locations)
        try BackupService.validateDatabase(locations.appSupport.appending(path: "default.store"))
    }

    func testSameSizeCorruptionAndMissingFilesRejectWithoutReplacingPendingRestore() async throws {
        let backup = try await BackupService.make(manifest: manifest(), locations: locations) { _, _ in }
        _ = try await BackupService.stage(backup, locations: locations) { _, _ in }
        let oldManifest = try Data(contentsOf: locations.staged.appending(path: "manifest.json"))
        let tree = home.appending(path: "Damaged")
        try BackupService.extract(backup, into: tree, report: .init()) { _ in }
        let transcript = tree.appending(path: "AppSupport/Transcripts/a.json")
        try write("transcripx", to: transcript)
        for missing in [false, true] {
            if missing { try FileManager.default.removeItem(at: transcript) }
            let damaged = home.appending(path: "damaged-\(missing).podskipper")
            try BackupService.archive(tree, to: damaged, compress: true) { _ in }
            do {
                _ = try await BackupService.stage(damaged, locations: locations) { _, _ in }
                XCTFail("A damaged archive was staged")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: locations.staged.appending(path: "manifest.json")), oldManifest)
            XCTAssertEqual(try String(contentsOf: locations.appSupport.appending(path: "Transcripts/a.json"), encoding: .utf8), "transcript")
        }
    }
}
