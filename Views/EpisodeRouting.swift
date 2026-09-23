import SwiftUI
import SwiftData
import UIKit

// MARK: - Episode and show routing
//
// One episode page for the whole app: tapping an episode anywhere — a show
// page, Up Next, a search result, a chart, a store shelf, a show nobody has
// followed — opens the same page a long-press's "Episode Details" already
// could. Apple Podcasts does this everywhere; PodSkipper only did it from
// that one menu item, reported as "clicking on an episode doesn't open up
// the episode page".
//
// `EpisodeRoute` and `ShowRoute` carry a `PersistentIdentifier` and are
// registered once, by `.episodeDestinations()`, on the root of each tab's
// `NavigationStack` — never inside a List row, which is what caused three
// links in one row to push three screens at once elsewhere in this app.
// Every row that only *identifies* an episode or a show pushes one of these
// two; a row's play button or ⋯ menu stays a separate control beside it.
//
// `PreviewEpisodeRoute` is for an episode of a show nobody has followed —
// there is no library `Episode` to point at, so it carries its own display
// fields instead. Nothing pushes it through this modifier: a chart, a
// search result and a show preview each already own a piece of state for
// their own next screen, and this route rides in that instead (see
// `DiscoverRoute.previewEpisode`, `ShowPreviewView`'s own `previewEpisode`,
// and `StoreLink.episode`).

/// A library episode's own page.
struct EpisodeRoute: Hashable {
    let id: PersistentIdentifier
    init(_ episode: Episode) { id = episode.persistentModelID }
}

/// A library show's own page, for "Go to Show" reached from outside the
/// Library tab — Up Next, Search, a show preview — where `LibraryRoute` (the
/// Library tab's own routing) is not registered.
struct ShowRoute: Hashable {
    let id: PersistentIdentifier
    init(_ podcast: Podcast) { id = podcast.persistentModelID }
}

extension View {
    /// The episode and show pages, registered once per tab. Apply this to
    /// the view inside each tab's `NavigationStack`.
    func episodeDestinations() -> some View {
        modifier(EpisodeDestinations())
    }
}

private struct EpisodeDestinations: ViewModifier {
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: EpisodeRoute.self) { route in
                if let episode = modelContext.model(for: route.id) as? Episode {
                    EpisodeDetailView(episode: episode)
                } else {
                    ContentUnavailableView("Episode not found", systemImage: "questionmark")
                }
            }
            .navigationDestination(for: ShowRoute.self) { route in
                if let podcast = modelContext.model(for: route.id) as? Podcast {
                    ShowDetailView(podcast: podcast)
                } else {
                    ContentUnavailableView("Show not found", systemImage: "questionmark")
                }
            }
    }
}

// MARK: - An episode of a show nobody has followed yet

/// Enough of an episode — from a chart, a search result, a store shelf, or a
/// show preview's own list — to draw its page right away.
/// `PreviewEpisodeDetailView` loads the show's feed itself to fill in
/// anything missing, the same way `ShowPreviewView` already does for the
/// show around it.
struct PreviewEpisodeRoute: Hashable {
    var feedURL: String?
    var showID: Int?
    var showName: String
    var showArtworkURL: String?
    var title: String
    var artworkURL: String?
    var publishedAt: Date?
    var duration: Double?
    var summary: String?
    /// A stream already in hand — a search result's or a store item's own —
    /// used before the feed finishes loading.
    var audioURL: String?
}

extension PreviewEpisodeRoute {
    init(chartEpisode episode: DiscoverService.ChartEpisode) {
        self.init(feedURL: nil, showID: episode.showID, showName: episode.showName,
                  showArtworkURL: episode.artworkURL, title: episode.title,
                  artworkURL: episode.artworkURL, publishedAt: nil, duration: nil,
                  summary: nil, audioURL: nil)
    }

    init(episodeResult episode: DiscoverService.EpisodeResult) {
        self.init(feedURL: episode.feedURL, showID: episode.showID, showName: episode.showTitle,
                  showArtworkURL: episode.artworkURL, title: episode.title,
                  artworkURL: episode.artworkURL, publishedAt: episode.releaseDate,
                  duration: episode.duration, summary: episode.summary, audioURL: episode.audioURL)
    }

    init(storeItem item: StoreItem) {
        let showID = Int(item.showAdamID ?? "") ?? StoreClient.showID(in: item.destination)
        let art = (item.icon ?? item.artwork)?.squareURL(600)
        self.init(feedURL: item.feedURL, showID: showID, showName: item.showTitle ?? item.title,
                  showArtworkURL: art, title: item.title, artworkURL: art,
                  publishedAt: nil, duration: item.duration, summary: item.summary,
                  audioURL: item.streamURL)
    }
}

// MARK: - Notes with tappable links

/// The full HTML description, with its links kept tappable — `HTMLText.strip`
/// throws them away, which the two-line preview in a row can afford but a
/// page whose whole point is to read the notes cannot.
///
/// `NSAttributedString`'s HTML import is documented as a main-thread call
/// (it runs a hidden web view under the hood), so this parses on appearance
/// rather than off to a background task, and only once per episode
/// (`.task(id:)`) — the plain, stripped text shows meanwhile.
struct EpisodeNotesText: View {
    let html: String
    let id: String
    @State private var attributed: AttributedString?

    var body: some View {
        Text(attributed ?? AttributedString(HTMLText.strip(html)))
            .font(.body)
            .foregroundStyle(.secondary)
            .tint(Theme.accentHot)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .task(id: id) { attributed = Self.parse(html) }
    }

    private static func parse(_ html: String) -> AttributedString? {
        guard let data = html.data(using: .utf8),
              let ns = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return nil }
        // Only the links are wanted. The HTML's own font and colour are a
        // browser's defaults — black text among them, invisible on this
        // app's dark background — and they arrive as UIKit attributes,
        // which clearing SwiftUI's colour does not remove. Converting with
        // Foundation's attributes alone keeps the links and drops the rest.
        guard var result = try? AttributedString(ns, including: \.foundation)
        else { return nil }
        while result.characters.last?.isNewline == true {
            result.characters.removeLast()
        }
        return result
    }
}

// MARK: - An episode's page before you follow the show

/// Apple's episode page for a show you have not followed: enough to read and
/// to press Play, with Follow standing in for the row of controls a library
/// episode has. Same layout as `EpisodeDetailView` as far as the data allows
/// — no Find Ads (nothing has been transcribed), no "More from this show".
///
/// A chart or a search result doesn't know whether you already follow the
/// show, so every one of them pushes this route unconditionally; if it turns
/// out you do, this shows the real `EpisodeDetailView` instead.
struct PreviewEpisodeDetailView: View {
    let route: PreviewEpisodeRoute
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.modelContext) private var context
    @Query private var podcasts: [Podcast]
    @State private var player = PlayerEngine.shared
    @State private var feed: ParsedFeed?
    @State private var feedURL: String?
    @State private var resolved: ParsedItem?
    @State private var following = false
    @State private var loadFailed: String?
    /// The guid this page itself started playing, so its Play button shows
    /// Pause only for the episode it played — not any other episode that
    /// happens to share the player right now.
    @State private var playedGUID: String?
    @State private var openShow = false

    private var libraryPodcast: Podcast? {
        if let feedURL = route.feedURL { return podcasts.first { $0.feedURL == feedURL } }
        return podcasts.first { $0.title.caseInsensitiveCompare(route.showName) == .orderedSame }
    }

    private var libraryEpisode: Episode? {
        libraryPodcast?.episodes.first { $0.title.caseInsensitiveCompare(route.title) == .orderedSame }
    }

    var body: some View {
        if let libraryEpisode {
            EpisodeDetailView(episode: libraryEpisode)
        } else {
            content
        }
    }

    private var showName: some View {
        Text(route.showName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accentHot)
    }

    private var content: some View {
        List {
            VStack(spacing: 14) {
                Artwork(url: route.artworkURL ?? route.showArtworkURL, size: Metrics.artHero)
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                VStack(spacing: 6) {
                    Group {
                        if let libraryPodcast {
                            // On the stack's path, so its episode rows open (see ShowRoute).
                            NavigationLink(value: ShowRoute(libraryPodcast)) { showName }
                                .navigationLinkIndicatorVisibility(.hidden)
                        } else {
                            Button { openShow = true } label: { showName }
                        }
                    }
                    .buttonStyle(.plain)
                    Text(route.title)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                    if !metaLine.isEmpty {
                        Text(metaLine).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    playButton
                    followButton
                }
                if let loadFailed, audioURL == nil {
                    Text(loadFailed).font(.footnote).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity)
            .readableWidth(520)
            .plainRow(top: 8, bottom: 12)

            if let notesHTML, !notesHTML.isEmpty {
                EpisodeNotesText(html: notesHTML, id: route.showName + "|" + route.title)
                    .contentRow()
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .amoledScreen()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $openShow) {
            ShowPreviewView(previewEpisode: route)
        }
        .task(id: route) { await load() }
    }

    private var audioURL: String? { resolved?.audioURL ?? route.audioURL }
    private var notesHTML: String? { resolved?.description ?? route.summary }
    private var publishedAt: Date? { resolved?.publishedAt ?? route.publishedAt }
    private var durationSeconds: Double { resolved?.duration ?? route.duration ?? 0 }
    private var isCurrent: Bool {
        guard let playedGUID else { return false }
        return player.currentEpisode?.guid == playedGUID
    }

    private var metaLine: String {
        var parts: [String] = []
        if let publishedAt { parts.append(publishedAt.formatted(.dateTime.month(.wide).day().year())) }
        if durationSeconds > 0 { parts.append(formatMinutes(durationSeconds)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var playButton: some View {
        Button { play() } label: {
            Label(isCurrent && player.isPlaying ? "Pause" : "Play",
                  systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .tint(Theme.accentHot)
        .disabled(audioURL == nil)
    }

    @ViewBuilder
    private var followButton: some View {
        if let libraryPodcast {
            NavigationLink(value: ShowRoute(libraryPodcast)) {
                Label("Following", systemImage: "checkmark")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .navigationLinkIndicatorVisibility(.hidden)
        } else {
            Button {
                Task { await follow() }
            } label: {
                HStack(spacing: 6) {
                    if following { ProgressView().controlSize(.small) } else { Image(systemName: "plus") }
                    Text("Follow")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glass)
            .disabled(following)
        }
    }

    private func play() {
        if isCurrent { player.togglePlayPause(); return }
        guard let audioURL else { return }
        let guid = (resolved?.guid).flatMap { $0.isEmpty ? nil : $0 }
            ?? "preview:\(route.showName)/\(route.title)"
        let item = ParsedItem(guid: guid, title: route.title, description: notesHTML ?? "",
                              audioURL: audioURL, publishedAt: publishedAt ?? .now,
                              duration: durationSeconds, artworkURL: route.artworkURL ?? route.showArtworkURL)
        // Not inserted into the model context — playing a preview does not
        // add it to the library, the way pressing play on a real row would.
        let episode = Episode(item: item)
        playedGUID = episode.guid
        PlayCoordinator.play(episode, settings: settings, pipeline: pipeline)
    }

    private func load() async {
        guard resolved == nil, feed == nil else { return }
        var url = route.feedURL
        if url == nil, let id = route.showID,
           let found = try? await DiscoverService.lookup(ids: [id]).first {
            url = found.feedURL
        }
        guard let url else {
            loadFailed = "This show's feed isn't listed in the directory."
            return
        }
        feedURL = url
        do {
            let parsedFeed = try await FeedParser.fetch(url)
            feed = parsedFeed
            resolved = parsedFeed.items.first { $0.title.caseInsensitiveCompare(route.title) == .orderedSame }
        } catch {
            loadFailed = error.localizedDescription
        }
    }

    private func follow() async {
        guard libraryPodcast == nil else { return }
        following = true
        defer { following = false }
        if feed == nil { await load() }
        guard let feed, let feedURL else { return }
        let podcast = Podcast(feedURL: feedURL,
                              title: feed.title.isEmpty ? route.showName : feed.title,
                              author: feed.author,
                              summary: feed.summary,
                              artworkURL: feed.artworkURL ?? route.showArtworkURL,
                              category: "")
        context.insert(podcast)
        await EpisodeCatalogue.fill(podcast, from: feed, context: context)
        Haptics.success()
    }
}
