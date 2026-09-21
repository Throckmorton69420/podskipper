import Foundation
import Observation
import SwiftData

/// All heavy library work, off the main thread, in its own database context.
///
/// Reported after the build that started storing whole catalogues: the app
/// froze, scrolling stuttered, the phone got hot, the battery drained, and it
/// crashed a couple of times. The cause was this work running on the main
/// thread — the thread that draws the screen:
///
/// - Filling in every show's back catalogue inserted tens of thousands of
///   episodes through the main context in one go, then saved them all at once.
///   A crash part-way (memory) meant the "done" flag was never written, so it
///   started over on every launch.
/// - Library totals and each show's counts walked every episode in the store,
///   on the main thread, every time anything changed — and the show counts
///   expired every 0.75 s, so any screen showing them redid it constantly.
///
/// Now both happen here: a `@ModelActor` with its own context on a background
/// executor, saving in small batches, one show at a time, resuming where it
/// left off (each show records `catalogueIndexedAt` when done). The main
/// context picks up saved changes automatically; screens read the published
/// results from `LibraryIndexStatus`, never compute them.
@ModelActor
actor LibraryIndex {

    struct Counts: Sendable, Equatable {
        var unplayed = 0
        var ready = 0
        var published = 0
        var total = 0
        var newest: Date?
        var newSinceSeen = 0
        /// Seconds actually listened to across the show, for recommendations.
        var listened: Double = 0
    }

    struct Totals: Sendable, Equatable {
        var downloaded = 0
        var starred = 0
        var unplayed = 0
        var ready = 0
        var adsRemoved = 0
        var secondsSaved: Double = 0
        /// Episodes in ad-free feeds, and how many shows have one.
        var published = 0
        var feeds = 0
    }

    struct Progress: Sendable {
        var showsDone: Int
        var showsTotal: Int
        var current: String
        var episodesAdded: Int
    }

    struct MergeResult: Sendable {
        var added = 0
        var freshIDs: [PersistentIdentifier] = []
    }

    // MARK: Catalogue

    /// Merge one parsed feed into a show. Batched saves keep memory flat.
    func merge(_ feed: ParsedFeed, into podcastID: PersistentIdentifier, markComplete: Bool) -> MergeResult {
        guard let podcast = modelContext.model(for: podcastID) as? Podcast else { return MergeResult() }
        var result = MergeResult()
        let cutoff = podcast.lastRefreshed

        // Only this show's guids, and a store-wide check per candidate —
        // `Episode.guid` is unique across the store, so a guid that belongs to
        // another show must not be inserted here (it would move that episode).
        let existing = Set(podcast.episodes.map(\.guid))
        if !feed.people.isEmpty { podcast.people = feed.people.joined(separator: "|") }
        // Video versions and named people can be added to a feed after an
        // episode was first stored; bring those across on every merge.
        // The same for the explicit rating and the bonus / trailer type,
        // which episodes stored before these were read do not have.
        let extras = Dictionary(feed.items.filter {
                                    $0.videoURL != nil || !$0.people.isEmpty
                                    || $0.explicit == true || !$0.episodeType.isEmpty
                                }
                                .map { ($0.guid, $0) }, uniquingKeysWith: { a, _ in a })
        if !extras.isEmpty {
            for episode in podcast.episodes {
                guard let item = extras[episode.guid] else { continue }
                if episode.videoURL != item.videoURL { episode.videoURL = item.videoURL }
                let joined = item.people.joined(separator: "|")
                if episode.people != joined { episode.people = joined }
                let explicit = item.explicit ?? false
                if episode.isExplicit != explicit { episode.isExplicit = explicit }
                if episode.episodeType != item.episodeType { episode.episodeType = item.episodeType }
            }
        }
        var pending = 0
        var inserted: [Episode] = []
        for item in feed.items where !item.guid.isEmpty && !existing.contains(item.guid) {
            let guid = item.guid
            var probe = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            probe.fetchLimit = 1
            if ((try? modelContext.fetchCount(probe)) ?? 0) > 0 { continue }

            let episode = Episode(item: item)
            episode.podcast = podcast
            modelContext.insert(episode)
            inserted.append(episode)
            result.added += 1
            pending += 1
            if pending >= 250 {
                try? modelContext.save()
                pending = 0
            }
        }
        if let cutoff {
            for episode in inserted where episode.publishedAt > cutoff {
                result.freshIDs.append(episode.persistentModelID)
            }
        }
        podcast.lastRefreshed = .now
        if markComplete { podcast.catalogueIndexedAt = .now }
        try? modelContext.save()
        return result
    }

    /// Shows whose back catalogue has not been indexed yet.
    func unindexedShows() -> [(PersistentIdentifier, String, String)] {
        let all = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        return all.filter { $0.catalogueIndexedAt == nil && !$0.isArchived }
            .map { ($0.persistentModelID, $0.feedURL, $0.title) }
    }

    func allShows() -> [(PersistentIdentifier, String, String)] {
        let all = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        return all.filter { !$0.isArchived }.map { ($0.persistentModelID, $0.feedURL, $0.title) }
    }

    /// How many shows have their whole catalogue in, for the progress line.
    func indexedSummary() -> (indexed: Int, total: Int) {
        let all = (try? modelContext.fetch(FetchDescriptor<Podcast>())) ?? []
        let live = all.filter { !$0.isArchived }
        return (live.filter { $0.catalogueIndexedAt != nil }.count, live.count)
    }

    // MARK: Counts

    /// Every show's counts and the library totals, in one pass.
    ///
    /// A throwaway context, so the twelve thousand rows it touches are released
    /// when it returns instead of staying registered in the actor's context,
    /// and only the columns the counts need are read — not descriptions or
    /// transcripts.
    func computeCounts() -> (perShow: [String: Counts], totals: Totals) {
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Episode>()
        descriptor.propertiesToFetch = [\.isPlayed, \.isArchived, \.processingState, \.publishedURL,
                                        \.localFilename, \.isStarred, \.publishedAt, \.secondsListened]
        descriptor.relationshipKeyPathsForPrefetching = [\.podcast]
        let episodes = (try? context.fetch(descriptor)) ?? []
        var perShow: [String: Counts] = [:]
        var totals = Totals()
        let downloaded = FileIndex.snapshot()
        for episode in episodes {
            let key = episode.podcast?.feedURL ?? ""
            var counts = perShow[key] ?? Counts()
            counts.total += 1
            counts.listened += episode.secondsListened
            if counts.newest == nil || episode.publishedAt > counts.newest! { counts.newest = episode.publishedAt }
            if let seen = episode.podcast?.lastSeenAt, episode.publishedAt > seen { counts.newSinceSeen += 1 }
            if !episode.isPlayed && !episode.isArchived { counts.unplayed += 1; totals.unplayed += 1 }
            if episode.processingState == .ready {
                counts.ready += 1
                totals.ready += 1
            }
            if episode.publishedURL != nil { counts.published += 1; totals.published += 1 }
            if let name = episode.localFilename, downloaded.contains(name) { totals.downloaded += 1 }
            if episode.isStarred { totals.starred += 1 }
            perShow[key] = counts
        }
        totals.feeds = perShow.values.filter { $0.published > 0 }.count
        // Ads straight from their own table rather than through each episode.
        let segments = (try? context.fetch(FetchDescriptor<AdSegment>())) ?? []
        for segment in segments where segment.userVerdict != .notAnAd && segment.episode != nil {
            totals.adsRemoved += 1
            totals.secondsSaved += segment.duration
        }
        return (perShow, totals)
    }

    // MARK: Searching what was said

    struct TranscriptHit: Sendable, Identifiable {
        let id: PersistentIdentifier
        let title: String
        let show: String
        let artwork: String?
        let snippet: String
        let at: Double
    }

    /// Episodes whose transcript contains the words, with where they were
    /// said. Only processed episodes have transcripts; this reads them in a
    /// throwaway context so none of that text stays in memory afterwards.
    func searchTranscripts(_ term: String, limit: Int = 20) -> [TranscriptHit] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.count >= 3 else { return [] }
        let context = ModelContext(modelContainer)
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.transcriptData != nil },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.relationshipKeyPathsForPrefetching = [\.podcast]
        let episodes = (try? context.fetch(descriptor)) ?? []
        var hits: [TranscriptHit] = []
        for episode in episodes {
            if Task.isCancelled { break }
            if let text = episode.transcriptText,
               text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) == nil { continue }
            guard let data = episode.transcriptData,
                  let lines = try? JSONDecoder().decode([TimedLine].self, from: data),
                  let index = lines.firstIndex(where: {
                      $0.text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                  }) else { continue }
            let around = lines[max(0, index - 1)...min(lines.count - 1, index + 1)]
                .map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            hits.append(TranscriptHit(id: episode.persistentModelID,
                                      title: episode.title,
                                      show: episode.podcast?.title ?? "",
                                      artwork: episode.artworkURL ?? episode.podcast?.artworkURL,
                                      snippet: around,
                                      at: lines[index].start))
            if hits.count >= limit { break }
        }
        return hits
    }

    // MARK: Apple Podcasts history

    /// Apply an Apple Podcasts history export, off the main thread.
    func applyHistory(_ file: HistoryImport.File) -> HistoryImport.Result {
        let context = ModelContext(modelContainer)
        var result = HistoryImport.Result()

        let podcasts = (try? context.fetch(FetchDescriptor<Podcast>())) ?? []
        var followed: [String: Podcast] = [:]
        for podcast in podcasts { followed[HistoryImport.normal(podcast.feedURL)] = podcast }

        // By show, then episode. The same guid appears in several shows — Cum
        // Town episodes are reposted in MYCTP and on The Adam Friedland Show —
        // so an Apple Podcasts episode only ever marks the PodSkipper episode
        // that belongs to the same feed.
        var descriptor = FetchDescriptor<Episode>()
        descriptor.relationshipKeyPathsForPrefetching = [\.podcast]
        let episodes = (try? context.fetch(descriptor)) ?? []
        var byFeedGUID: [String: Episode] = [:]
        var byFeedTitle: [String: Episode] = [:]
        for episode in episodes {
            guard let feed = episode.podcast?.feedURL else { continue }
            let show = HistoryImport.normal(feed)
            byFeedGUID[show + "|" + episode.guid] = episode
            byFeedTitle[show + "|" + episode.title.lowercased()] = episode
        }

        var changed = 0
        for item in file.episodes {
            let feeds = [item.feedURL, item.originalFeedURL].compactMap { $0 }.map(HistoryImport.normal)
            guard feeds.contains(where: { followed[$0] != nil }) else {
                result.otherShows += 1
                continue
            }
            var match: Episode?
            for feed in feeds where match == nil {
                if let guid = item.guid { match = byFeedGUID[feed + "|" + guid] }
                if match == nil, let title = item.title { match = byFeedTitle[feed + "|" + title.lowercased()] }
            }
            guard let episode = match else {
                result.notInFeed += 1
                continue
            }
            if let last = item.lastPlayed {
                let date = Date(timeIntervalSince1970: last)
                if episode.lastPlayedAt == nil || date > episode.lastPlayedAt! { episode.lastPlayedAt = date }
            }
            let playhead = item.playhead ?? 0
            if item.played == 1 {
                if !episode.isPlayed {
                    episode.isPlayed = true
                    episode.playbackPosition = 0
                    episode.isInQueue = false
                    result.markedPlayed += 1
                    changed += 1
                } else {
                    result.alreadyPlayed += 1
                }
            } else {
                // Only if it was not actually listened to here: something
                // you finished in PodSkipper stays played.
                if episode.isPlayed, episode.secondsListened < 60 {
                    episode.isPlayed = false
                    result.markedUnplayed += 1
                    changed += 1
                }
                if playhead > 1, abs(playhead - episode.playbackPosition) > 1 {
                    episode.playbackPosition = playhead
                    result.resumePoints += 1
                    changed += 1
                }
            }
            if (item.saved ?? 0) == 1, !episode.isStarred {
                episode.isStarred = true
                result.starred += 1
                changed += 1
            }
            if changed >= 500 {
                try? context.save()
                changed = 0
            }
        }
        try? context.save()
        return result
    }
}

/// One show's counts, observed on its own.
@MainActor
@Observable
final class CountsBox {
    var value: LibraryIndex.Counts
    init(value: LibraryIndex.Counts) { self.value = value }
}

/// What the screens read: indexing progress and the counts, published on the
/// main thread. Nothing here computes anything.
@MainActor
@Observable
final class LibraryIndexStatus {
    static let shared = LibraryIndexStatus()

    private(set) var isIndexing = false
    private(set) var showsDone = 0
    private(set) var showsTotal = 0
    private(set) var currentShow = ""
    private(set) var episodesAdded = 0
    private(set) var failures: [String] = []
    /// Why indexing stopped before the end, in words — no connection, Low
    /// Power Mode. Nil when it simply finished or has not started.
    private(set) var pausedReason: String?
    /// Across the whole library, including shows done on earlier launches.
    private(set) var indexedShows = 0
    private(set) var totalShows = 0

    @ObservationIgnored private(set) var counts: [String: LibraryIndex.Counts] = [:]
    private(set) var totals = LibraryIndex.Totals()

    @ObservationIgnored private var index: LibraryIndex?
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    private init() {}

    func configure(container: ModelContainer) {
        guard index == nil else { return }
        index = LibraryIndex(modelContainer: container)
        refreshCounts(after: .zero)
        Task { await refreshSummary() }
    }

    /// Every followed show has its whole catalogue in.
    var catalogueComplete: Bool { !isIndexing && totalShows > 0 && indexedShows >= totalShows }

    /// Counts for one show, or zeros until the first pass lands.
    ///
    /// Read through a box of its own, so a show's tile depends on that show's
    /// numbers only. Reading them out of the shared dictionary made every
    /// tile in the library depend on every show's counts, and one show
    /// changing redrew the whole grid — during indexing, every few seconds,
    /// sometimes mid-scroll.
    func counts(for feedURL: String) -> LibraryIndex.Counts { box(for: feedURL).value }

    @ObservationIgnored private var boxes: [String: CountsBox] = [:]

    private func box(for feedURL: String) -> CountsBox {
        if let box = boxes[feedURL] { return box }
        let box = CountsBox(value: counts[feedURL] ?? .init())
        boxes[feedURL] = box
        return box
    }

    func refreshSummary() async {
        guard let index else { return }
        let summary = await index.indexedSummary()
        if indexedShows != summary.indexed { indexedShows = summary.indexed }
        if totalShows != summary.total { totalShows = summary.total }
    }

    /// Recompute counts in the background, coalescing bursts of changes into
    /// one pass a moment later.
    func refreshCounts(after delay: Duration = .milliseconds(800)) {
        guard let index else { return }
        countsTask?.cancel()
        countsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = await index.computeCounts()
            guard !Task.isCancelled, let self else { return }
            if self.counts != result.perShow {
                self.counts = result.perShow
                for (key, box) in self.boxes {
                    let value = result.perShow[key] ?? .init()
                    if box.value != value { box.value = value }
                }
            }
            if self.totals != result.totals { self.totals = result.totals }
        }
    }

    /// Fill in back catalogues for shows that do not have them yet.
    ///
    /// One show at a time, at low priority, while the app is open. Safe to
    /// call on every launch and every return to the app: finished shows are
    /// skipped, so it picks up where it stopped. It pauses rather than
    /// pressing on in Low Power Mode or with no connection, since every show
    /// would only fail.
    func indexCatalogues(all: Bool = false) {
        guard let index, indexTask == nil else { return }
        // Demo runs have no feeds to fetch; just report where things stand.
        if DemoData.isEnabled {
            Task { await refreshSummary() }
            return
        }
        indexTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.indexTask = nil }
            let shows = all ? await index.allShows() : await index.unindexedShows()
            await self.refreshSummary()
            guard !shows.isEmpty else { return }
            if ProcessInfo.processInfo.isLowPowerModeEnabled {
                self.pausedReason = "Paused in Low Power Mode"
                return
            }
            self.pausedReason = nil
            self.isIndexing = true
            self.showsTotal = shows.count
            self.showsDone = 0
            self.episodesAdded = 0
            self.failures = []
            var offlineStreak = 0
            for (id, feedURL, title) in shows {
                if Task.isCancelled { break }
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    self.pausedReason = "Paused in Low Power Mode"
                    break
                }
                self.currentShow = title
                do {
                    let feed = try await FeedParser.fetch(feedURL)
                    let merged = await index.merge(feed, into: id, markComplete: true)
                    self.episodesAdded += merged.added
                    self.indexedShows += 1
                    offlineStreak = 0
                } catch {
                    if NetworkStatus.shared.isOffline {
                        offlineStreak += 1
                        if offlineStreak >= 2 {
                            self.pausedReason = "Waiting for a connection"
                            break
                        }
                    }
                    self.failures.append(title)
                }
                self.showsDone += 1
                if self.showsDone % 3 == 0 { self.refreshCounts() }
            }
            self.isIndexing = false
            self.currentShow = ""
            self.refreshCounts(after: .zero)
            await self.refreshSummary()
            if self.pausedReason == "Waiting for a connection" {
                // Try again once the connection is back.
                Task { [weak self] in
                    await NetworkStatus.shared.waitUntilOnline()
                    self?.indexCatalogues()
                }
            }
        }
    }

    /// Wait for indexing to finish, starting it if some shows still need it.
    func waitForIndexing() async {
        indexCatalogues()
        await indexTask?.value
    }

    /// Merge a feed fetched elsewhere (a refresh or a new follow), off the
    /// main thread.
    func merge(_ feed: ParsedFeed, into podcastID: PersistentIdentifier) async -> LibraryIndex.MergeResult {
        guard let index else { return .init() }
        let result = await index.merge(feed, into: podcastID, markComplete: true)
        refreshCounts()
        return result
    }

    func searchTranscripts(_ term: String) async -> [LibraryIndex.TranscriptHit] {
        guard let index else { return [] }
        return await index.searchTranscripts(term)
    }

    func applyHistory(_ file: HistoryImport.File) async -> HistoryImport.Result {
        guard let index else { return .init() }
        let result = await index.applyHistory(file)
        refreshCounts(after: .zero)
        return result
    }
}
