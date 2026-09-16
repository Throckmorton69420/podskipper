import SwiftUI
import SwiftData

/// App-wide automatic downloads. Shows follow this unless they say otherwise.
struct AutoDownloadSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline

    var body: some View {
        @Bindable var settings = settings
        List {
            Section {
                Picker("Automatically Download", selection: $settings.autoDownloadMode) {
                    ForEach(AutoDownloadMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if settings.autoDownloadMode != AutoDownloadMode.off.rawValue {
                    Picker("Limit Downloads", selection: $settings.autoDownloadLimit) {
                        ForEach(AutoDownloadLimit.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Toggle("Find Ads Right Away", isOn: $settings.autoDownloadFindAds)
                    Toggle("Only on Wi-Fi", isOn: $settings.autoDownloadWiFiOnly)
                }
            } footer: {
                Text("Only New downloads episodes released from now on. All Unplayed also fetches ones you haven’t heard. The limit removes older automatic downloads — never ones you downloaded yourself, starred, or put in Up Next. With Find Ads Right Away, an episode is ad-free by the time you press play. Each show can have its own rule in its settings.")
            }
            .listRowBackground(Color.white.opacity(0.06))

            Section {
                Button("Apply Now", systemImage: "arrow.down.circle") {
                    Haptics.select()
                    Task { await AutoDownload.apply(context: context, settings: settings, pipeline: pipeline) }
                }
            } footer: {
                Text("Rules also run whenever feeds refresh.")
            }
            .listRowBackground(Color.white.opacity(0.06))
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Automatic Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One show's rule: follow the default, or its own — plus filters.
struct ShowAutoDownloadView: View {
    @Bindable var podcast: Podcast
    @Environment(AppSettings.self) private var settings
    @Environment(\.modelContext) private var context
    @Environment(ProcessingPipeline.self) private var pipeline

    private var modeBinding: Binding<String> {
        Binding(get: { podcast.autoDownloadModeRaw ?? (podcast.autoDownloadNew ? AutoDownloadMode.onlyNew.rawValue : "default") },
                set: { value in
                    podcast.autoDownloadNew = false
                    podcast.autoDownloadModeRaw = value == "default" ? nil : value
                    if value == AutoDownloadMode.onlyNew.rawValue { podcast.autoDownloadSince = .now }
                })
    }

    private var limitBinding: Binding<String> {
        Binding(get: { podcast.autoDownloadLimitRaw ?? "default" },
                set: { podcast.autoDownloadLimitRaw = $0 == "default" ? nil : $0 })
    }

    private var findAdsBinding: Binding<String> {
        Binding(get: { podcast.autoDownloadFindAds.map { $0 ? "on" : "off" } ?? "default" },
                set: { podcast.autoDownloadFindAds = $0 == "default" ? nil : $0 == "on" })
    }

    private var defaultMode: AutoDownloadMode { AutoDownloadMode(rawValue: settings.autoDownloadMode) ?? .off }
    private var defaultLimit: AutoDownloadLimit { AutoDownloadLimit(rawValue: settings.autoDownloadLimit) ?? .recent3 }

    var body: some View {
        List {
            Section {
                Picker("Automatically Download", selection: modeBinding) {
                    Text("Default (\(defaultMode.label))").tag("default")
                    ForEach(AutoDownloadMode.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if podcast.effectiveAutoDownloadMode(settings) != .off {
                    Picker("Limit Downloads", selection: limitBinding) {
                        Text("Default (\(defaultLimit.label))").tag("default")
                        ForEach(AutoDownloadLimit.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    Picker("Find Ads Right Away", selection: findAdsBinding) {
                        Text("Default (\(settings.autoDownloadFindAds ? "On" : "Off"))").tag("default")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                }
            }
            .listRowBackground(Color.white.opacity(0.06))

            if podcast.effectiveAutoDownloadMode(settings) != .off {
                Section {
                    Picker("Skip Shorter Than", selection: $podcast.autoDownloadMinMinutes) {
                        Text("Don’t Skip").tag(0)
                        Text("5 Minutes").tag(5)
                        Text("10 Minutes").tag(10)
                        Text("20 Minutes").tag(20)
                        Text("30 Minutes").tag(30)
                    }
                    TextField("Skip titles containing (comma-separated)", text: $podcast.autoDownloadExcludeWords)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Filters")
                } footer: {
                    Text("Keeps trailers, bonus clips and reruns off your phone. For example: trailer, rerun, best of.")
                }
                .listRowBackground(Color.white.opacity(0.06))

                Section("Would download now") {
                    let list = AutoDownload.wanted(for: podcast, settings: settings)
                    if list.isEmpty {
                        Text("Nothing matches yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(list) { episode in
                            HStack {
                                Text(episode.title).lineLimit(1)
                                Spacer()
                                if episode.isDownloaded {
                                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                                }
                            }
                            .font(.subheadline)
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.06))
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Automatic Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            try? context.save()
            Task { await AutoDownload.apply(context: context, settings: settings, pipeline: pipeline) }
        }
    }
}
