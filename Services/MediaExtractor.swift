import Foundation
import AVFoundation

/// Pulls the audio track out of a video episode.
///
/// Everything that makes this app worth using reads audio: the transcriber
/// opens the file with `AVAudioFile`, which cannot open an mp4 at all, and the
/// silence pass reads PCM buffers. Rather than write a second path for video,
/// the audio track is exported once into its own file beside the episode and
/// the existing pipeline runs on that unchanged.
///
/// The cost is one export — fast, because it copies the existing track rather
/// than re-encoding it — and one extra file, which is deleted with the
/// episode's audio.
enum MediaExtractor {

    enum ExtractionError: LocalizedError {
        case noAudioTrack
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack:
                return "This video has no audio track to analyse."
            case .exportFailed(let reason):
                return "Couldn't read the video's audio: \(reason)"
            }
        }
    }

    /// Writes the audio track of `videoURL` to an m4a beside it and returns
    /// the new file's name.
    ///
    /// Returns the existing file's name unchanged if it has already been
    /// extracted, so reprocessing an episode does not redo the work.
    static func extractAudio(from videoURL: URL,
                             named filename: String) async throws -> String {
        let destination = FileStore.episodesDirectory.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: destination.path) {
            FileIndex.insert(filename)
            return filename
        }

        let asset = AVURLAsset(url: videoURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ExtractionError.noAudioTrack }

        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A)
        else {
            throw ExtractionError.exportFailed("no exporter for this file")
        }

        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            // A half-written file would be picked up as "already extracted"
            // next time and never retried.
            try? FileManager.default.removeItem(at: destination)
            throw ExtractionError.exportFailed(error.localizedDescription)
        }

        FileIndex.insert(filename)
        return filename
    }

    /// The name to give an episode's extracted audio.
    static func audioFilename(for episodeFilename: String) -> String {
        let stem = (episodeFilename as NSString).deletingPathExtension
        return "\(stem)-audio.m4a"
    }
}
