import Foundation
import AVFoundation
import SwiftData

// MARK: - Chapters

/// Chapters come from two places: some feeds carry a JSON chapters file,
/// and most well-produced shows embed them in the audio itself. We read the
/// file, because by the time we care the episode is already downloaded.
enum ChapterService {

    @MainActor
    static func extract(for episode: Episode, context: ModelContext) async {
        guard episode.chapters.isEmpty,
              let url = episode.localFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }

        let asset = AVURLAsset(url: url)
        var found: [(Double, String)] = []

        // Preferred: real chapter metadata groups.
        if let locales = try? await asset.load(.availableChapterLocales), !locales.isEmpty {
            for locale in locales {
                let groups = (try? await asset.loadChapterMetadataGroups(
                    withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle])) ?? []
                for group in groups {
                    let start = group.timeRange.start.seconds
                    guard start.isFinite else { continue }
                    var title = "Chapter \(found.count + 1)"
                    if let item = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                       let loaded = try? await item.load(.stringValue),
                       !loaded.isEmpty {
                        title = loaded
                    }
                    found.append((start, title))
                }
                if !found.isEmpty { break }
            }
        }

        guard !found.isEmpty else { return }

        for (start, title) in found.sorted(by: { $0.0 < $1.0 }) {
            let chapter = Chapter(start: start, title: title)
            chapter.episode = episode
            context.insert(chapter)
        }
        try? context.save()
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
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        let downloaded = episodes.filter(\.isDownloaded)

        if settings.deletePlayedAfterDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(settings.deletePlayedAfterDays) * 86_400)
            for episode in downloaded where episode.isPlayed && !episode.isInQueue {
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
            .filter { $0.isDownloaded && !$0.isInQueue }
            .sorted { ($0.lastPlayedAt ?? $0.publishedAt) < ($1.lastPlayedAt ?? $1.publishedAt) }

        for episode in candidates {
            guard used > limit else { break }
            let size = fileSize(of: episode)
            reclaimed += remove(episode)
            used -= size
        }

        try? context.save()
        return reclaimed
    }

    private static func fileSize(of episode: Episode) -> Int64 {
        guard let url = episode.localFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attrs[.size] as? NSNumber else { return 0 }
        return number.int64Value
    }

    @discardableResult
    private static func remove(_ episode: Episode) -> Int {
        guard let filename = episode.localFilename else { return 0 }
        FileStore.deleteAudio(named: filename)
        episode.localFilename = nil
        return 1
    }

    /// Delete an episode's audio the moment it finishes, if the show — or the
    /// global default — asks for that.
    ///
    /// Apple Podcasts calls this "Remove Played Downloads". The transcript and
    /// the detected ad ranges stay, so an episode re-downloaded later doesn't
    /// need re-analysing.
    @MainActor
    static func removePlayedIfWanted(_ episode: Episode, settings: AppSettings) {
        // Flattened by hand: a show's value is itself optional, where nil
        // means "use the default", so a single ?? would infer the wrong type.
        let showPreference: Bool? = episode.podcast.flatMap { $0.removePlayedDownloads }
        let wanted = showPreference ?? settings.removePlayedDownloads
        guard wanted, episode.isPlayed, !episode.isInQueue else { return }
        remove(episode)
    }
}
