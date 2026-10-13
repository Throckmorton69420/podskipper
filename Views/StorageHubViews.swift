import SwiftData
import SwiftUI

/// Tidy Up (Settings → Downloads & Storage).
///
/// Pass 35 (his 9 Oct phone): "Tidy up now" removed things at once and then
/// showed its count in the OPML import's alert — titled "Import". Now it
/// scans first, shows what it found by kind with sizes, lets each kind be
/// left out, removes only what it showed, and says what was actually freed.
/// It only ever offers what is safe by kind: downloads your own rules say can
/// go, stopped model downloads, and scratch files nothing is using. Models,
/// transcripts, compiled model copies and unidentified files are left to
/// their own screens.
struct TidyUpView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    struct EpisodeLine: Identifiable { let id: String; let title: String; let bytes: Int64; let reason: String }

    @State private var episodes: [EpisodeLine] = []
    @State private var report: ModelStorage.Report?
    @State private var includeEpisodes = true
    @State private var includePartials = true
    @State private var includedKinds = Set(ModelStorage.ScratchEntry.Kind.allCases.filter(\.safeByKind))
    @State private var working = false
    @State private var result: ResultNote?

    private var scratch: [ModelStorage.ScratchEntry] {
        (report?.tidyEntries ?? []).filter { includedKinds.contains($0.kind) }
    }
    private var total: Int64 {
        (includeEpisodes ? episodes.reduce(0) { $0 + $1.bytes } : 0)
            + (includePartials ? report?.partialBytes ?? 0 : 0)
            + scratch.reduce(0) { $0 + $1.bytes }
    }

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    Section { ResultNoteRow(note: result) }
                } else if let report {
                    Section {
                        LabeledContent("Can be removed", value: formattedBytes(total))
                        FreeSpaceRow(free: report.freeBytes)
                    } footer: {
                        Text("Nothing here is a model, a transcript, the episode that's playing, or anything being worked on.")
                    }
                    Section {
                        Toggle(isOn: $includeEpisodes) {
                            LabeledContent("Downloads your rules remove", value: formattedBytes(episodes.reduce(0) { $0 + $1.bytes }))
                        }
                        .disabled(episodes.isEmpty)
                        ForEach(episodes.prefix(12)) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.subheadline).lineLimit(1)
                                Text("\(formattedBytes(line.bytes)) · \(line.reason)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if episodes.count > 12 { Text("and \(episodes.count - 12) more").font(.caption).foregroundStyle(.secondary) }
                    } footer: {
                        Text(episodes.isEmpty ? "Nothing is past “Delete played after” or over “Keep at most”."
                             : "Played downloads past “Delete played after”, or the oldest played ones over “Keep at most”. Transcripts and ads found stay.")
                    }
                    if report.partialBytes > 0 {
                        Section {
                            Toggle(isOn: $includePartials) {
                                LabeledContent("Stopped model downloads", value: formattedBytes(report.partialBytes))
                            }
                        }
                    }
                    let kinds = Dictionary(grouping: report.tidyEntries, by: \.kind)
                    if !kinds.isEmpty {
                        Section {
                            ForEach(kinds.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                                Toggle(isOn: Binding(get: { includedKinds.contains(kind) },
                                                     set: { if $0 { includedKinds.insert(kind) } else { includedKinds.remove(kind) } })) {
                                    LabeledContent(kind.label, value: formattedBytes(kinds[kind]!.reduce(0) { $0 + $1.bytes }))
                                }
                            }
                        } header: {
                            Text("Temporary files")
                        } footer: {
                            Text("Files in use, written in the last 15 minutes, or not identified are never included. Temporary Files in Models and Caches lists every file.")
                        }
                    }
                } else {
                    Section { HStack { ProgressView(); Text("Looking for what can go…").foregroundStyle(.secondary) } }
                }
            }
            .navigationTitle("Tidy Up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
                if result == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(working ? "Removing…" : "Remove \(formattedBytes(total))", role: .destructive) {
                            Task { await run() }
                        }
                        .disabled(working || total == 0 || report == nil)
                        .accessibilityIdentifier("tidy.run")
                    }
                }
            }
            .task { await scan() }
        }
    }

    private func scan() async {
        let plan = DownloadManager.tidyPlan(context: context, settings: settings) { episode in
            StorageCleanup.audioNames(episode).reduce(Int64(0)) { total, name in
                guard let url = FileStore.directChild(named: name, in: FileStore.episodesDirectory) else { return total }
                return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        episodes = plan.map { EpisodeLine(id: $0.episode.guid, title: $0.episode.title, bytes: $0.bytes, reason: $0.reason) }
        let known = ModelStorage.Known.current()
        report = await Task.detached(priority: .userInitiated) { ModelStorage.measure(known) }.value
    }

    private func run() async {
        guard let report else { return }
        working = true
        defer { working = false }
        let freeBefore = ModelStorage.freeBytes() ?? 0
        var freed: Int64 = 0, removed = 0
        var failures: [String] = []
        if includeEpisodes, !episodes.isEmpty {
            // Exactly the episodes shown, re-checked for use at this moment.
            let ids = Set(episodes.map(\.id))
            let protected = ProcessingPipeline.shared.protectedCleanupGUIDs
                .union([PlayerEngine.shared.currentEpisode?.guid].compactMap { $0 })
            let rows = ((try? context.fetch(StorageCleanup.descriptor())) ?? []).filter { ids.contains($0.guid) }
            for episode in rows {
                guard !protected.contains(episode.guid) else { failures.append("“\(episode.title)” is in use and was kept"); continue }
                let result = DownloadManager.removeFiles(episode, protectedGUIDs: protected)
                freed += result.bytes; removed += result.removed.isEmpty ? 0 : 1
                failures += result.failed.sorted()
            }
            do { try context.save() } catch { failures.append("Couldn't save the library: \(error.localizedDescription)") }
            FileIndex.refresh()
            LibraryTotals.shared.invalidate()
        }
        let partials = includePartials ? report.partials.map(\.url) : []
        let chosenScratch = scratch
        let files = await Task.detached(priority: .userInitiated) { () -> (Int64, Int, [String]) in
            let a = ModelStorage.removeModelFiles(partials)
            let b = ModelStorage.removeScratch(chosenScratch, context: "Tidy Up")
            return (a.freed + b.freed, partials.count + chosenScratch.count - a.failures.count - b.failures.count,
                    a.failures + b.failures)
        }.value
        freed += files.0; removed += files.1; failures += files.2
        let freeAfter = ModelStorage.freeBytes() ?? 0
        var note = ResultNote.freed(freed, removed: removed, noun: "item", failures: failures)
        if freeAfter > freeBefore {
            note.text += " Free on this iPhone: \(formattedBytes(freeAfter))."
        }
        result = note
        BackgroundLog.shared.note("Tidy Up: " + note.text)
        if failures.isEmpty { Haptics.success() } else { Haptics.warning() }
    }
}
