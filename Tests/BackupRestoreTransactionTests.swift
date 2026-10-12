import XCTest
@testable import PodSkipper

final class BackupRestoreTransactionTests: XCTestCase {
    private var home: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var paths: BackupRestoreTransaction.Locations!
    override func setUpWithError() throws {
        suite = "RestoreTests." + UUID().uuidString
        home = URL.temporaryDirectory.appending(path: suite)
        defaults = UserDefaults(suiteName: suite)!
        paths = .init(root: home.appending(path: "Restore"), appSupport: home.appending(path: "Support"),
                      checkpoints: home.appending(path: "Checkpoints"), defaults: defaults, domain: suite,
                      preservedFolders: ["Models"])
        defaults.set("old", forKey: "setting")
        try write("old", to: paths.appSupport.appending(path: "old.store"))
        try write("original", to: paths.appSupport.appending(path: "Models/model.bin"))
        try write("old-answer", to: paths.checkpoints.appending(path: "a.json"))
        try write("older-rollback", to: paths.previous.appending(path: "older.txt"))
        try write("new", to: paths.staged.appending(path: "AppSupport/new.store"))
        try write("new-answer", to: paths.staged.appending(path: "Checkpoints/b.json"))
        let data = try PropertyListSerialization.data(fromPropertyList: ["setting": "new"], format: .binary, options: 0)
        try data.write(to: paths.staged.appending(path: "defaults.plist"))
        try write("", to: paths.ready)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }
    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testRoundTripPreservesModelAndKeepsOneCompleteOriginalRollback() throws {
        try BackupRestoreTransaction.apply(paths)
        XCTAssertEqual(try read(paths.appSupport.appending(path: "new.store")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appSupport.appending(path: "old.store").path))
        XCTAssertEqual(try read(paths.appSupport.appending(path: "Models/model.bin")), "original")
        XCTAssertEqual(try read(paths.previous.appending(path: "AppSupport/old.store")), "old")
        XCTAssertEqual(try read(paths.previous.appending(path: "Checkpoints/a.json")), "old-answer")
        XCTAssertEqual(try read(paths.checkpoints.appending(path: "b.json")), "new-answer")
        XCTAssertEqual(defaults.string(forKey: "setting"), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.ready.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.transaction.path))
    }
    func testFailureAtEveryRenameRestoresOriginalsAndKeepsBackupForRetry() throws {
        enum Injected: Error { case stop }
        for step in 1...5 {
            XCTAssertThrowsError(try BackupRestoreTransaction.apply(paths) { if $0 == step { throw Injected.stop } })
            XCTAssertEqual(try read(paths.appSupport.appending(path: "old.store")), "old")
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appSupport.appending(path: "new.store").path))
            XCTAssertEqual(try read(paths.appSupport.appending(path: "Models/model.bin")), "original")
            XCTAssertEqual(try read(paths.checkpoints.appending(path: "a.json")), "old-answer")
            XCTAssertEqual(try read(paths.previous.appending(path: "older.txt")), "older-rollback")
            XCTAssertEqual(try read(paths.staged.appending(path: "AppSupport/new.store")), "new")
            XCTAssertEqual(defaults.string(forKey: "setting"), "old")
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.ready.path))
        }
        try BackupRestoreTransaction.apply(paths)
        XCTAssertEqual(defaults.string(forKey: "setting"), "new")
    }
    func testInterruptedSwapRecoversBeforeOpeningLibrary() throws {
        struct Move: Encodable { var from: URL; var to: URL }
        struct Journal: Encodable {
            var version = 1
            var moves: [Move]
            var committed = false
            var oldDefaults: Data
        }
        let old = paths.transaction.appending(path: "previous/AppSupport")
        let incoming = paths.staged.appending(path: "AppSupport")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: paths.appSupport, to: old)
        try FileManager.default.moveItem(at: incoming, to: paths.appSupport)
        let journal = Journal(moves: [Move(from: paths.appSupport, to: old), Move(from: incoming, to: paths.appSupport)],
            oldDefaults: try PropertyListSerialization.data(fromPropertyList: ["setting": "old"], format: .binary, options: 0))
        try JSONEncoder().encode(journal).write(to: paths.journal)
        defaults.set("partial", forKey: "setting")
        try BackupRestoreTransaction.recover(paths)
        try BackupRestoreTransaction.recover(paths) // recovery can be retried safely
        XCTAssertEqual(try read(paths.appSupport.appending(path: "old.store")), "old")
        XCTAssertEqual(try read(paths.staged.appending(path: "AppSupport/new.store")), "new")
        XCTAssertEqual(defaults.string(forKey: "setting"), "old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.ready.path))
    }

    /// Pass 35: on his install SwiftData keeps the library in the App
    /// Group container. The restored library must land there; the live one
    /// (with its -wal/-shm) is kept for rollback; Application Support's own
    /// stale copy is not what the app opens.
    private func useGroupStore() throws -> URL {
        let group = home.appending(path: "Group/Library/Application Support")
        try write("live", to: group.appending(path: "new.store"))
        try write("live-wal", to: group.appending(path: "new.store-wal"))
        paths.storeDirectory = group
        return group
    }

    func testRestorePutsTheLibraryWhereSwiftDataOpensIt() throws {
        let group = try useGroupStore()
        try BackupRestoreTransaction.apply(paths)
        XCTAssertEqual(try read(group.appending(path: "new.store")), "new", "the backup's library is the one opened")
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.appending(path: "new.store-wal").path),
                       "the old library's journal never meets the restored one")
        XCTAssertEqual(try read(paths.previous.appending(path: "LiveStore/new.store")), "live")
        XCTAssertEqual(try read(paths.previous.appending(path: "LiveStore/new.store-wal")), "live-wal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appSupport.appending(path: "new.store").path))
    }

    func testFailureAtEveryRenameKeepsTheLiveGroupLibrary() throws {
        enum Injected: Error { case stop }
        let group = try useGroupStore()
        for step in 1...7 {
            XCTAssertThrowsError(try BackupRestoreTransaction.apply(paths) { if $0 == step { throw Injected.stop } })
            XCTAssertEqual(try read(group.appending(path: "new.store")), "live", "step \(step)")
            XCTAssertEqual(try read(group.appending(path: "new.store-wal")), "live-wal", "step \(step)")
            XCTAssertEqual(try read(paths.appSupport.appending(path: "old.store")), "old")
            XCTAssertEqual(try read(paths.staged.appending(path: "AppSupport/new.store")), "new")
            XCTAssertEqual(defaults.string(forKey: "setting"), "old")
        }
        try BackupRestoreTransaction.apply(paths)
        XCTAssertEqual(try read(group.appending(path: "new.store")), "new")
    }

    /// Pass 35: choosing parts. Settings only: the library and the
    /// unfinished work on the phone stay; the backup's library is set aside.
    func testRestoringOnlySettingsKeepsTheLibraryAndWork() throws {
        try write("old-transcript", to: paths.appSupport.appending(path: "Transcripts/t.json"))
        try write("new-transcript", to: paths.staged.appending(path: "AppSupport/Transcripts/t.json"))
        try RestorePlan(categories: [.settings]).save(to: paths.staged)
        try BackupRestoreTransaction.apply(paths)
        XCTAssertEqual(defaults.string(forKey: "setting"), "new")
        XCTAssertEqual(try read(paths.appSupport.appending(path: "old.store")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appSupport.appending(path: "new.store").path))
        XCTAssertEqual(try read(paths.appSupport.appending(path: "Transcripts/t.json")), "old-transcript")
        XCTAssertEqual(try read(paths.checkpoints.appending(path: "a.json")), "old-answer")
        XCTAssertEqual(try read(paths.appSupport.appending(path: "Models/model.bin")), "original")
    }

    func testRestoringOnlyTheLibraryKeepsSettings() throws {
        try RestorePlan(categories: [.library]).save(to: paths.staged)
        try BackupRestoreTransaction.apply(paths)
        XCTAssertEqual(defaults.string(forKey: "setting"), "old")
        XCTAssertEqual(try read(paths.appSupport.appending(path: "new.store")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.appSupport.appending(path: "old.store").path))
        XCTAssertEqual(try read(paths.checkpoints.appending(path: "a.json")), "old-answer")
    }

    func testFailureDuringASelectiveRestoreRestoresEverything() throws {
        enum Injected: Error { case stop }
        try write("old-transcript", to: paths.appSupport.appending(path: "Transcripts/t.json"))
        try write("new-transcript", to: paths.staged.appending(path: "AppSupport/Transcripts/t.json"))
        try RestorePlan(categories: [.settings]).save(to: paths.staged)
        for step in 1...6 {
            XCTAssertThrowsError(try BackupRestoreTransaction.apply(paths) { if $0 == step { throw Injected.stop } })
            XCTAssertEqual(try read(paths.appSupport.appending(path: "old.store")), "old", "step \(step)")
            XCTAssertEqual(try read(paths.appSupport.appending(path: "Transcripts/t.json")), "old-transcript", "step \(step)")
            XCTAssertEqual(try read(paths.staged.appending(path: "AppSupport/new.store")), "new", "step \(step)")
            XCTAssertEqual(defaults.string(forKey: "setting"), "old")
        }
    }

    func testInvalidSettingsNeverMoveOriginalData() throws {
        try write("broken", to: paths.staged.appending(path: "defaults.plist"))
        XCTAssertThrowsError(try BackupRestoreTransaction.apply(paths))
        XCTAssertEqual(try read(paths.appSupport.appending(path: "old.store")), "old")
        XCTAssertEqual(defaults.string(forKey: "setting"), "old")
    }
}
