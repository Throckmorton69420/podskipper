import SwiftUI
import SwiftData
import UIKit
import AVKit

// MARK: - Mini player
//
// Placed by the system via .tabViewBottomAccessory, which puts it above the
// tab bar and gives it glass automatically. The old hand-rolled version sat
// on top of the tab bar and blocked it.

struct MiniPlayer: View {
    var onTap: () -> Void
    @State private var player = PlayerEngine.shared
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Group {
            if let episode = player.currentEpisode {
                HStack(spacing: 10) {
                    Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL,
                            size: 30, corner: 6)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(episode.title).font(.caption.weight(.medium)).lineLimit(1)
                        if placement != .inline {
                            Text(subtitle).font(.caption2)
                                .foregroundStyle(subtitleTint).lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Button { player.skipBackward() } label: {
                        Image(systemName: "gobackward.15")
                            .font(.footnote)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Skip back")

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                            .frame(width: 34, height: 34)
                            .contentShape(Circle())
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 14)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.footnote).foregroundStyle(.tertiary)
                    Text("Nothing playing").font(.caption).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            }
        }
    }

    private var subtitle: String {
        if let skip = player.lastSkip {
            return "Skipped \(Int(skip.seconds))s\(skip.sponsor.isEmpty ? "" : " · \(skip.sponsor)")"
        }
        if player.smartSpeedSavedSeconds > 1 {
            return "Smart Speed saved \(Int(player.smartSpeedSavedSeconds))s"
        }
        return formatDuration(max(0, player.duration - player.currentTime)) + " left"
    }

    private var subtitleTint: Color {
        if player.lastSkip != nil { return .green }
        if player.smartSpeedSavedSeconds > 1 { return Theme.accentWarm }
        return .secondary
    }
}

// MARK: - Full player

struct PlayerView: View {
    @State private var player = PlayerEngine.shared
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss

    @State private var showEffects = false
    @State private var showChapters = false
    @State private var showBookmarkNote = false
    @State private var bookmarkNote = ""
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var showTranscript = false
    @State private var seekPreview: Double?

    private let sleepOptions = [5, 10, 15, 30, 45, 60]

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                stage
                Spacer(minLength: 6)
                VStack(spacing: 14) {
                    titleBlock
                    scrubber
                    speedRow
                    transport
                    actionBar
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
                .readableWidth(560)
            }
        }
        .sheet(isPresented: $showEffects) { NavigationStack { EffectsView() } }
        .sheet(isPresented: $showChapters) {
            if let episode = player.currentEpisode {
                NavigationStack { ChapterListView(episode: episode) }
            }
        }
        .alert("Bookmark", isPresented: $showBookmarkNote) {
            TextField("What was this?", text: $bookmarkNote)
            Button("Save") { saveBookmark(note: bookmarkNote) }
            Button("Cancel", role: .cancel) { bookmarkNote = "" }
        } message: {
            Text("Saved at \(formatDuration(player.currentTime)).")
        }
    }

    // MARK: Background
    //
    // Glass refracts what's behind it. Over flat black there is nothing to
    // refract and every control renders as grey — which is why the controls
    // looked dead. This wash gives the glass something to work with.

    private var background: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [Theme.accentHot.opacity(0.28), .clear],
                           center: .init(x: 0.5, y: 0.18), startRadius: 8, endRadius: 460)
            RadialGradient(colors: [Theme.accentWarm.opacity(0.16), .clear],
                           center: .init(x: 0.9, y: 0.75), startRadius: 8, endRadius: 380)
        }
        .ignoresSafeArea()
    }

    // MARK: Stage — artwork or transcript

    @ViewBuilder
    private var stage: some View {
        if showTranscript {
            LiveTranscript(episode: player.currentEpisode)
                .transition(.opacity)
        } else {
            VStack {
                Spacer(minLength: 16)
                Artwork(url: player.currentEpisode?.artworkURL
                        ?? player.currentEpisode?.podcast?.artworkURL,
                        size: 296, corner: 24)
                    .shadow(color: .black.opacity(0.65), radius: 30, y: 16)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.9)
                    .animation(.spring(response: 0.45, dampingFraction: 0.78),
                               value: player.isPlaying)
                    // Drag anywhere on the artwork to scrub. Much easier than
                    // hitting a 3-point slider thumb while walking.
                    .gesture(scrubGesture)
                    .overlay(alignment: .bottom) { seekBadge }
                Spacer(minLength: 16)
            }
            .transition(.opacity)
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let span = max(30, player.duration * 0.25)
                let delta = Double(value.translation.width / 260) * span
                seekPreview = min(max(0, player.currentTime + delta), player.duration)
            }
            .onEnded { _ in
                if let target = seekPreview {
                    player.seek(to: target)
                    Haptics.skip()
                }
                seekPreview = nil
            }
    }

    @ViewBuilder
    private var seekBadge: some View {
        if let seekPreview {
            Text(formatDuration(seekPreview))
                .font(.headline.monospacedDigit())
                .padding(.horizontal, 16).padding(.vertical, 9)
                .glassCapsule()
                .padding(.bottom, 18)
        }
    }

    // MARK: Title — fixed height so nothing jumps

    private var titleBlock: some View {
        VStack(spacing: 3) {
            Text(player.currentEpisode?.podcast?.title ?? "")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(player.currentEpisode?.title ?? "Nothing playing")
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 44)
            Group {
                if let chapter = player.currentChapter {
                    Button { showChapters = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.indent").font(.caption2)
                            Text(chapter.title).font(.caption).lineLimit(1)
                        }
                        .foregroundStyle(Theme.accentWarm)
                    }
                    .buttonStyle(.plain)
                } else if let error = player.loadError {
                    Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .frame(height: 18)
        }
    }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(spacing: 5) {
            AdTimeline(episode: player.currentEpisode,
                       current: displayTime,
                       duration: player.duration)

            Slider(value: Binding(
                get: { displayTime },
                set: { scrubValue = $0 }
            ), in: 0...max(1, player.duration), onEditingChanged: { editing in
                scrubbing = editing
                if !editing { player.seek(to: scrubValue) }
            })
            .tint(Theme.accentHot)

            HStack {
                Text(formatDuration(displayTime))
                Spacer()
                Text("−" + formatDuration(max(0, player.duration - displayTime)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var displayTime: Double {
        seekPreview ?? (scrubbing ? scrubValue : player.currentTime)
    }

    // MARK: Speed — a real slider, plus Smart Speed right beside it

    private var speedRow: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Text("\(player.playbackRate, specifier: "%g")×")
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(width: 46)
                    .contentTransition(.numericText())

                Slider(value: Binding(
                    get: { player.playbackRate },
                    set: { player.playbackRate = (($0 * 20).rounded()) / 20 }
                ), in: 0.5...3.0, step: 0.05)
                .tint(Theme.accentWarm)

                Button {
                    settings.smartSpeedEnabled.toggle()
                    player.applyAudioSettings()
                    Haptics.success()
                } label: {
                    Image(systemName: "hare.fill")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 38, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(settings.smartSpeedEnabled ? Theme.accentWarm : .secondary)
                .accessibilityLabel("Smart Speed")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassPanel(cornerRadius: 20)
        }
    }

    // MARK: Transport — large targets

    private var transport: some View {
        GlassEffectContainer(spacing: 22) {
            HStack(spacing: 20) {
                GlassIconButton(symbol: "gobackward.15", size: 58, label: "Skip back") {
                    player.skipBackward()
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in player.seekChapter(-1) })
                .accessibilityHint("Long press for previous chapter")

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 80, height: 80)
                        .background(Circle().fill(Theme.accentGradient))
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                GlassIconButton(symbol: "goforward.30", size: 58, label: "Skip forward") {
                    player.skipForward()
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in player.seekChapter(1) })
                .accessibilityHint("Long press for next chapter")
            }
        }
    }

    // MARK: Actions

    private var actionBar: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 12) {
                GlassIconButton(symbol: "slider.horizontal.3", size: 46, label: "Audio") {
                    showEffects = true
                }
                GlassIconButton(symbol: showTranscript ? "photo" : "text.alignleft",
                                size: 46,
                                label: showTranscript ? "Artwork" : "Transcript") {
                    withAnimation(.snappy) { showTranscript.toggle() }
                }
                GlassIconButton(symbol: "bookmark", size: 46, label: "Bookmark") {
                    bookmarkNote = ""
                    showBookmarkNote = true
                }
                Menu {
                    moreMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .clipShape(Circle())
                .accessibilityLabel("More")
            }
        }
    }

    /// Menus use Buttons with checkmarks, never Toggles. A Toggle inside a
    /// Menu, driven by a custom Binding, is what made Smart Speed need two or
    /// three taps before it registered.
    @ViewBuilder
    private var moreMenuContent: some View {
        if let episode = player.currentEpisode {
            Button {
                episode.isStarred.toggle()
                try? context.save()
                Haptics.success()
            } label: {
                Label(episode.isStarred ? "Unstar" : "Star",
                      systemImage: episode.isStarred ? "star.slash" : "star")
            }
            ShareLink(item: shareText(for: episode)) {
                Label("Share at \(formatDuration(player.currentTime))",
                      systemImage: "square.and.arrow.up")
            }
            if !episode.chapters.isEmpty {
                Button("Chapters", systemImage: "list.bullet.indent") { showChapters = true }
            }
        }

        Section("Effects") {
            Button {
                settings.voiceBoostEnabled.toggle()
                player.applyAudioSettings()
            } label: {
                Label("Voice Boost",
                      systemImage: settings.voiceBoostEnabled ? "checkmark" : "waveform.badge.mic")
            }
            Button {
                settings.volumeNormalizationEnabled.toggle()
                player.applyAudioSettings()
            } label: {
                Label("Volume Normalization",
                      systemImage: settings.volumeNormalizationEnabled ? "checkmark" : "speaker.wave.2")
            }
        }

        if let skip = player.lastSkip {
            Section("Last skip") {
                Button("Undo (\(Int(skip.seconds))s)", systemImage: "arrow.uturn.backward") {
                    player.rewindLastSkip()
                }
                Button("Not an ad", systemImage: "exclamationmark.triangle") {
                    markNotAnAd(start: skip.segmentStart)
                }
            }
        }

        Section("Sleep timer") {
            ForEach(sleepOptions, id: \.self) { minutes in
                Button("\(minutes) minutes") { player.setSleepTimer(minutes: minutes) }
            }
            Button("End of episode") { player.sleepAtEndOfEpisode() }
            if player.sleepTimerEndsAt != nil || player.sleepAtEpisodeEnd {
                Button("Turn off", role: .destructive) { player.setSleepTimer(minutes: nil) }
            }
        }
    }

    private func shareText(for episode: Episode) -> String {
        "\(episode.title) — \(episode.podcast?.title ?? "") at \(formatDuration(player.currentTime))"
    }

    private func saveBookmark(note: String) {
        guard let episode = player.currentEpisode else { return }
        context.insert(Bookmark(timestamp: player.currentTime, note: note, episode: episode))
        try? context.save()
        bookmarkNote = ""
        Haptics.success()
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

// MARK: - Live transcript

struct LiveTranscript: View {
    let episode: Episode?
    @State private var player = PlayerEngine.shared
    @Environment(ProcessingPipeline.self) private var pipeline

    private var lines: [TimedLine] { episode?.timedTranscript ?? [] }

    private func isCurrent(_ line: TimedLine) -> Bool {
        guard player.currentEpisode === episode else { return false }
        return player.currentTime >= line.start && player.currentTime < line.end
    }

    var body: some View {
        Group {
            if lines.isEmpty {
                emptyState
            } else {
                transcript
            }
        }
        .frame(maxHeight: 340)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(lines) { line in
                        Text(line.text)
                            .font(.system(size: 20, weight: isCurrent(line) ? .semibold : .regular))
                            .foregroundStyle(isCurrent(line)
                                             ? Color.primary : Color.secondary.opacity(0.5))
                            .id(line.start)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                player.seek(to: line.start)
                                if !player.isPlaying { player.play() }
                            }
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 34)
            }
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.14),
                    .init(color: .black, location: 0.86),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: player.currentTime) { _, _ in
                guard let active = lines.first(where: { isCurrent($0) }) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(active.start, anchor: .center)
                }
            }
        }
    }

    /// The transcript button used to be disabled with no explanation when an
    /// episode hadn't been processed. Now it says why, and offers to fix it.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No transcript for this episode")
                .font(.headline)
            Text("Transcription runs on your iPhone when an episode is processed. It takes a few minutes for an hour of audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let episode, !pipeline.isRunning {
                Button {
                    Task { await pipeline.process(episode) }
                } label: {
                    Label("Transcribe now", systemImage: "wand.and.sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(Theme.accentHot)
            } else if pipeline.isRunning {
                VStack(spacing: 6) {
                    ProgressView(value: pipeline.overallFraction)
                        .frame(width: 180)
                    Text(pipeline.stage.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Timeline

/// Ads in orange, shortened silences in blue, playhead in white.
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
                        Capsule().fill(Color.blue.opacity(0.22))
                            .frame(width: max(1, geo.size.width * ((range.upperBound - range.lowerBound) / duration)))
                            .offset(x: geo.size.width * (range.lowerBound / duration))
                    }
                    ForEach(episode.adSegments) { segment in
                        Capsule()
                            .fill(segment.userVerdict == .notAnAd
                                  ? Color.gray.opacity(0.35) : Theme.adTint.opacity(0.9))
                            .frame(width: max(2, geo.size.width * (segment.duration / duration)))
                            .offset(x: geo.size.width * (segment.start / duration))
                    }
                }

                if duration > 0 {
                    Capsule().fill(Color.white).frame(width: 2.5)
                        .offset(x: geo.size.width * min(1, current / duration))
                }
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Audio effects

struct EffectsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared

    // The body is split into small pieces on purpose. A single List with a
    // dozen children and a couple of conditionals is enough to make Swift's
    // type checker give up — which is exactly what it did here.
    var body: some View {
        List {
            speechSection
            cleanupSection
            equalizerSection
            Color.clear.frame(height: 60).plainRow(top: 0, bottom: 0)
        }
        .listStyle(.plain)
        .navigationTitle("Audio")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar { Button("Done") { dismiss() } }
        .onChange(of: settings.equalizerPreset) { _, name in
            settings.equalizerGains = EQPreset.named(name).gains
            player.applyAudioSettings()
        }
        .onChange(of: settings.smartSpeedEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.voiceBoostEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.deEsserEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.rumbleFilterEnabled) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.monoDownmix) { _, _ in player.applyAudioSettings() }
        .onChange(of: settings.equalizerEnabled) { _, _ in player.applyAudioSettings() }
        .onDisappear { player.applyAudioSettings() }
    }

    @ViewBuilder
    private var speechSection: some View {
        @Bindable var settings = settings

        SectionHeader("Speech")

        ToggleRow(title: "Smart Speed",
                  subtitle: "Shortens pauses using the silence map measured during processing.",
                  symbol: "hare.fill", tint: Theme.accentWarm,
                  isOn: $settings.smartSpeedEnabled)
            .contentRow()

        if settings.smartSpeedEnabled {
            smartSpeedSlider
        }

        ToggleRow(title: "Voice Boost",
                  subtitle: "Lifts speech and evens out quiet hosts.",
                  symbol: "waveform.badge.mic", tint: Theme.accentHot,
                  isOn: $settings.voiceBoostEnabled)
            .contentRow()

        ToggleRow(title: "Volume Normalization",
                  subtitle: "Keeps every show at the same level.",
                  symbol: "speaker.wave.2.fill", tint: .green,
                  isOn: $settings.volumeNormalizationEnabled)
            .contentRow()
    }

    private var smartSpeedSlider: some View {
        @Bindable var settings = settings
        // Computed outside the Text. Arithmetic inside a string interpolation
        // inside a ViewBuilder is a reliable way to stall the type checker.
        let percent = Int(settings.smartSpeedAggressiveness * 100)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shorten pauses by").font(.caption)
                Spacer()
                Text("\(percent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            Slider(value: $settings.smartSpeedAggressiveness, in: 0.2...1.0)
                .tint(Theme.accentWarm)
        }
        .contentRow()
    }

    @ViewBuilder
    private var cleanupSection: some View {
        @Bindable var settings = settings

        SectionHeader("Cleanup")

        ToggleRow(title: "De-esser",
                  subtitle: "Softens harsh sibilance around 7 kHz.",
                  symbol: "s.circle.fill", tint: .blue,
                  isOn: $settings.deEsserEnabled)
            .contentRow()

        ToggleRow(title: "Rumble Filter",
                  subtitle: "High-pass at 80 Hz — traffic, air conditioning, mic handling. Not spectral noise reduction, and I'd rather name it accurately.",
                  symbol: "wind", tint: .teal,
                  isOn: $settings.rumbleFilterEnabled)
            .contentRow()

        ToggleRow(title: "Mono",
                  subtitle: "For one-earbud listening.",
                  symbol: "circle.lefthalf.filled", tint: .purple,
                  isOn: $settings.monoDownmix)
            .contentRow()
    }

    @ViewBuilder
    private var equalizerSection: some View {
        @Bindable var settings = settings

        SectionHeader(title: "Equalizer") {
            Toggle("", isOn: $settings.equalizerEnabled).labelsHidden()
        }

        Picker("Preset", selection: $settings.equalizerPreset) {
            ForEach(EQPreset.all) { Text($0.name).tag($0.name) }
        }
        .pickerStyle(.menu)
        .contentRow()
        .disabled(!settings.equalizerEnabled)

        if settings.equalizerEnabled {
            EqualizerSliders(gains: $settings.equalizerGains)
                .frame(height: 200)
                .plainRow(top: 4, bottom: 12)
        }
    }
}

/// One consistent row for every audio switch.
struct ToggleRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? tint : Color.secondary)
                    .frame(width: 26)
                Text(title).font(.body)
                Spacer()
                Toggle("", isOn: $isOn).labelsHidden().tint(tint)
            }
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 38)
        }
    }
}

struct EqualizerSliders: View {
    @Binding var gains: [Double]
    private let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
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
                    .frame(width: 130, height: 20)
                    .frame(width: 24, height: 140)
                    .tint(Theme.accentHot)
                    Text(labels[index]).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Standalone transcript screen

struct TranscriptView: View {
    let episode: Episode
    @State private var search = ""
    @State private var player = PlayerEngine.shared

    private var lines: [TimedLine] {
        let all = episode.timedTranscript
        guard !search.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Group {
            if episode.timedTranscript.isEmpty {
                ContentUnavailableView("No transcript yet",
                    systemImage: "text.alignleft",
                    description: Text("Process this episode and the transcript is saved automatically."))
            } else {
                List {
                    ForEach(lines) { line in
                        Button {
                            if player.currentEpisode !== episode { player.load(episode, autoplay: false) }
                            player.seek(to: line.start)
                            player.play()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Text(formatDuration(line.start))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 44, alignment: .leading)
                                Text(line.text).font(.callout)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contentRow()
                    }
                    Color.clear.frame(height: 70).plainRow(top: 0, bottom: 0)
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Transcript")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .searchable(text: $search, prompt: "Search this episode")
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Theme.accentHot)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
