import SwiftData
import SwiftUI

/// One category-specific operation shared by the storage UI and disposable
/// tests. A transcript deletion intentionally discards its resumable text
/// and model-answer caches, while preserving listening history and cuts.
@MainActor
enum StorageCleanup {
    static func descriptor() -> FetchDescriptor<Episode> {
        FetchDescriptor(predicate: #Predicate {
            $0.localFilename != nil || $0.extractedAudioFilename != nil || $0.transcriptOnDisk ||
            $0.transcriptData != nil || $0.transcriptText != nil
        })
    }

    static func inlineTranscriptBytes(_ episode: Episode) -> Int64 {
        Int64(episode.transcriptData?.count ?? 0) + Int64(episode.transcriptText?.utf8.count ?? 0)
    }

    static func audioNames(_ episode: Episode) -> [String] {
        let named = Set([episode.localFilename, episode.extractedAudioFilename].compactMap { $0 })
        return named.union(named.map { MediaExtractor.audioFilename(for: $0) }).sorted()
    }

    struct TranscriptDeletion {
        var bytes: Int64 = 0
        var failed = 0
        var completed = false
        var kept = false
    }

    static func deleteTranscript(_ episode: Episode, transcriptURL: URL? = nil,
                                 checkpointURLs: [URL]? = nil, protectedGUIDs: Set<String>? = nil,
                                 removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                                 invalidate: ((String) -> Bool)? = nil) -> TranscriptDeletion {
        guard !(protectedGUIDs ?? ProcessingPipeline.shared.protectedCleanupGUIDs).contains(episode.guid) else {
            return .init(kept: true)
        }
        var result = TranscriptDeletion()
        let checkpoints = checkpointURLs ?? ([TranscriptCheckpointStore.url(episode.guid)] +
            DetectionCheckpoint.fileURLs(guid: episode.guid))
        for file in checkpoints {
            let deletion = FileStore.deleteNamedFiles([file.lastPathComponent], in: file.deletingLastPathComponent(),
                                                       removeItem: removeItem, retire: { _ in })
            result.bytes += deletion.bytes
            result.failed += deletion.failed.count
        }
        guard result.failed == 0 else { return result }
        guard (invalidate ?? {
            ProcessingPipeline.shared.invalidateDeletedTranscript($0, keepDownloadStage: episode.isDownloaded)
        })(episode.guid) else {
            result.failed += 1; return result
        }
        let file = transcriptURL ?? TranscriptStore.url(episode.guid)
        let deletion = FileStore.deleteNamedFiles([file.lastPathComponent], in: file.deletingLastPathComponent(),
                                                   removeItem: removeItem, retire: { _ in })
        result.bytes += deletion.bytes
        result.failed += deletion.failed.count
        guard deletion.succeeded else { return result }
        result.bytes += inlineTranscriptBytes(episode)
        episode.transcriptOnDisk = false
        episode.transcriptData = nil
        episode.transcriptText = nil
        DerivedCache.clear(episode.guid)
        result.completed = true
        return result
    }
}

/// Settings → Downloads & Storage → Downloaded Episodes: every episode that
/// holds audio or a transcript on the phone.
///
/// Pass 35 (his 9 Oct phone): Edit did nothing (a toolbar EditButton drives
/// the navigation stack's edit mode, not this List's), a long press showed
/// no menu, and audio and transcripts were one undivided list. Now: a type
/// filter separate from the sort, search, Select/Select All, a menu and swipe
/// actions on every row, and for each episode the choice of removing the
/// audio, the transcript or both — always naming what goes and what stays.
/// Only files inside the app are ever touched; sizes are read off the main
/// thread.
struct StorageView: View {
    struct Item: Identifiable, Sendable {
        let id: String              // the episode's guid
        let show: String
        let title: String
        let artwork: String?
        let published: Date
        let duration: Double
        let position: Double
        let played: Bool
        let downloaded: Date?
        let audioNames: [String]
        let audioBytes: Int64
        let transcriptBytes: Int64
        var total: Int64 { audioBytes + transcriptBytes }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case all = "All", audio = "Audio", transcripts = "Transcripts", both = "Both"
        var id: Self { self }
        func includes(_ item: Item) -> Bool {
            switch self {
            case .all: true
            case .audio: item.audioBytes > 0
            case .transcripts: item.transcriptBytes > 0
            case .both: item.audioBytes > 0 && item.transcriptBytes > 0
            }
        }
    }

    enum Order: String, CaseIterable, Identifiable {
        case size = "Size", downloaded = "Date Downloaded", released = "Release Date", show = "Show", title = "Title"
        var id: Self { self }
    }

    enum Action { case download, transcript, both }

    var initialKind: Kind = .all

    @Environment(\.modelContext) private var context
    @State private var items: [Item] = []
    @State private var loading = true
    @State private var kind: Kind = .all
    @State private var order: Order = .size
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var confirm: Confirmation?
    @State private var note: ResultNote?
    @State private var deleting = false
    @State private var protected = Set<String>()
    @State private var appliedInitialKind = false

    private var visible: [Item] {
        let filtered = items.filter { kind.includes($0) && (search.isEmpty
            || $0.title.localizedCaseInsensitiveContains(search) || $0.show.localizedCaseInsensitiveContains(search)) }
        switch order {
        case .size: return filtered.sorted { $0.total > $1.total }
        case .downloaded: return filtered.sorted { ($0.downloaded ?? .distantPast) > ($1.downloaded ?? .distantPast) }
        case .released: return filtered.sorted { $0.published > $1.published }
        case .show: return filtered.sorted { ($0.show, $0.title) < ($1.show, $1.title) }
        case .title: return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                LabeledContent("Audio", value: formattedBytes(items.reduce(0) { $0 + $1.audioBytes }))
                    .accessibilityIdentifier("storage.audioTotal")
                LabeledContent("Transcripts", value: formattedBytes(items.reduce(0) { $0 + $1.transcriptBytes }))
                LabeledContent("Total", value: formattedBytes(items.reduce(0) { $0 + $1.total }))
                    .accessibilityIdentifier("storage.total")
                Picker("Show", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("storage.kind")
            }
            if let note { Section { ResultNoteRow(note: note) } }
            Section {
                if loading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if visible.isEmpty {
                    Text(search.isEmpty ? "Nothing of this kind is saved on this iPhone." : "No episodes match.")
                        .foregroundStyle(.secondary)
                }
                ForEach(visible) { item in
                    row(item)
                        .tag(item.id)
                        .selectionDisabled(protected.contains(item.id))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !protected.contains(item.id) {
                                Button("Remove", role: .destructive) { ask(defaultAction(for: item), [item]) }
                                    .accessibilityIdentifier("storage.swipeDelete")
                            }
                        }
                        .contextMenu { menu(for: [item]) }
                }
            } header: {
                HStack {
                    Text("\(visible.count) episode\(visible.count == 1 ? "" : "s")")
                    Spacer()
                    Menu {
                        Picker("Sort by", selection: $order) {
                            ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Label("Sort: " + order.rawValue, systemImage: "arrow.up.arrow.down")
                            .font(.footnote)
                    }
                    .accessibilityIdentifier("storage.sort")
                }
            }
            BottomClearance()
        }
        .navigationTitle("Downloaded Episodes")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Episodes or shows")
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditModeButton(editMode: $editMode) { selection = [] }
                    .accessibilityIdentifier("storage.edit")
            }
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    let selectable = visible.filter { !protected.contains($0.id) }.map(\.id)
                    Button(Set(selectable).isSubset(of: selection) && !selectable.isEmpty ? "Deselect All" : "Select All") {
                        if Set(selectable).isSubset(of: selection) { selection.subtract(selectable) }
                        else { selection.formUnion(selectable) }
                    }
                    .accessibilityIdentifier("storage.selectAll")
                }
            }
        }
        .confirmation($confirm)
        .selectionBar(editMode.isEditing) {
            let chosen = selectedItems
            return SelectionActionBar(count: chosen.count, noun: chosen.count == 1 ? "episode selected" : "episodes selected", actions: [
                .init(title: "Audio", symbol: "arrow.down.circle", enabled: chosen.contains { $0.audioBytes > 0 }) {
                    ask(.download, chosen.filter { $0.audioBytes > 0 })
                },
                .init(title: "Transcript", symbol: "text.alignleft", enabled: chosen.contains { $0.transcriptBytes > 0 }) {
                    ask(.transcript, chosen.filter { $0.transcriptBytes > 0 })
                },
                .init(title: "Both", symbol: "trash") { ask(.both, chosen) },
            ])
        }
        .task {
            if !appliedInitialKind { kind = initialKind; appliedInitialKind = true }
            await load()
        }
        .disabled(deleting)
        .accessibilityIdentifier("storage.list")
    }

    private var selectedItems: [Item] { items.filter { selection.contains($0.id) && !protected.contains($0.id) } }

    @ViewBuilder
    private func menu(for chosen: [Item]) -> some View {
        let open = chosen.filter { !protected.contains($0.id) }
        let audio = open.filter { $0.audioBytes > 0 }
        let transcripts = open.filter { $0.transcriptBytes > 0 }
        if open.isEmpty {
            Text("In use: playing or being worked on")
        }
        if !audio.isEmpty {
            Button("Remove Audio (\(formattedBytes(audio.reduce(0) { $0 + $1.audioBytes })))", systemImage: "arrow.down.circle") {
                ask(.download, audio)
            }
        }
        if !transcripts.isEmpty {
            Button("Remove Transcript (\(formattedBytes(transcripts.reduce(0) { $0 + $1.transcriptBytes })))", systemImage: "text.alignleft") {
                ask(.transcript, transcripts)
            }
        }
        if !audio.isEmpty && !transcripts.isEmpty {
            Button("Remove Both (\(formattedBytes(open.reduce(0) { $0 + $1.total })))", systemImage: "trash", role: .destructive) {
                ask(.both, open)
            }
        }
    }

    private func defaultAction(for item: Item) -> Action {
        item.audioBytes > 0 && item.transcriptBytes > 0 ? .both : item.audioBytes > 0 ? .download : .transcript
    }

    private func row(_ item: Item) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(url: item.artwork, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.show).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    .foregroundStyle(item.played ? .secondary : .primary)
                Text(meta(item)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 12) {
                    if item.audioBytes > 0 {
                        Label(formattedBytes(item.audioBytes), systemImage: "arrow.down.circle.fill")
                    }
                    if item.transcriptBytes > 0 {
                        Label(formattedBytes(item.transcriptBytes), systemImage: "text.alignleft")
                    }
                    if protected.contains(item.id) {
                        Label("In use", systemImage: "lock.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("storage.row")
    }

    private func meta(_ item: Item) -> String {
        var parts = [RelativeDate.release(item.published)]
        if item.duration > 0 { parts.append(formatDuration(item.duration)) }
        if item.played { parts.append("Played") }
        else if item.position > 30, item.duration > 0 { parts.append("\(Int(item.position / item.duration * 100))% heard") }
        if let downloaded = item.downloaded { parts.append("saved " + downloaded.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Words

    private func ask(_ action: Action, _ chosen: [Item]) {
        guard !chosen.isEmpty else { return }
        let bytes: Int64 = chosen.reduce(0) { total, item in
            switch action {
            case .download: total + item.audioBytes
            case .transcript: total + item.transcriptBytes
            case .both: total + item.total
            }
        }
        let what = chosen.count == 1 ? "“\(chosen[0].title)”" : "\(chosen.count) episodes"
        let title: String
        let message: String
        switch action {
        case .download:
            title = "Remove the audio of \(what)?"
            message = "Goes: the downloaded audio (\(formattedBytes(bytes))). Stays: the transcript, the ads found, your corrections, bookmarks, listening history and position. The episode still plays by streaming, with ads skipped."
        case .transcript:
            title = "Remove the transcript of \(what)?"
            message = "Goes: the transcript and its saved working files (\(formattedBytes(bytes))). Stays: the audio, the ads found, your corrections, bookmarks and history. Finding ads again would need a new transcription."
        case .both:
            title = "Remove the audio and transcript of \(what)?"
            message = "Goes: the downloaded audio and the transcript (\(formattedBytes(bytes))). Stays: the ads found, your corrections, bookmarks, listening history and position. Finding ads again would need a new download and transcription."
        }
        confirm = Confirmation(title: title, message: message, actionTitle: "Remove \(formattedBytes(bytes))") {
            await perform(action, chosen.map(\.id))
        }
    }

    // MARK: Work

    private func load() async {
        loading = items.isEmpty
        protected = ProcessingPipeline.shared.protectedCleanupGUIDs
            .union([PlayerEngine.shared.currentEpisode?.guid].compactMap { $0 })
        var descriptor = StorageCleanup.descriptor()
        descriptor.propertiesToFetch = [\.guid, \.title, \.publishedAt, \.duration, \.artworkURL, \.playbackPosition,
                                        \.isPlayed, \.localFilename, \.extractedAudioFilename, \.transcriptOnDisk,
                                        \.transcriptData, \.transcriptText]
        let episodes = (try? context.fetch(descriptor)) ?? []
        struct Raw: Sendable {
            let guid, show, title: String; let artwork: String?; let date: Date
            let duration, position: Double; let played: Bool; let names: [String]
            let transcript: Bool; let inlineBytes: Int64
        }
        let raw = episodes.map { e in
            Raw(guid: e.guid, show: e.podcast?.title ?? "", title: e.title, artwork: e.artworkURL ?? e.podcast?.artworkURL,
                date: e.publishedAt, duration: e.duration, position: e.playbackPosition, played: e.isPlayed,
                names: StorageCleanup.audioNames(e), transcript: e.transcriptOnDisk,
                inlineBytes: StorageCleanup.inlineTranscriptBytes(e))
        }
        let directory = FileStore.episodesDirectory
        let built: [Item] = await Task.detached(priority: .userInitiated) {
            func values(_ url: URL) -> (Int64, Date?) {
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
                return (Int64(v?.fileSize ?? 0), v?.creationDate)
            }
            return raw.compactMap { r in
                var audio: Int64 = 0
                var saved: Date?
                for name in r.names {
                    guard let url = FileStore.directChild(named: name, in: directory) else { continue }
                    let (bytes, created) = values(url)
                    audio += bytes
                    if let created, created > (saved ?? .distantPast) { saved = created }
                }
                let transcript = r.inlineBytes + (r.transcript ? values(TranscriptStore.url(r.guid)).0 : 0)
                guard audio > 0 || transcript > 0 else { return nil }
                return Item(id: r.guid, show: r.show, title: r.title, artwork: r.artwork, published: r.date,
                            duration: r.duration, position: r.position, played: r.played,
                            downloaded: audio > 0 ? saved : nil, audioNames: r.names,
                            audioBytes: audio, transcriptBytes: transcript)
            }
        }.value
        items = built
        selection.formIntersection(Set(built.map(\.id)))
        loading = false
    }

    private func perform(_ action: Action, _ ids: [String]) async {
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }
        let chosen = Set(ids)
        var removed: Int64 = 0, skipped = 0, failed = 0, done = 0
        let episodes = ((try? context.fetch(StorageCleanup.descriptor())) ?? []).filter { chosen.contains($0.guid) }
        let before = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for (index, episode) in episodes.enumerated() {
            let protected = ProcessingPipeline.shared.protectedCleanupGUIDs
                .union([PlayerEngine.shared.currentEpisode?.guid].compactMap { $0 })
            guard !protected.contains(episode.guid) else { skipped += 1; continue }
            var ok = true
            if action != .transcript {
                let result = DownloadManager.removeFiles(episode, protectedGUIDs: protected)
                failed += result.failed.count
                ok = ok && result.failed.isEmpty
            }
            if action != .download {
                let result = StorageCleanup.deleteTranscript(episode, protectedGUIDs: protected)
                failed += result.failed
                ok = ok && result.failed == 0
            }
            if ok { done += 1 }
            if index % 16 == 15 { await Task.yield() }
        }
        do { try context.save() } catch { failed += 1 }
        LibraryTotals.shared.invalidate()
        await load()
        // What actually went: measured again, not added up from the plan.
        let after = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for id in chosen {
            removed += max(0, (before[id]?.total ?? 0) - (after[id]?.total ?? 0))
        }
        selection = []
        editMode = .inactive
        var failures: [String] = []
        if skipped > 0 { failures.append("\(skipped) in use and kept") }
        if failed > 0 { failures.append("\(failed) file\(failed == 1 ? "" : "s") could not be removed") }
        note = .freed(removed, removed: done, noun: "episode", failures: failures)
        if failed == 0 { Haptics.success() } else { Haptics.warning() }
        BackgroundLog.shared.note("Downloaded Episodes: " + (note?.text ?? ""))
    }
}

/// Diagnostics' way into Log Files. Pass 35: one log manager, the same view
/// Downloads & Storage opens, instead of a second, smaller one here.
struct DiagnosticsLogsSection: View {
    var body: some View {
        Section {
            NavigationLink { LogFilesView() } label: {
                Label("Log Files", systemImage: "doc.text")
            }
            .accessibilityIdentifier("diagnostics.logsLink")
        } footer: {
            Text("Open, share or remove individual logs, or everything older than a date.")
        }
    }
}
