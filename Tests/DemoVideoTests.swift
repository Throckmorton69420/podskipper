import XCTest
import AVFoundation
@testable import PodSkipper

@MainActor
final class DemoVideoTests: XCTestCase {
    func testGeneratedFileHasPlayableChangingNonblackClockFramesAndReusesCache() async throws {
        let folder = try disposableFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clock.mp4")
        let result = try await DemoVideo.makeFixture(at: url, seconds: 1.2)
        XCTAssertEqual(result, url)
        let asset = AVURLAsset(url: result)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1.2, accuracy: 0.025)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let size = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 480, height: 270))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await generator.image(at: .zero)
        let (later, actual) = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600))
        XCTAssertEqual(actual.seconds, 0.8, accuracy: 0.025)
        let firstPixels = try pixels(first)
        let laterPixels = try pixels(later)
        let rgbTotal = stride(from: 0, to: firstPixels.count, by: 4)
            .reduce(0) { $0 + Int(firstPixels[$1]) + Int(firstPixels[$1 + 1]) + Int(firstPixels[$1 + 2]) }
        XCTAssertGreaterThan(Double(rgbTotal) / Double(64 * 36 * 3), 35,
                             "Decoding an all-black fixture must fail verification")
        let whitePixels = stride(from: 0, to: firstPixels.count, by: 4).filter {
            firstPixels[$0] > 210 && firstPixels[$0 + 1] > 210 && firstPixels[$0 + 2] > 210
        }.count
        XCTAssertGreaterThan(whitePixels, 10, "The clock text must be rendered into the video")
        XCTAssertTrue(DemoVideo.frameContainsClockContent(first))
        XCTAssertNotEqual(firstPixels, laterPixels, "The picture must advance rather than repeat one still frame")

        let reused = try await DemoVideo.makeFixture(at: url, seconds: 1.2) { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }
        XCTAssertEqual(reused, result, "A verified cache must avoid fresh encoding")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["clock.mp4"])
    }

    func testCorruptCachedFileAndInterruptedPartialAreRegenerated() async throws {
        let folder = try disposableFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clock.mp4")
        let partial = folder.appendingPathComponent("partial-clock.mp4")
        try Data("corrupt cached video".utf8).write(to: url)
        try Data("interrupted encoding".utf8).write(to: partial)
        _ = try await DemoVideo.makeFixture(at: url, seconds: 0.4)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        let (image, _) = try await generator.image(at: .zero)
        XCTAssertEqual(image.width, 480)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testInterruptedGenerationReportsFailureAndPreservesExistingCache() async throws {
        let folder = try disposableFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clock.mp4")
        let original = Data("original invalid fixture remains until replacement succeeds".utf8)
        try original.write(to: url)
        do {
            _ = try await DemoVideo.makeFixture(at: url, seconds: 0.4) { partial, _ in
                try Data("unfinished".utf8).write(to: partial)
                throw CocoaError(.fileWriteOutOfSpace)
            }
            XCTFail("An encoding failure must be surfaced to the demo initializer")
        } catch let error as DemoVideo.Failure {
            XCTAssertTrue(error.localizedDescription.contains("generation"))
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("partial-clock.mp4").path))
    }

    func testCancellationCleansPartialWithoutPublishingFinalFile() async throws {
        let folder = try disposableFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clock.mp4")
        let partial = folder.appendingPathComponent("partial-clock.mp4")
        let task = Task {
            try await DemoVideo.makeFixture(at: url, seconds: 0.4) { partial, _ in
                try Data("unfinished".utf8).write(to: partial)
                try await Task.sleep(for: .seconds(5))
            }
        }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: partial.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "The writer must begin before cancellation")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must reach the awaited generator")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testConflictingDurationCannotShareAnInFlightWriter() async throws {
        let folder = try disposableFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clock.mp4")
        let partial = folder.appendingPathComponent("partial-clock.mp4")
        let first = Task {
            try await DemoVideo.makeFixture(at: url, seconds: 0.4) { partial, _ in
                try Data("unfinished".utf8).write(to: partial)
                try await Task.sleep(for: .seconds(5))
            }
        }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: partial.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        do {
            _ = try await DemoVideo.makeFixture(at: url, seconds: 1.2)
            XCTFail("Two durations cannot share the same pending destination")
        } catch let error as DemoVideo.Failure {
            XCTAssertTrue(error.localizedDescription.contains("different duration"))
        }
        first.cancel()
        do { _ = try await first.value } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDecodableBlackCacheIsRegenerated() async throws {
        let folder = try disposableFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clock.mp4")
        try await writeBlackVideo(to: url)
        let original = AVURLAsset(url: url)
        let (black, _) = try await AVAssetImageGenerator(asset: original).image(at: .zero)
        XCTAssertFalse(DemoVideo.frameContainsClockContent(black))
        _ = try await DemoVideo.makeFixture(at: url, seconds: 0.4)
        let replacement = AVURLAsset(url: url)
        let (clock, _) = try await AVAssetImageGenerator(asset: replacement).image(at: .zero)
        XCTAssertEqual(clock.width, 480, "The valid but black64px cache must be replaced by the generated clock")
        XCTAssertTrue(DemoVideo.frameContainsClockContent(clock))
    }

    func testRejectsInvalidRequestsBeforeCreatingFiles() async throws {
        let folder = try disposableFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clock.mp4")
        for seconds in [0, Double.nan, .infinity, 121] {
            do {
                _ = try await DemoVideo.makeFixture(at: url, seconds: seconds)
                XCTFail("Invalid duration must fail before writing")
            } catch DemoVideo.Failure.invalidRequest {}
        }
        do {
            _ = try await DemoVideo.makeFixture(at: URL(string: "https://example.invalid/clock.mp4")!, seconds: 1)
            XCTFail("The fixture writer must accept only local destinations")
        } catch DemoVideo.Failure.invalidRequest {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    private func disposableFolder() throws -> URL {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64 * 36 * 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: 64, height: 36,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 36))
        }
        return bytes
    }

    private func writeBlackVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 36
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adapter.pixelBufferPool)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData, writer.status == .writing, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            guard input.isReadyForMoreMediaData else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer), kCVReturnSuccess)
            let black = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(black, [])
            memset(CVPixelBufferGetBaseAddress(black), 0, CVPixelBufferGetBytesPerRow(black) * 36)
            CVPixelBufferUnlockBaseAddress(black, [])
            XCTAssertTrue(adapter.append(black, withPresentationTime: CMTime(value: Int64(frame), timescale: 5)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 0.4, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
