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
        case staged(date: Date, shows: Int, episodes: Int, audio: Bool)
        case failed(String)
    }

    var state: State = .idle
    var includeAudio = false
    /// The backup just made, to share.
    var lastBackup: URL?
    var historyFile: URL?

    var isBusy: Bool { if case .working = state { return true } else { return false } }

    func backUp(context: ModelContext) {
        guard !isBusy else { return }
        try? context.save()
        ProcessingPipeline.shared.saveCheckpointNow()
        let shows = (try? context.fetchCount(FetchDescriptor<Podcast>())) ?? 0
        let episodes = (try? context.fetchCount(FetchDescriptor<Episode>())) ?? 0
        let manifest = BackupService.Manifest(createdAt: .now, build: BuildInfo.commit,
                                              bundleID: Bundle.main.bundleIdentifier ?? "",
                                              shows: shows, episodes: episodes, includesAudio: includeAudio)
        state = .working(0, "Starting")
        lastBackup = nil
        Task {
            do {
                let file = try await BackupService.make(manifest: manifest) { value, step in
                    Task { @MainActor in BackupCenter.shared.update(value, step) }
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
                state = .staged(date: manifest.createdAt, shows: manifest.shows,
                                episodes: manifest.episodes, audio: manifest.includesAudio)
                BackgroundLog.shared.note("Restore ready: backup of \(manifest.createdAt.formatted()) with \(manifest.shows) shows, \(manifest.episodes) episodes")
                Haptics.success()
            } catch {
                BackgroundLog.shared.note("Restore failed: \(error.localizedDescription)")
                state = .failed(error.localizedDescription)
            }
        }
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
                historyFile = try await BackupService.writeHistory(container: container)
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// Settings → Backup: make one, restore one, export listening history.
struct BackupSection: View {
    @Environment(\.modelContext) private var context
    @State private var center = BackupCenter.shared
    @State private var audioBytes: Int64 = 0

    var body: some View {
        Group {
            SectionHeader("Backup")
            Toggle(isOn: $center.includeAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Downloaded Episodes")
                    Text(ByteCountFormatter.string(fromByteCount: audioBytes, countStyle: .file) + " of audio")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("backup.audio")
            .contentRow()
            Button {
                Haptics.select()
                center.backUp(context: context)
            } label: {
                HStack {
                    Label("Back Up Everything", systemImage: "externaldrive.badge.plus")
                    if center.isBusy { Spacer(); ProgressView() }
                }
            }
            .disabled(center.isBusy)
            .accessibilityIdentifier("backup.make")
            .contentRow()
            if let file = center.lastBackup {
                ShareLink(item: file) {
                    Label("Share \(file.lastPathComponent)", systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                }
                .contentRow()
            }
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
            ForEach(stored.backups, id: \.self) { file in
                Menu {
                    ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button("Restore This Backup", systemImage: "arrow.counterclockwise") { center.offer(file) }
                    Divider()
                    Button("Delete This Backup", systemImage: "trash", role: .destructive) { deletingOne = file }
                } label: {
                    HStack {
                        Label(file.deletingPathExtension().lastPathComponent, systemImage: "archivebox")
                            .font(.subheadline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.bytes(stored.backupSizes[file] ?? 0))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .disabled(center.isBusy)
                .contentRow(top: 8, bottom: 8)
            }
            Text("A backup is one file with your shows, what you've played and how far, stars and bookmarks, transcripts, every ad found and your edits to them, diagnostics and settings. It's saved in the Files app under On My iPhone → PodSkipper. To move to a new copy of PodSkipper, open that copy and choose Restore from Backup (or tap the file in Files).")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentRow()
            storedBackupData
            Button {
                center.exportHistory(container: context.container)
            } label: {
                Label("Export Listening History (CSV)", systemImage: "tablecells")
            }
            .disabled(center.isBusy)
            .contentRow()
            if let file = center.historyFile {
                ShareLink(item: file) {
                    Label("Share \(file.lastPathComponent)", systemImage: "square.and.arrow.up").lineLimit(1)
                }
                .contentRow()
            }
            if let result = UserDefaults.standard.string(forKey: "lastRestoreResult") {
                Text(result).font(.footnote).foregroundStyle(.secondary).contentRow()
            }
        }
        .task(id: Refresh(backup: center.lastBackup, history: center.historyFile, busy: center.isBusy, tick: tick)) {
            stored = await Task.detached(priority: .utility) { BackupService.stored() }.value
            audioBytes = ProcessingPipeline.downloadedBytes()
        }
        .confirmationDialog("Delete this backup?", isPresented: Binding(
            get: { deletingOne != nil }, set: { if !$0 { deletingOne = nil } }), titleVisibility: .visible) {
            Button("Delete Backup", role: .destructive) {
                if let file = deletingOne {
                    do { try BackupService.deleteBackup(file) }
                    catch { center.state = .failed(error.localizedDescription) }
                }
                deletingOne = nil
                tick += 1
            }
        } message: {
            Text("\(deletingOne?.deletingPathExtension().lastPathComponent ?? "") is removed from On My iPhone → PodSkipper. Your library, transcripts and downloads are not touched, and neither is any copy you shared or saved somewhere else.")
        }
        .alert("Delete Stored Backup Data?", isPresented: $confirmingAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete \(Self.bytes(stored.total))", role: .destructive) {
                Haptics.select()
                Task {
                    _ = await Task.detached(priority: .userInitiated) { BackupService.deleteStoredBackupData() }.value
                    center.lastBackup = nil
                    center.historyFile = nil
                    tick += 1
                }
            }
        } message: {
            Text(Self.deleteAllMessage(stored))
        }
    }

    @State private var stored = BackupService.Stored()
    @State private var deletingOne: URL?
    @State private var confirmingAll = false
    @State private var tick = 0

    private struct Refresh: Equatable {
        var backup: URL?, history: URL?, busy: Bool, tick: Int
    }

    static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    /// What backups keep on this phone, and one button that removes exactly
    /// that (pass 22). The library, transcripts and downloads are separate:
    /// downloads have their own "Clear downloads" under Storage.
    @ViewBuilder
    private var storedBackupData: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Stored Backup Data")
                Spacer()
                Text(Self.bytes(stored.total)).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(Self.breakdown(stored), id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("backup.stored")
        .contentRow()
        Button(role: .destructive) {
            confirmingAll = true
        } label: {
            Label("Delete Stored Backup Data…", systemImage: "trash")
        }
        .disabled(center.isBusy || stored.isEmpty)
        .accessibilityIdentifier("backup.deleteStored")
        .contentRow()
        Text("Removes only what backups keep on this iPhone: the backup files and listening-history exports in On My iPhone → PodSkipper, the copy of your data kept from before your last restore, and any restore waiting to be put in place. Your shows, history, transcripts, ads found and downloads stay. Copies you shared or saved elsewhere (iCloud Drive, AirDrop, another app) are not touched.")
            .font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .contentRow()
    }

    static func breakdown(_ s: BackupService.Stored) -> [String] {
        var lines: [String] = []
        if !s.backups.isEmpty {
            lines.append("\(s.backups.count) backup file\(s.backups.count == 1 ? "" : "s") · \(bytes(s.backupBytes))")
        }
        if !s.histories.isEmpty {
            lines.append("\(s.histories.count) listening-history export\(s.histories.count == 1 ? "" : "s") · \(bytes(s.historyBytes))")
        }
        if s.previousBytes > 0 { lines.append("Data kept from before your last restore · \(bytes(s.previousBytes))") }
        if s.stagedBytes > 0 {
            lines.append((s.restorePending ? "Restore waiting for next launch" : "Unfinished restore") + " · \(bytes(s.stagedBytes))")
        }
        if s.leftoverBytes > 0 { lines.append("Leftovers from interrupted backups · \(bytes(s.leftoverBytes))") }
        if lines.isEmpty { lines.append("Nothing stored") }
        return lines
    }

    static func deleteAllMessage(_ s: BackupService.Stored) -> String {
        var text = "Deletes: " + breakdown(s).joined(separator: "; ") + "."
        if s.restorePending { text += "\n\nThe restore waiting for the next launch is cancelled." }
        text += "\n\nKept: your shows, listening history, transcripts, ads found, settings and downloads. Copies saved outside PodSkipper are not touched."
        return text
    }
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
        case .staged(let date, let shows, let episodes, let audio):
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                Text("Backup Ready").font(.headline)
                Text("From \(date.formatted(date: .abbreviated, time: .shortened)): \(shows) shows, \(episodes) episodes\(audio ? ", with downloads" : "").")
                    .font(.subheadline).multilineTextAlignment(.center)
                Text("PodSkipper closes to put it in place. Open it again from the Home Screen and everything is there.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Close PodSkipper") { center.closeToFinish() }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("backup.finish")
                Button("Later (it goes in next time PodSkipper opens)") { center.state = .idle }
                    .font(.footnote)
            }
        case .failed(let why):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(why).font(.subheadline).multilineTextAlignment(.center)
                Button("OK") { center.state = .idle }.buttonStyle(.glass)
            }
        }
    }
}
