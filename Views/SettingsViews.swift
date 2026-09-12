import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

// MARK: - Settings

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    /// Was `@Query private var allEpisodes: [Episode]`, which loaded the whole
    /// store to draw three numbers and re-ran the reduce on every render.
    @State private var totals = LibraryTotals.shared
    @State private var player = PlayerEngine.shared
    @State private var hasCredentials = R2Credentials.load() != nil
    @State private var storageBytes: Int64 = 0
    @State private var notificationsDenied = false
    @Query private var podcasts: [Podcast]
    @Environment(\.modelContext) private var context
    @State private var showImporter = false
    @State private var exportURL: URL?
    @State private var opmlMessage: String?
    @State private var isImporting = false

    private let seekOptions: [Double] = [10, 15, 30, 45, 60]
    private let storageOptions: [Double] = [2, 4, 8, 16, 32]
    private let retentionOptions: [Int] = [1, 3, 7, 14, 30]
    private let speeds: [Double] = [0.8, 1.0, 1.2, 1.4, 1.5, 1.75, 2.0, 2.5, 3.0]

    // Split into sections. The whole thing as one Form body was 200 lines,
    // which is far past what Swift's type checker will sit through.
    var body: some View {
        List {
            Group {
                statsSection
                playbackSection
                audioSection
                adSection
                processingSection
            }
            Group {
                notificationsSection
                aiSection
                storageSection
                subscriptionsSection
                shortcutsSection
                publishingSection
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Settings")
        .amoledScreen()
        .onAppear {
            storageBytes = ProcessingPipeline.downloadedBytes()
            totals.refresh(context: context, force: true)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "opml") ?? .xml, .xml],
                      allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            Task { await runImport(url) }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var statsSection: some View {
        Group {
            SectionHeader("Since you installed this")
            HStack {
                statTile(value: "\(totalAdCount)", label: "ads removed", tint: Theme.accentHot)
                Divider().frame(height: 34)
                statTile(value: savedText, label: "time saved", tint: .green)
                Divider().frame(height: 34)
                statTile(value: "\(readyCount)", label: "ad-free", tint: Theme.accentWarm)
            }
            .frame(maxWidth: .infinity)
            .contentRow()
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        @Bindable var settings = settings
        Group {
            SectionHeader("Playback")
            Picker("Default speed", selection: $settings.defaultPlaybackSpeed) {
                ForEach(speeds, id: \.self) { Text("\($0, specifier: "%g")×").tag($0) }
            }
            .contentRow()
            Picker("Skip forward", selection: $settings.seekForwardSeconds) {
                ForEach(seekOptions, id: \.self) { Text("\(Int($0))s").tag($0) }
            }
            .contentRow()
            Picker("Skip back", selection: $settings.seekBackwardSeconds) {
                ForEach(seekOptions, id: \.self) { Text("\(Int($0))s").tag($0) }
            }
            .contentRow()
            Toggle("Play next automatically", isOn: $settings.continuousPlayback)
            .contentRow()
            Toggle("Mark played at the end", isOn: $settings.markPlayedAtEnd)
            .contentRow()
        }
    }

    @ViewBuilder
    private var audioSection: some View {
        Group {
            SectionHeader("Audio")
            NavigationLink {
                EffectsView()
            } label: {
                HStack {
                    Text("Effects and equalizer")
                    Spacer()
                    Text(activeEffectsSummary).foregroundStyle(.secondary).font(.caption)
                }
            }
            .contentRow()
        }
    }

    @ViewBuilder
    private var adSection: some View {
        @Bindable var settings = settings
        Group {
            SectionHeader("What to skip")

            // One switch per kind. A sponsor read and a host spending four
            // minutes on their own tour dates are both things you might want
            // gone — and they are not the same decision.
            kindToggle(.ad, isOn: $settings.autoSkipEnabled)
            kindToggle(.selfPromo, isOn: $settings.skipSelfPromo)
            kindToggle(.crossPromo, isOn: $settings.skipCrossPromo)
            kindToggle(.intro, isOn: $settings.skipIntroOutro)

            Text("Every show and every episode can override these — from the ⋯ menu on the show, or on the episode itself.")
                .font(.caption).foregroundStyle(.secondary)
                .contentRow()

            SectionHeader("Accuracy")
            Stepper("Minimum confidence: \(settings.minimumConfidence)",
                    value: $settings.minimumConfidence, in: 0...100, step: 5)
            .contentRow()
            Text("Higher means fewer wrong cuts, but more ads slip through.")
                .font(.caption).foregroundStyle(.secondary)
            .contentRow()
        }
    }

    /// One row per kind: name, what it covers, switch. Changing any of them
    /// rebuilds the jump list immediately, so a switch flipped mid-episode
    /// takes effect on the very next break rather than the next episode.
    private func kindToggle(_ kind: SegmentKind, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                // Spelled out rather than a Label. Squeezed by the switch
                // beside it, `Label` breaks to icon-above-title, so every row
                // read as a stray glyph with a word underneath.
                HStack(spacing: 8) {
                    Image(systemName: kind.symbol)
                        .font(.body)
                        .foregroundStyle(Theme.accentHot)
                        .frame(width: 24, alignment: .leading)
                    Text(kind.name).font(.body)
                }
                Text(kind.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: isOn.wrappedValue) { _, _ in player.refreshSkipRanges() }
        .contentRow()
    }

    @ViewBuilder
    private var processingSection: some View {
        @Bindable var settings = settings
        Group {
            SectionHeader("Processing")
            Toggle("Queue new episodes automatically", isOn: $settings.autoQueueNewEpisodes)
            .contentRow()
            Toggle("Only while charging", isOn: $settings.processOnlyWhileCharging)
            .contentRow()
            Toggle("Measure silence and loudness", isOn: $settings.analyzeSilence)
            .contentRow()
            Text("The silence pass is what Smart Speed and volume normalization run on. It adds about 8% to processing time.")
                .font(.caption).foregroundStyle(.secondary)
            .contentRow()
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        @Bindable var settings = settings
        Group {
            SectionHeader("Notifications")
            Toggle("New episode alerts", isOn: $settings.notificationsEnabled)
                .onChange(of: settings.notificationsEnabled) { _, value in
                    guard value else { return }
                    Task {
                        let granted = await NotificationService.requestPermission()
                        if !granted {
                            notificationsDenied = true
                            settings.notificationsEnabled = false
                        }
                    }
                }
                .contentRow()

            if notificationsDenied {
                Text("iOS declined. Turn notifications on for PodSkipper in the Settings app first.")
                    .font(.caption).foregroundStyle(.orange)
                    .contentRow()
            }

            Text("Choose which shows alert you in each show's own settings.")
                .font(.caption).foregroundStyle(.secondary)
                .contentRow()
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        Group {
            SectionHeader("On-device AI")
            if let reason = AdDetector.availability() {
                Label("Unavailable: \(reason)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("Needs an iPhone with Apple Intelligence turned on.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            Text("The first episode you process downloads a speech model of a few hundred megabytes. Keep the app open on Wi-Fi for that one.")
                .font(.caption).foregroundStyle(.secondary)
            .contentRow()
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        @Bindable var settings = settings
        Group {
            SectionHeader("Storage")
            HStack {
                Text("Downloaded audio")
                Spacer()
                Text(storageText).foregroundStyle(.secondary)
            }
            .contentRow()
            Picker("Keep at most", selection: $settings.storageLimitGB) {
                Text("No limit").tag(0.0)
                ForEach(storageOptions, id: \.self) { Text("\($0, specifier: "%g") GB").tag($0) }
            }
            .contentRow()
            Toggle("Remove played downloads", isOn: $settings.removePlayedDownloads)
                .contentRow()
            Text("Deletes the audio as soon as an episode finishes. The transcript and the ad markers are kept, so re-downloading it later doesn't mean re-analysing it. Individual shows can override this in their own settings.")
                .font(.caption).foregroundStyle(.secondary)
                .contentRow()
            Picker("Delete played after", selection: $settings.deletePlayedAfterDays) {
                Text("Never").tag(0)
                ForEach(retentionOptions, id: \.self) { Text("\($0) days").tag($0) }
            }
            .contentRow()
            Button("Tidy up now") {
                let removed = DownloadManager.tidy(context: context, settings: settings)
                FileIndex.refresh()
                LibraryTotals.shared.invalidate()
                totals.refresh(context: context, force: true)
                storageBytes = ProcessingPipeline.downloadedBytes()
                opmlMessage = removed == 0 ? "Nothing to remove."
                                           : "Freed \(removed) episode\(removed == 1 ? "" : "s")."
            }
            .contentRow()
            Button("Clear downloads", role: .destructive) {
                pipeline.clearDownloads()
                totals.refresh(context: context, force: true)
                storageBytes = ProcessingPipeline.downloadedBytes()
            }
            .contentRow()
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        Group {
            SectionHeader("Subscriptions")
            Button {
                exportURL = try? OPMLService.writeExportFile(podcasts: podcasts)
            } label: {
                Label("Export as OPML", systemImage: "square.and.arrow.up")
            }
            .contentRow()

            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("Share the file", systemImage: "doc.badge.arrow.up")
                }
                .contentRow()
            }
            Button {
                showImporter = true
            } label: {
                HStack {
                    Label("Import OPML", systemImage: "square.and.arrow.down")
                    if isImporting { Spacer(); ProgressView() }
                }
            }
            .disabled(isImporting)
            .contentRow()

            if let opmlMessage {
                Text(opmlMessage).font(.caption).foregroundStyle(.secondary)
                    .contentRow()
            }

            Text("OPML is how every podcast app moves subscriptions in and out. Yours aren't locked in here.")
                .font(.caption).foregroundStyle(.secondary)
                .contentRow()
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        Group {
            SectionHeader("More")
            NavigationLink { StatsView() } label: {
                Label("Statistics and history", systemImage: "chart.bar")
            }
            .contentRow()
            NavigationLink { BookmarksView() } label: {
                Label("Bookmarks", systemImage: "bookmark")
            }
            .contentRow()
            NavigationLink { FiltersView() } label: {
                Label("Playlists", systemImage: "square.stack.3d.up")
            }
            .contentRow()
        }
    }

    @ViewBuilder
    private var publishingSection: some View {
        Group {
            SectionHeader("Publishing to Apple Podcasts")
            NavigationLink {
                R2SettingsView(hasCredentials: $hasCredentials)
            } label: {
                HStack {
                    Text("Cloudflare storage")
                    Spacer()
                    if hasCredentials {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Text("Not set up").foregroundStyle(.secondary)
                    }
                }
            }
            .contentRow()
            Text("Only needed if you want ad-free versions in the Apple Podcasts app, CarPlay, or your Watch.")
                .font(.caption).foregroundStyle(.secondary)
            .contentRow()
        }
    }

    private func runImport(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }
        do {
            let outcome = try await OPMLService.importFile(at: url, into: context)
            var parts = ["Added \(outcome.added)"]
            if outcome.skipped > 0 { parts.append("skipped \(outcome.skipped) already subscribed") }
            if !outcome.failed.isEmpty { parts.append("\(outcome.failed.count) failed") }
            opmlMessage = parts.joined(separator: ", ") + "."
        } catch {
            opmlMessage = error.localizedDescription
        }
    }

    private func statTile(value: String, label: String, tint: Color) -> some View {
        // `.contentRow()` was applied to the two Texts inside here. It is a
        // List *row* modifier, so on nested views it did nothing useful — and
        // now that it also caps width for iPad it would have squeezed the
        // tiles. It belongs on the row, which is where the caller puts it.
        VStack(spacing: 2) {
            Text(value).font(.title3.bold().monospacedDigit()).foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var totalAdCount: Int { totals.adsRemoved }

    private var readyCount: Int { totals.ready }

    private var savedText: String {
        let seconds = totals.secondsSaved
        guard seconds >= 60 else { return "\(Int(seconds))s" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    private var storageText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: storageBytes)
    }

    private var activeEffectsSummary: String {
        var on: [String] = []
        if settings.smartSpeedEnabled { on.append("Smart Speed") }
        if settings.voiceBoostEnabled { on.append("Voice Boost") }
        if settings.equalizerEnabled { on.append("EQ") }
        if on.isEmpty { return "Off" }
        return on.joined(separator: ", ")
    }
}

// MARK: - Cloudflare R2 credentials

struct R2SettingsView: View {
    @Binding var hasCredentials: Bool

    @State private var accountID = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var bucket = "podcasts"
    @State private var publicBaseURL = ""

    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    var body: some View {
        List {
            Section {
                Text("Paste the five values from your Cloudflare account. Step-by-step instructions are in the setup guide.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Account") {
                LabeledField(label: "Account ID",
                             hint: "A long string of letters and numbers",
                             text: $accountID)
            }

            Section("API token") {
                LabeledField(label: "Access Key ID", hint: "", text: $accessKeyID)
                SecureField("Secret Access Key", text: $secretAccessKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section("Bucket") {
                LabeledField(label: "Bucket name",
                             hint: "The name you gave your R2 bucket",
                             text: $bucket)
                LabeledField(label: "Public address",
                             hint: "e.g. https://pods.yourdomain.com",
                             text: $publicBaseURL)
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: statusIsError
                          ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(statusIsError ? .red : .green)
                        .font(.callout)
                }
            }

            Section {
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack {
                        Text("Save and test")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(!isComplete || isTesting)
            }
        }
        .navigationTitle("Cloudflare storage")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .onAppear(perform: loadExisting)
    }

    private var isComplete: Bool {
        !accountID.isEmpty && !accessKeyID.isEmpty && !secretAccessKey.isEmpty
            && !bucket.isEmpty && !publicBaseURL.isEmpty
    }

    private func loadExisting() {
        guard let saved = R2Credentials.load() else { return }
        accountID = saved.accountID
        accessKeyID = saved.accessKeyID
        secretAccessKey = saved.secretAccessKey
        bucket = saved.bucket
        publicBaseURL = saved.publicBaseURL
    }

    /// Saves, then writes a real test file. Far better to find out here than
    /// three hours into a publish.
    private func saveAndTest() async {
        isTesting = true
        statusMessage = nil
        defer { isTesting = false }

        let trimmed = R2Uploader.Credentials(
            accountID: accountID.trimmed,
            accessKeyID: accessKeyID.trimmed,
            secretAccessKey: secretAccessKey.trimmed,
            bucket: bucket.trimmed,
            publicBaseURL: publicBaseURL.trimmed
        )

        do {
            try R2Credentials.save(trimmed)
            hasCredentials = true
        } catch {
            statusIsError = true
            statusMessage = "Couldn't save to the Keychain."
            return
        }

        let uploader = R2Uploader(credentials: trimmed)
        do {
            let url = try await uploader.upload(data: Data("PodSkipper connection test".utf8),
                                                key: "podskipper-test.txt",
                                                contentType: "text/plain")
            try? await uploader.delete(key: "podskipper-test.txt")
            statusIsError = false
            statusMessage = "Working. Files will appear at \(url.host() ?? trimmed.publicBaseURL)."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}

private struct LabeledField: View {
    let label: String
    let hint: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(hint.isEmpty ? label : hint, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
