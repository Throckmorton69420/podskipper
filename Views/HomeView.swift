import SwiftUI
import SwiftData

/// Pass 58 (Apple Podcasts 27.2–27.3 parity, his 5 Nov request): the Home
/// tab. Apple's Home has two sections in place of the old Up Next — New
/// Episodes ("the latest updates from your shows") and Continue Playing
/// ("pick up where you left off") — and 27.3 adds "Remove from Continue
/// Playing" and "Remove from New Episodes" to each item's menu. PodSkipper's
/// own queue (the episodes you chose with Play Next / Play Last, which are got
/// ready ahead of time) follows as Up Next, with the full page one tap away.
///
/// Each section reads only its own few episodes from the store (a predicate,
/// a fetch limit, the row's columns), and only while Home is the tab showing:
/// when it appears and after saves that touch episodes.
struct HomeView: View {
    private let active: Bool
    init(active: Bool = true) { self.active = active }

    @Environment(\.modelContext) private var context
    @State private var shelves = HomeShelves.shared
    @State private var inProgress: [Episode] = []
    @State private var latest: [Episode] = []
    @State private var queue: [Episode] = []
    @State private var loaded = false
    @State private var reloadTask: Task<Void, Never>?

    private var continuePlaying: [Episode] {
        HomeShelves.continuePlaying(inProgress.filter(\.isLive), removals: shelves.removals)
    }

    private var newEpisodes: [Episode] {
        let playing = Set(continuePlaying.map(\.guid))
        return HomeShelves.newEpisodes(latest.filter { $0.isLive && !playing.contains($0.guid) },
                                       removals: shelves.removals)
    }

    var body: some View {
        let continuing = continuePlaying
        let fresh = newEpisodes
        let queued = queue.filter(\.isLive)
        return List {
            if !continuing.isEmpty {
                SectionHeader("Continue Playing")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(continuing) { episode in
                            ContinueCard(episode: episode) {
                                shelves.remove(episode, from: .continuePlaying)
                            }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, Metrics.gutter)
                }
                .scrollTargetBehavior(.viewAligned)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .accessibilityIdentifier("home.continuePlaying")
            }

            if !fresh.isEmpty {
                ShelfHeader(title: "New Episodes", identifier: "home.newEpisodes.all") {
                    EpisodeCollectionView(title: "New Episodes", kind: .latest)
                }
                ForEach(fresh) { episode in
                    EpisodeListRow(episode: episode,
                                   removal: EpisodeRemoval(title: "Remove", systemImage: "minus.circle") {
                                       shelves.remove(episode, from: .newEpisodes)
                                   })
                        .environment(\.homeShelf, HomeShelfRemoval(title: "Remove from New Episodes") {
                            shelves.remove(episode, from: .newEpisodes)
                        })
                }
            }

            ShelfHeader(title: "Up Next", identifier: "home.upNext") {
                UpNextView(active: active)
            }
            if queued.isEmpty {
                Text("Episodes you add with Play Next or Play Last appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .plainRow(top: 2, bottom: 8)
            } else {
                ForEach(queued.prefix(3)) { episode in
                    EpisodeListRow(episode: episode,
                                   removal: EpisodeRemoval(title: "Remove", systemImage: "minus.circle") {
                                       episode.removeFromUpNext(context: context)
                                   })
                }
            }

            if loaded && continuing.isEmpty && fresh.isEmpty && queued.isEmpty {
                ContentUnavailableView("Nothing New Yet",
                    systemImage: "house",
                    description: Text("New episodes from the shows you follow, and the ones you’ve started, will appear here."))
                    .plainRow(top: 30, bottom: 30)
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Home")
        .watchName("Home")
        .toolbarTitleDisplayMode(.inlineLarge)
        .amoledScreen()
        // Read when Home shows and again after any save that touched an
        // episode (debounced), from whichever context saved it — the pattern
        // the Library's collections use. Live queries missed episodes added
        // just after launch (the simulator's demo library, Pass 58).
        .task(id: active) { if active { reload() } }
        .onReceive(StoreChanges.saves(in: context.container)) { change in
            guard active, change.unknown || !change.of(Episode.self, change.inserted.union(change.updated).union(change.deleted)).isEmpty
            else { return }
            reloadTask?.cancel()
            reloadTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                reload()
            }
        }
    }

    private func reload() {
        inProgress = (try? context.fetch(HomeShelves.inProgressDescriptor())) ?? []
        latest = (try? context.fetch(HomeShelves.latestDescriptor())) ?? []
        queue = (try? context.fetch(HomeShelves.queueDescriptor())) ?? []
        loaded = true
    }
}

/// A section title that opens its full page, as Apple's shelves do:
/// "New Episodes ›" — the whole title is the link, with no row chevron.
private struct ShelfHeader<Destination: View>: View {
    let title: String
    let identifier: String
    @ViewBuilder var destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.system(size: Metrics.titleSize, weight: .bold)).foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: Metrics.titleSize * 0.7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .navigationLinkIndicatorVisibility(.hidden)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(.isHeader)
        .plainRow(top: Metrics.sectionTop, bottom: Metrics.sectionBottom)
    }
}

/// One episode you've started: cover, how far you are, what's left.
private struct ContinueCard: View {
    let episode: Episode
    let remove: () -> Void
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline

    private var side: CGFloat { UIScale.pt(150) }
    private var fraction: Double {
        let total = episode.duration > 0 ? episode.duration : episode.publishedDuration
        return total > 0 ? min(1, max(0, episode.playbackPosition / total)) : 0
    }

    var body: some View {
        Button {
            Feel.selection.play()
            if PlayerEngine.shared.currentEpisode?.guid == episode.guid { PlayerEngine.shared.togglePlayPause() }
            else { PlayCoordinator.play(episode, settings: settings, pipeline: pipeline) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: side)
                    .overlay(alignment: .bottom) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                    }
                    .padding(.bottom, 4)
                Text(episode.podcast?.title ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(episode.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                Text("\(formatMinutes(episode.remainingSeconds)) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: side, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            EpisodeMenuItems(episode: episode)
                .environment(\.homeShelf, HomeShelfRemoval(title: "Remove from Continue Playing", action: remove))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(episode.title), \(episode.podcast?.title ?? ""), \(formatMinutes(episode.remainingSeconds)) left")
        .accessibilityIdentifier("home.continue.card")
    }
}

/// The Home section an episode's menu was opened from, and how to take it
/// off that section ("Remove from Continue Playing", "Remove from New
/// Episodes"). Read by `EpisodeMenuItems`.
struct HomeShelfRemoval {
    var title: String
    var action: () -> Void
}

extension EnvironmentValues {
    @Entry var homeShelf: HomeShelfRemoval? = nil
}

/// What Home shows, and what you took off it. Removals are kept on this
/// device (UserDefaults, by episode guid and when): an episode taken off
/// Continue Playing comes back once you play it again; one taken off New
/// Episodes stays off. Entries older than 120 days are forgotten.
@MainActor @Observable
final class HomeShelves {
    static let shared = HomeShelves()

    enum Shelf: String, CaseIterable, Sendable { case continuePlaying, newEpisodes }

    struct Removals: Equatable, Sendable {
        var byShelf: [Shelf: [String: Date]] = [:]

        func isRemoved(guid: String, lastPlayedAt: Date?, from shelf: Shelf) -> Bool {
            guard let at = byShelf[shelf]?[guid] else { return false }
            if shelf == .continuePlaying, let played = lastPlayedAt, played > at { return false }
            return true
        }
    }

    private(set) var removals = Removals()
    private let defaults: UserDefaults
    private static let key = "home.removed.v1"
    static let forgetAfter: TimeInterval = 120 * 24 * 3600

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.dictionary(forKey: Self.key) as? [String: [String: Double]] {
            let cutoff = Date().timeIntervalSince1970 - Self.forgetAfter
            for shelf in Shelf.allCases {
                let kept = (raw[shelf.rawValue] ?? [:]).filter { $0.value > cutoff }
                removals.byShelf[shelf] = kept.mapValues { Date(timeIntervalSince1970: $0) }
            }
        }
    }

    func remove(_ episode: Episode, from shelf: Shelf, at date: Date = Date()) {
        remove(guid: episode.guid, from: shelf, at: date)
        Haptics.success()
    }

    func remove(guid: String, from shelf: Shelf, at date: Date = Date()) {
        removals.byShelf[shelf, default: [:]][guid] = date
        let raw = Dictionary(uniqueKeysWithValues: Shelf.allCases.map { shelf in
            (shelf.rawValue, (removals.byShelf[shelf] ?? [:]).mapValues(\.timeIntervalSince1970))
        })
        defaults.set(raw, forKey: Self.key)
    }

    /// Started (past the first half-minute), not finished, newest listen first.
    nonisolated static func continuePlaying(_ episodes: [Episode], removals: Removals, limit: Int = 12) -> [Episode] {
        Array(episodes.filter { episode in
            !episode.isPlayed && episode.playbackPosition >= 30
                && !removals.isRemoved(guid: episode.guid, lastPlayedAt: episode.lastPlayedAt, from: .continuePlaying)
        }
        .sorted { listened($0) > listened($1) }
        .prefix(limit))
    }

    /// When it was last listened to: here, or (a position synced from another
    /// device) when its position last changed.
    nonisolated static func listened(_ episode: Episode) -> Date {
        episode.lastPlayedAt ?? episode.playbackPositionChangedAt ?? episode.publishedAt
    }

    /// The newest unplayed, unstarted episodes of the shows you follow, two
    /// at most from any one show so one busy feed doesn't fill the section.
    nonisolated static func newEpisodes(_ episodes: [Episode], removals: Removals,
                                        limit: Int = 8, perShow: Int = 2) -> [Episode] {
        var counts: [String: Int] = [:]
        var out: [Episode] = []
        for episode in episodes.sorted(by: { $0.publishedAt > $1.publishedAt }) {
            guard !episode.isPlayed, !episode.isArchived, episode.playbackPosition < 30,
                  let show = episode.podcast, !show.isArchived,
                  !removals.isRemoved(guid: episode.guid, lastPlayedAt: episode.lastPlayedAt, from: .newEpisodes)
            else { continue }
            let key = show.feedURL
            guard counts[key, default: 0] < perShow else { continue }
            counts[key, default: 0] += 1
            out.append(episode)
            if out.count >= limit { break }
        }
        return out
    }

    nonisolated static func inProgressDescriptor() -> FetchDescriptor<Episode> {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { !$0.isPlayed && !$0.isArchived && $0.playbackPosition >= 30 },
            sortBy: [SortDescriptor(\.lastPlayedAt, order: .reverse)])
        descriptor.fetchLimit = 60
        descriptor.propertiesToFetch = EpisodeRowFetch.properties + [\.playbackPositionChangedAt]
        descriptor.relationshipKeyPathsForPrefetching = [\.podcast]
        return descriptor
    }

    nonisolated static func latestDescriptor() -> FetchDescriptor<Episode> {
        var descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { !$0.isArchived && !$0.isPlayed && $0.playbackPosition < 30 },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        descriptor.fetchLimit = 80
        descriptor.propertiesToFetch = EpisodeRowFetch.properties
        descriptor.relationshipKeyPathsForPrefetching = [\.podcast]
        return descriptor
    }

    nonisolated static func queueDescriptor() -> FetchDescriptor<Episode> {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.isInQueue },
                                                  sortBy: [SortDescriptor(\.queueOrder)])
        descriptor.fetchLimit = 12
        descriptor.propertiesToFetch = EpisodeRowFetch.properties
        descriptor.relationshipKeyPathsForPrefetching = [\.podcast]
        return descriptor
    }
}
