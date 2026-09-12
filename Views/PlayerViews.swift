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
                            size: Metrics.artMini)

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

    private let sleepOptions = [5, 10, 15, 30, 45, 60]

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
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

    /// Always-present handle and close button. With the transcript open the
    /// scroll view swallows a downward drag, so there has to be a control
    /// that doesn't depend on finding a dead spot.
    private var topBar: some View {
        ZStack {
            Capsule().fill(Color.white.opacity(0.28))
                .frame(width: 40, height: 5)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .clipShape(Circle())
                .accessibilityLabel("Close player")

                Spacer()

                if let episode = player.currentEpisode {
                    Menu {
                        moreMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .clipShape(Circle())
                    .accessibilityLabel("More")
                    .id(episode.guid)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Background
    //
    // Glass refracts what's behind it. Over flat black there is nothing to
    // refract and every control renders as grey — which is why the controls
    // looked dead. This wash gives the glass something to work with.

    private var background: some View {
        ZStack {
            Theme.background
            // Derived from the episode's own artwork rather than a fixed pink
            // wash, so the player reads as belonging to the show you are
            // listening to — and so the glass controls have real colour and
            // texture to refract instead of flat black.
            ArtworkBackdrop(url: player.currentEpisode?.artworkURL
                            ?? player.currentEpisode?.podcast?.artworkURL,
                            variant: .player,
                            fadeHeight: 260)
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
                // No drag gesture on the artwork.
                //
                // Scrubbing by dragging across the cover sounded good, but the
                // artwork is the biggest target on the screen and it sits
                // right where you grab to pull the player down — so half the
                // time a dismiss became an accidental thirty-second jump. The
                // scrubber below is the only place that seeks now.
                Artwork(url: player.currentEpisode?.artworkURL
                        ?? player.currentEpisode?.podcast?.artworkURL,
                        size: Metrics.artPlayer)
                    .shadow(color: .black.opacity(0.65), radius: 30, y: 16)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.92)
                    .animation(.spring(response: 0.45, dampingFraction: 0.78),
                               value: player.isPlaying)
                Spacer(minLength: 16)
            }
            .transition(.opacity)
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
        scrubbing ? scrubValue : player.currentTime
    }

    // MARK: Speed

    private let presetSpeeds: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

    private var speedRow: some View {
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 6) {
                    Button {
                        player.playbackRate = max(0.5, (player.playbackRate - 0.05).rounded(toPlaces: 2))
                    } label: {
                        Image(systemName: "minus").font(.footnote.weight(.bold))
                            .frame(width: 38, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Slower")

                    ForEach(presetSpeeds, id: \.self) { speed in
                        Button {
                            player.playbackRate = speed
                            Haptics.success()
                        } label: {
                            Text(speed == 1.0 ? "1×" : "\(speed, specifier: "%g")×")
                                .font(.footnote.weight(.semibold).monospacedDigit())
                                .frame(maxWidth: .infinity, minHeight: 34)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(abs(player.playbackRate - speed) < 0.001
                                         ? Color.black : Color.primary)
                        .background {
                            if abs(player.playbackRate - speed) < 0.001 {
                                Capsule().fill(Theme.accentGradient)
                            }
                        }
                    }

                    Button {
                        player.playbackRate = min(3.0, (player.playbackRate + 0.05).rounded(toPlaces: 2))
                    } label: {
                        Image(systemName: "plus").font(.footnote.weight(.bold))
                            .frame(width: 38, height: 34).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Faster")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .glassPanel(cornerRadius: 20)
            }

            // Two quick switches, reachable without leaving the player.
            HStack(spacing: 8) {
                quickToggle(title: "Smart Speed",
                            symbol: "hare.fill",
                            isOn: settings.smartSpeedEnabled,
                            tint: Theme.accentWarm) {
                    settings.smartSpeedEnabled.toggle()
                    player.applyAudioSettings()
                    Haptics.success()
                }

                quickToggle(title: "Skip Intro",
                            symbol: "forward.end.alt.fill",
                            isOn: skipIntroOutroActive,
                            tint: Theme.accentHot) {
                    toggleSkipIntroOutro()
                }
            }

            savedLine
        }
    }

    /// Compact on/off pill. Filled when active so the state is readable at a
    /// glance rather than needing the label to be read.
    private func quickToggle(title: String, symbol: String, isOn: Bool,
                             tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption2)
                Text(title).font(.caption.weight(.medium))
            }
            .foregroundStyle(isOn ? Color.black : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(isOn ? tint : Color.white.opacity(0.09))
            }
            .overlay {
                Capsule().strokeBorder(isOn ? .clear : Theme.hairline, lineWidth: 0.8)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    /// The quick toggle writes an episode-level override, so flipping it
    /// mid-listen changes this episode and nothing else. The show sheet and
    /// Settings hold the wider scopes.
    private var skipIntroOutroActive: Bool {
        player.currentEpisode?.skipsIntroOutro(default: settings.skipIntroOutro)
            ?? settings.skipIntroOutro
    }

    private func toggleSkipIntroOutro() {
        guard let episode = player.currentEpisode else {
            settings.skipIntroOutro.toggle()
            Haptics.success()
            return
        }
        episode.skipIntroOutroOverride = !skipIntroOutroActive
        try? context.save()
        player.refreshSkipRanges()
        Haptics.success()
    }

    @ViewBuilder
    private var savedLine: some View {
        let showsSmartSpeed = settings.smartSpeedEnabled && player.smartSpeedSavedSeconds > 1
        let showsRate = abs(player.playbackRate - 1.0) > 0.001
        if showsSmartSpeed || showsRate {
            HStack(spacing: 5) {
                if showsSmartSpeed {
                    Text("Smart Speed saved \(Int(player.smartSpeedSavedSeconds))s")
                }
                if showsSmartSpeed && showsRate { Text("·") }
                if showsRate {
                    Text("\(player.playbackRate, specifier: "%g")×").monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
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
                GlassIconButton(symbol: "star", size: 46, label: "Star") {
                    guard let episode = player.currentEpisode else { return }
                    episode.isStarred.toggle()
                    try? context.save()
                    Haptics.success()
                }
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

    /// Index of the line the playhead is inside, or nil.
    ///
    /// The old version ran `lines.first(where:)` on every tick of the playhead
    /// and called `isCurrent` once per line on every body evaluation — an O(n)
    /// scan five times a second over a transcript that can be thousands of
    /// lines long, all on the main thread. Now it's a binary search, and the
    /// view only redraws when the result actually changes.
    @State private var activeIndex: Int?

    private var lines: [TimedLine] { episode?.timedTranscript ?? [] }

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

    /// Lines are in ascending time order, so the active one can be found in
    /// log(n) instead of walking the list.
    private func indexOfLine(at time: Double) -> Int? {
        let lines = self.lines
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let line = lines[mid]
            if time < line.start {
                high = mid - 1
            } else if time >= line.end {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    private func updateActiveLine() {
        guard player.currentEpisode === episode else {
            if activeIndex != nil { activeIndex = nil }
            return
        }
        let found = indexOfLine(at: player.currentTime)
        if found != activeIndex { activeIndex = found }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        let isCurrent = index == activeIndex
                        Text(line.text)
                            .font(.system(size: 20, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent
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
            .onAppear { updateActiveLine() }
            .onChange(of: player.currentTime) { _, _ in updateActiveLine() }
            .onChange(of: activeIndex) { _, index in
                guard let index, lines.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lines[index].start, anchor: .center)
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
///
/// The markers are drawn into a single `Canvas` rather than one `Capsule` view
/// per range. An hour-long episode can have hundreds of measured silences, and
/// the old version rebuilt every one of those views on each tick of the
/// playhead — several hundred view identities recreated five times a second,
/// which showed up as stutter during playback.
struct AdTimeline: View {
    let episode: Episode?
    let current: Double
    let duration: Double

    /// Snapshotted when the episode changes, so the per-tick redraw below
    /// doesn't touch the SwiftData relationship at all.
    private struct Marker {
        var start: Double
        var end: Double
        var color: Color
    }

    @State private var markers: [Marker] = []

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.10))

            Canvas { context, size in
                guard duration > 0 else { return }
                for marker in markers {
                    let x = size.width * (marker.start / duration)
                    let width = max(1.5, size.width * ((marker.end - marker.start) / duration))
                    let rect = CGRect(x: x, y: 0, width: min(width, size.width - x), height: size.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: size.height / 2),
                                 with: .color(marker.color))
                }
            }
            .allowsHitTesting(false)

            GeometryReader { geo in
                if duration > 0 {
                    Capsule().fill(Color.white).frame(width: 2.5)
                        .offset(x: geo.size.width * min(1, max(0, current / duration)))
                }
            }
        }
        .frame(height: 8)
        .task(id: episode?.guid) { rebuildMarkers() }
        .onChange(of: episode?.adSegments.count ?? 0) { _, _ in rebuildMarkers() }
    }

    private func rebuildMarkers() {
        guard let episode else {
            markers = []
            return
        }
        var built: [Marker] = []
        for range in episode.silenceRanges {
            built.append(Marker(start: range.lowerBound, end: range.upperBound,
                                color: Color.blue.opacity(0.22)))
        }
        for segment in episode.adSegments {
            built.append(Marker(start: segment.start, end: segment.end,
                                color: segment.userVerdict == .notAnAd
                                    ? Color.gray.opacity(0.35) : Theme.adTint.opacity(0.9)))
        }
        markers = built
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
            BottomClearance()
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
                    BottomClearance()
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
