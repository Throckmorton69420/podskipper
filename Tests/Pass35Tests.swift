import XCTest
@testable import PodSkipper

/// Pass 35 (his 9 Oct phone report on build 36410ed). Everything destructive
/// here runs on a throwaway folder.
final class Pass35Tests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pass35-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var locations: ModelStorage.Locations {
        ModelStorage.Locations(mlxRoot: root.appending(path: "Models"),
                               coreAIRoot: root.appending(path: "CoreAIKit/Models"),
                               caches: root.appending(path: "Caches"),
                               temporary: root.appending(path: "tmp"))
    }

    @discardableResult
    private func file(_ path: String, bytes: Int = 4096, modified: Date? = nil) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
        if let modified {
            // The file and every folder above it, up to (not including) the area root.
            var item = url
            while item.pathComponents.count > root.pathComponents.count + 1 {
                try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: item.path)
                item = item.deletingLastPathComponent()
            }
        }
        return url
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: path).path) }

    // MARK: Model inventory

    /// His phone: three MLX models in "owner/repo" folders, none of them the
    /// chosen one. Every one must be found as a downloaded model, and none
    /// may be offered for bulk removal.
    func testNestedMLXModelsAreInstalledNotUnused() throws {
        for id in ["mlx-community/Qwen3.5-4B-MLX-4bit", "ALTICDEV/Qwen3.5-4B-Instruct-MLX-Q6", "prism-ml/Bonsai-8B-mlx-1bit"] {
            try file("Models/\(id)/config.json", bytes: 100)
            try file("Models/\(id)/model.safetensors", bytes: 20_000)
        }
        let ids: Set = ["mlx-community/Qwen3.5-4B-MLX-4bit", "ALTICDEV/Qwen3.5-4B-Instruct-MLX-Q6", "prism-ml/Bonsai-8B-mlx-1bit"]
        let report = ModelStorage.measure(.init(mlxIDs: ids, mlxReady: ids), at: locations)
        let mlx = report.models(.mlx)
        XCTAssertEqual(Set(mlx.map(\.relativePath)), ids)
        XCTAssertTrue(mlx.allSatisfy { $0.status == .installed })
        XCTAssertEqual(Set(mlx.compactMap(\.catalogID)), ids)
        XCTAssertTrue(report.partials.isEmpty)
        XCTAssertTrue(report.tidyEntries.isEmpty, "Tidy Up never offers a model")
        XCTAssertGreaterThan(report.modelBytes, 60_000)
    }

    /// A model the list no longer names is still a model: shown, kept, and
    /// labelled — not "unused". An unfinished one of a listed model is
    /// "incomplete"; a hidden folder is a stopped download.
    func testUnlistedAndIncompleteMLXModelsAreKeptAndLabelled() throws {
        try file("Models/old-owner/Retired-Model/config.json", bytes: 100)
        try file("Models/old-owner/Retired-Model/model.safetensors", bytes: 9_000)
        try file("Models/mlx-community/Qwen3.5-2B-MLX-4bit/.download.json", bytes: 100)
        try file("Models/flat-legacy-model/config.json", bytes: 100)
        try file("Models/.partial-xyz/blob", bytes: 3_000)
        try file("Models/mlx-community/stray.txt", bytes: 50)
        let report = ModelStorage.measure(.init(mlxIDs: ["mlx-community/Qwen3.5-2B-MLX-4bit"]), at: locations)
        let byPath = Dictionary(uniqueKeysWithValues: report.models(.mlx).map { ($0.relativePath, $0) })
        XCTAssertEqual(byPath["old-owner/Retired-Model"]?.status, .notInList)
        XCTAssertEqual(byPath["mlx-community/Qwen3.5-2B-MLX-4bit"]?.status, .incomplete)
        XCTAssertEqual(byPath["flat-legacy-model"]?.status, .notInList)
        // A loose file is its own item, never its owner folder.
        XCTAssertEqual(byPath["mlx-community/stray.txt"]?.url.lastPathComponent, "stray.txt")
        XCTAssertNil(byPath["mlx-community"])
        XCTAssertEqual(report.partials.count, 1)
    }

    /// Core AI copies: the one loaded, another version of a listed model,
    /// a model not in the list, and a stopped download, told apart.
    func testCoreAICopiesAreToldApart() throws {
        try file("CoreAIKit/Models/acme/gemma/rev2/gpu-pipelined/portable/metadata.json")
        try file("CoreAIKit/Models/acme/gemma/rev2/gpu-pipelined/aotc_h18p/metadata.json")
        try file("CoreAIKit/Models/acme/gemma/rev1/gpu-pipelined/portable/metadata.json")
        try file("CoreAIKit/Models/other/model/rev/ios/metadata.json")
        try file("CoreAIKit/Models/acme/qwen/rev9/.podskipper-staging-ios/main.mlirb", bytes: 8_000)
        let known = ModelStorage.Known(coreAIPaths: ["gemma": "acme/gemma/rev2/gpu-pipelined/portable"],
                                       coreAIRepos: ["gemma": "acme/gemma", "qwen": "acme/qwen"])
        let report = ModelStorage.measure(known, at: locations)
        let byPath = Dictionary(uniqueKeysWithValues: report.models(.coreAI).map { ($0.relativePath, $0) })
        XCTAssertEqual(byPath["acme/gemma/rev2/gpu-pipelined/portable"]?.status, .installed)
        XCTAssertEqual(byPath["acme/gemma/rev2/gpu-pipelined/aotc_h18p"]?.status, .otherVersion)
        XCTAssertEqual(byPath["acme/gemma/rev1/gpu-pipelined/portable"]?.status, .otherVersion)
        XCTAssertEqual(byPath["acme/gemma/rev1/gpu-pipelined/portable"]?.revision, "rev1")
        XCTAssertEqual(byPath["other/model/rev/ios"]?.status, .notInList)
        XCTAssertEqual(report.partials.count, 1)
        // A running download's files are not "stopped".
        var active = known; active.downloadActive = true
        XCTAssertTrue(ModelStorage.measure(active, at: locations).partials.isEmpty)
    }

    // MARK: Removal stays inside its folders

    func testRemovalRefusesTheRootsOutsidePathsAndSymlinkEscapes() throws {
        try file("CoreAIKit/Models/acme/gemma/rev1/portable/metadata.json")
        let library = try file("Library/default.store")
        let link = root.appending(path: "Models/escape")
        try FileManager.default.createDirectory(at: locations.mlxRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: library.deletingLastPathComponent())
        let result = ModelStorage.removeModelFiles([
            root.appending(path: "CoreAIKit/Models/acme/gemma/rev1/portable"),
            library, locations.coreAIRoot, locations.mlxRoot,
            link.appending(path: "default.store"),
            root.appending(path: "Models/../Library/default.store"),
        ], at: locations)
        XCTAssertEqual(result.failures.count, 5)
        XCTAssertTrue(exists("Library/default.store"), "the library is never touched")
        XCTAssertFalse(exists("CoreAIKit/Models/acme/gemma"), "the removed copy and its emptied folders go")
        XCTAssertGreaterThan(result.freed, 0)
    }

    // MARK: Temporary files and caches

    func testScratchIsClassifiedAndRecentOrUnknownFilesAreProtected() throws {
        let old = Date(timeIntervalSinceNow: -86_400)
        try file("tmp/CFNetworkDownload_ab12.tmp", bytes: 50_000, modified: old)
        try file("tmp/Backup-1234/AppSupport/x", bytes: 10_000, modified: old)
        try file("tmp/PodSkipper-diagnostics-1.json", bytes: 2_000, modified: old)
        try file("tmp/com.apple.mpsgraph.cache/blob", bytes: 30_000, modified: old)
        try file("tmp/mystery.bin", bytes: 7_000, modified: old)
        try file("tmp/Clips/clip.m4a", bytes: 1_000) // just written
        try file("Caches/com.apple.e5rt.e5bundlecache/26A/x.e5", bytes: 40_000, modified: old)

        let report = ModelStorage.measure(.init(), at: locations)
        let kinds = Dictionary(uniqueKeysWithValues: report.scratch.map { ($0.name, $0) })
        XCTAssertEqual(kinds["CFNetworkDownload_ab12.tmp"]?.kind, .interruptedDownload)
        XCTAssertEqual(kinds["Backup-1234"]?.kind, .backupStaging)
        XCTAssertEqual(kinds["PodSkipper-diagnostics-1.json"]?.kind, .shareExports)
        XCTAssertEqual(kinds["com.apple.mpsgraph.cache"]?.kind, .modelCompileScratch)
        XCTAssertEqual(kinds["mystery.bin"]?.kind, .unknown)
        XCTAssertEqual(kinds["com.apple.e5rt.e5bundlecache"]?.kind, .compiledModels)
        XCTAssertEqual(kinds["Clips"]?.inUse, true, "written in the last 15 minutes")
        XCTAssertGreaterThan(report.compiledBytes, 0)

        let tidy = Set(report.tidyEntries.map(\.name))
        XCTAssertEqual(tidy, ["CFNetworkDownload_ab12.tmp", "Backup-1234", "PodSkipper-diagnostics-1.json", "com.apple.mpsgraph.cache"],
                       "unknown, in-use and compiled copies are never in Tidy Up")

        // Asking to remove everything still keeps what is in use.
        let result = ModelStorage.removeScratch(report.scratch, at: locations)
        XCTAssertTrue(exists("tmp/Clips/clip.m4a"))
        XCTAssertFalse(exists("tmp/CFNetworkDownload_ab12.tmp"))
        XCTAssertEqual(result.failures.count, 1)
    }

    /// While a download runs its interrupted-looking files are in use; while
    /// heavy work runs, the compiled cache is too.
    func testWorkUnderWayProtectsItsScratch() throws {
        let old = Date(timeIntervalSinceNow: -86_400)
        try file("tmp/CFNetworkDownload_cd34.tmp", modified: old)
        try file("Caches/com.apple.e5rt.e5bundlecache/x", modified: old)
        let report = ModelStorage.measure(.init(downloadActive: true, workActive: true), at: locations)
        XCTAssertTrue(report.scratch.allSatisfy(\.inUse))
    }

    // MARK: Free space

    func testStorageGuardKeepsRoomForTheLibrary() {
        XCTAssertEqual(StorageGuard.check(writing: 2_500_000_000, free: 339_000_000),
                       .insufficient(free: 339_000_000, needed: 3_500_000_000))
        XCTAssertEqual(StorageGuard.check(writing: 0, free: 1_500_000_000), .low(free: 1_500_000_000))
        XCTAssertEqual(StorageGuard.check(writing: 1_000_000_000, free: 30_000_000_000), .ok)
        XCTAssertEqual(StorageGuard.check(writing: 1, free: nil), .ok)
        XCTAssertNotNil(StorageGuard.message(for: .insufficient(free: 1, needed: 2), doing: "prepare Qwen3 4B"))
    }

    // MARK: Library open failure, in words

    func testSQLiteShmOpenIsExplained() {
        let detail = "Error Domain=NSCocoaErrorDomain Code=256 UserInfo={NSFilePath=/x/default.store, NSSQLiteErrorDomain=4618}"
        XCTAssertEqual(LibraryStore.sqliteMeaning(in: detail)?.contains("SQLITE_IOERR_SHMOPEN"), true)
        XCTAssertEqual(LibraryStore.sqliteMeaning(in: "NSSQLiteErrorDomain = 13")?.contains("SQLITE_FULL"), true)
        XCTAssertNil(LibraryStore.sqliteMeaning(in: "no sqlite here"))
    }

    // MARK: Compiled copies

    private func fakeBundle() throws -> URL {
        let bundle = root.appending(path: "CoreAIKit/Models/m/qwen3-4b/rev/ios")
        try FileManager.default.createDirectory(at: bundle.appending(path: "qwen3_4b_static.aimodel"), withIntermediateDirectories: true)
        let metadata: [String: Any] = ["kind": "llm", "assets": ["main": "qwen3_4b_static.aimodel"], "language": ["vocab_size": 1]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: bundle.appending(path: "metadata.json"))
        try Data([1]).write(to: bundle.appending(path: "qwen3_4b_static.aimodel/main.mlirb"))
        return bundle
    }

    private func fakeCompiled(_ name: String) throws -> URL {
        let folder = root.appending(path: "Import/\(name)")
        try file("Import/\(name)/metadata.json", bytes: 10)
        try file("Import/\(name)/main-h17p.mlirb", bytes: 5_000)
        try file("Import/\(name)/main-h17p-delegates/MPSGraph/resources.bin", bytes: 9_000)
        return folder
    }

    func testCompiledCopyInstallsBesideTheDownloadAndRemovesCleanly() throws {
        let bundle = try fakeBundle()
        let source = try fakeCompiled("qwen3_4b_static.h17p.aimodelc")
        let original = try Data(contentsOf: bundle.appending(path: "metadata.json"))

        try CoreAICompiledCopy.install(from: source, into: bundle, machine: "iPhone17,1", free: 50_000_000_000)
        XCTAssertEqual(CoreAICompiledCopy.installed(in: bundle), "qwen3_4b_static.h17p.aimodelc")
        XCTAssertEqual(CoreAICompiledCopy.mainAsset(in: bundle), "qwen3_4b_static.h17p.aimodelc")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "qwen3_4b_static.aimodel/main.mlirb").path),
                      "the download's own graph is untouched")
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(atPath: bundle.path)) ?? []).contains { $0.hasPrefix(".podskipper-staging") })
        // The inventory still sees one installed bundle, not two.
        let report = ModelStorage.measure(.init(coreAIPaths: ["qwen3-4b": "m/qwen3-4b/rev/ios"]), at: locations)
        XCTAssertEqual(report.models(.coreAI).map(\.status), [.installed])

        try CoreAICompiledCopy.remove(from: bundle)
        XCTAssertNil(CoreAICompiledCopy.installed(in: bundle))
        XCTAssertEqual(try Data(contentsOf: bundle.appending(path: "metadata.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.appending(path: CoreAICompiledCopy.portableMetadata).path))
    }

    func testCompiledCopyRefusesAnotherChipAnotherModelOrNoRoom() throws {
        let bundle = try fakeBundle()
        let otherChip = try fakeCompiled("qwen3_4b_static.h18p.aimodelc")
        XCTAssertThrowsError(try CoreAICompiledCopy.install(from: otherChip, into: bundle, machine: "iPhone17,1", free: 50_000_000_000)) {
            XCTAssertEqual($0 as? CoreAICompiledCopy.Failure, .wrongChip("h18p"))
        }
        let otherModel = try fakeCompiled("gemma_static.h17p.aimodelc")
        XCTAssertThrowsError(try CoreAICompiledCopy.install(from: otherModel, into: bundle, machine: "iPhone17,1", free: 50_000_000_000))
        let right = try fakeCompiled("qwen3_4b_static.h17p.aimodelc")
        XCTAssertThrowsError(try CoreAICompiledCopy.install(from: right, into: bundle, machine: "iPhone17,1", free: 100))
        XCTAssertNil(CoreAICompiledCopy.installed(in: bundle), "nothing changed after a refusal")
        let notCompiled = root.appending(path: "Import/plain")
        try FileManager.default.createDirectory(at: notCompiled, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CoreAICompiledCopy.install(from: notCompiled, into: bundle, machine: "iPhone17,1", free: 50_000_000_000)) {
            XCTAssertEqual($0 as? CoreAICompiledCopy.Failure, .notACompiledModel)
        }
    }
}
