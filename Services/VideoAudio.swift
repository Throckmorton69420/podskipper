import Foundation
import SwiftData

/// Video is streamed, never kept (his rule, 30 Sep). A video episode is
/// downloaded only long enough to pull its audio out; the video file is
/// removed in the same step, whether the extraction worked or not. A failed
/// unlink is reported and retried by housekeeping; its index is not falsified.
enum VideoAudio {

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm"]

    static func isVideoFile(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    // Downloads may not have a database filename until they return. Keep
    // ownership across their awaits, and keep both extraction files protected
    // until the exporter and its cleanup have actually unwound.
    @MainActor private static var work: [UUID: (guid: String?, names: Set<String>)] = [:]

    @MainActor static func protect(guid: String? = nil, names: Set<String> = []) -> UUID {
        let token = UUID()
        work[token] = (guid, names)
        return token
    }

    @MainActor static func release(_ token: UUID) { work[token] = nil }
    @MainActor static var protectedGUIDs: Set<String> { Set(work.values.compactMap(\.guid)) }
    @MainActor static var protectedFilenames: Set<String> { work.values.reduce(into: []) { $0.formUnion($1.names) } }

    enum SourceError: LocalizedError {
        case invalidFile
        var errorDescription: String? { "The temporary video is not a regular episode file." }
    }

    /// Extract audio, then attempt to remove only this owned source. Invalid
    /// paths and links are never followed or deleted. Dependencies allow
    /// failure/cancellation checks on disposable files without real inference.
    @MainActor
    static func keepOnlyAudio(of filename: String, in directory: URL = FileStore.episodesDirectory,
        extract: (URL, String) async throws -> String = { try await MediaExtractor.extractAudio(from: $0, named: $1) },
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        retire: (String) -> Void = { FileIndex.remove($0) }) async throws -> String {
        guard isVideoFile(filename), let video = FileStore.directChild(named: filename, in: directory),
              (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]) as? FileAttributeType == .typeDirectory,
              (try? FileManager.default.attributesOfItem(atPath: video.path)[.type]) as? FileAttributeType == .typeRegular else {
            throw SourceError.invalidFile
        }
        let audioName = MediaExtractor.audioFilename(for: filename)
        let token = protect(names: [filename, audioName])
        defer {
            let removed = FileStore.deleteNamedFiles([filename], in: directory, removeItem: removeItem, retire: retire)
            if !removed.succeeded {
                BackgroundLog.shared.note("Temporary video cleanup failed; its file is preserved for retry.")
            }
            release(token)
        }
        try Task.checkCancellation()
        let saved = try await extract(video, audioName)
        try Task.checkCancellation()
        return saved
    }

    /// Deletes video files an earlier version saved, keeping their extracted
    /// audio, and writes the space freed in the background log. Cheap when
    /// there is nothing to do, so it runs at every launch.
    struct CleanupResult {
        var deletion = FileStore.DeletionResult()
        var kept = Set<String>()
        var scanFailed = false
        var saveFailed = false
    }

    @MainActor @discardableResult
    static func removeSavedVideos(context: ModelContext, in directory: URL = FileStore.episodesDirectory,
        protectedGUIDs: (() -> Set<String>)? = nil,
        listFiles: (URL) async throws -> Set<String> = { directory in
            try await Task.detached(priority: .utility) {
                Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            }.value
        }, removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        retire: (String) -> Void = { FileIndex.remove($0) }) async -> CleanupResult {
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.localFilename != nil || $0.extractedAudioFilename != nil
        })
        var result = CleanupResult()
        var episodes: [Episode]
        let files: Set<String>
        do {
            files = try await listFiles(directory)
            episodes = try context.fetch(descriptor)
        } catch {
            result.scanFailed = true
            BackgroundLog.shared.note("Saved video cleanup could not read the episode files; nothing was removed.")
            return result
        }
        let referenced = Set(episodes.compactMap(\.localFilename))
        let candidates = files.union(referenced).filter { isVideoFile($0) }.sorted()
        for (index, name) in candidates.enumerated() {
            if Task.isCancelled { break }
            if index > 0 && index % 16 == 0 {
                await Task.yield()
                if Task.isCancelled { break }
                do { episodes = try context.fetch(descriptor) }
                catch { result.scanFailed = true; break }
            }
            // No suspension between this fresh ownership check and unlink.
            let owners = (protectedGUIDs?() ?? ProcessingPipeline.shared.protectedCleanupGUIDs).union(Self.protectedGUIDs)
            let liveReferences = Set(episodes.flatMap { [$0.localFilename, $0.extractedAudioFilename].compactMap { $0 } })
            let protectedNames = Set(episodes.filter { owners.contains($0.guid) }
                .flatMap { [$0.localFilename, $0.extractedAudioFilename].compactMap { $0 } })
                .union(Self.protectedFilenames)
            // An active download can have bytes before it gains a database
            // reference. Leave unknown files alone until all writers unwind.
            if protectedNames.contains(name) || (!liveReferences.contains(name) && !owners.isEmpty) {
                result.kept.insert(name); continue
            }
            let one = FileStore.deleteNamedFiles([name], in: directory, removeItem: removeItem, retire: retire)
            result.deletion.removed.formUnion(one.removed)
            result.deletion.absent.formUnion(one.absent)
            result.deletion.failed.formUnion(one.failed)
            result.deletion.bytes += one.bytes
            guard one.retired.contains(name) else { continue }
            for episode in episodes where episode.localFilename == name {
                if let audio = episode.extractedAudioFilename,
                   let file = FileStore.directChild(named: audio, in: directory),
                   (try? FileManager.default.attributesOfItem(atPath: file.path)[.type]) as? FileAttributeType == .typeRegular {
                    episode.localFilename = audio
                } else {
                    episode.localFilename = nil
                    episode.extractedAudioFilename = nil
                }
            }
        }
        if !result.deletion.retired.isEmpty {
            do { try context.save() } catch { result.saveFailed = true }
            LibraryTotals.shared.invalidate()
        }
        if !result.deletion.removed.isEmpty {
            let count = result.deletion.removed.count
            let freed = ByteCountFormatter.string(fromByteCount: result.deletion.bytes, countStyle: .file)
            BackgroundLog.shared.note("Removed \(count) saved video file\(count == 1 ? "" : "s"), freed \(freed). Extracted audio files were preserved.")
        }
        if !result.deletion.failed.isEmpty || result.scanFailed || result.saveFailed {
            BackgroundLog.shared.note("Saved video cleanup was incomplete; failed files and remaining work were preserved for retry.")
        }
        return result
    }
}
