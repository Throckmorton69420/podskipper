import SwiftUI

/// Where catalogue indexing stands, in words: how many shows have their every
/// episode in, which one it is on, and whether the history import is ready.
///
/// Its own small view, so the progress numbers changing re-draw this row and
/// nothing around it.
struct LibraryIndexRow: View {
    /// Settings says what it means for the history import; the Library only
    /// needs the progress.
    var forImport = false
    @State private var status = LibraryIndexStatus.shared

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status.isIndexing, status.showsTotal > 0 {
                    ProgressView(value: Double(status.showsDone), total: Double(status.showsTotal))
                        .tint(Theme.accentHot)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("LibraryIndexRow")
    }

    @ViewBuilder
    private var icon: some View {
        if status.isIndexing {
            ProgressView().controlSize(.small)
        } else if status.pausedReason != nil {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
        } else if status.catalogueComplete {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Image(systemName: "tray.full").foregroundStyle(.secondary)
        }
    }

    private var title: String {
        if status.isIndexing {
            return "Getting every episode · \(status.showsDone) of \(status.showsTotal) shows"
        }
        if let reason = status.pausedReason { return reason }
        if status.catalogueComplete {
            return forImport ? "Ready to import" : "Every episode is in"
        }
        let left = max(0, status.totalShows - status.indexedShows)
        return "\(left) show\(left == 1 ? "" : "s") still to fetch"
    }

    private var detail: String {
        if status.isIndexing {
            var text = status.currentShow.isEmpty ? "" : "Now: \(status.currentShow). "
            if status.episodesAdded > 0 { text += "\(status.episodesAdded.formatted()) episodes added. " }
            text += forImport
                ? "An import started now waits for this to finish, so everything you've played can be matched."
                : "One show at a time, in the background, only while the app is open."
            return text
        }
        if status.pausedReason != nil {
            return "It carries on by itself when it can. \(status.indexedShows) of \(status.totalShows) shows are done."
        }
        if status.catalogueComplete {
            let failed = status.failures.isEmpty ? "" : " \(status.failures.count) couldn't be reached this time and will be tried again."
            return "All \(status.totalShows) shows have their whole back catalogue in PodSkipper.\(failed)"
        }
        return "\(status.indexedShows) of \(status.totalShows) shows have their whole back catalogue in."
    }
}

/// The Library's version: a slim glass line under the title while indexing
/// is under way or paused, gone once it is done.
struct LibraryIndexBanner: View {
    @State private var status = LibraryIndexStatus.shared

    var body: some View {
        if status.isIndexing || status.pausedReason != nil {
            LibraryIndexRow()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}
