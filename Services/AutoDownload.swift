import Foundation
import Network
import SwiftData

/// What to download without being asked, the way Apple Podcasts offers it.
///
/// Apple's choices, read from its strings: Automatically Download is Off, Only
/// New or All Unplayed; Limit Downloads keeps the most recent 1, 2, 3, 5 or 10,
/// or the last day, 7, 14 or 30 days. Both are an app default a show can
/// override. PodSkipper adds what is particular to it — find the ads as soon
/// as something arrives, so it is ad-free by the time you press play — and
/// two filters Apple does not have: a minimum length, which keeps trailers
/// and bonus clips off the phone, and words that rule an episode out.
///
/// A rule only ever removes what a rule downloaded. Anything downloaded by
/// hand, starred, or in Up Next is left alone.
enum AutoDownloadMode: String, CaseIterable, Identifiable {
    case off, onlyNew, allUnplayed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:         return "Off"
        case .onlyNew:     return "Only New"
        case .allUnplayed: return "All Unplayed"
        }
    }
}

enum AutoDownloadLimit: String, CaseIterable, Identifiable {
    case recent1, recent2, recent3, recent5, recent10
    case day1, days7, days14, days30
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent1:  return "Most Recent Episode"
        case .recent2:  return "Most Recent 2 Episodes"
        case .recent3:  return "Most Recent 3 Episodes"
        case .recent5:  return "Most Recent 5 Episodes"
        case .recent10: return "Most Recent 10 Episodes"
        case .day1:     return "Last 24 Hours"
        case .days7:    return "Last 7 Days"
        case .days14:   return "Last 14 Days"
        case .days30:   return "Last 30 Days"
        case .all:      return "No Limit"
        }
    }

    var count: Int? {
        switch self {
        case .recent1: return 1
        case .recent2: return 2
        case .recent3: return 3
        case .recent5: return 5
        case .recent10: return 10
        default: return nil
        }
    }

    var days: Double? {
        switch self {
        case .day1: return 1
        case .days7: return 7
        case .days14: return 14
        case .days30: return 30
        default: return nil
        }
    }
}

extension Podcast {
    func effectiveAutoDownloadMode(_ settings: AppSettings) -> AutoDownloadMode {
        if let raw = autoDownloadModeRaw, let mode = AutoDownloadMode(rawValue: raw) { return mode }
        // The old single switch, for shows that had it on.
        if autoDownloadNew { return .onlyNew }
        return AutoDownloadMode(rawValue: settings.autoDownloadMode) ?? .off
    }

    func effectiveAutoDownloadLimit(_ settings: AppSettings) -> AutoDownloadLimit {
        if let raw = autoDownloadLimitRaw, let limit = AutoDownloadLimit(rawValue: raw) { return limit }
        return AutoDownloadLimit(rawValue: settings.autoDownloadLimit) ?? .recent3
    }

    func effectiveAutoFindAds(_ settings: AppSettings) -> Bool {
        autoDownloadFindAds ?? settings.autoDownloadFindAds
    }
}

@MainActor
enum AutoDownload {

    /// Cellular or a hotspot, so a Wi-Fi-only rule can wait.
    private static let monitor: NWPathMonitor = {
        let monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "PodSkipper.path"))
        return monitor
    }()

    private static var running = false

    /// What each show's rule wants on the phone right now, newest first.
    static func wanted(for podcast: Podcast, settings: AppSettings, context: ModelContext,
                       now: Date = .now) -> [Episode] {
        let mode = podcast.effectiveAutoDownloadMode(settings)
        guard mode != .off, !podcast.isArchived else { return [] }
        let limit = podcast.effectiveAutoDownloadLimit(settings)
        let excluded = podcast.autoDownloadExcludeWords
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let minimum = Double(podcast.autoDownloadMinMinutes) * 60

        // From the store, newest first and only as many as could matter —
        // not the show's whole catalogue loaded and sorted in memory.
        let feedURL = podcast.feedURL
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.podcast?.feedURL == feedURL && !$0.isPlayed && !$0.isArchived },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.fetchLimit = 60
        var list = ((try? context.fetch(descriptor)) ?? [])
            .filter { minimum == 0 || $0.duration == 0 || $0.duration >= minimum }
            .filter { episode in
                let title = episode.title.lowercased()
                return !excluded.contains { title.contains($0) }
            }

        if mode == .onlyNew {
            let since = podcast.autoDownloadSince ?? now
            list = list.filter { $0.publishedAt >= since || $0.wasAutoDownloaded }
        }
        if let days = limit.days {
            list = list.filter { $0.publishedAt >= now.addingTimeInterval(-days * 86_400) }
        }
        if let count = limit.count {
            list = Array(list.prefix(count))
        }
        return Array(list.prefix(25))
    }

    /// Download what the rules want, remove what they no longer want, and
    /// optionally start finding ads. Safe to call often.
    static func apply(context: ModelContext, settings: AppSettings, pipeline: ProcessingPipeline) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        var wantedIDs = Set<String>()
        var toFetch: [Episode] = []
        var toProcess: [Episode] = []
        for podcast in podcasts {
            let mode = podcast.effectiveAutoDownloadMode(settings)
            if mode == .onlyNew, podcast.autoDownloadSince == nil {
                // First time this rule is seen: "new" starts now, rather than
                // meaning the whole back catalogue.
                podcast.autoDownloadSince = .now
            }
            let keep = Self.wanted(for: podcast, settings: settings, context: context)
            wantedIDs.formUnion(keep.map(\.guid))

            toFetch += keep.filter { !$0.isDownloaded }
            if podcast.effectiveAutoFindAds(settings) {
                toProcess += keep.filter { $0.processingState != .ready && $0.processingState != .failed }
            }
        }
        // Only what a rule brought in, and never what someone is keeping. One
        // query for the handful a rule downloaded, not a walk of every show.
        let auto = (try? context.fetch(FetchDescriptor<Episode>(
            predicate: #Predicate { $0.wasAutoDownloaded }))) ?? []
        for episode in auto where episode.isDownloaded
            && !wantedIDs.contains(episode.guid)
            && !episode.isStarred && !episode.isInQueue
            && PlayerEngine.shared.currentEpisode?.guid != episode.guid {
            DownloadManager.remove(episode)
            episode.wasAutoDownloaded = false
        }
        try? context.save()

        let path = monitor.currentPath
        let allowed = !settings.autoDownloadWiFiOnly || (!path.isExpensive && !path.isConstrained)
        if allowed {
            for episode in toFetch.prefix(10) {
                guard !episode.isDownloaded else { continue }
                if await pipeline.ensureDownloaded(episode) {
                    episode.wasAutoDownloaded = true
                    try? context.save()
                }
            }
            LibraryTotals.shared.invalidate()
        }

        // Finding ads downloads first if it has to, so on cellular with a
        // Wi-Fi-only rule these wait for the next pass too.
        if !toProcess.isEmpty, allowed {
            pipeline.enqueueBackground(toProcess)
        }
    }

    /// A one-line description of a rule, for a settings row.
    static func summary(mode: AutoDownloadMode, limit: AutoDownloadLimit) -> String {
        mode == .off ? "Off" : "\(mode.label) · \(limit.label)"
    }
}
