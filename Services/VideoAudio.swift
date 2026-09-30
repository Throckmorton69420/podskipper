import Foundation
import SwiftData

/// Video is streamed, never kept (his rule, 30 Sep). A video episode is
/// downloaded only long enough to pull its audio out; the video file is
/// deleted in the same step, whether the extraction worked or not.
enum VideoAudio {

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm"]

    static func isVideoFile(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Extracts the audio of `filename` (a video in the episodes folder) and
    /// deletes the video. Returns the audio file's name. The video is gone
    /// afterwards on every path, including a thrown error or a cancel.
    static func keepOnlyAudio(of filename: String) async throws -> String {
        let video = FileStore.episodesDirectory.appendingPathComponent(filename)
        defer {
            try? FileManager.default.removeItem(at: video)
            FileIndex.remove(filename)
        }
        let audioName = MediaExtractor.audioFilename(for: filename)
        let saved = try await MediaExtractor.extractAudio(from: video, named: audioName)
        try Task.checkCancellation()
        return saved
    }

    /// Deletes video files an earlier version saved, keeping their extracted
    /// audio, and writes the space freed in the background log. Cheap when
    /// there is nothing to do, so it runs at every launch.
    @MainActor
    static func removeSavedVideos(context: ModelContext) async {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.localFilename != nil })
        let episodes = (try? context.fetch(descriptor)) ?? []
        let playing = PlayerEngine.shared.currentEpisode?.localFilename
        let referenced = episodes.compactMap(\.localFilename)
        let stale = referenced.filter { isVideoFile($0) && $0 != playing }
        let directory = FileStore.episodesDirectory
        // Also video files no episode points at (left by a failed job).
        let known = Set(referenced)
        let removed: (names: Set<String>, bytes: Int64) = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var names = Set<String>(), bytes: Int64 = 0
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            let doomed = Set(stale).union(files.map(\.lastPathComponent).filter {
                isVideoFile($0) && !known.contains($0)
            })
            for name in doomed {
                let url = directory.appendingPathComponent(name)
                let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if (try? fm.removeItem(at: url)) != nil { names.insert(name); bytes += size }
            }
            return (names, bytes)
        }.value
        guard !removed.names.isEmpty else { return }
        for name in removed.names { FileIndex.remove(name) }
        for episode in episodes {
            guard let name = episode.localFilename, removed.names.contains(name) else { continue }
            if let audio = episode.extractedAudioFilename, FileIndex.contains(audio) {
                episode.localFilename = audio
            } else {
                episode.localFilename = nil
                episode.extractedAudioFilename = nil
            }
        }
        try? context.save()
        LibraryTotals.shared.invalidate()
        let freed = ByteCountFormatter.string(fromByteCount: removed.bytes, countStyle: .file)
        BackgroundLog.shared.note("Removed \(removed.names.count) saved video file\(removed.names.count == 1 ? "" : "s"), freed \(freed). Video is streamed now; the audio was kept.")
    }
}
