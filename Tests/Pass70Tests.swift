import XCTest
import SwiftData
@testable import PodSkipper

/// Pass 70 (his 25 Nov runbook): Import in every model's row with or without
/// the drive, row-scoped Files matching, the drive read again as it comes and
/// goes, Core AI builds compiled for this chip read in place, and the
/// Reader's Basic/Hard tied to the detector version.
@MainActor
final class Pass70Tests: XCTestCase {

    // MARK: Stage 1 — Import in every row

    private func state(downloaded: Bool = false, local: Bool? = nil, compatible: Bool = true, heavy: Bool = false,
                       downloading: Bool = false, removing: Bool = false, onDrive: Bool) -> ModelRowState {
        ModelRowState.make(downloaded: downloaded, local: local ?? downloaded, compatible: compatible, heavy: heavy,
                           enabled: true, downloading: downloading, removing: removing, importing: false, inUse: false,
                           onDrive: onDrive, anotherDownload: false, unsupported: "Not published for iPhone")
    }

    /// Import is beside Download whether or not a drive is linked or holds
    /// the model; only where it comes from changes.
    func testImportIsOfferedWithAndWithoutTheDrive() {
        for onDrive in [false, true] {
            let fresh = state(onDrive: onDrive)
            XCTAssertTrue(fresh.offersImport, "not downloaded, drive \(onDrive)")
            XCTAssertEqual(fresh.importsFromDrive, onDrive)
            XCTAssertEqual(fresh.actionTitle, "Download")
            XCTAssertTrue(state(heavy: true, onDrive: onDrive).offersImport, "a heavy Core AI model, drive \(onDrive)")
            XCTAssertTrue(state(downloaded: true, local: false, onDrive: onDrive).offersImport, "read from the drive: a copy of its own")
            XCTAssertFalse(state(downloaded: true, onDrive: onDrive).offersImport, "already on this iPhone")
            XCTAssertFalse(state(downloading: true, onDrive: onDrive).offersImport, "downloading")
            XCTAssertFalse(state(removing: true, onDrive: onDrive).offersImport, "being removed")
            XCTAssertFalse(state(compatible: false, onDrive: onDrive).offersImport, "no build this iPhone could hold")
        }
        XCTAssertEqual(state(onDrive: false).availability, "Not downloaded")
        XCTAssertEqual(state(onDrive: true).availability, "Not downloaded · on your drive")
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pass70-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func sparse(_ url: URL, bytes: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    /// As `Scripts/ssd_models.py --compile` leaves a build for h17p.
    private func compiledBundle(at bundle: URL, chip: String = "h17p") throws {
        try write(#"{"assets":{"main":"qwen3_4b.aimodel"},"name":"q"}"#, to: bundle.appending(path: "metadata.portable.json"))
        try write(#"{"assets":{"main":"qwen3_4b.\#(chip).aimodelc"},"name":"q"}"#, to: bundle.appending(path: "metadata.json"))
        try write(String(repeating: "w", count: 4_000), to: bundle.appending(path: "qwen3_4b.aimodel/main.mlirb"))
        try write(#"{"sourceHash":"AB"}"#, to: bundle.appending(path: "qwen3_4b.\(chip).aimodelc/metadata.json"))
        try write(String(repeating: "c", count: 3_000), to: bundle.appending(path: "qwen3_4b.\(chip).aimodelc/main.mlirb"))
    }

    private func portableBundle(at bundle: URL) throws {
        try write(#"{"assets":{"main":"m.aimodel"}}"#, to: bundle.appending(path: "metadata.json"))
        try write("w", to: bundle.appending(path: "m.aimodel/main.mlirb"))
    }

    private let qwenPath = "mlboydaisuke/qwen3-4b-CoreAI-official/e40878f/ios"
    private var qwen: ModelImportTarget {
        ModelImportTarget(kind: .coreAI, modelID: "qwen3-4b", name: "Qwen3 4B", bundlePath: qwenPath, bundleTail: "e40878f/ios")
    }

    /// What is picked in Files from a row is that row's model, or refused with why.
    func testARowsFilesPickIsCheckedAgainstItsModel() throws {
        let root = try temporaryFolder()
        let catalog = CPUReading.catalog
        XCTAssertGreaterThan(catalog.count, 1)
        let cpu = catalog[0], otherCPU = catalog[1]
        let cpuRow = ModelImportTarget(kind: .gguf, modelID: cpu.id, name: cpu.name)
        // CPU: its own complete file.
        let gguf = root.appending(path: cpu.file)
        try sparse(gguf, bytes: cpu.bytes)
        guard case .item(let item) = ChosenModel.classify(gguf, for: cpuRow) else { return XCTFail("the row's own GGUF") }
        XCTAssertEqual(item.id, cpuRow.itemID)
        XCTAssertTrue(item.scoped)
        // Another CPU model's complete file in this row.
        let other = root.appending(path: otherCPU.file)
        try sparse(other, bytes: otherCPU.bytes)
        guard case .refused(let wrongCPU) = ChosenModel.classify(other, for: cpuRow) else { return XCTFail("another CPU model") }
        XCTAssertTrue(wrongCPU.contains("not \(cpu.name)"), wrongCPU)
        // An incomplete file of the right name.
        let short = root.appending(path: "short/" + cpu.file)
        try sparse(short, bytes: 10)
        guard case .refused(let incomplete) = ChosenModel.classify(short, for: cpuRow) else { return XCTFail("incomplete") }
        XCTAssertTrue(incomplete.contains("complete file"), incomplete)

        // MLX: its own folder; it is refused in the CPU row.
        let spec = try XCTUnwrap(LocalModelSpec.all.first)
        let mlxRow = ModelImportTarget(kind: .mlx, modelID: spec.id, name: spec.name)
        let mlx = root.appending(path: String(spec.id.split(separator: "/").last!), directoryHint: .isDirectory)
        try write("{}", to: mlx.appending(path: "config.json"))
        guard case .item(let mlxItem) = ChosenModel.classify(mlx, for: mlxRow) else { return XCTFail("the MLX folder") }
        XCTAssertEqual(mlxItem.id, "mlx:" + spec.id)
        guard case .refused(let kind) = ChosenModel.classify(mlx, for: cpuRow) else { return XCTFail("MLX in the CPU row") }
        XCTAssertTrue(kind.contains("an MLX model"), kind)

        // Core AI, compiled: in the drive's layout, and copied without its repo folders.
        let drive = root.appending(path: "coreai/" + qwenPath, directoryHint: .isDirectory)
        try compiledBundle(at: drive)
        guard case .item(let compiled) = ChosenModel.classify(drive, for: qwen) else { return XCTFail("compiled bundle") }
        XCTAssertEqual(compiled.id, "coreai:" + qwenPath)
        XCTAssertEqual(compiled.graph, .compiled(chip: "h17p"))
        let copied = root.appending(path: "iCloud/e40878f/ios", directoryHint: .isDirectory)
        try compiledBundle(at: copied)
        guard case .item(let copiedItem) = ChosenModel.classify(copied, for: qwen) else { return XCTFail("copied build folder") }
        XCTAssertEqual(copiedItem.id, "coreai:" + qwenPath)
        // Core AI, portable (non-compiled).
        let portable = root.appending(path: "p/e40878f/ios", directoryHint: .isDirectory)
        try portableBundle(at: portable)
        guard case .item(let portableItem) = ChosenModel.classify(portable, for: qwen) else { return XCTFail("portable") }
        XCTAssertEqual(portableItem.graph, .portable)
        // Another Core AI build in this row, and a folder with no graph.
        let another = root.appending(path: "x/other-model/abc/gpu", directoryHint: .isDirectory)
        try portableBundle(at: another)
        guard case .refused = ChosenModel.classify(another, for: qwen) else { return XCTFail("another Core AI build") }
        let empty = root.appending(path: "e/e40878f/ios", directoryHint: .isDirectory)
        try write("{}", to: empty.appending(path: "metadata.json"))
        guard case .refused(let noGraph) = ChosenModel.classify(empty, for: qwen) else { return XCTFail("no graph") }
        XCTAssertTrue(noGraph.contains("no Core AI graph"), noGraph)
        // A compiled .aimodelc alone: into this iPhone's download only.
        let graph = drive.appending(path: "qwen3_4b.h17p.aimodelc", directoryHint: .isDirectory)
        guard case .refused(let first) = ChosenModel.classify(graph, for: qwen) else { return XCTFail("nothing to install into") }
        XCTAssertTrue(first.contains("first"), first)
        var downloaded = qwen
        downloaded.onPhone = true
        XCTAssertEqual(ChosenModel.classify(graph, for: downloaded), .compiledCopy(graph))
        guard case .refused = ChosenModel.classify(graph, for: mlxRow) else { return XCTFail("a compiled graph in the MLX row") }
        // Not a model at all.
        let text = root.appending(path: "notes.txt")
        try write("x", to: text)
        guard case .refused = ChosenModel.classify(text, for: cpuRow) else { return XCTFail("a text file") }
    }

    /// A compiled build for this iPhone's chip reads from the drive; another
    /// chip's, a portable build or a missing word table is imported instead.
    func testACompiledBuildOnTheDriveReadsInPlaceOnlyForThisChip() throws {
        let folder = try temporaryFolder()
        try compiledBundle(at: folder.appending(path: qwenPath, directoryHint: .isDirectory))
        let found = CoreAIDriveBundle.readable(under: folder, path: qwenPath, architecture: "h17p")
        XCTAssertEqual(found?.standardizedFileURL.path, folder.appending(path: qwenPath).standardizedFileURL.path)
        XCTAssertNil(CoreAIDriveBundle.readable(under: folder, path: qwenPath, architecture: "h18p"), "another chip")
        XCTAssertNil(CoreAIDriveBundle.readable(under: folder, path: qwenPath, architecture: nil), "the simulator")
        XCTAssertNil(CoreAIDriveBundle.readable(under: folder, path: qwenPath, architecture: "h17p", tablesComplete: { _ in false }),
                     "word tables incomplete")
        let portable = "o/r/rev/gpu"
        try portableBundle(at: folder.appending(path: portable, directoryHint: .isDirectory))
        XCTAssertNil(CoreAIDriveBundle.readable(under: folder, path: portable, architecture: "h17p"), "a portable build")
        XCTAssertNil(CoreAIDriveBundle.readable(under: folder, path: "nothing/here/x", architecture: "h17p"))
        // The drive's list says the same.
        let items = ExternalModelInventory.coreAIItems(under: folder, store: nil, architecture: "h17p")
        let qwenItems = items.filter { $0.id.hasSuffix(qwenPath) }
        XCTAssertEqual(qwenItems.map(\.readsInPlace), [true, false], "compiled copy in place; its portable build imported")
        XCTAssertEqual(items.first { $0.id.hasSuffix(portable) }?.readsInPlace, false)
        XCTAssertEqual(ExternalModelInventory.coreAIItems(under: folder, store: nil, architecture: "h18p")
                        .filter { $0.id.hasSuffix(qwenPath) }.map(\.readsInPlace), [false, false])
    }

    /// The drive is read again as it is unplugged and plugged in (the
    /// watch's reachability check), without Read Again.
    func testTheDriveIsReadAgainWhenItComesAndGoes() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: ExternalModelLibrary.bookmarkKey)
        let interval = ExternalModelImport.watchInterval
        addTeardownBlock { @MainActor in
            ExternalModelImport.watchInterval = interval
            if let saved { defaults.set(saved, forKey: ExternalModelLibrary.bookmarkKey) }
            else { defaults.removeObject(forKey: ExternalModelLibrary.bookmarkKey) }
            ExternalModelLibrary.invalidate()
        }
        let models = try temporaryFolder().appending(path: "Models", directoryHint: .isDirectory)
        let cpu = try XCTUnwrap(CPUReading.catalog.min { $0.bytes < $1.bytes })
        func plugIn() throws { try sparse(models.appending(path: "gguf/" + cpu.file), bytes: cpu.bytes) }
        try plugIn()
        try ExternalModelLibrary.choose(models)
        XCTAssertEqual(ExternalModelLibrary.reachability(), true)
        let external = ExternalModelImport.shared
        ExternalModelImport.watchInterval = 0.2
        func until(_ what: String, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(condition(), what)
        }
        external.rediscover()
        await until("read on appearing") { external.inventory.connected && external.item(gguf: cpu.id) != nil }
        external.watchDrive()
        defer { external.unwatchDrive() }
        let changes = external.rediscoveries
        // Unplugged: the folder can't be reached.
        try FileManager.default.removeItem(at: models)
        await until("unplugged: read again by itself") { !external.inventory.connected && external.item(gguf: cpu.id) == nil }
        XCTAssertGreaterThan(external.rediscoveries, changes, "every runtime looked again")
        // Plugged back in.
        try plugIn()
        await until("plugged in: its model is back") { external.inventory.connected && external.item(gguf: cpu.id) != nil }
    }

    // MARK: Stage 4 — a phone-checklist item moved to the simulator (A5)

    /// Home's "Remove from Continue Playing" / "Remove from New Episodes":
    /// the episode leaves its shelf, stays gone after a relaunch (a new
    /// `HomeShelves` on the same defaults), and Continue Playing brings it
    /// back once it is played again.
    func testHomeShelfRemovalsLastAcrossARelaunch() throws {
        let suite = "pass70.home.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let started = Episode(guid: "started", title: "Started", episodeDescription: "", audioURL: "https://example.invalid/1.mp3",
                              publishedAt: .now.addingTimeInterval(-86_400), duration: 3_600)
        started.playbackPosition = 600
        started.lastPlayedAt = .now.addingTimeInterval(-3_600)
        let shelves = HomeShelves(defaults: defaults)
        XCTAssertEqual(HomeShelves.continuePlaying([started], removals: shelves.removals).map(\.guid), ["started"])
        shelves.remove(guid: "started", from: .continuePlaying)
        shelves.remove(guid: "fresh", from: .newEpisodes)
        XCTAssertTrue(HomeShelves.continuePlaying([started], removals: shelves.removals).isEmpty, "gone from the shelf")
        let relaunched = HomeShelves(defaults: defaults)
        XCTAssertTrue(HomeShelves.continuePlaying([started], removals: relaunched.removals).isEmpty, "still gone after a relaunch")
        XCTAssertTrue(relaunched.removals.isRemoved(guid: "fresh", lastPlayedAt: nil, from: .newEpisodes))
        started.lastPlayedAt = .now.addingTimeInterval(60)
        XCTAssertEqual(HomeShelves.continuePlaying([started], removals: relaunched.removals).map(\.guid), ["started"],
                       "played again: back on Continue Playing")
        XCTAssertTrue(relaunched.removals.isRemoved(guid: "fresh", lastPlayedAt: .now.addingTimeInterval(60), from: .newEpisodes),
                      "New Episodes keeps it off")
    }

    /// Checklist D26: a show page's filter and Hide Played are the show's own
    /// saved settings, so leaving and coming back (a new context on the same
    /// store) keeps them.
    func testAShowsFilterIsKeptWithTheShow() throws {
        let folder = try temporaryFolder()
        let config = ModelConfiguration(url: folder.appending(path: "library.store"))
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self, Chapter.self, configurations: config)
        let context = ModelContext(container)
        let show = Podcast(feedURL: "https://example.invalid/feed.xml", title: "Show")
        context.insert(show)
        show.episodeFilter = "Unplayed"
        show.hidePlayed = true
        try context.save()
        let again = ModelContext(container)
        let read = try XCTUnwrap(again.fetch(FetchDescriptor<Podcast>()).first)
        XCTAssertEqual(read.episodeFilter, "Unplayed")
        XCTAssertTrue(read.hidePlayed)
    }

    // MARK: Stage 2 — the Reader's Basic/Hard follow the detector

    func testReaderResultsFollowTheDetectorVersion() throws {
        func reader(_ detector: Int) -> BenchResult {
            BenchResult(engine: "reader", name: "Reader", sample: .basic, date: .now, score: 0.93,
                        policyVersion: BenchResult.readerPolicy(detector: detector))
        }
        XCTAssertFalse(reader(AdDetector.version - 1).isComparable, "measured with the previous detector")
        XCTAssertTrue(reader(AdDetector.version).isComparable, "measured with this one")
        XCTAssertEqual(reader(AdDetector.version).readerDetectorVersion, AdDetector.version)
        // New results take the current policy by themselves.
        let fresh = BenchResult(engine: "reader", name: "Reader", sample: .hard, date: .now, score: 0.98)
        XCTAssertEqual(fresh.policyVersion, BenchResult.readerPolicyBase + AdDetector.version)
        XCTAssertTrue(fresh.isComparable)
        // A detector bump makes it earlier policy.
        XCTAssertNotEqual(fresh.policyVersion, BenchResult.currentPolicy(for: "reader", detector: AdDetector.version + 1))
        // Other finders are unchanged.
        XCTAssertEqual(BenchResult.currentPolicy(for: "apple"), 2)
        XCTAssertEqual(BenchResult.currentPolicy(for: "qwen3-4b"), 3)
    }

    /// Records saved before Pass 70 (policy 2, or no policy at all) decode,
    /// keep their scores, and read as earlier policy.
    func testOlderReaderRecordsStillDecode() throws {
        let saved = BenchResult(engine: "reader", name: "Reader", sample: .basic, date: Date(timeIntervalSince1970: 1_790_000_000),
                                score: 0.93)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["policyVersion"] = 2
        let pass69 = try JSONDecoder().decode(BenchResult.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(pass69.policyVersion, 2)
        XCTAssertEqual(pass69.score, 0.93)
        XCTAssertFalse(pass69.isComparable)
        XCTAssertNil(pass69.readerDetectorVersion)
        object.removeValue(forKey: "policyVersion")
        object.removeValue(forKey: "runID")
        let older = try JSONDecoder().decode(BenchResult.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.policyVersion, 0)
        XCTAssertEqual(older.engine, "reader")
        XCTAssertFalse(older.isComparable)
        // Round trip of a current one.
        let again = try JSONDecoder().decode(BenchResult.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(again, saved)
        XCTAssertTrue(again.isComparable)
    }
}
