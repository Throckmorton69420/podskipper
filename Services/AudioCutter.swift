import Foundation
import AVFoundation

/// Physically removes ad ranges from an audio file, producing a shorter file.
///
/// The player skips ads at playback time; this is different — it produces a
/// cut copy that can be uploaded and handed to Apple Podcasts, which has no
/// idea what a skip range is and needs the audio to already be clean.
///
/// No ffmpeg involved. AVFoundation can stitch time ranges natively, which is
/// the whole reason this is feasible on a phone.
enum AudioCutter {

    enum CutError: LocalizedError {
        case noAudioTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:          return "That file has no audio track."
            case .exportFailed(let m):   return "Export failed: \(m)"
            }
        }
    }

    struct Result {
        let url: URL
        let duration: Double
        let byteCount: Int
        let secondsRemoved: Double
    }

    /// - Parameters:
    ///   - source: the downloaded episode
    ///   - adRanges: ranges to remove, in seconds
    ///   - destination: where to write the .m4a
    static func cut(source: URL,
                    removing adRanges: [ClosedRange<Double>],
                    to destination: URL) async throws -> Result {

        let asset = AVURLAsset(url: source)
        let fullDuration = try await asset.load(.duration).seconds

        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw CutError.noAudioTrack
        }

        let keepRanges = complement(of: adRanges, within: fullDuration)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CutError.noAudioTrack
        }

        var cursor = CMTime.zero
        for keep in keepRanges {
            let start = CMTime(seconds: keep.lowerBound, preferredTimescale: 600)
            let length = CMTime(seconds: keep.upperBound - keep.lowerBound, preferredTimescale: 600)
            let range = CMTimeRange(start: start, duration: length)
            try track.insertTimeRange(range, of: sourceTrack, at: cursor)
            cursor = cursor + length
        }

        try? FileManager.default.removeItem(at: destination)

        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetAppleM4A) else {
            throw CutError.exportFailed("couldn't create an export session")
        }

        do {
            try await export.export(to: destination, as: .m4a)
        } catch {
            throw CutError.exportFailed(error.localizedDescription)
        }

        var size = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
           let number = attrs[.size] as? NSNumber {
            size = number.intValue
        }
        let removed = adRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }

        return Result(url: destination,
                      duration: cursor.seconds,
                      byteCount: size,
                      secondsRemoved: removed)
    }

    /// Everything that isn't an ad. Assumes ranges are already merged and sorted.
    static func complement(of ads: [ClosedRange<Double>],
                           within duration: Double) -> [ClosedRange<Double>] {
        guard duration > 0 else { return [] }
        guard !ads.isEmpty else { return [0...duration] }

        var keep: [ClosedRange<Double>] = []
        var cursor = 0.0
        for ad in ads.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let start = max(0, ad.lowerBound)
            if start - cursor > 0.5 { keep.append(cursor...start) }
            cursor = max(cursor, min(duration, ad.upperBound))
        }
        if duration - cursor > 0.5 { keep.append(cursor...duration) }
        return keep
    }
}
