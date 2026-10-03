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

    func testInvalidSettingsNeverMoveOriginalData() throws {
        try write("broken", to: paths.staged.appending(path: "defaults.plist"))
        XCTAssertThrowsError(try BackupRestoreTransaction.apply(paths))
        XCTAssertEqual(try read(paths.appSupport.appending(path: "old.store")), "old")
        XCTAssertEqual(defaults.string(forKey: "setting"), "old")
    }
}
