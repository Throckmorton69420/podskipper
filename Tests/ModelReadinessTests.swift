import XCTest
@testable import PodSkipper

final class ModelReadinessTests: XCTestCase {
    func testPartialBundleCannotBecomeReadyUntilEveryPinnedFileArrives() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = LocalModelSpec.qwen35_4B
        let folder = root.appending(path: spec.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = ModelStore.Manifest(repo: spec.id, revision: spec.revision,
            files: [.init(path: "config.json", size: 2), .init(path: "tokenizer.json", size: 2), .init(path: "model.safetensors", size: 32)])
        try Data("{}".utf8).write(to: folder.appending(path: "config.json"))
        try Data(repeating: 0, count: 32).write(to: folder.appending(path: "model.safetensors"))
        let partial = await ModelStore.readDisk(for: spec, manifest: manifest, rootURL: root)
        XCTAssertEqual(partial.nextFile?.path, "tokenizer.json")
        try Data("{}".utf8).write(to: folder.appending(path: "tokenizer.json"))
        let complete = await ModelStore.readDisk(for: spec, manifest: manifest, rootURL: root)
        XCTAssertNil(complete.nextFile)
        XCTAssertEqual(complete.doneBytes, manifest.total)
        // Same byte count does not make corrupt JSON usable.
        try Data("xx".utf8).write(to: folder.appending(path: "config.json"))
        let corrupt = await ModelStore.readDisk(for: spec, manifest: manifest, rootURL: root)
        XCTAssertEqual(corrupt.nextFile?.path, "config.json")
    }

    func testEmptyForeignAndUnsafeManifestsAreNotDownloadedModels() async {
        let spec = LocalModelSpec.qwen35_4B
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = ModelStore.Manifest(repo: spec.id, revision: spec.revision, files: [])
        XCTAssertFalse(manifest.isValid(for: spec))
        let disk = await ModelStore.readDisk(for: spec, manifest: manifest, rootURL: root)
        XCTAssertNil(disk.manifest, "An empty file list must not mark an empty folder ready.")
        manifest.files = [.init(path: "config.json", size: 2), .init(path: "tokenizer.json", size: 2), .init(path: "model.safetensors", size: 32)]
        XCTAssertTrue(manifest.isValid(for: spec))
        manifest.revision = "older-version"
        XCTAssertFalse(manifest.isValid(for: spec))
        manifest.revision = spec.revision
        manifest.files.append(.init(path: "../escape.safetensors", size: 1))
        XCTAssertFalse(manifest.isValid(for: spec))
    }

    func testCoreAIBundlePathsCannotEscapeStaging() {
        XCTAssertTrue(CoreAIModelDownload.safePath("model.aimodel/model.bin"))
        XCTAssertFalse(CoreAIModelDownload.safePath("../model.bin"))
        XCTAssertFalse(CoreAIModelDownload.safePath("/model.bin"))
        XCTAssertFalse(CoreAIModelDownload.safePath(""))
    }
}
