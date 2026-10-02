import SwiftUI
import SwiftData
import UIKit

/// Changes are held in a draft until Save; dismissing leaves the chapter intact.
struct ChapterEditorView: View {
    let episode: Episode
    let chapter: Chapter?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var time: String
    @State private var artworkURL: String
    @State private var linkURL: String
    @State private var errorMessage: String?
    @State private var confirmsDelete = false
    @State private var keepEmbeddedArtwork = true
    private enum Field: Hashable { case title, time, artwork, link }
    @FocusState private var focusedField: Field?

    init(episode: Episode, chapter: Chapter? = nil) {
        self.episode = episode
        self.chapter = chapter
        // This is an intentional one-time draft for the presented editor.
        _title = State(initialValue: chapter?.title ?? "")
        let player = PlayerEngine.shared
        let start = chapter?.start ?? (player.currentEpisode?.guid == episode.guid ? player.currentTime : 0)
        _time = State(initialValue: ChapterService.timeText(start))
        _artworkURL = State(initialValue: chapter?.imageURL.flatMap { ChapterService.embeddedArtworkURL($0) == nil ? $0 : nil } ?? "")
        _linkURL = State(initialValue: chapter?.linkURL ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("chapter.editor.error")
                    }
                }
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                        .focused($focusedField, equals: .title)
                        .accessibilityIdentifier("chapter.editor.title")
                    TextField("Start time", text: $time)
                        .focused($focusedField, equals: .time)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("chapter.editor.time")
                } header: {
                    Text("Chapter")
                } footer: {
                    Text("Use seconds, minutes:seconds, or hours:minutes:seconds. Chapter times refer to the original episode audio.")
                }
                Section {
                    TextField("Artwork URL", text: $artworkURL)
                        .focused($focusedField, equals: .artwork)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("chapter.editor.artwork")
                    TextField("Link URL", text: $linkURL)
                        .focused($focusedField, equals: .link)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("chapter.editor.link")
                    if let embedded = chapter?.imageURL, ChapterService.embeddedArtworkURL(embedded) != nil {
                        Toggle("Keep Embedded Artwork", isOn: $keepEmbeddedArtwork)
                            .accessibilityIdentifier("chapter.editor.keepArtwork")
                        if keepEmbeddedArtwork, artworkURL.isEmpty {
                            ChapterArtwork(reference: embedded, size: Metrics.artRow)
                                .accessibilityLabel("Embedded chapter artwork preview")
                        }
                    }
                    if let address = ChapterService.webURL(artworkURL) {
                        Artwork(url: address, size: Metrics.artRow)
                            .accessibilityLabel("Chapter artwork preview")
                    }
                } header: {
                    Text("Artwork and Link")
                } footer: {
                    Text("Both addresses are optional. Use a complete http or https address.")
                }
                Section {
                    Text("Your changes stay on this episode when its feed refreshes or its audio is downloaded again.")
                        .foregroundStyle(.secondary)
                }
                if chapter != nil {
                    Section {
                        Button("Delete Chapter", role: .destructive) { confirmsDelete = true }
                            .accessibilityIdentifier("chapter.editor.delete")
                    }
                }
            }
            .onChange(of: title) { _, _ in errorMessage = nil }
            .onChange(of: time) { _, _ in errorMessage = nil }
            .onChange(of: artworkURL) { _, _ in errorMessage = nil }
            .onChange(of: linkURL) { _, _ in errorMessage = nil }
            .onChange(of: keepEmbeddedArtwork) { _, _ in errorMessage = nil }
            .navigationTitle(chapter == nil ? "Add Chapter" : "Edit Chapter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("chapter.editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("chapter.editor.save")
                }
            }
            .confirmationDialog("Delete this chapter?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete This Chapter", role: .destructive) { delete() }
                    .accessibilityIdentifier("chapter.editor.confirmDelete")
            } message: {
                Text("The episode audio and your other chapters will be kept.")
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        do {
            let reference = artworkURL.isEmpty && keepEmbeddedArtwork
                ? chapter?.imageURL.flatMap { ChapterService.embeddedArtworkURL($0) == nil ? nil : $0 } ?? artworkURL
                : artworkURL
            try ChapterService.save(.init(title: title, time: time, imageURL: reference, linkURL: linkURL),
                                    for: episode, editing: chapter, context: context)
            if PlayerEngine.shared.currentEpisode?.guid == episode.guid { PlayerEngine.shared.rebuildJumps() }
            dismiss()
        } catch {
            focusedField = nil
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let chapter else { return }
        do {
            try ChapterService.delete(chapter, from: episode, context: context)
            if PlayerEngine.shared.currentEpisode?.guid == episode.guid { PlayerEngine.shared.rebuildJumps() }
            dismiss()
        } catch {
            focusedField = nil
            errorMessage = error.localizedDescription
        }
    }
}

/// Stable sheet identity, separate from a chapter's editable time and title.
struct ChapterEditorRequest: Identifiable {
    let id = UUID()
    let chapter: Chapter?
}

struct EpisodeChapterRow: View {
    let chapter: Chapter
    let isCurrent: Bool
    let play: () -> Void
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: play) {
                HStack(alignment: .center, spacing: 12) {
                    if let image = chapter.imageURL {
                        ChapterArtwork(reference: image, size: Metrics.artRow)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(chapter.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isCurrent ? Theme.accentHot : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(ChapterService.timeText(chapter.start), systemImage: isCurrent ? "speaker.wave.2.fill" : "play.fill")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(chapter.title) from \(ChapterService.timeText(chapter.start))")
            .accessibilityIdentifier("chapter.play.\(ChapterService.timeText(chapter.start))")
            Menu {
                Button("Edit Chapter", systemImage: "pencil", action: edit)
                if let link = chapter.linkURL.flatMap(ChapterService.webURL).flatMap(URL.init(string:)) {
                    Link(destination: link) { Label("Open Chapter Link", systemImage: "link") }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Actions for \(chapter.title)")
            .accessibilityIdentifier("chapter.actions.\(ChapterService.timeText(chapter.start))")
        }
        .accessibilityElement(children: .contain)
    }
}

/// Uses the shared remote image cache and the same downsampler for locally
/// extracted chapter art. Local references resolve within the restored app,
/// rather than storing an absolute container URL that breaks after reinstall.
private struct ChapterArtwork: View {
    let reference: String
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let url = ChapterService.embeddedArtworkURL(reference) {
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.artCorner(size), style: .continuous)
                        .fill(Theme.surface)
                    if let image { Image(uiImage: image).resizable().scaledToFill() }
                    else { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.artCorner(size), style: .continuous))
                .task(id: reference) {
                    let decoded = await Task.detached(priority: .utility) {
                        guard let bytes = try? Data(contentsOf: url), bytes.count <= 512 * 1_024 else { return nil as UIImage? }
                        return ArtworkStore.downsample(bytes, to: 400)
                    }.value
                    if !Task.isCancelled { image = decoded }
                }
            } else { Artwork(url: reference, size: size) }
        }
    }
}


/// Shared episode and player entry points observe the live chapter relationship.
struct EpisodeChaptersSection: View {
    let episode: Episode
    @Binding var chapterEditor: ChapterEditorRequest?
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @State private var player = PlayerEngine.shared
    @State private var isLoadingChapters = false
    @State private var chapterError: String?
    @State private var chapterLoadTask: Task<Void, Never>?
    private var isCurrent: Bool { player.currentEpisode?.guid == episode.guid }
    private var chapters: [Chapter] { episode.chapters.sorted { $0.start < $1.start } }

    @ViewBuilder
    var body: some View {
        Section {
        SectionHeader("From This Episode")
        if chapters.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No saved chapters")
                    .font(.body.weight(.medium))
                Text(ChapterService.hasLocalEdits(episode.guid)
                     ? "You removed this episode's chapters. Add a chapter to start a new list."
                     : "Load the publisher's chapters or add your own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .contentRow()
        }
        ForEach(chapters) { chapter in
            EpisodeChapterRow(chapter: chapter,
                              isCurrent: isCurrent && player.currentChapter === chapter,
                              play: { playChapter(chapter) },
                              edit: { chapterEditor = .init(chapter: chapter) })
                .contentRow(top: 8, bottom: 8)
        }
        HStack(spacing: 16) {
            Button("Add Chapter", systemImage: "plus") { chapterEditor = .init(chapter: nil) }
                .accessibilityIdentifier("episode.chapters.add")
            if chapters.isEmpty, !ChapterService.hasLocalEdits(episode.guid) {
                Button { loadChapters() } label: {
                    if isLoadingChapters { ProgressView().accessibilityLabel("Loading chapters") }
                    else { Label("Load Chapters", systemImage: "arrow.down") }
                }
                .disabled(isLoadingChapters)
                .accessibilityIdentifier("episode.chapters.load")
            }
        }
        .font(.subheadline)
        .buttonStyle(.borderless)
        .frame(minHeight: 44)
        .contentRow()
        if let chapterError {
            Label(chapterError, systemImage: "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentRow()
                .accessibilityIdentifier("episode.chapters.error")
        }
        }
        .onDisappear { chapterLoadTask?.cancel() }
    }

    private func playChapter(_ chapter: Chapter) {
        PlayCoordinator.play(episode, settings: settings, pipeline: pipeline, startingAt: chapter.start)
    }

    private func loadChapters() {
        chapterLoadTask?.cancel()
        chapterError = nil
        isLoadingChapters = true
        chapterLoadTask = Task {
            defer { isLoadingChapters = false }
            do {
                try await ChapterService.loadPublished(for: episode, context: context)
                if isCurrent { player.rebuildJumps() }
            }
            catch is CancellationError { }
            catch { if !Task.isCancelled { chapterError = error.localizedDescription } }
        }
    }

}

struct ChapterBrowserView: View {
    let episode: Episode
    @State private var chapterEditor: ChapterEditorRequest?
    var body: some View {
        List {
            EpisodeChaptersSection(episode: episode, chapterEditor: $chapterEditor)
            BottomClearance()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Chapters")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .sheet(item: $chapterEditor) { request in
            ChapterEditorView(episode: episode, chapter: request.chapter)
        }
    }
}
