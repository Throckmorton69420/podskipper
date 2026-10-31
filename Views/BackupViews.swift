import SwiftData
import SwiftUI
import UIKit

/// What a backup or restore is doing, for the screens that show it (pass 21).
@MainActor
@Observable
final class BackupCenter {
    static let shared = BackupCenter()

    enum State: Equatable {
        case idle
        case working(Double, String)
        case confirm(URL)
        case staged(BackupService.Manifest)
        case failed(String)
    }

    var state: State = .idle
    var includeAudio = false
    /// The backup just made, to share.
    var lastBackup: URL?
    /// What cleanup removed after the last backup, in one line.
    var cleanupNote: String?
    var historyFile: URL?

    var isBusy: Bool { if case .working = state { return true } else { return false } }

    /// `keep`: how many of the app's own backups to keep afterwards, the
    /// new one included (0 keeps all).
    /// Pass 35: `categories` nil = everything (audio by its own switch).
    func backUp(context: ModelContext, keep: Int, categories: Set<BackupCategory>? = nil) {
        guard !isBusy else { return }
        try? context.save()
        ProcessingPipeline.shared.saveCheckpointNow()
        let shows = (try? context.fetchCount(FetchDescriptor<Podcast>())) ?? 0
        let episodes = (try? context.fetchCount(FetchDescriptor<Episode>())) ?? 0
        let parts = categories ?? BackupCategory.everything.union(includeAudio ? [.audio] : [])
        var manifest = BackupService.Manifest(createdAt: .now, build: BuildInfo.commit,
                                              bundleID: Bundle.main.bundleIdentifier ?? "",
                                              shows: shows, episodes: episodes, includesAudio: parts.contains(.audio))
        manifest.categories = BackupCategory.allCases.filter { parts.contains($0) }
        manifest.device = UIDevice.current.name + " · " + Diagnostics.deviceModel
        manifest.appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + BuildInfo.commit + ")"
        state = .working(0, "Starting")
        lastBackup = nil
        cleanupNote = nil
        Task {
            do {
                let file = try await BackupService.make(manifest: manifest) { value, step in
                    Task { @MainActor in BackupCenter.shared.update(value, step) }
                }
                // Only after a backup that worked, so there is always a
                // newer one before an older one goes.
                let cleanup = await Task.detached(priority: .utility) {
                    BackupService.removeOldBackups(keeping: keep, justMade: file)
                }.value
                if let note = cleanup.note {
                    cleanupNote = note
                    BackgroundLog.shared.note("Backup cleanup: \(note)")
                }
                lastBackup = file
                state = .idle
                Haptics.success()
            } catch {
                BackgroundLog.shared.note("Backup failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func update(_ value: Double, _ step: String) {
        if isBusy { state = .working(value, step) }
    }

    /// A backup file picked, or opened from Files: ask first.
    func offer(_ url: URL) { state = .confirm(url) }

    func restore(_ url: URL) {
        state = .working(0, "Unpacking")
        Task {
            do {
                let manifest = try await BackupService.stage(url) { value, step in
                    Task { @MainActor in BackupCenter.shared.update(value, step) }
                }
                state = .staged(manifest)
                BackgroundLog.shared.note("Restore ready: backup of \(manifest.createdAt.formatted()) with \(manifest.shows) shows, \(manifest.episodes) episodes")
                Haptics.success()
            } catch {
                BackgroundLog.shared.note("Restore failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Pass 35: which parts of the staged backup go in.
    func choose(_ categories: Set<BackupCategory>) throws {
        try RestorePlan(categories: categories).save(to: BackupService.staged)
    }

    /// Pass 35: the staged backup is dropped; nothing on the phone changed.
    func cancelStagedRestore() {
        try? FileManager.default.removeItem(at: BackupService.readyMarker)
        try? FileManager.default.removeItem(at: BackupService.staged)
        BackgroundLog.shared.note("Restore cancelled before it was put in place")
        state = .idle
    }

    /// The swap happens as PodSkipper opens, before the library is read,
    /// so it has to close first. He opens it again from the Home Screen.
    func closeToFinish() {
        ProcessingPipeline.shared.saveCheckpointNow()
        exit(0)
    }

    func exportHistory(container: ModelContainer) {
        state = .working(0.3, "Writing your listening history")
        Task {
            do {
                let file = try await BackupService.writeHistory(container: container)
                historyFile = file
                state = .idle
                // Pass 35: offered straight away, and kept as a row to share again.
                SharePresenter.present([file])
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Settings → Backup: make one, restore one, export listening history.
struct BackupSection: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @State private var center = BackupCenter.shared
    @State private var audioBytes: Int64 = 0

    var body: some View {
        Group {
            SectionHeader("Backups")
            Toggle(isOn: $center.includeAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Downloaded Episodes")
                    Text(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file) + " of audio")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("backup.audio")
            .contentRow()
            // On one row: on the section's Group it ran once per row.
            .task(id: Refresh(backup: center.lastBackup, history: center.historyFile, busy: center.isBusy, tick: tick)) {
                stored = await Task.detached(priority: .utility) { BackupService.stored() }.value
                audioBytes = ProcessingPipeline.downloadedBytes()
            }
            Button {
                Haptics.select()
                center.backUp(context: context, keep: settings.backupsToKeep)
            } label: {
                HStack {
                    Label("Back Up Everything", systemImage: "externaldrive.badge.plus")
                    if center.isBusy { Spacer(); ProgressView() }
                }
            }
            .disabled(center.isBusy)
            .accessibilityIdentifier("backup.make")
            .contentRow()
            Button {
                showsComposer = true
            } label: {
                Label("Choose What to Back Up…", systemImage: "checklist")
            }
            .disabled(center.isBusy)
            .accessibilityIdentifier("backup.choose")
            .contentRow()
            .sheet(isPresented: $showsComposer) { BackupComposer() }
            if let file = center.lastBackup {
                FileResultRow(url: file).contentRow()
            }
            if let note = center.cleanupNote {
                Text(note)
                    .font(.footnote).foregroundStyle(.secondary)
                    .contentRow()
            }
            keepPicker
            Button {
                DocumentPicker.present(types: [BackupService.type, .data], asCopy: false) { urls in
                    if let url = urls.first { center.offer(url) }
                }
            } label: {
                Label("Restore from Backup…", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(center.isBusy)
            .accessibilityIdentifier("backup.restore")
            .contentRow()
            NavigationLink { ManageBackupsView() } label: {
                LabeledContent {
                    Text("\(stored.backups.count) · \(Self.bytes(stored.total))").monospacedDigit()
                } label: {
                    Label("Manage Backups", systemImage: "archivebox")
                }
            }
            .accessibilityIdentifier("backup.manage")
            .contentRow()
            Text("A backup is one file with your shows, what you've played and how far, stars and bookmarks, transcripts, every ad found and your edits to them, diagnostics and settings. It's saved in the Files app under On My iPhone → PodSkipper. To move to a new copy of PodSkipper, open that copy and choose Restore from Backup (or tap the file in Files).")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentRow()
            Button {
                center.exportHistory(container: context.container)
            } label: {
                Label("Export Listening History (CSV)", systemImage: "tablecells")
            }
            .disabled(center.isBusy)
            .contentRow()
            if let file = center.historyFile {
                // Pass 35: tapping the file shares it (it did nothing on his phone).
                FileResultRow(url: file, onDelete: {
                    try? FileManager.default.removeItem(at: file)
                    center.historyFile = nil
                    tick += 1
                })
                .contentRow()
            }
            if let result = UserDefaults.standard.string(forKey: "lastRestoreResult") {
                Text(result).font(.footnote).foregroundStyle(.secondary).contentRow()
            }
        }
    }

    @State private var stored = BackupService.Stored()
    @Environment(\.askConfirmation) private var ask
    @State private var showsComposer = false
    @State private var tick = 0

    private struct Refresh: Equatable {
        var backup: URL?, history: URL?, busy: Bool, tick: Int
    }

    /// "Keep the newest __ backups".
    private var keepPicker: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Keep the Newest Backups", selection: $settings.backupsToKeep) {
                ForEach(BackupService.keepChoices, id: \.self) { count in
                    Text(count == 0 ? "All" : "\(count)").tag(count)
                }
            }
            .feel(.selection, trigger: settings.backupsToKeep)
            .pickerStyle(.menu)
            Text(settings.backupsToKeep == 0
                 ? "Every backup is kept."
                 : "After each backup, older ones PodSkipper made here are deleted. Copies you saved or shared elsewhere are never touched.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("backup.keep")
        .contentRow()
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

}

/// The card for a restore (asking, unpacking, done) or a backup under way.
/// Laid over the whole app, and over the first-run screens, so a backup
/// opened from Files shows wherever he is.
struct BackupOverlay: View {
    @State private var center = BackupCenter.shared

    var body: some View {
        if center.state != .idle {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { if case .failed = center.state { center.state = .idle } }
                card
                    .padding(22)
                    .frame(maxWidth: 380)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    .padding(24)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var card: some View {
        switch center.state {
        case .idle:
            EmptyView()
        case .working(let value, let step):
            VStack(spacing: 14) {
                Image(systemName: "archivebox").font(.largeTitle).symbolEffect(.pulse)
                Text(step).font(.headline)
                ProgressView(value: value)
                Text("\(Int(value * 100))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        case .confirm(let url):
            VStack(spacing: 14) {
                Image(systemName: "arrow.counterclockwise.circle").font(.largeTitle)
                Text("Restore This Backup?").font(.headline)
                Text(url.deletingPathExtension().lastPathComponent).font(.subheadline).multilineTextAlignment(.center)
                Text("Everything in this copy of PodSkipper is replaced with what's in the backup. The current data is kept once, in case.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack {
                    Button("Cancel") { center.state = .idle }.buttonStyle(.glass)
                    Button("Restore") { center.restore(url) }
                        .buttonStyle(.glassProminent)
                        .accessibilityIdentifier("backup.confirm")
                }
            }
        case .staged(let manifest):
            RestoreInventory(manifest: manifest)
        case .failed(let why):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(why).font(.subheadline).multilineTextAlignment(.center)
                Button("OK") { center.state = .idle }.buttonStyle(.glass)
            }
        }
    }
}


/// Pass 35 (his request): what a backup holds, before anything changes —
/// when and where it was made, each part with its size — and which parts to
/// put in. Parts left out, or not in the backup, keep what is on the phone.
struct RestoreInventory: View {
    let manifest: BackupService.Manifest
    @State private var center = BackupCenter.shared
    @State private var chosen: Set<BackupCategory> = []
    @State private var error: String?

    private var summary: [BackupCategory: BackupCategory.Summary] { BackupCategory.summarize(manifest.files ?? [:]) }
    private var held: [BackupCategory] { BackupCategory.allCases.filter { manifest.holds.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Backup Ready to Restore", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Made \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
                if let device = manifest.device { Text("On " + device) }
                Text("App " + (manifest.appVersion ?? manifest.build))
                Text("\(manifest.shows) shows, \(manifest.episodes) episodes")
            }
            .font(.footnote).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(held) { part in
                        Toggle(isOn: Binding(get: { chosen.contains(part) },
                                             set: { if $0 { chosen.insert(part) } else { chosen.remove(part) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.title + (summary[part].map { " · " + formattedBytes($0.bytes) } ?? ""))
                                    .font(.subheadline.weight(.semibold))
                                Text(part.detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .tint(Theme.accentHot)
                        .accessibilityIdentifier("restore.part." + part.rawValue)
                    }
                    let missing = BackupCategory.allCases.filter { !manifest.holds.contains($0) }
                    if !missing.isEmpty {
                        Text("Not in this backup, so kept as they are: " + missing.map(\.title).joined(separator: ", ") + ".")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 320)
            Text(chosen.isEmpty ? "Choose at least one part."
                 : "Chosen parts replace what is on this iPhone; everything else stays. What is replaced is kept once, so the restore can be undone. PodSkipper closes to put it in place.")
                .font(.footnote).foregroundStyle(.secondary)
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            HStack {
                Button("Cancel Restore", role: .destructive) { center.cancelStagedRestore() }
                    .buttonStyle(.glass)
                Spacer()
                Button("Restore & Close") {
                    do { try center.choose(chosen); center.closeToFinish() }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(.glassProminent)
                .disabled(chosen.isEmpty)
                .accessibilityIdentifier("backup.finish")
            }
            Button("Later (put in next time PodSkipper opens)") {
                do { try center.choose(chosen); center.state = .idle } catch { self.error = error.localizedDescription }
            }
            .font(.footnote)
            .disabled(chosen.isEmpty)
        }
        .onAppear { if chosen.isEmpty { chosen = Set(held) } }
    }
}

/// Pass 35: Back up chosen parts, each with what it takes now.
struct BackupComposer: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var sizes: [BackupCategory: Int64] = [:]
    @State private var chosen = BackupCategory.everything
    @State private var counts: (shows: Int, episodes: Int) = (0, 0)

    private var total: Int64 { chosen.reduce(0) { $0 + (sizes[$1] ?? 0) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Selected", value: formattedBytes(total) + " before compression")
                    FreeSpaceRow(free: ModelStorage.freeBytes())
                } footer: {
                    Text("Library: \(counts.shows) shows and \(counts.episodes) episodes. A backup of some parts restores only those parts; everything else on the phone stays as it is.")
                }
                Section {
                    ForEach(BackupCategory.allCases) { part in
                        Toggle(isOn: Binding(get: { chosen.contains(part) },
                                             set: { if $0 { chosen.insert(part) } else { chosen.remove(part) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(part.title)
                                    Spacer()
                                    Text(sizes[part].map(formattedBytes) ?? "…").foregroundStyle(.secondary).monospacedDigit()
                                }
                                Text(part.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tint(Theme.accentHot)
                        .accessibilityIdentifier("backup.part." + part.rawValue)
                    }
                }
            }
            .navigationTitle("Choose What to Back Up")
            .watchName("Choose What to Back Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Back Up") {
                        BackupCenter.shared.backUp(context: context, keep: settings.backupsToKeep, categories: chosen)
                        dismiss()
                    }
                    .disabled(chosen.isEmpty || BackupCenter.shared.isBusy)
                    .accessibilityIdentifier("backup.composer.make")
                }
            }
            .task {
                counts = ((try? context.fetchCount(FetchDescriptor<Podcast>())) ?? 0,
                          (try? context.fetchCount(FetchDescriptor<Episode>())) ?? 0)
                sizes = await Task.detached(priority: .userInitiated) { BackupService.categorySizes() }.value
            }
        }
    }
}

/// Pass 35: every backup file, and every other kind of stored backup data,
/// each removable on its own; several backups at once with Select.
struct ManageBackupsView: View {
    @State private var center = BackupCenter.shared
    @State private var stored = BackupService.Stored()
    @State private var selection = Set<URL>()
    @State private var editMode: EditMode = .inactive
    @State private var confirm: Confirmation?
    @State private var note: ResultNote?

    var body: some View {
        List(selection: $selection) {
            Section {
                LabeledContent("Stored backup data", value: formattedBytes(stored.total))
            } footer: {
                Text("A backup file is checked as a whole when restored, so parts can't be removed from inside one. To keep a smaller backup, make one of just the parts you want, then delete the larger one.")
            }
            if let note { Section { ResultNoteRow(note: note) } }
            Section("Backup Files") {
                if stored.backups.isEmpty { Text("No backups on this iPhone.").foregroundStyle(.secondary) }
                ForEach(stored.backups, id: \.self) { file in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.deletingPathExtension().lastPathComponent).lineLimit(2)
                        Text(formattedBytes(stored.backupSizes[file] ?? 0)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(file)
                    .swipeActions { Button("Delete", role: .destructive) { askDelete([file]) } }
                    .contextMenu {
                        Button("Share", systemImage: "square.and.arrow.up") { SharePresenter.present([file]) }
                        Button("Restore This Backup", systemImage: "arrow.counterclockwise") { center.offer(file) }
                        Button("Delete", systemImage: "trash", role: .destructive) { askDelete([file]) }
                    }
                }
            }
            Section("Other Stored Data") {
                kindRow(.histories, "Listening-history exports", stored.historyBytes, count: stored.histories.count)
                kindRow(.previous, "Data kept from before your last restore", stored.previousBytes,
                        note: "Lets the last restore be undone by hand. Removing it makes that restore final.")
                kindRow(.staged, stored.restorePending ? "Restore waiting for next launch" : "Unfinished restore", stored.stagedBytes,
                        note: stored.restorePending ? "Removing it cancels that restore." : nil)
                kindRow(.leftovers, "Leftovers from interrupted backups", stored.leftoverBytes)
                kindRow(.trashed, "Deleted in the Files app (Recently Deleted)", stored.trashedBytes)
                kindRow(.strays, "Other backup files in PodSkipper's space", stored.strayBytes, count: stored.strays.count)
            }
            BottomClearance()
        }
        .navigationTitle("Manage Backups")
        .watchName("Manage Backups")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditModeButton(editMode: $editMode) { selection = [] } } }
        .selectionBar(editMode.isEditing) {
            SelectionActionBar(count: selection.count, noun: selection.count == 1 ? "backup selected" : "backups selected", actions: [
                .init(title: "Share", symbol: "square.and.arrow.up") { SharePresenter.present(Array(selection)) },
                .init(title: "Delete", symbol: "trash") { askDelete(Array(selection)) },
            ])
        }
        .confirmation($confirm)
        .task { await refresh() }
        .refreshable { await refresh() }
        // A backup made, a restore staged or cancelled elsewhere: show it.
        .onChange(of: center.state) { Task { await refresh() } }
        .onChange(of: center.lastBackup) { Task { await refresh() } }
        .disabled(center.isBusy)
    }

    @ViewBuilder
    private func kindRow(_ kind: BackupService.StoredKind, _ title: String, _ bytes: Int64, count: Int? = nil, note: String? = nil) -> some View {
        if bytes > 0 || (count ?? 0) > 0 {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title + (count.map { " (\($0))" } ?? ""))
                    Text(formattedBytes(bytes) + (note.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    confirm = Confirmation(title: "Remove \(title.lowercased())?",
                                           message: "Frees \(formattedBytes(bytes)). Your shows, history, transcripts, ads found, settings and downloads stay. " + (note ?? ""),
                                           actionTitle: "Remove \(formattedBytes(bytes))") { await remove([kind], backups: nil) }
                }
                .buttonStyle(.borderless)
            }
            .selectionDisabled()
        }
    }

    private func askDelete(_ files: [URL]) {
        guard !files.isEmpty else { return }
        let bytes = files.reduce(Int64(0)) { $0 + (stored.backupSizes[$1] ?? 0) }
        confirm = Confirmation(title: files.count == 1 ? "Delete this backup?" : "Delete \(files.count) backups?",
                               message: "Removes \(files.count == 1 ? files[0].deletingPathExtension().lastPathComponent : "\(files.count) backup files") from On My iPhone → PodSkipper (\(formattedBytes(bytes))). Your library isn't touched, and copies you've saved elsewhere stay.",
                               actionTitle: "Delete \(formattedBytes(bytes))") { await remove([.backups], backups: Set(files)) }
    }

    private func remove(_ kinds: Set<BackupService.StoredKind>, backups: Set<URL>?) async {
        let freed = await Task.detached(priority: .userInitiated) {
            BackupService.deleteStoredBackupData(only: kinds, backups: backups)
        }.value
        selection = []
        editMode = .inactive
        await refresh()
        note = ResultNote(text: "Freed \(formattedBytes(freed)).")
        if kinds.contains(.backups) { center.lastBackup = nil }
    }

    private func refresh() async {
        stored = await Task.detached(priority: .utility) { BackupService.stored() }.value
    }
}
