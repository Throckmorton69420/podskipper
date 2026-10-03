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
    @State private var coreAILibrary = CoreAIModelLibrary.shared
    @State private var modelStore = ModelStore.shared
    @State private var hasCredentials = R2Credentials.load() != nil
    @State private var storageBytes: Int64 = 0
    @State private var confirmClearDownloads = false
    @State private var clearingDownloads = false
    /// "Removed 3.2 GB", shown in place of the size for a few seconds.
    @State private var storageNote: String?
    @State private var storageHadFailure = false
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
    @AppStorage(ProcessingActivityController.enabledKey) private var processingCard = true

    private let seekOptions: [Double] = [10, 15, 30, 45, 60]
    private let storageOptions: [Double] = [2, 4, 8, 16, 32]
    private let retentionOptions: [Int] = [1, 3, 7, 14, 30]
    private let speeds: [Double] = [0.8, 1.0, 1.2, 1.4, 1.5, 1.75, 2.0, 2.5, 3.0]

    // The top level is a short list of named groups, like iOS Settings; each
    // opens a page with what used to be one very long list. Split into small
    // sections because the whole thing as one body was far past what Swift's
    // type checker will sit through.
    var body: some View {
        List {
            statsSection
            SectionHeader("Settings")
            // Pass 27f (his call): iOS Settings style — a coloured icon
            // tile and a name, nothing else; the detail is one tap in.
            ForEach(SettingsGroup.allCases) { group in
                NavigationLink(value: group) {
                    SettingsGroupLabel(title: group.title, symbol: group.symbol, tint: group.tint)
                }
                .accessibilityIdentifier("settings.group.\(group.rawValue)")
                .accessibilityHint(group.blurb)
                .contentRow()
            }
            NavigationLink { DiagnosticsView() } label: {
                SettingsGroupLabel(title: "Diagnostics", symbol: "stethoscope", tint: .gray)
            }
            .accessibilityIdentifier("DiagnosticsLink")
            .contentRow()
            aboutSection
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsGroup.self) { groupPage($0) }
        .amoledScreen()
        // The activity bar here too (pass 20).
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
        .onAppear {
            storageBytes = ProcessingPipeline.downloadedBytes()
            totals.refresh(context: context, force: true)
        }
    }

    /// One group's page: its sections, with the index down the right edge when
    /// it has more than one to jump between (pass 27e).
    private func groupPage(_ group: SettingsGroup) -> some View {
        ScrollViewReader { proxy in
            List {
                switch group {
                case .display:
                    SettingsJump.anchor(.display); displaySection
                case .playback:
                    SettingsJump.anchor(.audio); audioSection
                    SettingsJump.anchor(.playback); playbackSection
                case .adSkipping:
                    SettingsJump.anchor(.ads); adSection
                    SettingsJump.anchor(.ai); aiSection
                    SettingsJump.anchor(.processing); processingSection
                case .downloads:
                    SettingsJump.anchor(.storage); storageSection
                case .notifications:
                    SettingsJump.anchor(.notifications); notificationsSection
                case .library:
                    SettingsJump.anchor(.subscriptions); subscriptionsSection
                    SettingsJump.anchor(.more); shortcutsSection
                    SettingsJump.anchor(.publishing); publishingSection
                case .backup:
                    SettingsJump.anchor(.backup); BackupSection()
                }
                BottomClearance()
            }
            .listStyle(.plain)
            .environment(\.pageTitle, group.title)
        }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .processingBanner(pipeline, publisher: FeedPublisher.shared)
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
                Text("Scales text, icons, covers and buttons together.")
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
            Toggle(isOn: $settings.resumeAfterInterruption) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Resume After Calls")
                    Text("Carry on after a call, Siri or another app's sound.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .contentRow()
            Toggle(isOn: $lockScreenShortcut) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock Screen Shortcut")
                    Text("A card on the Lock Screen and Dynamic Island that opens the player.")
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
            .feel(.selection, trigger: settings.defaultPlaybackSpeed)
            .contentRow()
            Picker("Skip forward", selection: $settings.seekForwardSeconds) {
                ForEach(seekOptions, id: \.self) { Text("\(Int($0))s").tag($0) }
            }
            .feel(.selection, trigger: settings.seekForwardSeconds)
            .contentRow()
            Picker("Skip back", selection: $settings.seekBackwardSeconds) {
                ForEach(seekOptions, id: \.self) { Text("\(Int($0))s").tag($0) }
            }
            .feel(.selection, trigger: settings.seekBackwardSeconds)
            .contentRow()
            Toggle("Play next automatically", isOn: $settings.continuousPlayback)
            .contentRow()
            Toggle("Mark played at the end", isOn: $settings.markPlayedAtEnd)
            .contentRow()
            Toggle("Always start in video", isOn: $settings.alwaysStartInVideo)
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
            .accessibilityIdentifier("settings.effects")
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
            .onChange(of: settings.keepHostReadAds) {
                PlayerEngine.shared.refreshSkipRanges()
                if settings.keepHostReadAds { ProcessingPipeline.shared.classifyMissingStyles() }
            }
            .contentRow()
            Toggle(isOn: $settings.keepComedyBitAds) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep Ads Played for Laughs")
                    Text("When the hosts turn an ad read into a bit, keep it. Straight reads are still skipped.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .onChange(of: settings.keepComedyBitAds) {
                PlayerEngine.shared.refreshSkipRanges()
                if settings.keepComedyBitAds { ProcessingPipeline.shared.classifyMissingStyles() }
            }
            .contentRow()
            Toggle(isOn: $settings.useAdFreeCopy) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compare with the Ad-Free Copy")
                    Text("Finds ads a host adds on download, using a few small pieces (under 1 MB).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .accessibilityIdentifier("AdFreeCopyToggle")
            .contentRow()

            Text("Any show or episode can override these from its ⋯ menu.")
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
                    Text("Play starts even if the ads haven't been found yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .contentRow()

            Toggle(isOn: $settings.promptSwipeCancels) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swipe the question away to cancel").font(.body)
                    Text("Off: a swipe plays it, like letting the countdown finish.")
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
                    Text("Finds ads in what's next in Up Next so autoplay doesn't stop to think.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .feel(.selection, trigger: settings.preprocessAhead)
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
            NavigationLink(value: ActivityRoute()) {
                HStack {
                    Text("Activity")
                    Spacer()
                    Text(pipeline.isRunning ? "Finding ads" + (pipeline.waitingQueue.isEmpty ? "" : " · \(pipeline.waitingQueue.count) in line") : "Idle")
                        .foregroundStyle(.secondary).font(.footnote).lineLimit(1)
                }
            }
            .contentRow()
            .accessibilityIdentifier("settings.activity")
            // His 27 Sep ask: see on the Lock Screen whether ads are still
            // being found (pass 21).
            Toggle("Show Progress on Lock Screen", isOn: $processingCard)
                .onChange(of: processingCard) { _, on in
                    if on { ProcessingActivityController.shared.jobStarted() }
                    else { ProcessingActivityController.shared.endNow() }
                }
                .contentRow()
            Toggle("Only while charging", isOn: $settings.processOnlyWhileCharging)
            .contentRow()
            Text("Background processing continues while iOS grants time and resources. If interrupted, saved work resumes when processing can continue.")
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("processing.backgroundExplanation")
            .contentRow()
            Toggle("Measure silence and loudness", isOn: $settings.analyzeSilence)
            .contentRow()
            Text("Needed for Smart Speed and volume levelling. Adds about 8% to processing time.")
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
        @Bindable var settings = settings
        let choice = AdFinderChoice(rawValue: settings.adFinder) ?? .apple
        Group {
            SectionHeader("On-device AI")
            Picker("Find ads with", selection: $settings.adFinder) {
                ForEach(AdFinderChoice.allCases) { Text($0.title).tag($0.rawValue) }
            }.feel(.selection, trigger: settings.adFinder).contentRow()
                .accessibilityIdentifier("model.finder")
            Text(choice.explanation).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
                .accessibilityIdentifier("model.finder.description")
            if choice == .coreAI {
                NavigationLink { LocalModelView(mode: .coreAI) } label: {
                    ModelLibrarySettingsLabel(title: "Core AI model library", detail: coreAILibrary.isReady
                        ? (coreAILibrary.selectedEntry?.name ?? "Model") + " · Ready" : "Choose and download")
                }.contentRow().accessibilityIdentifier("model.library.coreAI")
            } else if choice == .model {
                NavigationLink { LocalModelView(mode: .mlx) } label: { LocalModelSettingsLabel() }
                    .contentRow().accessibilityIdentifier("model.library.mlx")
            } else if choice == .apple, let reason = AdDetector.availability() {
                Text(reason + " PodSkipper Reader is available instead.")
                    .font(.subheadline).foregroundStyle(.secondary).contentRow()
            }
            NavigationLink { ModelComparisonView() } label: {
                Label("Compare models", systemImage: "chart.bar.xaxis")
            }.contentRow().accessibilityIdentifier("model.compare")
            Label(SentenceTagger.isBundled ? "Ad reader ready" : "Ad reader missing from this build",
                  systemImage: SentenceTagger.isBundled ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.body).foregroundStyle(SentenceTagger.isBundled ? .green : .orange).contentRow()
            Text("Transcription downloads a separate speech model the first time it is needed. Use Wi-Fi for the initial download.")
                .font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
        }.task { coreAILibrary.load(); modelStore.refreshState() }
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
            SectionHeader("Downloads and Storage")
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
            HStack {
                Text("Downloaded audio")
                Spacer()
                Text(storageText).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .contentRow()
            Picker("Keep at most", selection: $settings.storageLimitGB) {
                Text("No limit").tag(0.0)
                ForEach(storageOptions, id: \.self) { Text("\($0, specifier: "%g") GB").tag($0) }
            }
            .feel(.selection, trigger: settings.storageLimitGB)
            .contentRow()
            Toggle("Remove played downloads", isOn: $settings.removePlayedDownloads)
                .contentRow()
            Text("Keeps the transcript and ad markers. Each show can override this.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()
            Picker("Delete played after", selection: $settings.deletePlayedAfterDays) {
                Text("Never").tag(0)
                ForEach(retentionOptions, id: \.self) { Text("\($0) days").tag($0) }
            }
            .feel(.selection, trigger: settings.deletePlayedAfterDays)
            .contentRow()
            NavigationLink { StorageView() } label: {
                Label("Downloads and Transcripts", systemImage: "internaldrive")
            }
            .accessibilityIdentifier("storage.open")
            .contentRow()
            NavigationLink { List { DiagnosticsLogsSection() }.navigationTitle("Log Files") } label: {
                Label("Log Files", systemImage: "doc.text")
            }
            .accessibilityIdentifier("diagnostics.logsLink")
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
            // Pass 23: he pressed it, the screen froze for a second and
            // nothing said whether anything happened. Now it asks first,
            // saying how much it frees and what it keeps, works off the main
            // thread with a spinner, and confirms right where he tapped —
            // a haptic and "Removed 3.2 GB" on the button for a few seconds.
            Button(role: .destructive) {
                guard storageNote == nil else { return }
                confirmClearDownloads = true
            } label: {
                HStack {
                    if let storageNote {
                        Label(storageNote, systemImage: storageHadFailure ? "exclamationmark.circle" : "checkmark.circle.fill")
                            .foregroundStyle(storageHadFailure ? Color.orange : Color.green)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            .accessibilityIdentifier("StorageNote")
                    } else {
                        Text("Clear Downloads")
                    }
                    if clearingDownloads { Spacer(); ProgressView() }
                }
            }
            .disabled(clearingDownloads || (storageBytes == 0 && storageNote == nil))
            .accessibilityIdentifier("ClearDownloadsButton")
            .contentRow()
            .confirmationDialog("Remove all downloaded audio?", isPresented: $confirmClearDownloads,
                                titleVisibility: .visible) {
                Button("Remove \(storageText)", role: .destructive) { clearDownloads() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Transcripts and the ads found are kept, so an episode only needs downloading again, not finding ads again. The episode that's playing or being worked on is kept.")
            }
        }
    }

    private func clearDownloads() {
        clearingDownloads = true
        Task {
            let result = await pipeline.clearDownloads()
            totals.refresh(context: context, force: true)
            storageBytes = ProcessingPipeline.downloadedBytes()
            clearingDownloads = false
            storageHadFailure = result.failed > 0
            if storageHadFailure { Haptics.warning() } else { Haptics.success() }
            let freed = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
            var notes = [result.files == 0 ? "Nothing removed" : "Removed \(freed)"]
            if result.failed > 0 { notes.append("\(result.failed) file\(result.failed == 1 ? "" : "s") could not be removed") }
            if result.kept > 0 { notes.append("\(result.kept) file\(result.kept == 1 ? "" : "s") kept while in use") }
            withAnimation(.snappy) { storageNote = notes.joined(separator: "; ") }
            try? await Task.sleep(for: .seconds(storageHadFailure ? 7 : 4))
            withAnimation(.snappy) { storageNote = nil }
        }
    }

    @ViewBuilder
    private var subscriptionsSection: some View {
        @Bindable var settings = settings
        Group {
            SectionHeader("Library and Subscriptions")
            Toggle("Queue new episodes automatically", isOn: $settings.autoQueueNewEpisodes)
            .contentRow()
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

            Text("OPML moves your subscriptions in and out of any podcast app.")
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

            Text("Needs a file made on a Mac with export-history.sh (in PodSkipper's Tools folder).")
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
            NavigationLink { PaidFeaturesView() } label: {
                Label("iCloud, CarPlay & Widgets", systemImage: "icloud")
            }
            .accessibilityIdentifier("PaidFeaturesLink")
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
        if settings.voiceBoostEnabled { on.append(Repair.dialogue.title) }
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

    /// `asCopy: false` opens the file where it is (a backup can be
    /// gigabytes: copying it first needed twice the space, pass 21b); the
    /// reader then has to ask for access to it, as `BackupService.stage` does.
    static func present(types: [UTType], asCopy: Bool = true, onPick: @escaping ([URL]) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = asCopy
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
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: Metrics.panelCorner, style: .continuous))
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

/// Under "Find ads with": says the reader is standing in until the model is
/// downloaded. Its own view, because the download state changes twice a
/// second and the rest of Settings shouldn't redraw with it.
private struct ModelNotReadyNote: View {
    @State private var store = ModelStore.shared

    var body: some View {
        if !store.isReady {
            Text("The on-device model isn't downloaded yet, so the reader finds the ads until it is.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()
        }
    }
}


/// One top-level Settings row: a rounded icon tile and the group's name,
/// like iOS Settings (pass 27f).
struct SettingsGroupLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    @ScaledMetric(relativeTo: .body) private var tile: CGFloat = 30

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: tile * 0.52, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: tile, height: tile)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: tile * 0.23, style: .continuous))
        }
        .labelStyle(SettingsLabelStyle())
        .padding(.vertical, 4)
    }
}

private struct SettingsLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 14) {
            configuration.icon
            configuration.title
        }
    }
}

/// The top level of Settings: a short list of named groups. Each opens a
/// page with what used to be part of one very long list.
enum SettingsGroup: String, CaseIterable, Identifiable, Hashable {
    case display, playback, adSkipping, downloads, notifications, library, backup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "Display"; case .playback: "Playback"; case .adSkipping: "Ad Skipping"
        case .downloads: "Downloads & Storage"; case .notifications: "Notifications"
        case .library: "Library & Subscriptions"; case .backup: "Backup"
        }
    }
    var symbol: String {
        switch self {
        case .display: "textformat.size"; case .playback: "play.fill"; case .adSkipping: "forward.end.fill"
        case .downloads: "arrow.down.circle.fill"; case .notifications: "bell.badge.fill"
        case .library: "square.stack.fill"; case .backup: "arrow.clockwise.icloud.fill"
        }
    }
    /// The icon tile's colour, as in iOS Settings.
    var tint: Color {
        switch self {
        case .display: .blue; case .playback: .purple; case .adSkipping: .pink
        case .downloads: .green; case .notifications: .red; case .library: .orange; case .backup: .teal
        }
    }
    /// One short line under the name, so a group can be found by what is in it.
    var blurb: String {
        switch self {
        case .display: "Text and icon size."
        case .playback: "Speed, skip buttons, autoplay, effects and equalizer."
        case .adSkipping: "What to skip, how eager, who finds ads, background work."
        case .downloads: "Automatic downloads, space limits, clearing audio."
        case .notifications: "New episode alerts."
        case .library: "Import and export, new episodes, stations, publishing."
        case .backup: "Save and restore everything."
        }
    }
    /// The sections on its page, for the index.
    var sections: [SettingsJump] {
        switch self {
        case .display: [.display]
        case .playback: [.playback, .audio]
        case .adSkipping: [.ads, .ai, .processing]
        case .downloads: [.storage]
        case .notifications: [.notifications]
        case .library: [.subscriptions, .more, .publishing]
        case .backup: [.backup]
        }
    }
}

/// The section index down Settings' right edge (pass 27e).
enum SettingsJump: String, CaseIterable, Identifiable {
    case stats, display, playback, audio, ads, processing, notifications, ai, storage, subscriptions, backup, more, publishing, about
    var id: String { rawValue }

    /// Short label on the bar; the full name is read by VoiceOver.
    var short: String {
        switch self {
        case .stats: "Stats"; case .display: "Look"; case .playback: "Play"; case .audio: "Audio"
        case .ads: "Skip"; case .processing: "Jobs"; case .notifications: "Alerts"; case .ai: "AI"
        case .storage: "Space"; case .subscriptions: "Shows"; case .backup: "Backup"; case .more: "More"; case .publishing: "Publish"; case .about: "About"
        }
    }
    var name: String {
        switch self {
        case .stats: "Since you installed this"; case .display: "Display"; case .playback: "Playback"
        case .audio: "Audio"; case .ads: "What to skip"; case .processing: "Processing"
        case .notifications: "Notifications"; case .ai: "On-device AI"; case .storage: "Storage"
        case .subscriptions: "Subscriptions"; case .backup: "Backup"; case .more: "More"; case .publishing: "Publishing to Apple Podcasts"; case .about: "About"
        }
    }

    /// An invisible row the bar scrolls to, just above the section.
    static func anchor(_ key: SettingsJump) -> some View {
        Color.clear.frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .id(key)
            .accessibilityHidden(true)
    }

    struct IndexBar: View {
        let proxy: ScrollViewProxy
        /// Only the sections of the page it sits on.
        let keys: [SettingsJump]
        @State private var current: SettingsJump?

        var body: some View {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    ForEach(keys) { key in
                        Text(key.short)
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(current == key ? Theme.accentHot : .secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(key.name)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { proxy.scrollTo(key, anchor: .top) }
                    }
                }
                .frame(width: 34)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let h = max(1, geo.size.height - 12)
                        let i = min(keys.count - 1, max(0, Int((value.location.y - 6) / h * CGFloat(keys.count))))
                        let key = keys[i]
                        guard key != current else { return }
                        current = key
                        Haptics.select()
                        proxy.scrollTo(key, anchor: .top)
                    }
                    .onEnded { _ in current = nil })
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(width: 36)
            .frame(maxHeight: 460)
            .padding(.trailing, 2)
            .accessibilityIdentifier("settings.index")
        }
    }
}
