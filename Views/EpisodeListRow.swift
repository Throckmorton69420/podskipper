import SwiftUI
import SwiftData

/// Pass 44 (his 20 Oct request): one episode row for every list in the app.
///
/// A show's episodes, Latest Episodes, Downloaded, Saved, Stations, Up Next,
/// Activity, and search and people results each had a row of their own —
/// 48 pt covers in Activity, compact rows with a round play button in the
/// collections, the full row on a show page and in Up Next — with different
/// type, spacing, metadata, menus, swipes and ways of choosing several. They
/// now all show the same row (`EpisodeRow`: date line, title, notes, cover,
/// Play pill, Find Ads, ⋯), the same touch-and-hold menu, the same swipes
/// (Apple's: Mark as Played; Save or Unsave; a download's Delete) and the
/// same ticks. A page adds only what is its own: a status line
/// (Up Next's "getting ready", Activity's place in the line, why a job
/// paused, what was found and by which model), the words on Find Ads, and
/// its own way of taking an episode off the page.
struct EpisodeListRow: View {
    let episode: Episode
    /// In a list mixing shows, the show's name leads the row.
    var showsShowName = true
    var yearInDate = true
    var status: EpisodeRowStatus? = nil
    var findAdsTitle: String? = nil
    /// Swipe left, first: the page's own removal ("Remove", "Archive"…).
    var removal: EpisodeRemoval? = nil
    var onPublish: (() -> Void)? = nil
    /// Choosing several, on pages that offer it.
    var choosing: EpisodeChoosing? = nil
    /// After a swipe changed the episode, for a page that lists by it.
    var changed: (() -> Void)? = nil
    @Environment(\.modelContext) private var context

    var body: some View {
        if let choosing, choosing.isActive {
            SelectionRow(isSelected: choosing.isSelected, drag: choosing.drag, toggle: choosing.toggle) {
                row
            }
            .accessibilityIdentifier("SelectableEpisode")
            .contentRow()
        } else {
            row
                .contentRow()
                .swipeActions(edge: .leading) { leading }
                .swipeActions(edge: .trailing) { trailing }
        }
    }

    private var row: EpisodeRow {
        EpisodeRow(episode: episode, onSelect: choosing?.begin, onPublish: onPublish,
                   showsShowName: showsShowName, status: status, findAdsTitle: findAdsTitle,
                   yearInDate: yearInDate)
    }

    // The same swipes everywhere, as Apple Podcasts has them (27.2 b2:
    // "Mark as Played", "Save", "Unsave", "Delete"): right to mark it played,
    // left for the page's own removal and Save. Play Next is in the menu.

    @ViewBuilder
    private var leading: some View {
        Button {
            Feel.confirm.play()
            // As Mark as Played does everywhere: played leaves Up Next.
            episode.isPlayed.toggle()
            if episode.isPlayed { episode.isNew = false; episode.isInQueue = false }
            try? context.save()
            if let podcast = episode.podcast { CountsCache.invalidate(podcast) }
            LibraryTotals.shared.invalidate()
            changed?()
        } label: {
            Label(episode.isPlayed ? "Mark as Unplayed" : "Mark as Played",
                  systemImage: episode.isPlayed ? "circle" : "checkmark.circle")
        }
        .tint(.blue)
    }

    @ViewBuilder
    private var trailing: some View {
        if let removal {
            Button(role: removal.isDestructive ? .destructive : nil) {
                Feel.warning.play()
                removal.action()
                changed?()
            } label: { Label(removal.title, systemImage: removal.systemImage) }
        }
        if removal?.title != "Unsave" {
            Button {
                Feel.confirm.play()
                episode.isStarred.toggle()
                try? context.save()
                LibraryTotals.shared.invalidate()
                changed?()
            } label: {
                Label(episode.isStarred ? "Unsave" : "Save", systemImage: episode.isStarred ? "star.slash" : "star")
            }
            .tint(.orange)
        }
    }
}

/// What a page has to say about one episode, under its notes.
struct EpisodeRowStatus: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case plain, working, warning, done }
    var text: String
    var symbol: String
    var tone: Tone = .plain

    /// Up Next: one of the next few being got ready.
    static func gettingReady(_ text: String) -> EpisodeRowStatus {
        EpisodeRowStatus(text: text, symbol: "sparkles", tone: .working)
    }
}

struct EpisodeRowStatusLine: View {
    let status: EpisodeRowStatus

    var body: some View {
        // Icon and words together, as the date line's marks are (a Label's
        // icon column left a wide gap at this size).
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: status.symbol)
            Text(status.text).lineLimit(2)
        }
        .font(.system(size: Metrics.metaSize, weight: .medium))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("EpisodeStatus")
    }

    private var color: Color {
        switch status.tone {
        case .plain: .secondary
        case .working: Theme.accentWarm
        case .warning: .orange
        case .done: .green
        }
    }
}

/// A page's own way of taking an episode off it.
struct EpisodeRemoval {
    var title: String
    var systemImage: String
    var isDestructive = true
    var action: () -> Void
}

/// Choosing several on a page: whether it is under way, this row's tick,
/// and touch-and-hold › Select starting it with this row.
struct EpisodeChoosing {
    var isActive: Bool
    var isSelected: Bool
    var drag: SelectionDrag.Handle?
    var toggle: () -> Void
    var begin: () -> Void
}
