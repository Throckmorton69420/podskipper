import AVFoundation
import UIKit

/// A test picture for the demo's video episode: the playhead's time drawn
/// large on every frame, five frames a second. Screenshot runs only.
enum DemoVideo {

    static func makeIfNeeded(named name: String, seconds: Double) {
        let url = FileStore.episodesDirectory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            FileIndex.insert(name)
            return
        }
        Task.detached(priority: .utility) {
            do {
                try await write(to: url, seconds: seconds)
                FileIndex.insert(name)
            } catch {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func write(to url: URL, seconds: Double) async throws {
        let width = 480, height = 270, fps: Int32 = 5
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * Double(fps))
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { break }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            draw(into: buffer, width: width, height: height, time: Double(frame) / Double(fps))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func draw(into buffer: CVPixelBuffer, width: Int, height: Int, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        let hue = CGFloat(time.truncatingRemainder(dividingBy: 30) / 30)
        context.setFillColor(UIColor(hue: hue, saturation: 0.55, brightness: 0.45, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPushContext(context)
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
        UIGraphicsPopContext()
    }
}
