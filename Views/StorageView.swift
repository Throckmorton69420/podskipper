import SwiftData
import SwiftUI

/// Settings → Storage → Downloads and Transcripts: every episode that holds
/// space on the phone, with sizes, and a way to delete what you pick.
///
/// Only files inside the app are ever touched. Sizes are read off the main
/// thread, once per visit.
struct StorageView: View {
    struct Item: Identifiable, Sendable {
        let id: String              // the episode's guid
        let show: String
        let title: String
        let date: Date
        let audioNames: [String]
        let audioBytes: Int64
        let transcriptBytes: Int64
    }

    enum Order: String, CaseIterable { case size = "Size", date = "Date", show = "Show" }
    enum Action { case download, transcript, both }

    @Environment(\.modelContext) private var context
    @State private var items: [Item] = []
    @State private var loading = true
    @State private var order: Order = .size
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var pending: (action: Action, ids: [String])?
    @State private var note: String?

    private var sorted: [Item] {
        switch order {
        case .size: items.sorted { $0.audioBytes + $0.transcriptBytes > $1.audioBytes + $1.transcriptBytes }
        case .date: items.sorted { $0.date > $1.date }
        case .show: items.sorted { ($0.show, $0.title) < ($1.show, $1.title) }
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                LabeledContent("Total", value: bytes(items.reduce(0) { $0 + $1.audioBytes + $1.transcriptBytes }))
                    .accessibilityIdentifier("storage.total")
                LabeledContent("Downloads", value: bytes(items.reduce(0) { $0 + $1.audioBytes }))
                LabeledContent("Transcripts", value: bytes(items.reduce(0) { $0 + $1.transcriptBytes }))
                Picker("Sort by", selection: $order) {
                    ForEach(Order.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("storage.sort")
            } footer: {
                if let note { Text(note) }
            }
            Section {
                if loading {
                    ProgressView()
                } else if items.isEmpty {
                    Text("Nothing is saved on this phone.").foregroundStyle(.secondary)
                }
                ForEach(sorted) { item in
                    row(item)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { pending = (.both, [item.id]) }
                                .accessibilityIdentifier("storage.swipeDelete")
                            if item.audioBytes > 0 {
                                Button("Download") { pending = (.download, [item.id]) }.tint(.orange)
                            }
                        }
                }
            }
        }
        .navigationTitle("Downloads and Transcripts")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().accessibilityIdentifier("storage.edit") }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Menu("Delete") {
                        Button("Delete Download") { pending = (.download, Array(selection)) }
                        Button("Delete Transcript") { pending = (.transcript, Array(selection)) }
                        Button("Delete Both", role: .destructive) { pending = (.both, Array(selection)) }
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("storage.deleteMenu")
                }
            }
        }
        .confirmationDialog(title(for: pending?.action), isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            if let pending {
                Button(confirmLabel(pending.action), role: .destructive) { perform(pending.action, pending.ids) }
                    .accessibilityIdentifier("storage.confirm")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message(for: pending?.action))
        }
        .task { await load() }
        .accessibilityIdentifier("storage.list")
    }

    private func row(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.title).lineLimit(2)
            Text(item.show).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Label(item.audioBytes > 0 ? bytes(item.audioBytes) : "No download", systemImage: "arrow.down.circle")
                Spacer()
                Label(item.transcriptBytes > 0 ? bytes(item.transcriptBytes) : "No transcript", systemImage: "text.alignleft")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("storage.row")
    }

    // MARK: Words

    private func title(for action: Action?) -> String {
        switch action {
        case .download: "Delete the download?"
        case .transcript: "Delete the transcript?"
        case .both: "Delete the download and the transcript?"
        case nil: ""
        }
    }

    private func confirmLabel(_ action: Action) -> String {
        switch action {
        case .download: "Delete Download"
        case .transcript: "Delete Transcript"
        case .both: "Delete Both"
        }
    }

    private func message(for action: Action?) -> String {
        switch action {
        case .download: "Only the audio file goes. The ads found and the transcript stay, and the episode still plays by streaming."
        case .transcript: "The transcript goes. The ads found stay, but finding ads again will need a new transcription."
        case .both: "The audio file and the transcript go. The ads found stay, but finding ads again will need a new download and a new transcription."
        case nil: ""
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    // MARK: Work

    private func load() async {
        loading = true
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate {
            $0.localFilename != nil || $0.extractedAudioFilename != nil || $0.transcriptOnDisk
        })
        descriptor.propertiesToFetch = [\.guid, \.title, \.publishedAt, \.localFilename,
                                        \.extractedAudioFilename, \.transcriptOnDisk]
        let episodes = (try? context.fetch(descriptor)) ?? []
        struct Raw: Sendable { let guid, show, title: String; let date: Date; let names: [String]; let transcript: Bool }
        let raw = episodes.map { e in
            var names = [String]()
            if let n = e.localFilename { names.append(n) }
            if let n = e.extractedAudioFilename, !names.contains(n) { names.append(n) }
            return Raw(guid: e.guid, show: e.podcast?.title ?? "", title: e.title, date: e.publishedAt,
                       names: names, transcript: e.transcriptOnDisk)
        }
        let directory = FileStore.episodesDirectory
        let built: [Item] = await Task.detached(priority: .userInitiated) {
            func size(_ url: URL) -> Int64 {
                Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return raw.compactMap { r in
                let audio = r.names.reduce(Int64(0)) { $0 + size(directory.appendingPathComponent($1)) }
                let transcript = r.transcript ? size(TranscriptStore.url(r.guid)) : 0
                guard audio > 0 || transcript > 0 else { return nil }
                return Item(id: r.guid, show: r.show, title: r.title, date: r.date,
                            audioNames: r.names, audioBytes: audio, transcriptBytes: transcript)
            }
        }.value
        items = built
        loading = false
    }

    private func perform(_ action: Action, _ ids: [String]) {
        let chosen = Set(ids)
        let playing = PlayerEngine.shared.currentEpisode?.guid
        var freed: Int64 = 0, skipped = false
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.localFilename != nil || $0.transcriptOnDisk })
        for episode in (try? context.fetch(descriptor)) ?? [] where chosen.contains(episode.guid) {
            guard let item = items.first(where: { $0.id == episode.guid }) else { continue }
            if action != .transcript {
                if episode.guid == playing { skipped = true } else {
                    freed += item.audioBytes
                    DownloadManager.remove(episode)
                }
            }
            if action != .download, episode.hasTranscript {
                freed += item.transcriptBytes
                try? FileManager.default.removeItem(at: TranscriptStore.url(episode.guid))
                episode.transcriptOnDisk = false
                episode.transcriptData = nil
                DerivedCache.clear(episode.guid)
            }
        }
        try? context.save()
        FileIndex.refresh()
        LibraryTotals.shared.invalidate()
        selection = []
        Haptics.success()
        note = "Freed \(bytes(freed))." + (skipped ? " The episode that's playing was kept." : "")
        Task { await load() }
    }
}

/// The Diagnostics folder's size and "Delete Older Logs". Lives in its own
/// file so `DiagnosticsView` only needs one line: `DiagnosticsLogsSection()`.
/// The self-test line and the breadcrumb window are settings, kept.
struct DiagnosticsLogsSection: View {
    enum Age: Int, Identifiable {
        case day = 1, week = 7, all = 0
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .day: "Older than 1 day"
            case .week: "Older than 7 days"
            case .all: "All logs"
            }
        }
    }

    @State private var size: Int64 = 0
    @State private var count = 0
    @State private var confirming: Age?
    @State private var result: String?

    var body: some View {
        Section {
            LabeledContent("Logs on this phone", value: "\(count) file\(count == 1 ? "" : "s"), \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))")
                .accessibilityIdentifier("diagnostics.logSize")
            Menu("Delete Older Logs") {
                ForEach([Age.day, .week, .all]) { age in
                    Button(age.label, role: .destructive) { confirming = age }
                }
            }
            .accessibilityIdentifier("diagnostics.deleteOlder")
        } header: {
            Text("Log files")
        } footer: {
            Text(result ?? "Deletes the saved timings, iOS reports and background log. Settings such as the self-test result aren't touched.")
        }
        .task { await refresh() }
        .confirmationDialog("Delete logs?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            if let age = confirming {
                Button("Delete \(age.label.lowercased())", role: .destructive) { delete(age) }
                    .accessibilityIdentifier("diagnostics.confirmDelete")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Goes: the files in the Diagnostics folder (\(confirming.map { $0.label.lowercased() } ?? "")) — processing timings, reports from iOS and the background log. Stays: your episodes, transcripts and ads found.")
        }
    }

    private func refresh() async {
        let (bytes, files) = await Task.detached(priority: .utility) { () -> (Int64, Int) in
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: Diagnostics.folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return (urls.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }, urls.count)
        }.value
        size = bytes
        count = files
    }

    private func delete(_ age: Age) {
        Task {
            let freed = await Task.detached(priority: .utility) { () -> Int64 in
                let cutoff = Date().addingTimeInterval(-Double(age.rawValue) * 86_400)
                let fm = FileManager.default
                let urls = (try? fm.contentsOfDirectory(
                    at: Diagnostics.folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
                var freed: Int64 = 0
                for url in urls {
                    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    if age != .all, (values?.contentModificationDate ?? .distantPast) >= cutoff { continue }
                    if (try? fm.removeItem(at: url)) != nil { freed += Int64(values?.fileSize ?? 0) }
                }
                return freed
            }.value
            Haptics.success()
            result = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))."
            await refresh()
        }
    }
}
