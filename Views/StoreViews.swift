import SwiftUI

// MARK: - Drawing Apple's pages
//
// Each shelf type Apple's servers send is drawn the way the Podcasts app and
// its web player draw it (see `StoreClient` for where the data comes from).
// Sizes were taken from the web player at iPhone width: a hero banner with its
// eyebrow and headline above it; chart covers with a rank number; two-row
// grids of covers; episode charts in columns of three; tall "hero" cards
// coloured from their artwork; wide "bricks"; and the Search tab's grid of
// category tiles.

/// Where a tap on something in a store page goes.
enum StoreLink: Hashable, Identifiable {
    case page(url: String, title: String?)
    case show(StoreItem)
    case shelf(StoreShelf)

    var id: String {
        switch self {
        case .page(let url, _): return "page:" + url
        case .show(let item):   return "show:" + item.id
        case .shelf(let shelf): return "shelf:" + shelf.id
        }
    }

    static func to(_ item: StoreItem) -> StoreLink? {
        switch item.kind {
        case .show, .showHero, .episode:
            return .show(item)
        default:
            if StoreClient.isShowPage(item.destination) { return .show(item) }
            if let url = StoreClient.fetchable(item.destination) {
                return .page(url: url.absoluteString, title: item.title.isEmpty ? nil : item.title)
            }
            return nil
        }
    }
}

/// The screen a store link opens.
struct StoreDestination: View {
    let link: StoreLink

    var body: some View {
        switch link {
        case .page(let url, let title):
            StorePageView(address: url, fallbackTitle: title)
        case .show(let item):
            ShowPreviewView(storeItem: item)
        case .shelf(let shelf):
            StoreSeeAllView(shelf: shelf)
        }
    }
}

// MARK: - A whole page

/// Any podcasts.apple.com page of shelves: a category, a collection, Top
/// Charts, a "More to Discover" tile.
struct StorePageView: View {
    let address: String
    var fallbackTitle: String?

    @State private var page: StorePage?
    @State private var failed: String?
    @State private var link: StoreLink?

    var body: some View {
        List {
            if let page {
                StoreShelves(page: page, skipFirstTitle: false) { link = $0 }
            } else if let failed {
                ContentUnavailableView("Couldn't Load", systemImage: "wifi.exclamationmark",
                                       description: Text(failed))
                    .plainRow(top: 60, bottom: 40)
            } else {
                ProgressView().frame(maxWidth: .infinity).plainRow(top: 80, bottom: 40)
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .amoledScreen()
        .navigationTitle(page?.title ?? fallbackTitle ?? "")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $link) { StoreDestination(link: $0) }
        .task(id: address) { await load(force: false) }
        .refreshable { await load(force: true) }
    }

    private func load(force: Bool) async {
        guard let url = URL(string: address) else { failed = StoreClient.Failure.badAddress.localizedDescription; return }
        if page == nil { page = StoreClient.cached(url) }
        do { page = try await StoreClient.load(url, force: force) }
        catch { if page == nil { failed = error.localizedDescription } }
    }
}

/// "See All" for a shelf whose own page only Apple's apps can open: the same
/// items, as a list.
struct StoreSeeAllView: View {
    let shelf: StoreShelf
    @State private var link: StoreLink?

    var body: some View {
        List {
            ForEach(shelf.items) { item in
                Button { link = StoreLink.to(item) } label: {
                    if item.kind == .episode {
                        StoreEpisodeRow(item: item)
                    } else {
                        StoreListRow(item: item)
                    }
                }
                .buttonStyle(.plain)
                .contentRow(top: 10, bottom: 10)
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .amoledScreen()
        .navigationTitle(shelf.title ?? "")
        .navigationDestination(item: $link) { StoreDestination(link: $0) }
    }
}

// MARK: - Shelves, as rows of a List

/// Every shelf of a page, each as one or more list rows.
struct StoreShelves: View {
    let page: StorePage
    /// New's own title is the navigation title; nothing to skip elsewhere.
    var skipFirstTitle = false
    var open: (StoreLink) -> Void

    var body: some View {
        ForEach(page.shelves) { shelf in
            StoreShelfView(shelf: shelf, open: open)
        }
    }
}

struct StoreShelfView: View {
    let shelf: StoreShelf
    var open: (StoreLink) -> Void

    var body: some View {
        if shelf.kind != .showcase, shelf.kind != .searchLanding,
           shelf.kind != .categoryHeader, let title = shelf.title {
            header(title)
        }
        content
    }

    private func header(_ title: String) -> some View {
        Button {
            if let url = StoreClient.fetchable(shelf.seeAll) {
                open(.page(url: url.absoluteString, title: title))
            } else if shelf.seeAll != nil || shelf.items.count > 6 {
                open(.shelf(shelf))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: Metrics.titleSize, weight: .bold))
                        .foregroundStyle(.primary)
                    if shelf.seeAll != nil || shelf.items.count > 6 {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: UIScale.pt(15), weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                if let subtitle = shelf.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .plainRow(top: Metrics.sectionTop, bottom: 8)
    }

    @ViewBuilder
    private var content: some View {
        switch shelf.kind {
        case .showcase:
            StoreCarousel(items: shelf.items, width: StoreMetrics.heroWidth, spacing: 14) { item in
                ShowcaseCard(item: item)
            } onTap: { open(StoreLink.to($0) ?? .show($0)) }
        case .largeChartLockup, .largeLockup, .channelOrdinal:
            StoreGridShelf(items: shelf.items, rows: shelf.kind == .largeLockup ? shelf.rowsPerColumn : 1,
                           width: StoreMetrics.coverWidth, spacing: 14) { item in
                CoverLockup(item: item, round: shelf.kind == .channelOrdinal)
            } onTap: { item in if let link = StoreLink.to(item) { open(link) } }
        case .episodeChartLockup:
            StoreGridShelf(items: shelf.items, rows: max(1, shelf.rowsPerColumn),
                           width: StoreMetrics.columnWidth, spacing: 16, divided: true) { item in
                StoreEpisodeRow(item: item)
            } onTap: { open(.show($0)) }
        case .episodeHero:
            StoreCarousel(items: shelf.items, width: StoreMetrics.cardWidth, spacing: 12) { item in
                EpisodeHeroCard(item: item)
            } onTap: { open(.show($0)) }
        case .showHero:
            StoreCarousel(items: shelf.items, width: StoreMetrics.showHeroWidth, spacing: 12) { item in
                ShowHeroCard(item: item)
            } onTap: { open(.show($0)) }
        case .brick:
            StoreCarousel(items: shelf.items, width: StoreMetrics.heroWidth, spacing: 12) { item in
                StoreImage(artwork: item.artwork, width: StoreMetrics.heroWidth,
                           height: StoreMetrics.heroWidth / 2.04, corner: 12)
                    .accessibilityLabel(item.title)
            } onTap: { item in if let link = StoreLink.to(item) { open(link) } }
        case .powerswoosh:
            StoreCarousel(items: shelf.items, width: 104, spacing: 16) { item in
                VStack(spacing: 8) {
                    StoreImage(artwork: item.artwork, width: 104, height: 104, corner: 52)
                    Text(item.showTitle ?? item.title)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            } onTap: { item in if let link = StoreLink.to(item) { open(link) } }
        case .searchLanding:
            SearchLandingGrid(items: shelf.items) { item in if let link = StoreLink.to(item) { open(link) } }
        case .categoryHeader:
            if let item = shelf.items.first {
                StoreImage(artwork: item.artwork, width: StoreMetrics.contentWidth,
                           height: StoreMetrics.contentWidth / 2.33, corner: 14)
                    .frame(maxWidth: .infinity)
                    .plainRow(top: 4, bottom: 8)
            }
        case .paragraph:
            if let text = shelf.items.first?.summary {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .plainRow(top: 4, bottom: 12)
            }
        case .unknown:
            // A shelf Apple added after this version was written. Drawn in
            // the nearest familiar style by what it holds, rather than left
            // out: shows as covers, episodes as episode rows, anything else
            // as a list.
            if shelf.items.allSatisfy({ $0.kind == .show || $0.kind == .channel }) {
                StoreGridShelf(items: shelf.items, rows: max(1, shelf.rowsPerColumn),
                               width: StoreMetrics.coverWidth, spacing: 14) { item in
                    CoverLockup(item: item, round: item.kind == .channel)
                } onTap: { item in if let link = StoreLink.to(item) { open(link) } }
            } else if shelf.items.allSatisfy({ $0.kind == .episode }) {
                StoreGridShelf(items: shelf.items, rows: max(1, min(3, shelf.rowsPerColumn)),
                               width: StoreMetrics.columnWidth, spacing: 16, divided: true) { item in
                    StoreEpisodeRow(item: item)
                } onTap: { open(.show($0)) }
            } else {
                ForEach(shelf.items.prefix(8)) { item in
                    Button {
                        if let link = StoreLink.to(item) { open(link) }
                    } label: { StoreListRow(item: item) }
                    .buttonStyle(.plain)
                    .plainRow(top: 4, bottom: 4)
                }
            }
        }
    }
}

// MARK: - Metrics

enum StoreMetrics {
    @MainActor static var screenWidth: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? 402
    }
    @MainActor static var contentWidth: CGFloat {
        min(Metrics.readableMax, screenWidth - Metrics.gutter * 2)
    }
    /// A banner the width of the page less a peek of the next one.
    @MainActor static var heroWidth: CGFloat { min(560, contentWidth - 30) }
    /// Three covers across with the fourth peeking, as on New.
    @MainActor static var coverWidth: CGFloat { min(170, (contentWidth - 28) / 2.75) }
    /// A column of episode rows, most of the width.
    @MainActor static var columnWidth: CGFloat { min(520, contentWidth - 34) }
    @MainActor static var cardWidth: CGFloat { min(320, contentWidth * 0.72) }
    @MainActor static var showHeroWidth: CGFloat { min(260, contentWidth * 0.56) }
}

// MARK: - Building blocks

/// One horizontal row of fixed-width cells.
struct StoreCarousel<Cell: View>: View {
    let items: [StoreItem]
    let width: CGFloat
    var spacing: CGFloat = 14
    @ViewBuilder var cell: (StoreItem) -> Cell
    var onTap: (StoreItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(items) { item in
                    Button { onTap(item) } label: {
                        cell(item).frame(width: width, alignment: .topLeading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Metrics.gutter)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .fullWidthRow()
    }
}

/// Columns of `rows` cells, scrolling sideways — Apple's two-row cover grids
/// and three-row episode charts.
struct StoreGridShelf<Cell: View>: View {
    let items: [StoreItem]
    let rows: Int
    let width: CGFloat
    var spacing: CGFloat = 14
    var divided = false
    @ViewBuilder var cell: (StoreItem) -> Cell
    var onTap: (StoreItem) -> Void

    private var columns: [[StoreItem]] {
        stride(from: 0, to: items.count, by: rows).map { Array(items[$0..<min($0 + rows, items.count)]) }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(columns, id: \.first?.id) { column in
                    VStack(alignment: .leading, spacing: divided ? 0 : 18) {
                        ForEach(Array(column.enumerated()), id: \.element.id) { index, item in
                            Button { onTap(item) } label: {
                                cell(item).frame(width: width, alignment: .topLeading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, divided ? 10 : 0)
                            .overlay(alignment: .bottom) {
                                if divided && index < column.count - 1 {
                                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                                }
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, Metrics.gutter)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollClipDisabled()
        .fullWidthRow()
    }
}

/// A picture from Apple's image server at exactly the size it is drawn.
struct StoreImage: View {
    let artwork: StoreArtwork?
    let width: CGFloat
    let height: CGFloat
    var corner: CGFloat = 8

    @State private var image: UIImage?

    private var address: String? {
        guard let artwork else { return nil }
        let scale = ImageCache.screenScale
        return artwork.url(width: Int(width * scale), height: Int(height * scale))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(artwork?.background.map { Color(hex: $0) } ?? Theme.surface)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                    .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .task(id: address) {
            guard let address else { return }
            if let hit = ImageCache.shared.cached(address, size: max(width, height)) {
                image = hit
                return
            }
            let loaded = await ImageCache.shared.load(address, size: max(width, height))
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// E and TV marks, as Apple puts them beside a caption.
struct StoreBadges: View {
    var explicit: Bool
    var video: Bool

    var body: some View {
        HStack(spacing: 4) {
            if video {
                Image(systemName: "tv").accessibilityLabel("Video")
            }
            if explicit {
                Image(systemName: "e.square.fill").accessibilityLabel("Explicit")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

// MARK: - Cells

/// The banner at the top of New: small capitals, a headline, a wide picture.
struct ShowcaseCard: View {
    let item: StoreItem

    var body: some View {
        let width = StoreMetrics.heroWidth
        VStack(alignment: .leading, spacing: 4) {
            Text(item.eyebrow?.uppercased() ?? " ")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.title)
                .font(.title3)
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .padding(.bottom, 6)
            StoreImage(artwork: item.artwork, width: width, height: width / 1.75, corner: 12)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A cover with its caption: a rank on charts, the genre and how often it
/// updates on the other grids — exactly the lines Apple sends.
struct CoverLockup: View {
    let item: StoreItem
    var round = false

    var body: some View {
        let side = StoreMetrics.coverWidth
        VStack(alignment: .leading, spacing: 3) {
            StoreImage(artwork: item.artwork, width: side, height: side, corner: round ? side / 2 : 8)
                .padding(.bottom, 5)
            if let rank = item.ordinal {
                Text(rank)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(item.title)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                StoreBadges(explicit: item.isExplicit, video: item.isVideo)
            }
            ForEach(item.subtitles.prefix(2), id: \.self) { line in
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(([item.showTitle ?? item.title] + item.subtitles).joined(separator: ", "))
    }
}

/// An episode row as Apple's episode charts draw it.
struct StoreEpisodeRow: View {
    let item: StoreItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StoreImage(artwork: item.artwork, width: 88, height: 88, corner: 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let caption = item.eyebrow { Text(caption) }
                    if item.isExplicit { Text("·"); Image(systemName: "e.square.fill") }
                    if item.isVideo { Text("·"); Image(systemName: "tv") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack {
                    DurationPill(seconds: item.duration)
                    Spacer()
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct DurationPill: View {
    let seconds: Double?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.fill").font(.caption2)
            Text(seconds.map { RelativeDate.duration($0) } ?? "Play")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(Theme.accentHot)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }
}

/// "The Moment" and "Worth the Watch": a card painted in the artwork's own
/// colour, with the show's cover (or, for video, a wide still) at the top.
struct EpisodeHeroCard: View {
    let item: StoreItem

    // Apple sends, with every picture, the colour to paint behind it and the
    // colours of text that reads on top of it. The card uses exactly those —
    // which is why a pale cover gets a pale card with dark writing.
    private var tint: Color { item.artwork?.background.map { Color(hex: $0) } ?? Theme.surface }
    private var primary: Color { item.artwork?.textPrimary.map { Color(hex: $0) } ?? .white }
    private var secondary: Color { item.artwork?.textSecondary.map { Color(hex: $0) } ?? .white.opacity(0.7) }

    var body: some View {
        let width = StoreMetrics.cardWidth
        VStack(alignment: .leading, spacing: 6) {
            if item.isVideo {
                // The episode's own picture, cropped wide by Apple's image
                // server ("sr"), as the web player shows it.
                StoreImage(artwork: item.artwork.map { var wide = $0; wide.crop = "sr"; return wide },
                           width: width, height: width * 0.56, corner: 0)
                    .overlay(alignment: .topTrailing) {
                        Label("Video", systemImage: "tv")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(8)
                    }
            } else {
                StoreImage(artwork: item.icon ?? item.artwork, width: 60, height: 60, corner: 8)
                    .padding([.top, .leading], 14)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if let caption = item.eyebrow { Text(caption) }
                    if item.isExplicit { Text("·"); Image(systemName: "e.square.fill") }
                }
                .font(.caption)
                .foregroundStyle(secondary.opacity(0.85))
                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if item.isVideo, let summary = item.summary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 6)
                HStack {
                    DurationPill(seconds: item.duration)
                        .environment(\.colorScheme, .dark)
                    Spacer()
                    Image(systemName: "ellipsis").foregroundStyle(primary.opacity(0.8))
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(width: width, height: item.isVideo ? width * 0.56 + 170 : 290, alignment: .topLeading)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "New Trailers" and "Essentials": the show's tall editorial art, a line
/// about it, its rating and category, and a Trailer / Latest Episode button.
struct ShowHeroCard: View {
    let item: StoreItem

    private var art: StoreArtwork? { item.uber ?? item.artwork }
    private var tint: Color { art?.background.map { Color(hex: $0) } ?? Theme.surface }
    private var primary: Color { art?.textPrimary.map { Color(hex: $0) } ?? .white }
    private var secondary: Color { art?.textSecondary.map { Color(hex: $0) } ?? .white.opacity(0.65) }

    var body: some View {
        let width = StoreMetrics.showHeroWidth
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                if let uber = item.uber {
                    StoreImage(artwork: uber, width: width, height: width * 0.78, corner: 0)
                } else {
                    StoreImage(artwork: item.artwork, width: width * 0.6, height: width * 0.6, corner: 8)
                        .frame(width: width, height: width * 0.78)
                }
                LinearGradient(colors: [.clear, tint], startPoint: .top, endPoint: .bottom)
                    .frame(height: 40)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let summary = item.summary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(primary)
                        .lineLimit(3, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
                HStack(spacing: 4) {
                    if let rating = item.rating {
                        Image(systemName: "star.fill")
                        Text(String(format: "%.1f", rating))
                        if let count = item.ratingCount { Text("(\(count))") }
                    }
                    if let genre = item.genre {
                        if item.rating != nil { Text("·") }
                        Text(genre)
                    }
                }
                .font(.caption)
                .foregroundStyle(secondary.opacity(0.85))
                .lineLimit(1)
                HStack {
                    if let button = item.buttonTitle {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.caption2)
                            Text(button).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(primary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(primary.opacity(0.18)))
                    }
                    Spacer()
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(primary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(primary.opacity(0.18)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: width, alignment: .topLeading)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
    }
}

/// One line per show in a "See All" list.
struct StoreListRow: View {
    let item: StoreItem

    var body: some View {
        HStack(spacing: 12) {
            StoreImage(artwork: item.artwork, width: 64, height: 64,
                       corner: item.kind == .channel ? 32 : 8)
            VStack(alignment: .leading, spacing: 2) {
                if let rank = item.ordinal {
                    Text(rank).font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                }
                Text(item.showTitle ?? item.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(((item.showTitle != nil && item.showTitle != item.title) ? [item.title] : [])
                     .appending(contentsOf: item.subtitles).joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            StoreBadges(explicit: item.isExplicit, video: item.isVideo)
        }
        .contentShape(Rectangle())
    }
}

private extension Array where Element == String {
    func appending(contentsOf other: [String]) -> [String] { self + other }
}

/// The Search tab before anything is typed: Apple's category tiles, two to a
/// row, each Apple's own picture with its name in the corner.
struct SearchLandingGrid: View {
    let items: [StoreItem]
    var onTap: (StoreItem) -> Void

    var body: some View {
        let spacing: CGFloat = 12
        let tileWidth = (StoreMetrics.contentWidth - spacing) / 2
        let tileHeight = tileWidth / 1.78
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        ForEach(rows, id: \.first?.id) { row in
            HStack(spacing: spacing) {
                ForEach(row) { item in
                    Button { onTap(item) } label: {
                        StoreImage(artwork: item.artwork, width: tileWidth, height: tileHeight, corner: 10)
                            .overlay(alignment: .bottomLeading) {
                                Text(item.title)
                                    .font(.system(size: UIScale.pt(16), weight: .semibold))
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 10)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.title)
                    .accessibilityIdentifier("CategoryTile")
                }
                if row.count == 1 { Spacer(minLength: 0) }
            }
            .plainRow(top: 0, bottom: spacing)
        }
    }
}
