import SwiftUI
import SwiftData

/// The player's bookmark button.
///
/// Filled, with a count, once this episode has bookmarks — it was an outline
/// whatever happened, so saving one left no trace. A tap saves the moment and
/// asks for a label; holding it opens this episode's bookmarks.
///
/// A hold opens the list without also starting a new bookmark: the button's
/// own tap on release is ignored once the hold has fired.
struct BookmarkButton: View {
    let size: CGFloat
    let onTap: () -> Void
    let onHold: () -> Void

    @Query private var bookmarks: [Bookmark]
    /// Set when a hold fired, so the button's own tap on release is ignored.
    @State private var held = false

    init(episodeGUID: String, size: CGFloat, onTap: @escaping () -> Void, onHold: @escaping () -> Void) {
        self.size = size
        self.onTap = onTap
        self.onHold = onHold
        _bookmarks = Query(filter: #Predicate<Bookmark> { $0.episodeGUID == episodeGUID })
    }

    // The same glass button as its neighbours, so it is the same size.
    //
    // The first version drew its own glass circle to fit the count badge and
    // came out visibly smaller than Audio, Transcript and Star beside it. The
    // badge now sits over the corner of a normal button instead of shrinking
    // it, and the hold is a gesture alongside the button's tap.
    var body: some View {
        Button {
            if held { held = false; return }
            Haptics.select()
            onTap()
        } label: {
            Image(systemName: bookmarks.isEmpty ? "bookmark" : "bookmark.fill")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(bookmarks.isEmpty ? Color.primary : Theme.accentHot)
                .frame(width: size, height: size)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    held = true
                    Haptics.commit()
                    onHold()
                    // If the system cancelled the button's tap instead of
                    // delivering it, do not swallow the next real one.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(700))
                        held = false
                    }
                }
        )
        .overlay(alignment: .topTrailing) {
            if !bookmarks.isEmpty {
                Text("\(bookmarks.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Theme.accentHot))
                    .offset(x: 2, y: -2)
                    .allowsHitTesting(false)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.snappy, value: bookmarks.count)
        .accessibilityLabel(bookmarks.isEmpty ? "Bookmark" : "Bookmark, \(bookmarks.count) saved")
        .accessibilityAction(named: "Show bookmarks") { onHold() }
    }
}

/// This episode's bookmarks: jump to one, label it, add one here.
struct EpisodeBookmarksView: View {
    let episode: Episode

    @Query private var bookmarks: [Bookmark]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared
    @State private var newNote = ""
    @FocusState private var focused: Bool

    init(episode: Episode) {
        self.episode = episode
        let guid = episode.guid
        _bookmarks = Query(filter: #Predicate<Bookmark> { $0.episodeGUID == guid },
                           sort: \Bookmark.timestamp)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    TextField("Label a bookmark at the current spot", text: $newNote)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button(action: add) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Theme.accentHot)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add bookmark")
                }
                .listRowBackground(Color.clear)
            }

            if bookmarks.isEmpty {
                Text("No bookmarks in this episode yet.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else {
                Section("In this episode") {
                    ForEach(bookmarks) { bookmark in
                        BookmarkRow(bookmark: bookmark) {
                            player.seek(to: bookmark.timestamp)
                            Haptics.select()
                        }
                        .listRowBackground(Color.clear)
                        .swipeActions {
                            Button(role: .destructive) {
                                context.delete(bookmark)
                                try? context.save()
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Bookmarks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") { dismiss() }
            }
        }
    }

    private func add() {
        // Read at the moment of adding, never in the body.
        let bookmark = Bookmark(timestamp: player.currentTime,
                                note: newNote.trimmingCharacters(in: .whitespacesAndNewlines),
                                episode: episode)
        context.insert(bookmark)
        try? context.save()
        newNote = ""
        focused = false
        Haptics.toggle(on: true)
    }
}

private struct BookmarkRow: View {
    @Bindable var bookmark: Bookmark
    let jump: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: jump) {
                Label(formatDuration(bookmark.timestamp), systemImage: "play.fill")
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.accentHot)
            }
            .buttonStyle(.glass)
            TextField("Add a label", text: $bookmark.note)
                .font(.subheadline)
                .submitLabel(.done)
        }
    }
}
