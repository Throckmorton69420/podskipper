import AVFoundation
import UIKit

/// An offline video fixture: a clock drawn into every frame. Callers await a
/// complete, decodable file before making the demo episode available to play.
enum DemoVideo {
    enum Failure: LocalizedError {
        case invalidRequest
        case stage(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest: "A demo video needs a local mp4 address and a duration between 0.2 and 120 seconds."
            case .stage(let stage, let detail): "Demo video \(stage): \(detail)"
            }
        }
    }

    private static let generation = Generation()

    static func makeIfNeeded(named name: String, seconds: Double) async throws -> URL {
        guard name == URL(fileURLWithPath: name).lastPathComponent else { throw Failure.invalidRequest }
        let url = try await makeFixture(at: FileStore.episodesDirectory.appendingPathComponent(name), seconds: seconds)
        FileIndex.insert(name)
        return url
    }

    /// The explicit destination keeps service tests in disposable folders.
    /// A writer hook exercises interruption cleanup without touching live files.
    static func makeFixture(at url: URL, seconds: Double,
                            writer: (@Sendable (URL, Double) async throws -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard url.isFileURL, url.pathExtension.lowercased() == "mp4",
              seconds.isFinite, (0.2...120).contains(seconds) else { throw Failure.invalidRequest }
        return try await generation.make(at: url, seconds: seconds, writer: writer)
    }

    /// Concurrent requests for the same fixture share its generation, so two
    /// launches cannot remove each other's partial output.
    private actor Generation {
        private struct Pending {
            let seconds: Double
            let task: Task<URL, Error>
        }
        private var pending: [String: Pending] = [:]

        func make(at url: URL, seconds: Double,
                  writer: (@Sendable (URL, Double) async throws -> Void)?) async throws -> URL {
            let key = url.standardizedFileURL.path
            if let existing = pending[key] {
                guard existing.seconds == seconds else {
                    throw Failure.stage("request", "The same fixture is already being generated with a different duration.")
                }
                return try await existing.task.value
            }
            let task = Task.detached(priority: .userInitiated) {
                try await DemoVideo.prepare(at: url, seconds: seconds, writer: writer)
            }
            pending[key] = Pending(seconds: seconds, task: task)
            defer { pending[key] = nil }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    private static func prepare(at url: URL, seconds: Double,
                                writer: (@Sendable (URL, Double) async throws -> Void)?) async throws -> URL {
        let files = FileManager.default
        if files.fileExists(atPath: url.path), await isUsable(url, seconds: seconds) { return url }
        try Task.checkCancellation()
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.deletingLastPathComponent().appendingPathComponent("partial-\(url.lastPathComponent)")
        if files.fileExists(atPath: partial.path) { try files.removeItem(at: partial) }
        defer { try? files.removeItem(at: partial) }
        do {
            if let writer { try await writer(partial, seconds) }
            else { try await write(to: partial, seconds: seconds) }
            try Task.checkCancellation()
            guard await isUsable(partial, seconds: seconds) else {
                throw Failure.stage("validation", "The completed file has no decodable video frame or the wrong duration.")
            }
            try Task.checkCancellation()
            if files.fileExists(atPath: url.path) {
                _ = try files.replaceItemAt(url, withItemAt: partial)
            } else {
                try files.moveItem(at: partial, to: url)
            }
            return url
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.stage("generation", error.localizedDescription)
        }
    }

    private static func isUsable(_ url: URL, seconds: Double) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty, duration.isFinite, abs(duration - seconds) <= 0.21 else { return false }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 64, height: 36)
            let (frame, _) = try await generator.image(at: .zero)
            return frameContainsClockContent(frame)
        } catch { return false }
    }

    /// Small decoded samples must contain both the colored field and white
    /// clock text. A decodable all-black/still placeholder is not this fixture.
    static func frameContainsClockContent(_ image: CGImage) -> Bool {
        let width = 64, height = 36
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        var brightness = 0, white = 0
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            brightness += Int(bytes[pixel]) + Int(bytes[pixel + 1]) + Int(bytes[pixel + 2])
            if bytes[pixel] > 210 && bytes[pixel + 1] > 210 && bytes[pixel + 2] > 210 { white += 1 }
        }
        return Double(brightness) / Double(width * height * 3) > 35 && white > 10
    }

    private static func write(to url: URL, seconds: Double) async throws {
        let width = 480, height = 270, fps: Int32 = 5
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw Failure.stage("configuration", "H.264 video input is unsupported.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw Failure.stage("start", writer.error?.localizedDescription ?? "The writer did not start.")
        }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw Failure.stage("buffer setup", writer.error?.localizedDescription ?? "No video pixel buffer pool was created.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        func checkWriter(_ stage: String) throws {
            try Task.checkCancellation()
            guard writer.status == .writing else {
                throw Failure.stage(stage, writer.error?.localizedDescription ?? "Writer status \(writer.status.rawValue).")
            }
            guard ContinuousClock.now < deadline else { throw Failure.stage(stage, "Encoding exceeded 30 seconds.") }
        }
        let frames = Int(ceil(seconds * Double(fps)))
        for frame in 0..<frames {
            try checkWriter("frame \(frame)")
            while !input.isReadyForMoreMediaData {
                try checkWriter("frame \(frame) readiness")
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard result == kCVReturnSuccess, let buffer else {
                throw Failure.stage("frame \(frame) allocation", "Core Video returned \(result).")
            }
            try draw(into: buffer, width: width, height: height, time: Double(frame) / Double(fps))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
                throw Failure.stage("frame \(frame) append", writer.error?.localizedDescription ?? "The frame was rejected.")
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        input.markAsFinished()
        writer.finishWriting(completionHandler: {})
        while writer.status == .writing {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw Failure.stage("finalization", "Encoding exceeded 30 seconds.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        guard writer.status == .completed else {
            throw Failure.stage("finalization", writer.error?.localizedDescription ?? "The writer did not complete.")
        }
    }

    private static func draw(into buffer: CVPixelBuffer, width: Int, height: Int, time: Double) throws {
        let locked = CVPixelBufferLockBaseAddress(buffer, [])
        guard locked == kCVReturnSuccess else { throw Failure.stage("drawing", "Could not lock the pixel buffer: \(locked).") }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            throw Failure.stage("drawing", "The BGRA bitmap context could not be created.")
        }
        let hue = CGFloat(time.truncatingRemainder(dividingBy: 30) / 30)
        context.setFillColor(UIColor(hue: hue, saturation: 0.55, brightness: 0.45, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let text = String(format: "%d:%02d.%d", Int(time) / 60, Int(time) % 60, Int(time * 10) % 10)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 72, weight: .bold),
            .foregroundColor: UIColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: (CGFloat(width) - size.width) / 2,
                                            y: (CGFloat(height) - size.height) / 2),
                                withAttributes: attributes)
    }
}
