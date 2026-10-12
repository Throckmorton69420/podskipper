import SwiftUI

/// Log Files (Downloads & Storage and Diagnostics both open this one view).
///
/// Pass 35 (his request): each log is its own row — what it is, its date and
/// size — and opens to a readable view with Share. Logs can be selected and
/// removed one, several, or everything older than a date. Logs a store keeps
/// open (timings, background activity, ad-finder attempts) are cleared
/// through that store, which serializes against its own writes, so a log
/// being written is never cut off mid-write or brought back by the next one;
/// iOS reports are removed by name and stay removed when iOS replays them.
struct LogFilesView: View {
    struct LogFile: Identifiable, Hashable, Sendable {
        enum Category: String, CaseIterable, Sendable {
            case timings = "Processing timings"
            case background = "Background activity"
            case finder = "Ad-finder attempts"
            case daily = "iOS daily reports"
            case diagnostic = "iOS crash, hang and disk reports"
            case libraryRecovery = "Library open failures"
            case other = "Other"

            static func of(_ name: String) -> Category {
                switch name {
                case "timings.json": .timings
                case "background.json": .background
                case "finder-attempts.json": .finder
                case "library-recovery.json": .libraryRecovery
                default: name.hasPrefix("daily-") ? .daily : name.hasPrefix("diagnostic-") ? .diagnostic : .other
                }
            }

            /// Logs written all the time by a store: removing one clears it through the store.
            var isLive: Bool { self == .timings || self == .background || self == .finder }
        }

        var id: String { url.lastPathComponent }
        var url: URL
        var name: String { url.lastPathComponent }
        var category: Category
        var date: Date
        var bytes: Int64
    }

    enum Order: String, CaseIterable, Identifiable {
        case newest = "Newest", oldest = "Oldest", largest = "Largest"
        var id: Self { self }
    }

    @State private var files: [LogFile] = []
    @State private var loaded = false
    @State private var filter: LogFile.Category?
    @State private var order: Order = .newest
    @State private var selection = Set<String>()
    @State private var editMode: EditMode = .inactive
    @State private var confirm: Confirmation?
    @State private var note: ResultNote?
    @State private var olderThan = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
    @State private var showsOlderThan = false

    private var visible: [LogFile] {
        let chosen = files.filter { filter == nil || $0.category == filter }
        switch order {
        case .newest: return chosen.sorted { $0.date > $1.date }
        case .oldest: return chosen.sorted { $0.date < $1.date }
        case .largest: return chosen.sorted { $0.bytes > $1.bytes }
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                LabeledContent("Logs on this iPhone", value: "\(files.count) · \(formattedBytes(files.reduce(0) { $0 + $1.bytes }))")
                    .accessibilityIdentifier("diagnostics.logSize")
                Button("Remove Logs Older Than…") { showsOlderThan = true }
                    .accessibilityIdentifier("diagnostics.deleteOlder")
            } footer: {
                Text("Logs record what the app did, for working out problems. Removing them doesn't touch episodes, transcripts, ads found, corrections or settings.")
            }
            if let note { Section { ResultNoteRow(note: note) } }
            Section {
                if loaded && visible.isEmpty { Text("No logs.").foregroundStyle(.secondary) }
                ForEach(visible) { file in
                    NavigationLink(value: file) { row(file) }
                        .tag(file.id)
                        .swipeActions(edge: .trailing) {
                            Button("Remove", role: .destructive) { ask([file]) }
                        }
                        .contextMenu {
                            Button("Share", systemImage: "square.and.arrow.up") { SharePresenter.present([file.url]) }
                            Button("Remove", systemImage: "trash", role: .destructive) { ask([file]) }
                        }
                }
            } header: {
                HStack {
                    Menu {
                        Picker("Show", selection: $filter) {
                            Text("All logs").tag(LogFile.Category?.none)
                            ForEach(LogFile.Category.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                        }
                    } label: {
                        Label(filter?.rawValue ?? "All logs", systemImage: "line.3.horizontal.decrease.circle").font(.footnote)
                    }
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $order) { ForEach(Order.allCases) { Text($0.rawValue).tag($0) } }
                    } label: {
                        Label(order.rawValue, systemImage: "arrow.up.arrow.down").font(.footnote)
                    }
                }
            }
            BottomClearance()
        }
        .navigationTitle("Log Files")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: LogFile.self) { LogFileDetailView(file: $0) }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditModeButton(editMode: $editMode) { selection = [] } }
            if editMode.isEditing {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selection.count == visible.count && !visible.isEmpty ? "Deselect All" : "Select All") {
                        selection = selection.count == visible.count ? [] : Set(visible.map(\.id))
                    }
                }
            }
        }
        .sheet(isPresented: $showsOlderThan) {
            NavigationStack {
                Form {
                    DatePicker("Older than", selection: $olderThan, in: ...Date.now, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                    let count = files.filter { $0.category.isLive || $0.date < olderThan }.count
                    Text("Removes iOS reports from before this date, and the entries before it inside the timings, background and ad-finder logs. \(count) log file\(count == 1 ? "" : "s") are affected.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .navigationTitle("Remove Older Logs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showsOlderThan = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Remove", role: .destructive) {
                            showsOlderThan = false
                            let cutoff = olderThan
                            Task { await removeOlder(than: cutoff) }
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .confirmation($confirm)
        .selectionBar(editMode.isEditing) {
            let chosen = files.filter { selection.contains($0.id) }
            return SelectionActionBar(count: chosen.count, actions: [
                .init(title: "Share", symbol: "square.and.arrow.up") { SharePresenter.present(chosen.map(\.url)) },
                .init(title: "Remove", symbol: "trash") { ask(chosen) },
            ])
        }
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private func row(_ file: LogFile) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(file.category.rawValue).lineLimit(1)
            Text("\(file.name) · \(file.date.formatted(date: .abbreviated, time: .shortened)) · \(formattedBytes(file.bytes))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func ask(_ chosen: [LogFile]) {
        guard !chosen.isEmpty else { return }
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.bytes }
        let live = chosen.filter(\.category.isLive)
        var message = "Removes \(chosen.count == 1 ? chosen[0].name : "\(chosen.count) log files") (\(formattedBytes(bytes)))."
        if !live.isEmpty {
            message += " \(live.map(\.category.rawValue).joined(separator: ", ")) start again empty; the app keeps writing to them."
        }
        confirm = Confirmation(title: chosen.count == 1 ? "Remove this log?" : "Remove \(chosen.count) logs?",
                               message: message, actionTitle: "Remove \(formattedBytes(bytes))") {
            await remove(chosen)
        }
    }

    private func remove(_ chosen: [LogFile]) async {
        var results: [DiagnosticLogCleanupResult] = []
        let categories = Set(chosen.map(\.category))
        if categories.contains(.timings) { results.append(await TimingLog.shared.prune(before: nil)) }
        if categories.contains(.background) { results.append(await BackgroundLog.shared.prune(before: nil)) }
        if categories.contains(.finder) { results.append(await FinderAttemptLog.shared.prune(before: nil)) }
        let reports = Set(chosen.filter { $0.category == .daily || $0.category == .diagnostic }.map(\.name))
        if !reports.isEmpty { results.append(await MetricsSubscriber.shared.remove(names: reports)) }
        let others = chosen.filter { $0.category == .other || $0.category == .libraryRecovery }.map(\.name)
        if !others.isEmpty {
            let deleted = await Task.detached { FileStore.deleteNamedFiles(Set(others), in: Diagnostics.folder, retire: { _ in }) }.value
            results.append(DiagnosticLogCleanupResult(removedFiles: deleted.removed.count, freedBytes: deleted.bytes,
                                                      failures: deleted.failed.sorted()))
        }
        await finish(results, count: chosen.count)
    }

    private func removeOlder(than cutoff: Date) async {
        let results = [await TimingLog.shared.prune(before: cutoff), await BackgroundLog.shared.prune(before: cutoff),
                       await MetricsSubscriber.shared.prune(before: cutoff), await FinderAttemptLog.shared.prune(before: cutoff)]
        let others = files.filter { $0.category == .other && $0.date < cutoff }.map(\.name)
        let deleted = await Task.detached { FileStore.deleteNamedFiles(Set(others), in: Diagnostics.folder, retire: { _ in }) }.value
        await finish(results + [DiagnosticLogCleanupResult(removedFiles: deleted.removed.count, freedBytes: deleted.bytes,
                                                           failures: deleted.failed.sorted())], count: nil)
    }

    private func finish(_ results: [DiagnosticLogCleanupResult], count: Int?) async {
        let before = files.reduce(Int64(0)) { $0 + $1.bytes }
        await refresh()
        let freed = max(0, before - files.reduce(0) { $0 + $1.bytes })
        let failures = results.flatMap(\.failures)
        let removed = count ?? results.reduce(0) { $0 + $1.removedFiles + ($1.removedEntries > 0 ? 1 : 0) }
        note = .freed(freed, removed: max(0, removed - failures.count), noun: "log", failures: failures)
        selection = []
        editMode = .inactive
        if failures.isEmpty { Haptics.success() }
    }

    private func refresh() async {
        files = await Task.detached(priority: .utility) { () -> [LogFile] in
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: Diagnostics.folder,
                                                                      includingPropertiesForKeys: Array(keys))) ?? []
            return urls.compactMap { url in
                guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return nil }
                let name = url.lastPathComponent
                // A report's own time is in its name; the file date is when it was saved.
                var date = v.contentModificationDate ?? .distantPast
                if let stamp = name.split(separator: "-").last?.split(separator: ".").first.flatMap({ Double($0) }),
                   name.hasPrefix("daily-") || name.hasPrefix("diagnostic-") {
                    date = Date(timeIntervalSince1970: stamp)
                }
                return LogFile(url: url, category: .of(name), date: date, bytes: Int64(v.fileSize ?? 0))
            }
        }.value
        selection.formIntersection(Set(files.map(\.id)))
        loaded = true
    }
}

/// One log, readable: JSON pretty-printed, long files shown in part with the
/// whole file available to Share.
struct LogFileDetailView: View {
    let file: LogFilesView.LogFile
    @State private var text: String?
    @State private var truncated = false

    nonisolated static let shownLimit = 400_000

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Kind", value: file.category.rawValue)
                LabeledContent("Date", value: file.date.formatted(date: .abbreviated, time: .standard))
                LabeledContent("Size", value: formattedBytes(file.bytes))
                if truncated {
                    Text("Showing the first part. Share sends the whole file.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Divider()
                if let text {
                    Text(text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                BottomClearance()
            }
            .padding()
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { SharePresenter.present([file.url]) } label: { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share")
            }
        }
        .task {
            let url = file.url
            let (shown, cut) = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
                guard let data = try? Data(contentsOf: url) else { return ("This log couldn't be read.", false) }
                var body = data
                if let object = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                    body = pretty
                }
                let cut = body.count > LogFileDetailView.shownLimit
                let string = String(decoding: body.prefix(LogFileDetailView.shownLimit), as: UTF8.self)
                return (string, cut)
            }.value
            text = shown
            truncated = cut
        }
    }
}
