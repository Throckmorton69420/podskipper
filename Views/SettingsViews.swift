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
    @State private var exportURL: URL?
    @State private var opmlMessage: String?
    @State private var isImporting = false
    /// What the history import is doing right now, in words.
    @State private var importStep: String?
    @State private var sizeDraft: Double?
    @AppStorage(NowPlayingActivityController.enabledKey) private var lockScreenShortcut = false

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
                displaySection
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
                aboutSection
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
        // The result used to be a footnote several rows down a long settings
        // page, which is indistinguishable from nothing having happened.
        .alert("Import", isPresented: Binding(get: { opmlMessage != nil },
                                              set: { if !$0 { opmlMessage = nil } })) {
            Button("OK", role: .cancel) { opmlMessage = nil }
        } message: {
            Text(opmlMessage ?? "")
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

    /// Smaller or larger, everything together: text, icons, covers, buttons
    /// and spacing.
    @ViewBuilder
    private var displaySection: some View {
        @Bindable var settings = settings
        let ids = UIScale.steps.map(\.id)
        let committed = Double(ids.firstIndex(of: settings.interfaceSize) ?? 2)
        // A draft while the finger is down, applied on release: applying
        // rebuilds the whole interface, which would end the drag.
        let index = Binding<Double>(
            get: { sizeDraft ?? committed },
            set: { value in
                let rounded = value.rounded()
                if rounded != (sizeDraft ?? committed) { Haptics.select() }
                sizeDraft = rounded
            })
        let draftName = UIScale.steps[Int(sizeDraft ?? committed)].name
        Group {
            SectionHeader("Display")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Text and Icon Size")
                    Spacer()
                    Text(draftName).foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                    Slider(value: index, in: 0...Double(ids.count - 1), step: 1) { editing in
                        guard !editing, let draft = sizeDraft else { return }
                        sizeDraft = nil
                        let next = ids[min(ids.count - 1, max(0, Int(draft)))]
                        if next != settings.interfaceSize { settings.interfaceSize = next }
                    }
                    .tint(Theme.accentHot)
                    .accessibilityLabel("Text and icon size")
                    .accessibilityValue(draftName)
                    Image(systemName: "textformat.size.larger")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Text("Scales the whole app — text, icons, covers and buttons — in proportion.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .contentRow()
        }
    }

    @ViewBuilder
    private var playbackSection: some View {
        @Bindable var settings = settings
        Group {
            SectionHeader("Playback")
            Toggle(isOn: $lockScreenShortcut) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock Screen Shortcut")
                    Text("A PodSkipper card on the Lock Screen and in the Dynamic Island whenever an episode is loaded, playing or paused, opening straight to the player. Swiping PodSkipper away removes it. Off by default.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .onChange(of: lockScreenShortcut) { _, on in
                if !on { NowPlayingActivityController.shared.end() }
            }
            .contentRow()
            if lockScreenShortcut {
                LockScreenCardPreview()
                    .contentRow()
            }
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
                EffectsView().amoledScreen()
            } label: {
                HStack {
                    Text("Effects and equalizer")
                    Spacer()
                    Text(activeEffectsSummary).foregroundStyle(.secondary).font(.footnote)
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
            // Separate switches now. Losing a ninety-second theme and keeping
            // the credits is a perfectly ordinary thing to want, and one
            // combined switch made it impossible.
            kindToggle(.intro, isOn: $settings.skipIntro)
            kindToggle(.outro, isOn: $settings.skipOutro)

            Toggle(isOn: $settings.keepHostReadAds) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Host-Read Ads")
                    Text("Skip only produced commercials, and hear the ones the hosts read themselves.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .onChange(of: settings.keepHostReadAds) { PlayerEngine.shared.refreshSkipRanges() }
            .contentRow()
            Toggle(isOn: $settings.keepComedyBitAds) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Ads Played for Laughs")
                    Text("When the hosts turn an ad read into a bit, keep it. Applies to episodes whose ads were found from this version on.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .onChange(of: settings.keepComedyBitAds) { PlayerEngine.shared.refreshSkipRanges() }
            .contentRow()

            Text("Every show and every episode can override these — from the ⋯ menu on the show, or on the episode itself.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()

            SectionHeader("How Eager to Be")
            // Was a stepper reading "Minimum confidence: 60", which asked you
            // to have an opinion about a machine-learning score.
            SensitivityPicker(sensitivity: $settings.detectionSensitivity,
                              threshold: $settings.minimumConfidence)

            SectionHeader("Playing")
            Toggle(isOn: $settings.playUnprocessedByDefault) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play straight away").font(.body)
                    Text("Pressing play on an episode whose ads haven't been found starts it anyway, unless you choose to wait.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .contentRow()

            Stepper(value: $settings.preprocessAhead, in: 0...5) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.preprocessAhead == 0
                         ? "Don't prepare episodes ahead"
                         : "Prepare \(settings.preprocessAhead) episode\(settings.preprocessAhead == 1 ? "" : "s") ahead")
                        .font(.body)
                    Text("Finds ads in what's next in Up Next — whenever it changes, when you open the app, and while you listen — so autoplay doesn't stop to think. Up Next shows which ones and how far along they are.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .onChange(of: settings.preprocessAhead) { PrepareAhead.shared.refresh() }
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
                    .font(.footnote)
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
            NavigationLink { AutoDownloadSettingsView() } label: {
                HStack {
                    Text("Automatic Downloads")
                    Spacer()
                    Text(AutoDownload.summary(mode: AutoDownloadMode(rawValue: settings.autoDownloadMode) ?? .off,
                                              limit: AutoDownloadLimit(rawValue: settings.autoDownloadLimit) ?? .recent3))
                        .foregroundStyle(.secondary).font(.footnote).lineLimit(1)
                }
            }
            .contentRow()
            Toggle("Queue new episodes automatically", isOn: $settings.autoQueueNewEpisodes)
            .contentRow()
            Toggle("Only while charging", isOn: $settings.processOnlyWhileCharging)
            .contentRow()
            Toggle("Measure silence and loudness", isOn: $settings.analyzeSilence)
            .contentRow()
            Text("The silence pass is what Smart Speed and volume normalization run on. It adds about 8% to processing time.")
                .font(.footnote).foregroundStyle(.secondary)
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
                    .font(.footnote).foregroundStyle(.orange)
                    .contentRow()
            }

            Text("Choose which shows alert you in each show's own settings.")
                .font(.footnote).foregroundStyle(.secondary)
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
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Label("Ready", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            Text("The first episode you process downloads a speech model of a few hundred megabytes. Keep the app open on Wi-Fi for that one.")
                .font(.footnote).foregroundStyle(.secondary)
            .contentRow()
        }
    }

    /// Which build this is.
    ///
    /// There is no way to tell a sideloaded IPA apart from the three that came
    /// before it, and four successful builds inside an hour is enough to lose
    /// track — which is exactly what happened: fixes were reported as missing
    /// from a build that did not contain them. The commit is stamped in at
    /// build time so a glance settles it.
    private var aboutSection: some View {
        // Wrapped in a Group because this returns two views and carries no
        // `@ViewBuilder` — the sibling sections do the same.
        Group {
        SectionHeader("About")

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Build").font(.body)
                Spacer()
                Text(BuildInfo.commit)
                    .font(.system(size: Metrics.metaSize).monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !BuildInfo.subject.isEmpty {
                Text(BuildInfo.subject)
                    .font(.system(size: Metrics.metaSize))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            Text(BuildInfo.builtAt)
                .font(.system(size: Metrics.metaSize))
                .foregroundStyle(.tertiary)
        }
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
                .font(.footnote).foregroundStyle(.secondary)
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
                // UIKit's picker, presented by UIKit — not `.fileImporter`.
                //
                // Three rounds went into what the SwiftUI importer was allowed
                // to open, and on the phone it still opened a picker in which
                // tapping a file did nothing. The type list was never the
                // problem any more (`.item` was in it). This skips SwiftUI's
                // presentation layer entirely and gives the picker the multiple-
                // selection mode, which is the one with a circle beside each
                // file and an Open button — the thing every other app shows.
                // `asCopy` hands back a private copy, so there is no
                // security-scoped access or iCloud coordination left to fail.
                DocumentPicker.present(types: Self.opmlTypes) { urls in
                    guard !urls.isEmpty else { return }
                    Task {
                        for url in urls { await runImport(url) }
                    }
                }
            } label: {
                HStack {
                    Label("Import OPML", systemImage: "square.and.arrow.down")
                    if isImporting { Spacer(); ProgressView() }
                }
            }
            .disabled(isImporting)
            .contentRow()

            Text("OPML is how every podcast app moves subscriptions in and out. Yours aren't locked in here.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()

            LibraryIndexRow(forImport: true)
                .contentRow()

            Button {
                DocumentPicker.present(types: [.json]) { urls in
                    guard let url = urls.first else { return }
                    Task { await runHistoryImport(url) }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Import Apple Podcasts History", systemImage: "clock.arrow.circlepath")
                        if let importStep {
                            Text(importStep).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if isImporting { Spacer(); ProgressView() }
                }
            }
            .disabled(isImporting)
            .contentRow()

            Text("Marks what you've played in Apple Podcasts as played here, restores where you stopped, and follows any shows you're missing. Apple Podcasts can't export this itself, so it comes from a Mac signed in to the same Apple Account: run export-history.sh from PodSkipper's Tools folder once, and it saves “Apple Podcasts History.json” to iCloud Drive → PodSkipper for you to choose here.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                Label("Stations", systemImage: "square.stack.3d.up")
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
                .font(.footnote).foregroundStyle(.secondary)
            .contentRow()
        }
    }

    /// Everything an OPML file might plausibly be typed as, and then `.item`.
    ///
    /// `.item` is the root of the whole type tree, so with it in the list
    /// nothing in the picker can be dimmed, whatever iOS decided a given file
    /// was. That is deliberate and it is the second half of the fix: the first
    /// attempt reasoned about which type a .opml file *ought* to resolve to,
    /// got it wrong twice, and each wrong answer cost a build and a sideload.
    /// Being permissive here costs nothing, because what the file actually
    /// contains is checked the moment it is read — a file with no `xmlUrl` in
    /// it comes back as "no feeds found in that file" rather than being
    /// prevented from ever being chosen.
    private static var opmlTypes: [UTType] {
        var types: [UTType] = []
        if let declared = UTType("org.opml.opml") { types.append(declared) }
        if let byExtension = UTType(filenameExtension: "opml") { types.append(byExtension) }
        types.append(contentsOf: [.xml, .text, .data, .item])
        return types
    }


    private func runHistoryImport(_ url: URL) async {
        isImporting = true
        defer { isImporting = false; importStep = nil }
        do {
            let data = try OPMLService.readPicked(url)
            guard HistoryImport.isHistoryFile(data) else {
                opmlMessage = "That file isn't an Apple Podcasts history export."
                return
            }
            let outcome = try await HistoryImport.importData(data, into: context) { step in
                importStep = step
            }
            importStep = nil
            opmlMessage = outcome.summary
            Haptics.success()
            PrepareAhead.shared.refresh()
        } catch {
            opmlMessage = "Couldn't read that history file. \(error.localizedDescription)"
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
            Text(label).font(.footnote).foregroundStyle(.secondary)
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
                    .font(.footnote).foregroundStyle(.secondary)
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
            Text(label).font(.footnote).foregroundStyle(.secondary)
            TextField(hint.isEmpty ? label : hint, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Document picker

/// Presents `UIDocumentPickerViewController` from the top-most view
/// controller, outside SwiftUI's presentation system.
@MainActor
enum DocumentPicker {
    private static var delegate: Delegate?

    static func present(types: [UTType], onPick: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        let handler = Delegate(onPick: onPick)
        delegate = handler           // the picker holds its delegate weakly
        picker.delegate = handler
        guard let top = topViewController() else { return }
        top.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    @MainActor
    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            onPick(urls)
            DocumentPicker.delegate = nil
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            DocumentPicker.delegate = nil
        }
    }
}


/// What the Lock Screen card looks like, drawn by the same code the Lock
/// Screen uses, for whatever is loaded now.
struct LockScreenCardPreview: View {
    @State private var player = PlayerEngine.shared
    @State private var artwork: Data?

    var body: some View {
        let episode = player.currentEpisode
        let state = NowPlayingAttributes.ContentState(
            title: episode?.title ?? "An episode title, on up to two lines",
            show: episode?.podcast?.title ?? "Show name",
            isPlaying: false,
            secondsSkipped: episode?.adSecondsRemoved ?? 134,
            endsAt: nil,
            published: episode?.publishedAt ?? .now,
            elapsed: episode?.playbackPosition ?? 900,
            duration: max(1, episode?.duration ?? 3600),
            rate: 1,
            artwork: artwork)
        VStack(alignment: .leading, spacing: 6) {
            Text("On the Lock Screen").font(.footnote).foregroundStyle(.secondary)
            NowPlayingCard(state: state)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .environment(\.colorScheme, .dark)
                .allowsHitTesting(false)
                .accessibilityIdentifier("LockScreenCardPreview")
        }
        .task(id: episode?.guid) {
            guard let url = episode?.artworkURL ?? episode?.podcast?.artworkURL,
                  let image = await ImageCache.shared.load(url, size: 72) else { return }
            artwork = image.jpegData(compressionQuality: 0.6)
        }
    }
}
