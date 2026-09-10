import Foundation
import SwiftData
import SwiftUI

// MARK: - Bookmarks

/// A moment you want to come back to. Overcast calls these clips; Apple
/// Podcasts has nothing like it. Cheap to store, and the thing people
/// actually miss when switching apps.
@Model
final class Bookmark {
    var timestamp: Double
    var note: String
    var createdAt: Date
    var episodeGUID: String
    var episodeTitle: String
    var showTitle: String

    init(timestamp: Double, note: String = "", episode: Episode) {
        self.timestamp = timestamp
        self.note = note
        self.createdAt = .now
        self.episodeGUID = episode.guid
        self.episodeTitle = episode.title
        self.showTitle = episode.podcast?.title ?? ""
    }
}

// MARK: - Chapters

/// Chapters parsed from the feed or from the file's own metadata.
@Model
final class Chapter {
    var start: Double
    var title: String
    var imageURL: String?
    var linkURL: String?
    var episode: Episode?

    init(start: Double, title: String, imageURL: String? = nil, linkURL: String? = nil) {
        self.start = start
        self.title = title
        self.imageURL = imageURL
        self.linkURL = linkURL
    }
}

// MARK: - Listening history

/// One continuous stretch of listening. Rolled up into the stats screen and
/// the streak counter.
@Model
final class ListeningSession {
    var startedAt: Date
    var seconds: Double
    var adSecondsSkipped: Double
    var silenceSecondsSkipped: Double
    var showTitle: String
    var episodeTitle: String

    init(startedAt: Date = .now, seconds: Double = 0, adSecondsSkipped: Double = 0,
         silenceSecondsSkipped: Double = 0, showTitle: String = "", episodeTitle: String = "") {
        self.startedAt = startedAt
        self.seconds = seconds
        self.adSecondsSkipped = adSecondsSkipped
        self.silenceSecondsSkipped = silenceSecondsSkipped
        self.showTitle = showTitle
        self.episodeTitle = episodeTitle
    }

    var day: Date { Calendar.current.startOfDay(for: startedAt) }
}

// MARK: - Smart filters

/// A saved rule-based playlist, in the shape Pocket Casts made standard.
///
/// Rules are stored as plain flags rather than a general expression tree.
/// A tree would be more powerful and nobody would ever build one on a phone.
@Model
final class SmartFilter {
    var name: String
    var iconName: String
    var colorHex: String
    var order: Int

    // Rules. nil or false means "don't care".
    var onlyUnplayed: Bool = true
    var onlyDownloaded: Bool = false
    var onlyAdFree: Bool = false
    var onlyStarred: Bool = false
    /// 0 = any, otherwise only episodes newer than this many days.
    var withinDays: Int = 0
    /// 0 = any. Otherwise a ceiling in minutes.
    var maxMinutes: Int = 0
    var minMinutes: Int = 0
    /// Empty means every show. Otherwise feed URLs.
    var showFeedURLs: [String] = []
    var sortRaw: String = FilterSort.newest.rawValue

    init(name: String, iconName: String = "line.3.horizontal.decrease.circle",
         colorHex: String = "FF3080", order: Int = 0) {
        self.name = name
        self.iconName = iconName
        self.colorHex = colorHex
        self.order = order
    }

    var sort: FilterSort {
        get { FilterSort(rawValue: sortRaw) ?? .newest }
        set { sortRaw = newValue.rawValue }
    }

    var tint: Color { Color(hex: colorHex) }

    /// Human-readable summary for the row subtitle.
    var summary: String {
        var parts: [String] = []
        if onlyUnplayed { parts.append("unplayed") }
        if onlyDownloaded { parts.append("downloaded") }
        if onlyAdFree { parts.append("ad-free") }
        if onlyStarred { parts.append("starred") }
        if withinDays > 0 { parts.append("last \(withinDays)d") }
        if maxMinutes > 0 { parts.append("under \(maxMinutes)m") }
        if minMinutes > 0 { parts.append("over \(minMinutes)m") }
        if !showFeedURLs.isEmpty { parts.append("\(showFeedURLs.count) shows") }
        return parts.isEmpty ? "Everything" : parts.joined(separator: " · ")
    }

    func matches(_ episode: Episode) -> Bool {
        if episode.isArchived { return false }
        if onlyUnplayed && episode.isPlayed { return false }
        if onlyDownloaded && !episode.isDownloaded { return false }
        if onlyAdFree && episode.processingState != .ready { return false }
        if onlyStarred && !episode.isStarred { return false }
        if withinDays > 0 {
            let cutoff = Date().addingTimeInterval(-Double(withinDays) * 86_400)
            if episode.publishedAt < cutoff { return false }
        }
        let minutes = episode.duration / 60
        if maxMinutes > 0 && minutes > Double(maxMinutes) { return false }
        if minMinutes > 0 && minutes < Double(minMinutes) { return false }
        if !showFeedURLs.isEmpty {
            guard let feed = episode.podcast?.feedURL, showFeedURLs.contains(feed) else { return false }
        }
        return true
    }

    func apply(to episodes: [Episode]) -> [Episode] {
        let matched = episodes.filter { matches($0) }
        switch sort {
        case .newest:   return matched.sorted { $0.publishedAt > $1.publishedAt }
        case .oldest:   return matched.sorted { $0.publishedAt < $1.publishedAt }
        case .shortest: return matched.sorted { $0.remainingSeconds < $1.remainingSeconds }
        case .longest:  return matched.sorted { $0.remainingSeconds > $1.remainingSeconds }
        case .show:     return matched.sorted {
            ($0.podcast?.title ?? "", $1.publishedAt) < ($1.podcast?.title ?? "", $0.publishedAt)
        }
        }
    }

    /// The set every new install starts with, so the feature isn't an empty screen.
    static func defaults() -> [SmartFilter] {
        let commute = SmartFilter(name: "Commute", iconName: "car.fill", colorHex: "FF9A3D", order: 0)
        commute.onlyUnplayed = true
        commute.onlyDownloaded = true
        commute.maxMinutes = 45

        let fresh = SmartFilter(name: "New this week", iconName: "sparkles", colorHex: "FF3080", order: 1)
        fresh.onlyUnplayed = true
        fresh.withinDays = 7

        let clean = SmartFilter(name: "Ad-free ready", iconName: "wand.and.sparkles", colorHex: "3DD68C", order: 2)
        clean.onlyAdFree = true
        clean.onlyUnplayed = true

        let starred = SmartFilter(name: "Starred", iconName: "star.fill", colorHex: "FFD23D", order: 3)
        starred.onlyStarred = true
        starred.onlyUnplayed = false

        return [commute, fresh, clean, starred]
    }
}

enum FilterSort: String, CaseIterable, Identifiable {
    case newest = "Newest first"
    case oldest = "Oldest first"
    case shortest = "Shortest first"
    case longest = "Longest first"
    case show = "By show"
    var id: String { rawValue }
}

// MARK: - Colour helper

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
