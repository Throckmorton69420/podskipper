import SwiftUI
import SwiftData
import UIKit
import AVKit

// MARK: - Mini player

struct MiniPlayer: View {
    @State private var player = PlayerEngine.shared
    @State private var showFull = false

    var body: some View {
        HStack(spacing: 11) {
            Artwork(url: player.currentEpisode?.artworkURL
                    ?? player.currentEpisode?.podcast?.artworkURL, size: 38, corner: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.currentEpisode?.title ?? "")
                    .font(.caption.weight(.medium)).lineLimit(1)
                if let skip = player.lastSkip {
                    Text("Skipped \(Int(skip.seconds))s\(skip.sponsor.isEmpty ? "" : " · \(skip.sponsor)")")
                        .font(.caption2).foregroundStyle(.green)
                } else if player.smartSpeedSavedSeconds > 1 {
                    Text("Smart Speed saved \(Int(player.smartSpeedSavedSeconds))s")
                        .font(.caption2).foregroundStyle(Theme.accentWarm)
                } else {
                    Text(formatDuration(max(0, player.duration - player.currentTime)) + " left")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { player.skipBackward() } label: {
                Image(systemName: "gobackward.15").font(.body)
            }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            GeometryReader { geo in
                Rectangle().fill(Theme.accentGradient)
                    .frame(width: geo.size.width * (player.duration > 0
                        ? player.currentTime / player.duration : 0), height: 1.5)
            }
            .frame(height: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture { showFull = true }
        .sheet(isPresented: $showFull) { PlayerView() }
    }
}

// MARK: - Full player

struct PlayerView: View {
    @State private var player = PlayerEngine.shared
    @Environment(\.modelContext) private var context
    @State private var showEffects = false
    @State private var showTranscript = false
    @State private var showChapters = false
    @State private var showBookmarkNote = false
    @State private var bookmarkNote = ""
    @State private var toast: String?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private let speeds: [Double] = [0.8, 1.0, 1.2, 1.4, 1.5, 1.75, 2.0, 2.5, 3.0]
    private let sleepOptions = [5, 10, 15, 30, 45, 60]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Artwork(url: player.currentEpisode?.artworkURL
                        ?? player.currentEpisode?.podcast?.artworkURL, size: 230, corner: 20)
                    .shadow(color: Theme.accentHot.opacity(0.25), radius: 30, y: 12)

                VStack(spacing: 4) {
                    Text(player.currentEpisode?.podcast?.title ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(player.currentEpisode?.title ?? "")
                        .font(.headline).multilineTextAlignment(.center).lineLimit(3)
                }

                if let chapter = player.currentChapter {
                    Button { showChapters = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.bullet.indent").font(.caption2)
                            Text(chapter.title).font(.caption).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                        .foregroundStyle(Theme.accentWarm)
                    }
                    .buttonStyle(.plain)
                }

                if let toast {
                    Text(toast).font(.caption).foregroundStyle(.green)
                }

                if let error = player.loadError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                scrubber

                HStack(spacing: 32) {
                    Button { player.skipBackward() } label: {
                        Image(systemName: "gobackward.15").font(.title2)
                    }
                    .accessibilityLabel("Skip back")
                    .accessibilityHint("Long press to go to the previous chapter")
                    .simultaneousGesture(LongPressGesture().onEnded { _ in
                        player.seekChapter(-1)
                    })
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.accentGradient)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                    Button { player.skipForward() } label: {
                        Image(systemName: "goforward.30").font(.title2)
                    }
                    .accessibilityLabel("Skip forward")
                    .accessibilityHint("Long press to go to the next chapter")
                    .simultaneousGesture(LongPressGesture().onEnded { _ in
                        player.seekChapter(1)
                    })
                }
                .buttonStyle(.plain)
                // Long-press either skip button to jump a whole chapter.

                controlRow
                secondaryRow

                if let skip = player.lastSkip {
                    VStack(spacing: 8) {
                        Text("Skipped \(Int(skip.seconds))s\(skip.sponsor.isEmpty ? "" : " of \(skip.sponsor)")")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Undo skip") { player.rewindLastSkip() }
                            Button("Not an ad") { markNotAnAd(start: skip.segmentStart) }
                                .tint(.orange)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .glassCard()
                }

                if player.smartSpeedSavedSeconds > 1 {
                    Label("Smart Speed saved \(Int(player.smartSpeedSavedSeconds))s this episode",
                          systemImage: "hare")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showEffects) { NavigationStack { EffectsView() } }
        .sheet(isPresented: $showChapters) {
            if let episode = player.currentEpisode {
                NavigationStack { ChapterListView(episode: episode) }
            }
        }
        .alert("Bookmark note", isPresented: $showBookmarkNote) {
            TextField("What was this?", text: $bookmarkNote)
            Button("Save") { saveBookmark(note: bookmarkNote) }
            Button("Cancel", role: .cancel) { bookmarkNote = "" }
        } message: {
            Text("Saved at \(formatDuration(player.currentTime)).")
        }
        .sheet(isPresented: $showTranscript) {
            if let episode = player.currentEpisode {
                NavigationStack { TranscriptView(episode: episode) }
            }
        }
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            AdTimeline(episode: player.currentEpisode,
                       current: scrubbing ? scrubValue : player.currentTime,
                       duration: player.duration)

            Slider(value: Binding(
                get: { scrubbing ? scrubValue : player.currentTime },
                set: { scrubValue = $0 }
            ), in: 0...max(1, player.duration), onEditingChanged: { editing in
                scrubbing = editing
                if !editing { player.seek(to: scrubValue) }
            })
            .tint(Theme.accentHot)

            HStack {
                Text(formatDuration(scrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("−" + formatDuration(max(0, player.duration - (scrubbing ? scrubValue : player.currentTime))))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(speeds, id: \.self) { speed in
                    Button {
                        player.playbackRate = speed
                    } label: {
                        if player.playbackRate == speed {
                            Label("\(speed, specifier: "%g")×", systemImage: "checkmark")
                        } else {
                            Text("\(speed, specifier: "%g")×")
                        }
                    }
                }
            } label: {
                Label("\(player.playbackRate, specifier: "%g")×", systemImage: "speedometer")
            }

            Button { showEffects = true } label: {
                Label("Audio", systemImage: "slider.horizontal.3")
            }

            Button { showTranscript = true } label: {
                Label("Text", systemImage: "text.alignleft")
            }
            .disabled(player.currentEpisode?.timedTranscript.isEmpty ?? true)

            Menu {
                ForEach(sleepOptions, id: \.self) { minutes in
                    Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
                }
                Button("End of episode") { player.sleepAtEndOfEpisode() }
                if player.sleepTimerEndsAt != nil || player.sleepAtEpisodeEnd {
                    Button("Turn off", role: .destructive) { player.setSleepTimer(minutes: nil) }
                }
            } label: {
                Label(sleepLabel, systemImage: "moon.zzz")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// Bookmark, star, share and AirPlay. These are the small things whose
    /// absence makes an app feel unfinished.
    private var secondaryRow: some View {
        HStack(spacing: 10) {
            Button {
                bookmarkNote = ""
                showBookmarkNote = true
            } label: { Label("Bookmark", systemImage: "bookmark") }

            Button {
                guard let episode = player.currentEpisode else { return }
                episode.isStarred.toggle()
                try? context.save()
                toast = episode.isStarred ? "Starred" : "Unstarred"
                clearToast()
            } label: {
                Label("Star", systemImage: player.currentEpisode?.isStarred == true
                      ? "star.fill" : "star")
            }

            if let episode = player.currentEpisode {
                ShareLink(item: shareText(for: episode)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }

            AirPlayButton()
                .frame(width: 30, height: 30)
                .accessibilityLabel("AirPlay")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func shareText(for episode: Episode) -> String {
        let stamp = formatDuration(player.currentTime)
        let show = episode.podcast?.title ?? ""
        return "\(episode.title) — \(show) at \(stamp)"
    }

    private func saveBookmark(note: String) {
        guard let episode = player.currentEpisode else { return }
        let bookmark = Bookmark(timestamp: player.currentTime, note: note, episode: episode)
        context.insert(bookmark)
        try? context.save()
        bookmarkNote = ""
        toast = "Bookmarked at \(formatDuration(bookmark.timestamp))"
        clearToast()
    }

    private func clearToast() {
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            toast = nil
        }
    }

    private var sleepLabel: String {
        if player.sleepAtEpisodeEnd { return "End" }
        guard let ends = player.sleepTimerEndsAt else { return "Sleep" }
        return "\(max(0, Int(ends.timeIntervalSinceNow / 60)))m"
    }

    private func markNotAnAd(start: Double) {
        guard let episode = player.currentEpisode else { return }
        if let segment = episode.adSegments.min(by: {
            abs($0.start - start) < abs($1.start - start)
        }) {
            segment.userVerdict = .notAnAd
            try? context.save()
            player.refreshSkipRanges()
            player.seek(to: max(0, start - 1))
        }
    }
}

/// Ad ranges in orange, shortened silences in a dim blue, playhead in white.
struct AdTimeline: View {
    let episode: Episode?
    let current: Double
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))

                if let episode, duration > 0 {
                    let silences = episode.silenceRanges
                    ForEach(silences.indices, id: \.self) { index in
                        let range = silences[index]
                        Capsule().fill(Color.blue.opacity(0.25))
                            .frame(width: max(1, geo.size.width * ((range.upperBound - range.lowerBound) / duration)))
                            .offset(x: geo.size.width * (range.lowerBound / duration))
                    }
                    ForEach(episode.adSegments) { segment in
                        Capsule()
                            .fill(segment.userVerdict == .notAnAd
                                  ? Color.gray.opacity(0.35) : Theme.adTint.opacity(0.85))
                            .frame(width: max(2, geo.size.width * (segment.duration / duration)))
                            .offset(x: geo.size.width * (segment.start / duration))
                    }
                }

                if duration > 0 {
                    Capsule().fill(Color.white)
                        .frame(width: 2.5)
                        .offset(x: geo.size.width * min(1, current / duration))
                }
            }
        }
        .frame(height: 9)
    }
}

// MARK: - Audio effects

struct EffectsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Speech") {
                Toggle("Smart Speed", isOn: $settings.smartSpeedEnabled)
                if settings.smartSpeedEnabled {
                    VStack(alignment: .leading) {
                        Text("Shorten pauses by \(Int(settings.smartSpeedAggressiveness * 100))%")
                            .font(.caption)
                        Slider(value: $settings.smartSpeedAggressiveness, in: 0.2...1.0)
                            .tint(Theme.accentHot)
                    }
                }
                Toggle("Voice Boost", isOn: $settings.voiceBoostEnabled)
                Toggle("Volume normalization", isOn: $settings.volumeNormalizationEnabled)
                Text("Smart Speed uses the silence map measured during processing, so an episode has to be processed first.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                Toggle("De-esser", isOn: $settings.deEsserEnabled)
                Toggle("Rumble filter", isOn: $settings.rumbleFilterEnabled)
                Toggle("Mono", isOn: $settings.monoDownmix)
                Text("Rumble filter is a high-pass at 80 Hz — traffic, air conditioning, mic handling. It isn't spectral noise reduction, and I'd rather name it accurately.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Equalizer") {
                Toggle("Enabled", isOn: $settings.equalizerEnabled)
                Picker("Preset", selection: $settings.equalizerPreset) {
                    ForEach(EQPreset.all) { Text($0.name).tag($0.name) }
                }
                .onChange(of: settings.equalizerPreset) { _, name in
                    settings.equalizerGains = EQPreset.named(name).gains
                    player.applyAudioSettings()
                }

                if settings.equalizerEnabled {
                    EqualizerSliders(gains: $settings.equalizerGains)
                        .frame(height: 190)
                }
            }
        }
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar { Button("Done") { dismiss() } }
        .onDisappear { player.applyAudioSettings() }
        .onChange(of: settings.smartSpeedEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.voiceBoostEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.deEsserEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.rumbleFilterEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.equalizerEnabled) { _, _ in player.applyAudioSettings() }
    }
}

struct EqualizerSliders: View {
    @Binding var gains: [Double]
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<10, id: \.self) { index in
                VStack(spacing: 4) {
                    Text(gains.indices.contains(index) ? "\(Int(gains[index]))" : "0")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { gains.indices.contains(index) ? gains[index] : 0 },
                        set: { if gains.indices.contains(index) { gains[index] = $0 } }
                    ), in: -12...12)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 120, height: 22)
                    .frame(width: 22, height: 130)
                    .tint(Theme.accentHot)
                    Text(labels[index]).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    let episode: Episode
    @State private var player = PlayerEngine.shared
    @State private var follow = true
    @State private var search = ""

    private var lines: [TimedLine] {
        let all = episode.timedTranscript
        guard !search.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    private func isCurrent(_ line: TimedLine) -> Bool {
        player.currentEpisode === episode
            && player.currentTime >= line.start && player.currentTime < line.end
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(lines) { line in
                    Button {
                        if player.currentEpisode !== episode { player.load(episode, autoplay: false) }
                        player.seek(to: line.start)
                        player.play()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Text(formatDuration(line.start))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 46, alignment: .leading)
                            Text(line.text)
                                .font(.callout)
                                .foregroundStyle(isCurrent(line) ? Color.black : Color.primary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        isCurrent(line)
                            ? AnyView(RoundedRectangle(cornerRadius: 10).fill(Theme.accentGradient)
                                .padding(.horizontal, 8))
                            : AnyView(Color.clear)
                    )
                    .listRowSeparator(.hidden)
                    .id(line.start)
                }
            }
            .listStyle(.plain)
            .onChange(of: player.currentTime) { _, _ in
                guard follow, player.currentEpisode === episode else { return }
                if let active = episode.timedTranscript.first(where: { isCurrent($0) }) {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(active.start, anchor: .center)
                    }
                }
            }
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .searchable(text: $search, prompt: "Search this episode")
        .toolbar {
            Button { follow.toggle() } label: {
                Image(systemName: follow ? "text.viewfinder" : "text.alignleft")
            }
        }
        .overlay {
            if episode.timedTranscript.isEmpty {
                ContentUnavailableView("No transcript yet",
                    systemImage: "text.alignleft",
                    description: Text("Process this episode and the transcript is saved automatically."))
            }
        }
    }
}


/// AirPlay picker. There's no SwiftUI equivalent, so this wraps the UIKit one.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = UIColor.white
        view.activeTintColor = UIColor.systemPink
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
