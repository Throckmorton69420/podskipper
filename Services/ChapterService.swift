import Foundation
import AVFoundation
import SwiftData
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

// MARK: - Chapters

/// Chapters come from two places: some feeds carry a JSON chapters file,
/// and most well-produced shows embed them in the audio itself. We read the
/// file, because by the time we care the episode is already downloaded.
enum ChapterService {

    struct Entry: Sendable, Equatable {
        var start: Double
        var title: String
        var imageURL: String?
        var linkURL: String?
    }

    struct Draft {
        var title: String
        var time: String
        var imageURL: String = ""
        var linkURL: String = ""
    }

    enum EditingError: LocalizedError {
        case emptyTitle, invalidTime, beyondEnd, duplicateTime, invalidURL(String), unavailable
        var errorDescription: String? {
            switch self {
            case .emptyTitle: "Enter a chapter title of 300 characters or fewer."
            case .invalidTime: "Enter a nonnegative time in seconds, minutes:seconds, or hours:minutes:seconds."
            case .beyondEnd: "The chapter must start before the episode ends."
            case .duplicateTime: "Another chapter already starts at that time."
            case .invalidURL(let field): "Enter a complete http or https address for \(field), or leave it empty."
            case .unavailable: "The publisher has not provided chapters for this episode. You can add your own."
            }
        }
    }

    /// Kept with the backed-up preferences so deleting the last local chapter
    /// cannot cause a later download or feed load to put it back.
    static let editsKey = "chapter.localEditEpisodes.v1"
    static let artworkPrefix = "chapter-artwork:"
    static let artworkDirectory = URL.applicationSupportDirectory.appendingPathComponent("ChapterArtwork", isDirectory: true)

    /// Embedded artwork is reduced before it reaches disk. The stored copy is
    /// included with Application Support in backups and survives reinstall restore.
    static func boundedArtwork(_ bytes: Data) -> Data? {
        guard !bytes.isEmpty, bytes.count <= 20 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), output.length <= 512 * 1_024 else { return nil }
        return output as Data
    }

    static func storeEmbeddedArtwork(_ bytes: Data, directory: URL = artworkDirectory) throws -> String? {
        guard let small = boundedArtwork(bytes) else { return nil }
        let name = SHA256.hash(data: small).map { String(format: "%02x", $0) }.joined() + ".jpg"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try small.write(to: url, options: .atomic) }
        return artworkPrefix + name
    }

    static func embeddedArtworkURL(_ reference: String, directory: URL = artworkDirectory) -> URL? {
        guard reference.hasPrefix(artworkPrefix) else { return nil }
        let name = String(reference.dropFirst(artworkPrefix.count))
        guard name.hasSuffix(".jpg"), name.count == 68,
              name.dropLast(4).allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return directory.appendingPathComponent(name)
    }

    static func hasLocalEdits(_ guid: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.stringArray(forKey: editsKey)?.contains(guid) ?? false
    }

    private static func markEdited(_ guid: String, defaults: UserDefaults) {
        var edited = Set(defaults.stringArray(forKey: editsKey) ?? [])
        edited.insert(guid)
        defaults.set(edited.sorted(), forKey: editsKey)
    }

    static func seconds(_ text: String) throws -> Double {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { throw EditingError.invalidTime }
        let values = fields.compactMap { Double($0) }
        guard values.count == fields.count,
              values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              values.dropFirst().allSatisfy({ $0 < 60 }),
              values.dropLast().allSatisfy({ $0.rounded(.down) == $0 }) else {
            throw EditingError.invalidTime
        }
        let result = values.reduce(0) { $0 * 60 + $1 }
        guard result.isFinite else { throw EditingError.invalidTime }
        return result
    }

    static func timeText(_ seconds: Double) -> String {
        let rounded = max(0, seconds)
        let hours = Int(rounded / 3600)
        let minutes = Int(rounded / 60) % 60
        let remainder = rounded.truncatingRemainder(dividingBy: 60)
        let tail = remainder.rounded() == remainder
            ? String(format: "%02.0f", remainder) : String(format: "%06.3f", remainder)
        return hours > 0 ? String(format: "%d:%02d:", hours, minutes) + tail
            : "\(Int(rounded / 60)):" + tail
    }

    static func webURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
    }

    @MainActor
    static func validate(_ draft: Draft, for episode: Episode, editing chapter: Chapter? = nil) throws -> Entry {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 300 else { throw EditingError.emptyTitle }
        let start = try seconds(draft.time)
        let duration = episode.duration > 0 ? episode.duration : episode.publishedDuration
        if duration > 0, start >= duration { throw EditingError.beyondEnd }
        if episode.chapters.contains(where: { $0 !== chapter && abs($0.start - start) < 0.001 }) {
            throw EditingError.duplicateTime
        }
        func address(_ text: String, _ field: String) throws -> String? {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            guard let result = webURL(text) else { throw EditingError.invalidURL(field) }
            return result
        }
        let keptEmbedded = chapter?.imageURL == draft.imageURL && embeddedArtworkURL(draft.imageURL) != nil
        return Entry(start: start, title: title,
            imageURL: keptEmbedded ? draft.imageURL : try address(draft.imageURL, "artwork"),
            linkURL: try address(draft.linkURL, "the link"))
    }

    @MainActor
    @discardableResult
    static func save(_ draft: Draft, for episode: Episode, editing chapter: Chapter? = nil,
                     context: ModelContext, defaults: UserDefaults = .standard) throws -> Chapter {
        let entry = try validate(draft, for: episode, editing: chapter)
        let original = chapter.map { Entry(start: $0.start, title: $0.title, imageURL: $0.imageURL, linkURL: $0.linkURL) }
        let result = chapter ?? Chapter(start: entry.start, title: entry.title)
        let previousEdits = defaults.stringArray(forKey: editsKey)
        // Mark first: a crash during a save must not reimport over local intent.
        markEdited(episode.guid, defaults: defaults)
        result.start = entry.start
        result.title = entry.title
        result.imageURL = entry.imageURL
        result.linkURL = entry.linkURL
        if chapter == nil {
            context.insert(result)
            result.episode = episode
            if !episode.chapters.contains(where: { $0 === result }) { episode.chapters.append(result) }
        }
        do { try context.save() }
        catch {
            if let original {
                result.start = original.start; result.title = original.title
                result.imageURL = original.imageURL; result.linkURL = original.linkURL
            } else {
                episode.chapters.removeAll { $0 === result }
                context.delete(result)
            }
            defaults.set(previousEdits, forKey: editsKey)
            throw error
        }
        return result
    }

    @MainActor
    static func delete(_ chapter: Chapter, from episode: Episode, context: ModelContext,
                       defaults: UserDefaults = .standard) throws {
        guard episode.chapters.contains(where: { $0 === chapter }) else { return }
        let previousEdits = defaults.stringArray(forKey: editsKey)
        markEdited(episode.guid, defaults: defaults)
        // Save the relationship removal before deleting the orphan: if saving
        // fails the visible chapter can be restored without rolling back other edits.
        episode.chapters.removeAll { $0 === chapter }
        chapter.episode = nil
        do { try context.save() }
        catch {
            chapter.episode = episode
            if !episode.chapters.contains(where: { $0 === chapter }) { episode.chapters.append(chapter) }
            defaults.set(previousEdits, forKey: editsKey)
            throw error
        }
        context.delete(chapter)
        try context.save()
    }

    /// Import is deliberately additive. Existing or locally edited chapters
    /// stay intact, including an intentionally empty chapter list.
    @MainActor
    @discardableResult
    static func importEntries(_ entries: [Entry], for episode: Episode, context: ModelContext,
                              defaults: UserDefaults = .standard) throws -> Int {
        guard episode.chapters.isEmpty, !hasLocalEdits(episode.guid, defaults: defaults) else { return 0 }
        let duration = episode.duration > 0 ? episode.duration : episode.publishedDuration
        var starts: Set<Double> = []
        var inserted: [Chapter] = []
        let valid = entries.filter { $0.start.isFinite && $0.start >= 0 && (duration <= 0 || $0.start < duration) }
        for entry in valid.sorted(by: { $0.start < $1.start }) {
            guard starts.insert(entry.start).inserted else { continue }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let chapter = Chapter(start: entry.start, title: title.isEmpty ? "Chapter \(inserted.count + 1)" : String(title.prefix(300)),
                imageURL: entry.imageURL.flatMap { embeddedArtworkURL($0) == nil ? webURL($0) : $0 },
                linkURL: entry.linkURL.flatMap(webURL))
            context.insert(chapter)
            chapter.episode = episode
            if !episode.chapters.contains(where: { $0 === chapter }) { episode.chapters.append(chapter) }
            inserted.append(chapter)
        }
        do { try context.save() }
        catch {
            episode.chapters.removeAll { candidate in inserted.contains(where: { $0 === candidate }) }
            for chapter in inserted { context.delete(chapter) }
            throw error
        }
        return inserted.count
    }

    static func parseJSON(_ data: Data) throws -> [Entry] {
        struct Document: Decodable { let version: String; let chapters: [Item] }
        struct Item: Decodable {
            let startTime: Double
            let title: String?
            let img: String?
            let url: String?
            let toc: Bool?
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version.hasPrefix("1.") else { throw EditingError.unavailable }
        return document.chapters.filter { $0.toc != false }.map {
            Entry(start: $0.startTime, title: $0.title ?? "", imageURL: $0.img.flatMap(webURL), linkURL: $0.url.flatMap(webURL))
        }
    }

    /// Explicit publisher refresh, used by the chapter editor. It never
    /// downloads episode audio or replaces an existing/local chapter list.
    @MainActor
    static func loadPublished(for episode: Episode, context: ModelContext) async throws {
        guard episode.chapters.isEmpty, !hasLocalEdits(episode.guid) else { return }
        if episode.isDownloaded {
            let embedded = try await embeddedEntries(for: episode)
            try Task.checkCancellation()
            if try importEntries(embedded, for: episode, context: context) > 0 { return }
        }
        guard let feed = episode.podcast?.feedURL else { throw EditingError.unavailable }
        let parsed = try await FeedParser.fetch(feed)
        try Task.checkCancellation()
        guard let item = parsed.items.first(where: { $0.guid == episode.guid }) else { throw EditingError.unavailable }
        var entries = item.chapters
        if entries.isEmpty, let address = item.chaptersURL.flatMap(webURL), let url = URL(string: address) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw FeedError.network("The chapter file could not be downloaded.")
            }
            entries = try parseJSON(data)
        }
        try Task.checkCancellation()
        guard try importEntries(entries, for: episode, context: context) > 0 else { throw EditingError.unavailable }
    }

    @MainActor
    static func extract(for episode: Episode, context: ModelContext) async {
        guard episode.chapters.isEmpty, !hasLocalEdits(episode.guid) else { return }
        guard let entries = try? await embeddedEntries(for: episode), !Task.isCancelled else { return }
        try? importEntries(entries, for: episode, context: context)
    }

    @MainActor
    private static func embeddedEntries(for episode: Episode) async throws -> [Entry] {
        guard let url = episode.analysableFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return [] }

        let asset = AVURLAsset(url: url)
        var found: [Entry] = []

        // Preferred: real chapter metadata groups.
        let locales = try await asset.load(.availableChapterLocales)
        if !locales.isEmpty {
            for locale in locales {
                let groups = (try? await asset.loadChapterMetadataGroups(
                    withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyArtwork])) ?? []
                for group in groups {
                    let start = group.timeRange.start.seconds
                    guard start.isFinite else { continue }
                    var title = "Chapter \(found.count + 1)"
                    if let item = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                       let loaded = try? await item.load(.stringValue),
                       !loaded.isEmpty {
                        title = loaded
                    }
                    var imageURL: String?
                    for item in group.items where item.commonKey == .commonKeyArtwork {
                        if let value = try? await item.load(.stringValue) { imageURL = webURL(value) }
                        if imageURL == nil, let bytes = try? await item.load(.dataValue) {
                            imageURL = try? await Task.detached(priority: .utility) {
                                try storeEmbeddedArtwork(bytes)
                            }.value
                        }
                    }
                    found.append(Entry(start: start, title: title, imageURL: imageURL))
                }
                if !found.isEmpty { break }
            }
        }

        return found
    }

    /// Which chapter covers a given moment.
    static func chapter(at seconds: Double, in chapters: [Chapter]) -> Chapter? {
        chapters.sorted { $0.start < $1.start }.last { $0.start <= seconds }
    }
}

// MARK: - Statistics

/// Rolls listening sessions up into the numbers on the stats screen.
enum StatsService {

    /// Swift has no key paths into tuples, so these are real types rather
    /// than the labelled tuples they'd otherwise be.
    struct DayTotal: Identifiable, Hashable {
        let day: Date
        let seconds: Double
        var id: Date { day }
    }

    struct ShowTotal: Identifiable, Hashable {
        let show: String
        let seconds: Double
        var id: String { show }
    }

    struct Summary {
        var totalListened: Double = 0
        var adsSkipped: Double = 0
        var silenceSkipped: Double = 0
        var episodesFinished: Int = 0
        var currentStreak: Int = 0
        var longestStreak: Int = 0
        var byDay: [DayTotal] = []
        var topShows: [ShowTotal] = []

        /// Time you didn't spend listening to advertising, expressed the way
        /// people actually think about it.
        var timeSavedText: String {
            let total = adsSkipped + silenceSkipped
            if total < 3600 { return "\(Int(total / 60)) minutes" }
            let hours = total / 3600
            return hours < 24 ? String(format: "%.1f hours", hours)
                              : String(format: "%.1f days", hours / 24)
        }
    }

    static func summarize(sessions: [ListeningSession], episodes: [Episode]) -> Summary {
        var summary = Summary()
        summary.totalListened = sessions.reduce(0) { $0 + $1.seconds }
        summary.adsSkipped = sessions.reduce(0) { $0 + $1.adSecondsSkipped }
        summary.silenceSkipped = sessions.reduce(0) { $0 + $1.silenceSecondsSkipped }
        summary.episodesFinished = episodes.filter(\.isPlayed).count

        // Per-day totals, most recent 30 days.
        let grouped = Dictionary(grouping: sessions) { $0.day }
        let days = grouped.keys.sorted(by: >).prefix(30)
        summary.byDay = days.reversed().map { day in
            DayTotal(day: day, seconds: grouped[day]?.reduce(0) { $0 + $1.seconds } ?? 0)
        }

        // Streaks. A day counts if anything at all was listened to.
        let listenedDays = Set(grouped.keys)
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: .now)
        // Today not counting yet shouldn't break a streak, so start at
        // yesterday if today is empty.
        if !listenedDays.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var streak = 0
        while listenedDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        summary.currentStreak = streak

        var longest = 0, running = 0
        var previousDay: Date?
        for day in listenedDays.sorted() {
            if let previous = previousDay,
               let expected = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(day, inSameDayAs: expected) {
                running += 1
            } else {
                running = 1
            }
            longest = max(longest, running)
            previousDay = day
        }
        summary.longestStreak = longest

        // Top shows by listening time.
        let byShow = Dictionary(grouping: sessions.filter { !$0.showTitle.isEmpty }) { $0.showTitle }
        summary.topShows = byShow
            .map { ShowTotal(show: $0.key, seconds: $0.value.reduce(0) { $0 + $1.seconds }) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(8)
            .map { $0 }

        return summary
    }
}

// MARK: - Download housekeeping

/// Keeps downloaded audio from growing without limit.
enum DownloadManager {

    /// Deletes played episodes older than the cutoff, then oldest-first until
    /// the folder is under the ceiling. Never touches anything unplayed or
    /// still in the queue — running out of space shouldn't cost you the
    /// episode you were about to hear.
    @MainActor
    @discardableResult
    static func tidy(context: ModelContext, settings: AppSettings) -> Int {
        var reclaimed = 0
        // Only episodes with a file: this runs at every launch, and the
        // whole library (every back catalogue) was being read to find them
        // (task 09: slow start).
        let withFile = FetchDescriptor<Episode>(predicate: #Predicate { $0.localFilename != nil || $0.extractedAudioFilename != nil })
        let episodes = (try? context.fetch(withFile)) ?? []
        let downloaded = episodes.filter(\.isDownloaded)

        if settings.deletePlayedAfterDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(settings.deletePlayedAfterDays) * 86_400)
            for episode in downloaded where canAutomaticallyRemove(episode, currentGUID: PlayerEngine.shared.currentEpisode?.guid) {
                if (episode.lastPlayedAt ?? episode.publishedAt) < cutoff {
                    reclaimed += remove(episode)
                }
            }
        }

        guard settings.storageLimitGB > 0 else {
            try? context.save()
            return reclaimed
        }

        let limit = Int64(settings.storageLimitGB * 1_073_741_824)
        var used = ProcessingPipeline.downloadedBytes()
        guard used > limit else {
            try? context.save()
            return reclaimed
        }

        let candidates = episodes
            .filter { $0.isDownloaded && canAutomaticallyRemove($0, currentGUID: PlayerEngine.shared.currentEpisode?.guid) }
            .sorted { ($0.lastPlayedAt ?? $0.publishedAt) < ($1.lastPlayedAt ?? $1.publishedAt) }

        for episode in candidates {
            guard used > limit else { break }
            let result = removeFiles(episode)
            if episode.localFilename == nil && episode.extractedAudioFilename == nil { reclaimed += 1 }
            used -= result.bytes
        }

        try? context.save()
        return reclaimed
    }

    static func canAutomaticallyRemove(_ episode: Episode, currentGUID: String?) -> Bool {
        episode.isPlayed && !episode.isInQueue && episode.guid != currentGUID
    }

    /// Delete one episode's audio. Transcript and detected ads are kept.
    /// Internal rather than private so batch actions on a show page can use
    /// the same path as automatic clean-up.
    @discardableResult
    @MainActor
    static func remove(_ episode: Episode, deleteFile: ((String) -> Bool)? = nil,
                       protectedGUIDs: Set<String>? = nil) -> Int {
        let hadReference = episode.localFilename != nil || episode.extractedAudioFilename != nil
        _ = removeFiles(episode, deleteFile: deleteFile, protectedGUIDs: protectedGUIDs)
        return hadReference && episode.localFilename == nil && episode.extractedAudioFilename == nil ? 1 : 0
    }

    @MainActor
    static func removeFiles(_ episode: Episode, deleteFile: ((String) -> Bool)? = nil,
                            protectedGUIDs: Set<String>? = nil, directory: URL = FileStore.episodesDirectory,
                            removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                            retire: (String) -> Void = { FileIndex.remove($0) }) -> FileStore.DeletionResult {
        let filenames = Set([episode.localFilename, episode.extractedAudioFilename].compactMap { $0 })
        guard !filenames.isEmpty else { return .init() }
        guard !(protectedGUIDs ?? ProcessingPipeline.shared.protectedCleanupGUIDs).contains(episode.guid) else {
            return .init(failed: filenames)
        }
        var result: FileStore.DeletionResult
        if let deleteFile {
            result = .init()
            for name in filenames {
                if deleteFile(name) { result.removed.insert(name) }
                else { result.failed.insert(name) }
            }
        } else { result = FileStore.deleteAudioFiles(named: filenames, in: directory, removeItem: removeItem, retire: retire) }
        if let name = episode.localFilename, result.canRetireAudioReference(name) { episode.localFilename = nil }
        if let name = episode.extractedAudioFilename, result.canRetireAudioReference(name) { episode.extractedAudioFilename = nil }
        return result
    }

    /// Delete an episode's audio the moment it finishes, if the show — or the
    /// global default — asks for that.
    ///
    /// Apple Podcasts calls this "Remove Played Downloads". The transcript and
    /// the detected ad ranges stay, so an episode re-downloaded later doesn't
    /// need re-analysing.
    @MainActor
    /// Fetch an episode's audio so it can be played right now.
    ///
    /// Pressing play on an episode that has not been downloaded used to fail
    /// with "isn't downloaded yet — tap Find ads", which is a dead end dressed
    /// as advice: it names a different button, and that button starts a
    /// transcription you did not ask for. This is the path that makes play mean
    /// play. It downloads only — no transcription, no detection, nothing that
    /// takes minutes — so an episode starts as soon as its bytes are here.
    ///
    /// Returns whether the file is now on disk.
    static func fetchAudio(for episode: Episode) async -> Bool {
        if episode.isDownloaded, episode.analysableFileURL != nil { return true }
        guard let url = URL(string: episode.audioURL) else { return false }

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return false
            }
            // Keep the original extension; AVAudioFile cares about it.
            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let filename = "\(UUID().uuidString).\(ext)"
            let destination = FileStore.episodesDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)

            // Video is streamed, never kept: only its audio stays.
            if episode.isVideo {
                let audio = try await VideoAudio.keepOnlyAudio(of: filename)
                episode.localFilename = audio
                episode.extractedAudioFilename = audio
                LibraryTotals.shared.invalidate()
                return episode.localFileURL != nil
            }
            episode.localFilename = filename
            FileIndex.insert(filename)
            LibraryTotals.shared.invalidate()
            return episode.localFileURL != nil
        } catch {
            return false
        }
    }

    @MainActor
    static func removePlayedIfWanted(_ episode: Episode, settings: AppSettings) {
        // Flattened by hand: a show's value is itself optional, where nil
        // means "use the default", so a single ?? would infer the wrong type.
        let showPreference: Bool? = episode.podcast.flatMap { $0.removePlayedDownloads }
        let wanted = showPreference ?? settings.removePlayedDownloads
        guard wanted, canAutomaticallyRemove(episode, currentGUID: PlayerEngine.shared.currentEpisode?.guid) else { return }
        remove(episode)
    }
}
