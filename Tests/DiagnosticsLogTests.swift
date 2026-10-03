import XCTest
@testable import PodSkipper

/// All paths/defaults are disposable. Gates model a write already running
/// while older snapshots are queued; injected failures never use permissions
/// or actual app logs to simulate a failed cleanup.
@MainActor
final class DiagnosticsLogTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let cutoff = Date(timeIntervalSince1970: 3_000)

    private final class ControlledFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var block = false
        private var entered = false
        private var failedWrite = false
        private var failedRemove = false
        private var failedList = false
        private var writes = 0
        private let gate = DispatchSemaphore(value: 0)
        var didEnter: Bool { lock.withLock { entered } }
        var writeCount: Int { lock.withLock { writes } }
        func blockNext() { lock.withLock { block = true; entered = false } }
        func release() { gate.signal() }
        func failWrite(_ value: Bool) { lock.withLock { failedWrite = value } }
        func failRemove(_ value: Bool) { lock.withLock { failedRemove = value } }
        func failList(_ value: Bool) { lock.withLock { failedList = value } }
        var operations: DiagnosticLogFile.Operations {
            var operations = DiagnosticLogFile.Operations.live
            operations.write = { [self] data, url in
                let shouldBlock = lock.withLock { () -> Bool in
                    writes += 1
                    if block { block = false; entered = true; return true }
                    return false
                }
                if shouldBlock, gate.wait(timeout: .now() + 5) == .timedOut { throw CocoaError(.fileWriteUnknown) }
                if lock.withLock({ failedWrite }) { throw CocoaError(.fileWriteNoPermission) }
                try DiagnosticLogFile.Operations.live.write(data, url)
            }
            operations.remove = { [self] url in
                if lock.withLock({ failedRemove }) { throw CocoaError(.fileWriteNoPermission) }
                try DiagnosticLogFile.Operations.live.remove(url)
            }
            operations.list = { [self] url in
                if lock.withLock({ failedList }) { throw CocoaError(.fileReadNoPermission) }
                return try DiagnosticLogFile.Operations.live.list(url)
            }
            return operations
        }
    }

    override func setUpWithError() throws {
        suite = "DiagnosticsLogTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        folder = URL.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }
    private func timing(_ date: Date, _ title: String = "Test") -> ProcessingTiming {
        ProcessingTiming(date: date, show: "Show", episode: title, audioSeconds: 60,
            transcribeSeconds: nil, analyzeSeconds: nil, detectSeconds: 1,
            thermalAtStart: "nominal", thermalAtEnd: "nominal", lowPowerMode: false,
            onPower: false, foreground: true, device: "test", build: "test")
    }
    private func decoded<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition())
    }

    func testTimingPruneUsesEntryDatesAndKeepsCutoffBoundaryInMemoryAndDisk() async throws {
        let url = folder.appending(path: "timings.json")
        let log = TimingLog(url: url, demo: false)
        log.record(timing(cutoff.addingTimeInterval(-1), "old"))
        log.record(timing(cutoff, "boundary"))
        log.record(timing(cutoff.addingTimeInterval(1), "new"))
        await log.flush()
        let beforeBytes = try Data(contentsOf: url).count
        // The file was just written; only its individual old entry is pruned.
        let result = await log.prune(before: cutoff)
        XCTAssertEqual(result.removedEntries, 1); XCTAssertEqual(result.removedFiles, 0)
        XCTAssertGreaterThan(result.freedBytes, 0); XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.freedBytes, Int64(beforeBytes - (try Data(contentsOf: url).count)))
        XCTAssertEqual(log.entries.map(\.episode), ["new", "boundary"])
        XCTAssertEqual(try decoded([ProcessingTiming].self, at: url).map(\.episode), ["new", "boundary"])
        let reopened = TimingLog(url: url, demo: false)
        XCTAssertEqual(reopened.entries.map(\.episode), ["new", "boundary"])
    }

    func testBackgroundPruneUsesEventDatesInsteadOfLogFileModificationDate() async throws {
        let url = folder.appending(path: "background.json")
        let events = [BackgroundLog.Event(date: cutoff, text: "boundary"),
                      BackgroundLog.Event(date: cutoff.addingTimeInterval(-1), text: "old")]
        try JSONEncoder.iso.encode(events).write(to: url)
        let log = BackgroundLog(url: url)
        let result = await log.prune(before: cutoff)
        XCTAssertEqual(result.removedEntries, 1); XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(log.events.map(\.text), ["boundary"])
        XCTAssertEqual(try decoded([BackgroundLog.Event].self, at: url).map(\.text), ["boundary"])
    }

    func testClearInvalidatesQueuedTimingSnapshotsAndKeepsNewRecordDuringCleanup() async throws {
        let files = ControlledFiles(), url = folder.appending(path: "timings.json")
        let log = TimingLog(url: url, operations: files.operations, demo: false)
        files.blockNext()
        log.record(timing(cutoff.addingTimeInterval(-2), "running old write"))
        try await waitUntil { files.didEnter }
        log.record(timing(cutoff.addingTimeInterval(-1), "queued stale write"))
        var began = false
        let clear = Task { began = true; return await log.prune(before: nil) }
        try await waitUntil { began }
        log.record(timing(cutoff.addingTimeInterval(1), "new during cleanup"))
        files.release()
        let result = await clear.value
        XCTAssertEqual(result.removedEntries, 2); XCTAssertEqual(result.removedFiles, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(files.writeCount, 2, "The queued stale write is invalidated; only running-old and new snapshots write")
        XCTAssertEqual(log.entries.map(\.episode), ["new during cleanup"])
        XCTAssertEqual(try decoded([ProcessingTiming].self, at: url).map(\.episode), ["new during cleanup"])
    }

    func testClearInvalidatesQueuedBackgroundSnapshotsAndLaterNotesDoNotResurrectOldEvents() async throws {
        let files = ControlledFiles(), url = folder.appending(path: "background.json")
        let log = BackgroundLog(url: url, operations: files.operations, now: { self.cutoff })
        files.blockNext(); log.note("running old write")
        try await waitUntil { files.didEnter }
        log.note("queued stale write")
        var began = false
        let clear = Task { began = true; return await log.prune(before: nil) }
        try await waitUntil { began }
        files.release()
        let result = await clear.value
        XCTAssertEqual(result.removedEntries, 2); XCTAssertEqual(result.removedFiles, 1)
        XCTAssertTrue(result.failures.isEmpty); XCTAssertTrue(log.events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        log.note("new after cleanup"); await log.flush()
        XCTAssertEqual(try decoded([BackgroundLog.Event].self, at: url).map(\.text), ["new after cleanup"])
    }

    func testTimingRewriteFailureKeepsOriginalEntriesAndReportsNoFreedSpace() async throws {
        let files = ControlledFiles(), url = folder.appending(path: "timings.json")
        let entries = [timing(cutoff, "boundary"), timing(cutoff.addingTimeInterval(-1), "old")]
        let original = try JSONEncoder.iso.encode(entries); try original.write(to: url)
        let log = TimingLog(url: url, operations: files.operations, demo: false)
        files.failWrite(true)
        let result = await log.prune(before: cutoff)
        XCTAssertEqual(result.removedEntries, 0); XCTAssertEqual(result.removedFiles, 0); XCTAssertEqual(result.freedBytes, 0)
        XCTAssertFalse(result.failures.isEmpty); XCTAssertNotNil(log.storageError)
        XCTAssertEqual(log.entries.map(\.id), entries.map(\.id))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testBackgroundUnlinkFailureKeepsMemoryAndFileUntilExplicitRetrySucceeds() async throws {
        let files = ControlledFiles(), url = folder.appending(path: "background.json")
        let original = [BackgroundLog.Event(date: cutoff, text: "keep if failed")]
        try JSONEncoder.iso.encode(original).write(to: url)
        let log = BackgroundLog(url: url, operations: files.operations)
        files.failRemove(true)
        let failed = await log.prune(before: nil)
        XCTAssertEqual(failed.removedEntries, 0); XCTAssertEqual(failed.removedFiles, 0); XCTAssertEqual(failed.freedBytes, 0)
        XCTAssertFalse(failed.failures.isEmpty); XCTAssertEqual(log.events.map(\.text), ["keep if failed"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        files.failRemove(false)
        let retried = await log.prune(before: nil)
        XCTAssertTrue(retried.failures.isEmpty); XCTAssertEqual(retried.removedFiles, 1)
        XCTAssertTrue(log.events.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUnreadableLogsArePreservedUntilExplicitClearAll() async throws {
        for filename in ["timings.json", "background.json"] {
            let url = folder.appending(path: filename), original = Data("unknown broken log".utf8)
            try original.write(to: url)
            if filename == "timings.json" {
                let log = TimingLog(url: url, demo: false)
                log.record(timing(cutoff)); await log.flush()
                XCTAssertEqual(try Data(contentsOf: url), original)
                let selective = await log.prune(before: cutoff)
                XCTAssertFalse(selective.failures.isEmpty)
                let all = await log.prune(before: nil)
                XCTAssertTrue(all.failures.isEmpty); XCTAssertEqual(all.removedFiles, 1)
            } else {
                let log = BackgroundLog(url: url)
                log.note("buffered new note"); await log.flush()
                XCTAssertEqual(try Data(contentsOf: url), original)
                let selective = await log.prune(before: cutoff)
                XCTAssertFalse(selective.failures.isEmpty)
                let all = await log.prune(before: nil)
                XCTAssertTrue(all.failures.isEmpty); XCTAssertEqual(all.removedFiles, 1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testTimingAndBackgroundRetentionCapsRemain200And150() async throws {
        let timingURL = folder.appending(path: "timings.json"), backgroundURL = folder.appending(path: "background.json")
        let timings = TimingLog(url: timingURL, demo: false), background = BackgroundLog(url: backgroundURL)
        for index in 0..<205 { timings.record(timing(cutoff, String(index))); background.note(String(index)) }
        await timings.flush(); await background.flush()
        XCTAssertEqual(timings.entries.count, 200); XCTAssertEqual(background.events.count, 150)
        XCTAssertEqual(try decoded([ProcessingTiming].self, at: timingURL).count, 200)
        XCTAssertEqual(try decoded([BackgroundLog.Event].self, at: backgroundURL).count, 150)
    }

    func testMetricReportDatePruningAndRetentionKeepNewest40AndOtherFiles() async throws {
        let subscriber = MetricsSubscriber(folder: folder, defaults: defaults)
        for index in 0..<45 { subscriber.save(Data("report".utf8), kind: "daily", stamp: Date(timeIntervalSince1970: Double(2_000 + index))) }
        await subscriber.flush()
        XCTAssertEqual(try subscriber.reportFiles().count, 40)
        XCTAssertEqual(try subscriber.reportFiles().last?.date, Date(timeIntervalSince1970: 2_005))
        let other = folder.appending(path: "unrelated.json"); try Data("keep".utf8).write(to: other)
        let result = await subscriber.prune(before: Date(timeIntervalSince1970: 2_010))
        XCTAssertEqual(result.removedFiles, 5); XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try subscriber.reportFiles().count, 35)
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        // Payload date controls the filter, even though every file was just written.
        XCTAssertEqual(try subscriber.reportFiles().last?.date, Date(timeIntervalSince1970: 2_010))
    }

    func testMetricQueuedWriteAndPastPayloadReplayCannotRestoreClearedReportsAfterRelaunch() async throws {
        let files = ControlledFiles()
        let subscriber = MetricsSubscriber(folder: folder, operations: files.operations, defaults: defaults)
        files.blockNext()
        subscriber.save(Data("old".utf8), kind: "daily", stamp: Date(timeIntervalSince1970: 2_000))
        try await waitUntil { files.didEnter }
        var began = false
        let clear = Task { began = true; return await subscriber.prune(before: nil) }
        try await waitUntil { began }; files.release()
        let result = await clear.value
        XCTAssertEqual(result.removedFiles, 1); XCTAssertTrue(result.failures.isEmpty)
        let reopened = MetricsSubscriber(folder: folder, defaults: defaults)
        reopened.save(Data("past replay".utf8), kind: "daily", stamp: Date(timeIntervalSince1970: 2_000))
        reopened.save(Data("new".utf8), kind: "diagnostic", stamp: Date.now.addingTimeInterval(10))
        await reopened.flush()
        let reports = try reopened.reportFiles()
        XCTAssertEqual(reports.count, 1); XCTAssertEqual(reports.first?.kind, "diagnostic")
    }

    func testMetricDeletionAndListingFailuresNeverClaimRemovedFilesOrSpace() async throws {
        let files = ControlledFiles()
        let subscriber = MetricsSubscriber(folder: folder, operations: files.operations, defaults: defaults)
        subscriber.save(Data("original".utf8), kind: "daily", stamp: Date(timeIntervalSince1970: 2_000))
        await subscriber.flush(); files.failRemove(true)
        let failed = await subscriber.prune(before: cutoff)
        XCTAssertEqual(failed.removedFiles, 0); XCTAssertEqual(failed.freedBytes, 0); XCTAssertFalse(failed.failures.isEmpty)
        let report = try XCTUnwrap(subscriber.reportFiles().first)
        subscriber.save(Data("replayed replacement".utf8), kind: "daily", stamp: Date(timeIntervalSince1970: 2_000))
        await subscriber.flush()
        XCTAssertEqual(try Data(contentsOf: report.url), Data("original".utf8))
        files.failList(true)
        let unlisted = await subscriber.prune(before: nil)
        XCTAssertEqual(unlisted.removedFiles, 0); XCTAssertEqual(unlisted.freedBytes, 0); XCTAssertFalse(unlisted.failures.isEmpty)
    }

    func testReportCleanupPreservesNamedDirectoriesSymlinksAndOutsideListedFiles() async throws {
        let outside = URL.temporaryDirectory.appending(path: "DiagnosticsOutside-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let external = outside.appending(path: "daily-2100.json")
        let externalData = Data("outside data".utf8); try externalData.write(to: external)
        let directory = folder.appending(path: "daily-2000.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inside = directory.appending(path: "keep.txt"); try Data("keep directory".utf8).write(to: inside)
        let link = folder.appending(path: "diagnostic-2001.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let regular = folder.appending(path: "diagnostic-1999.json"); try Data("owned report".utf8).write(to: regular)
        var operations = DiagnosticLogFile.Operations.live
        operations.list = { url in try DiagnosticLogFile.Operations.live.list(url) + [external] }
        let subscriber = MetricsSubscriber(folder: folder, operations: operations, defaults: defaults)
        XCTAssertEqual(try subscriber.reportFiles().map(\.url), [regular])
        let result = await subscriber.prune(before: nil)
        XCTAssertEqual(result.removedFiles, 1); XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: external), externalData)
    }

    func testDuplicateLogIdentitiesFailClosedInsteadOfDeletingANewerRow() async throws {
        let timingURL = folder.appending(path: "timings.json"), backgroundURL = folder.appending(path: "background.json")
        var oldTiming = timing(cutoff.addingTimeInterval(-1), "old"), newTiming = timing(cutoff, "keep")
        oldTiming.id = newTiming.id
        let timingBytes = try JSONEncoder.iso.encode([oldTiming, newTiming]); try timingBytes.write(to: timingURL)
        let timingLog = TimingLog(url: timingURL, demo: false)
        XCTAssertTrue(timingLog.entries.isEmpty); XCTAssertNotNil(timingLog.storageError)
        timingLog.record(timing(cutoff)); await timingLog.flush()
        let timingResult = await timingLog.prune(before: cutoff)
        XCTAssertFalse(timingResult.failures.isEmpty); XCTAssertEqual(timingResult.removedEntries, 0)
        XCTAssertEqual(try Data(contentsOf: timingURL), timingBytes)
        var oldEvent = BackgroundLog.Event(date: cutoff.addingTimeInterval(-1), text: "old")
        let newEvent = BackgroundLog.Event(date: cutoff, text: "keep")
        oldEvent.id = newEvent.id
        let backgroundBytes = try JSONEncoder.iso.encode([oldEvent, newEvent]); try backgroundBytes.write(to: backgroundURL)
        let backgroundLog = BackgroundLog(url: backgroundURL)
        XCTAssertTrue(backgroundLog.events.isEmpty); XCTAssertNotNil(backgroundLog.storageError)
        backgroundLog.note("buffered new event"); await backgroundLog.flush()
        let backgroundResult = await backgroundLog.prune(before: cutoff)
        XCTAssertFalse(backgroundResult.failures.isEmpty); XCTAssertEqual(backgroundResult.removedEntries, 0)
        XCTAssertEqual(try Data(contentsOf: backgroundURL), backgroundBytes)
        let timingClear = await timingLog.prune(before: nil), backgroundClear = await backgroundLog.prune(before: nil)
        XCTAssertTrue(timingClear.failures.isEmpty)
        XCTAssertTrue(backgroundClear.failures.isEmpty)
    }

    func testKnownLogNamesCannotRecursivelyRemoveDirectoriesOrFollowSymlinks() async throws {
        let directory = folder.appending(path: "timings.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inside = directory.appending(path: "unrelated.txt"); try Data("keep".utf8).write(to: inside)
        let target = folder.appending(path: "unrelated.json"), bytes = Data("outside log ownership".utf8)
        try bytes.write(to: target)
        let link = folder.appending(path: "background.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let timingLog = TimingLog(url: directory, demo: false), backgroundLog = BackgroundLog(url: link)
        XCTAssertNotNil(timingLog.storageError); XCTAssertNotNil(backgroundLog.storageError)
        timingLog.record(timing(cutoff)); backgroundLog.note("new record")
        await timingLog.flush(); await backgroundLog.flush()
        let timingResult = await timingLog.prune(before: nil), backgroundResult = await backgroundLog.prune(before: nil)
        XCTAssertFalse(timingResult.failures.isEmpty); XCTAssertFalse(backgroundResult.failures.isEmpty)
        XCTAssertEqual(timingResult.removedFiles, 0); XCTAssertEqual(backgroundResult.removedFiles, 0)
        XCTAssertEqual(timingResult.freedBytes, 0); XCTAssertEqual(backgroundResult.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }
}
