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
    @State private var backups: [URL] = []

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
            ForEach(backups, id: \.self) { file in
                Menu {
                    ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button("Restore This Backup", systemImage: "arrow.counterclockwise") { center.offer(file) }
                } label: {
                    Label(file.deletingPathExtension().lastPathComponent, systemImage: "archivebox")
                        .font(.subheadline).lineLimit(1)
                }
                .contentRow(top: 8, bottom: 8)
            }
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
                ShareLink(item: file) {
                    Label("Share \(file.lastPathComponent)", systemImage: "square.and.arrow.up").lineLimit(1)
                }
                .contentRow()
            }
            if let result = UserDefaults.standard.string(forKey: "lastRestoreResult") {
                Text(result).font(.footnote).foregroundStyle(.secondary).contentRow()
            }
        }
        .task(id: center.lastBackup) {
            backups = BackupService.existingBackups()
            audioBytes = ProcessingPipeline.downloadedBytes()
        }
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
