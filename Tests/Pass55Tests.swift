import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 55: what his 30–31 Oct phone (build 1c40b4f) showed.
@MainActor
final class Pass55LibraryOpenTests: XCTestCase {
    func testOnlySQLiteFailuresThatClearByThemselvesAreRetried() {
        // Seen on his phone after each Core AI compiler abort.
        XCTAssertTrue(LibraryStore.isPassing("Error Domain=NSCocoaErrorDomain Code=256 UserInfo={NSSQLiteErrorDomain=4618}"))
        XCTAssertTrue(LibraryStore.isPassing("NSSQLiteErrorDomain = 5"))
        XCTAssertTrue(LibraryStore.isPassing("NSSQLiteErrorDomain=3850"))
        XCTAssertFalse(LibraryStore.isPassing("NSSQLiteErrorDomain=11"), "damage is not retried")
        XCTAssertFalse(LibraryStore.isPassing("NSSQLiteErrorDomain=13"), "a full disk is not retried")
        XCTAssertFalse(LibraryStore.isPassing("NSSQLiteErrorDomain=14"), "a folder where the store should be is not retried")
        XCTAssertFalse(LibraryStore.isPassing("SwiftData.SwiftDataError error 1"))
    }

    func testAGoodStoreOpensFirstTimeWithoutWaiting() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "p55-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = LibraryStore(url: folder.appending(path: "copy.store"))
        let started = Date.now
        _ = try await store.container()
        XCTAssertLessThan(Date.now.timeIntervalSince(started), 5)
        XCTAssertEqual(store.openCount, 1)
    }
}

final class Pass55FunnyAdTests: XCTestCase {
    private func part(_ label: JudgeLabel, funny: Bool) -> JudgedPart {
        JudgedPart(firstLine: 0, lastLine: 3, label: label, sponsor: "Sheath", funny: funny, confidence: 80, why: "")
    }

    func testAPaidSpotIsNeverAFunnyAd() {
        // Jared #954: Qwen3 4B's PAID_AD, funny, played for three minutes.
        XCTAssertFalse(ModelFinder.funnyCounts(part(.paidAd, funny: true), words: "Use code JARED for 20 percent off", seconds: 115))
    }

    func testAHostReadThatSoundsProducedIsNotFunny() {
        XCTAssertFalse(ModelFinder.funnyCounts(part(.hostReadAd, funny: true),
                                               words: "Terms apply. Not available in all states.", seconds: 40))
    }

    func testAFunnyHostReadStaysFunny() {
        XCTAssertTrue(ModelFinder.funnyCounts(part(.hostReadAd, funny: true),
                                              words: "Dude you shaved your back with it, still smoother than you", seconds: 60))
        XCTAssertFalse(ModelFinder.funnyCounts(part(.hostReadAd, funny: false), words: "anything", seconds: 60))
    }
}

@MainActor
final class Pass55SoundScopeTests: XCTestCase {
    func testNeutralIsHowPodSkipperStarts() {
        let settings = AppSettings()
        let saved = settings.profile
        defer { settings.profile = saved }
        settings.resetSoundToDefaults()
        XCTAssertEqual(settings.profile, .neutral)
        XCTAssertTrue(settings.profile.isNeutral)
    }

    func testResetThisShowKeepsItsOwnNeutralSettingsAndLeavesTheDefault() throws {
        let container = try ModelContainer(for: LibraryStore.schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let show = Podcast(feedURL: "https://example.com/feed", title: "Show")
        container.mainContext.insert(show)
        let settings = AppSettings()
        let saved = settings.profile
        defer { settings.profile = saved }
        var loud = saved
        loud.speed = 1.8
        loud.smartSpeed = true
        settings.profile = loud
        show.setOwnSound(loud)

        show.setOwnSound(.neutral)
        XCTAssertTrue(show.hasOwnSound, "Reset This Show keeps settings of its own")
        XCTAssertTrue(settings.profile(for: show).isNeutral)
        XCTAssertEqual(settings.profile.speed, 1.8, "the default is untouched")

        show.useDefaultSound()
        XCTAssertFalse(show.hasOwnSound)
        XCTAssertEqual(settings.profile(for: show).speed, 1.8, "Use My Default follows the default")
    }
}
