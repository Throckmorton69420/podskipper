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

    @Environment(\.modelContext) private var context
    /// What would play if you pressed go. Resolved once when the bar appears
    /// rather than on every render, because it is a fetch.
    @State private var upNext: Episode?

    /// Never empty, and never useless.
    ///
    /// It started as a permanent "Nothing playing" bar. Returning nothing
    /// from here instead left the system's glass capsule on screen with
    /// nothing in it, which is worse — the accessory's height is reserved by
    /// the container, not by its content. So when nothing is loaded it offers
    /// the next thing in the queue, which is the only useful thing a player
    /// with nothing playing can say.
    var body: some View {
        Group {
            if let episode = player.currentEpisode {
                content(for: episode)
            } else if let next = upNext {
                idle(next: next)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform").font(.footnote).foregroundStyle(.tertiary)
                    Text("Nothing playing").font(.footnote).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
            }
        }
        .task(id: player.currentEpisode?.guid) {
            guard player.currentEpisode == nil else { upNext = nil; return }
            upNext = NextUpProvider.next(in: context)
        }
    }

    /// Nothing loaded, but something ready to go.
    private func idle(next: Episode) -> some View {
        HStack(spacing: 10) {
            Artwork(url: next.artworkURL ?? next.podcast?.artworkURL, size: Metrics.artMiniLarge)

            VStack(alignment: .leading, spacing: 1) {
                Text(next.title).font(.system(size: Metrics.subtitleSize, weight: .semibold)).lineLimit(1)
                if placement != .inline {
                    Text("Up Next").font(.footnote).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button {
                player.load(next)
            } label: {
                Image(systemName: "play.fill")
                    .font(.body)
                    .frame(width: 34, height: 34)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(next.title)")
        }
        .padding(.horizontal, 14)
        .contentShape(Rectangle())
        .onTapGesture { player.load(next) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MiniPlayer")
    }

    /// The bar itself.
    ///
    /// Rebuilt after actually looking at it on a device. The previous version
    /// was sized for a box that does not exist: `tabViewBottomAccessory` gives
    /// its content a fixed, fairly short height that the container decides, and
    /// a 44pt cover plus 44pt controls plus a progress line on its own row does
    /// not fit in it. The cover was clipped away entirely and the 17pt title
    /// filled what was left.
    ///
    /// So: 38pt cover, 36pt controls, 15pt title, and the progress line back
    /// under the content but only 2pt tall with 4pt of clearance — enough to
    /// read, small enough to fit. The rule still has its own line rather than
    /// being painted across the artwork, which was the original complaint.
    private func content(for episode: Episode) -> some View {
        // The collapsed pill is a different design, not a squeezed version of
        // the expanded bar.
        //
        // Reported as "so tiny it's hard to see anything there", and it was:
        // the same 15pt title and the same 38pt cover were being asked to live
        // in a pill about a third of the width, with the artwork taking most of
        // it. Collapsed, the cover goes — it is the least informative thing
        // there, because whatever is playing you already know what show it is —
        // the title gets the whole width, and the play button stays full size
        // because it is the only control left.
        let inline = placement == .inline

        return VStack(spacing: 3) {
            HStack(spacing: inline ? 8 : 10) {
                if !inline {
                    Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL,
                            size: Metrics.artMiniLarge)
                }

                VStack(alignment: .leading, spacing: 0) {
                    // Scrolls itself when the title is too long. Apple does not
                    // do this — there is no marquee anywhere in its app — but
                    // it was asked for, and this version waits two seconds at
                    // each end and honours Reduce Motion.
                    Marquee(text: episode.title,
                            font: .system(size: inline ? 15 : Metrics.subtitleSize),
                            weight: .semibold)
                    if !inline {
                        MiniSubtitle()
                    }
                }

                Spacer(minLength: 4)

                if !inline {
                    transportButton("gobackward.15", label: "Skip back", size: 15)
                        { player.skipBackward() }
                }

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                // Only where there is room. In the inline placement the
                // accessory is a narrow pill beside the tab bar and a third
                // control crowds the title out of it.
                if !inline {
                    transportButton("goforward.30", label: "Skip forward", size: 15)
                        { player.skipForward() }
                }
            }
            .padding(.horizontal, inline ? 10 : 12)

            if !inline { ProgressLine() }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // The whole bar is one tap target that opens the player, so it is one
        // element to VoiceOver and one element to find in a test. Without an
        // identifier the screenshot run had nothing to tap and never reached
        // the full player at all.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MiniPlayer")
        .accessibilityLabel(episode.title)
        .accessibilityHint("Opens the player")
    }

    private func transportButton(_ symbol: String,
                                 label: String,
                                 size: CGFloat,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                // 44 square. The old 34 was under Apple's minimum touch target
                // and these are controls people reach for without looking.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// A rule showing how far through you are.
    ///
    /// It used to be an overlay on the row, which meant it was drawn across the
    /// bottom of the artwork and the bottom of the title. It now has its own
    /// line under the content, and a faint track behind it so the bar reads as
    /// a proportion rather than as a stray mark.
    ///
    /// Its own `View`, along with `MiniSubtitle`, for the reason set out on
    /// `ScrubberBlock`: these two are the only things in the mini player that
    /// read the playhead, and read from `MiniPlayer`'s body they rebuilt the
    /// whole bar — artwork, marquee, three buttons — five times a second, on
    /// every screen in the app, including while a list was being scrolled.
    private struct ProgressLine: View {
        @State private var player = PlayerEngine.shared

        var body: some View {
            GeometryReader { proxy in
                let fraction = player.duration > 0
                    ? min(1, max(0, player.currentTime / player.duration))
                    : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(Theme.accentHot)
                        .frame(width: max(0, proxy.size.width * fraction))
                }
                .frame(height: 2)
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
            .allowsHitTesting(false)
        }
    }

    private struct MiniSubtitle: View {
        @State private var player = PlayerEngine.shared

        var body: some View {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .lineLimit(1)
        }

        private var text: String {
            if let skip = player.lastSkip {
                return "Skipped \(Int(skip.seconds))s\(skip.sponsor.isEmpty ? "" : " · \(skip.sponsor)")"
            }
            if player.smartSpeedSavedSeconds > 1 {
                return "Smart Speed saved \(Int(player.smartSpeedSavedSeconds))s"
            }
            return formatDuration(max(0, player.duration - player.currentTime)) + " left"
        }

        private var tint: Color {
            if player.lastSkip != nil { return .green }
            if player.smartSpeedSavedSeconds > 1 { return Theme.accentWarm }
            return .secondary
        }
    }
}

// MARK: - Full player

struct PlayerView: View {
    @State private var player = PlayerEngine.shared
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(\.dismiss) private var dismiss

    /// One sheet modifier, one enum.
    ///
    /// There were two `.sheet(isPresented:)` on this view, which is this
    /// project's oldest trap: the second one silently never presents. Chapters
    /// has almost certainly never opened from here.
    private enum PlayerSheet: Identifiable {
        case effects
        case chapters
        case skipReport
        case bookmarks
        case share(String)

        var id: String {
            switch self {
            case .effects:      return "effects"
            case .chapters:     return "chapters"
            case .skipReport:   return "report"
            case .bookmarks:    return "bookmarks"
            case .share(let s): return "share-\(s)"
            }
        }
    }

    @State private var activeSheet: PlayerSheet?
    @State private var showBookmarkNote = false
    @State private var bookmarkNote = ""
    @State private var bookmarkAt: Double = 0
    @State private var showTranscript = false
    @State private var pictureInPicture = false

    private let sleepOptions = [5, 10, 15, 30, 45, 60]

    var body: some View {
        // The GeometryReader is outermost, and the backdrop is a background
        // rather than a sibling in a ZStack.
        //
        // As a ZStack sibling the backdrop ignored the safe area, which sized
        // the stack to the whole display — so inside a sheet the reader
        // measured the screen, laid out for the screen, and iPad clipped the
        // overflow. The entire bottom row of controls, AirPlay included, was
        // simply not on screen.
        GeometryReader { geo in
            // The artwork used to be a fixed 296pt whatever the screen was,
            // so on anything short the controls underneath got squeezed until
            // the elapsed and remaining times were compressed out of
            // existence and the scrub handle rendered outside its row. The
            // cover gives way now; the controls never do.
            VStack(spacing: 0) {
                topBar
                stage(artSize: artworkSize(in: geo.size))
                Spacer(minLength: 4)
                VStack(spacing: 12) {
                    titleBlock
                    ScrubberBlock()
                    speedRow
                    transport
                    actionBar
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
                .readableWidth(560)
                // Everything below the cover has a floor it will not go
                // under, and the cover absorbs the difference.
                .layoutPriority(1)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background { background }
        // On iPad a sheet is otherwise a small fixed-size card. The player is
        // a whole screen's worth of controls, so it gets the page size.
        .presentationSizing(.page)
        .presentationDetents([.large])
        .sheet(item: $activeSheet) { which in
            switch which {
            case .effects:
                NavigationStack { EffectsView().scrollContentBackground(.hidden) }
                    .glassSheet()
            case .chapters:
                if let episode = player.currentEpisode {
                    NavigationStack { ChapterListView(episode: episode) }
                        .glassSheet()
                }
            case .skipReport:
                if let episode = player.currentEpisode {
                    NavigationStack { SkipReportView(episode: episode) }
                        .glassSheet()
                }
            case .bookmarks:
                if let episode = player.currentEpisode {
                    NavigationStack { EpisodeBookmarksView(episode: episode) }
                        .glassSheet()
                }
            case .share(let text):
                ShareSheet(text: text)
            }
        }
        .alert("Bookmark", isPresented: $showBookmarkNote) {
            TextField("What was this?", text: $bookmarkNote)
            Button("Save") { saveBookmark(note: bookmarkNote) }
            Button("Cancel", role: .cancel) { bookmarkNote = "" }
        } message: {
            Text("Saved at \(formatDuration(bookmarkAt)).")
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
                // No `.clipShape(Circle())` here any more. A glass button
                // draws its own material *outside* the label's frame, so
                // clipping to a circle the size of the 40pt label shaved the
                // material on every side — which is the corner buttons looking
                // cut off. `buttonBorderShape` already makes it a circle, and
                // it makes the right one.
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
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
                    .accessibilityLabel("More")
                    .id(episode.guid)
                }
            }
        }
        // Clear of the sheet's own rounded corner, glass and all.
        //
        // Removing the `.clipShape` stopped the material being shaved by the
        // button, and the corners were still reported as cut — because the
        // thing doing the cutting is the *sheet*. A glass button draws its
        // material outside the 40pt label, so at 18pt in from a corner with a
        // radius near 44 the top outer edge of that material is behind the
        // curve and disappears. Geometry, not clipping: the answer is to sit
        // further in.
        // Below the corner arc entirely, not merely inside it.
        //
        // Twice now these have been moved "further in" and reported as still
        // cut, on an iPhone 16 Pro. The arithmetic that matters is the sheet's
        // corner radius: its left edge does not reach x=0 until y equals that
        // radius, which on these phones is in the mid-fifties, and a glass
        // button draws its material several points outside its own label. At a
        // 26pt top inset the top-left of that material is still behind the
        // curve. 46 puts the whole button below the arc with room to spare, on
        // every width, and costs twenty points of a screen that has spare
        // vertical space above the artwork.
        .padding(.horizontal, 22)
        .padding(.top, 46)
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
                            // Nothing behind a full-screen sheet is visible,
                            // and the drift is the most expensive thing on
                            // this screen. Freeze it while one is up.
                            paused: activeSheet != nil || showBookmarkNote)
        }
        .ignoresSafeArea()
    }

    // MARK: Stage — artwork or transcript

    /// How big the cover can be here. Never wider than the screen allows,
    /// never taller than about a third of it, never smaller than 150 —
    /// below that it stops reading as artwork.
    private func artworkSize(in size: CGSize) -> CGFloat {
        let byWidth = size.width - 88
        let byHeight = size.height * 0.34
        // The cap rises with the space. Held at 296 on iPad the cover floated
        // in the middle of a screen with 250pt of nothing above and below it.
        let cap = size.width > 700 ? 460 : Metrics.artPlayer
        return max(150, min(cap, min(byWidth, byHeight)))
    }

    @ViewBuilder
    private func stage(artSize: CGFloat) -> some View {
        if showTranscript {
            LiveTranscript(episode: player.currentEpisode)
                .transition(.opacity)
        } else if let output = player.videoOutput {
            // A video episode shows the picture where the cover would be, at
            // the video's own shape rather than forced square.
            VStack {
                Spacer(minLength: 8)
                VideoSurface(player: output, pictureInPictureActive: $pictureInPicture)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.6), radius: 24, y: 12)
                    .padding(.horizontal, 12)
                Spacer(minLength: 8)
            }
            .transition(.opacity)
        } else {
            VStack {
                Spacer(minLength: 8)
                // No drag gesture on the artwork.
                //
                // Scrubbing by dragging across the cover sounded good, but the
                // artwork is the biggest target on the screen and it sits
                // right where you grab to pull the player down — so half the
                // time a dismiss became an accidental thirty-second jump. The
                // scrubber below is the only place that seeks now.
                Artwork(url: player.currentEpisode?.artworkURL
                        ?? player.currentEpisode?.podcast?.artworkURL,
                        size: artSize)
                    .shadow(color: .black.opacity(0.65), radius: 30, y: 16)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.92)
                    .animation(.spring(response: 0.45, dampingFraction: 0.78),
                               value: player.isPlaying)
                Spacer(minLength: 8)
            }
            .transition(.opacity)
        }
    }

    // MARK: Title — fixed height so nothing jumps

    private var titleBlock: some View {
        VStack(spacing: 3) {
            Text(player.currentEpisode?.podcast?.title ?? "")
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            Text(player.currentEpisode?.title ?? "Nothing playing")
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 44)
            Group {
                if let chapter = player.currentChapter {
                    Button { activeSheet = .chapters } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet.indent").font(.footnote)
                            Text(chapter.title).font(.footnote).lineLimit(1)
                        }
                        .foregroundStyle(Theme.accentWarm)
                    }
                    .buttonStyle(.plain)
                } else if let error = player.loadError {
                    Text(error).font(.footnote).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .frame(height: 18)
        }
    }

    // MARK: Scrubber

    /// One track, not two.
    ///
    /// This was a marker bar with a `Slider` stacked underneath it, which read
    /// as two unrelated progress bars and put a system thumb — drawn at its
    /// natural size in a squeezed row — half off the left edge of the screen.
    /// Everything lives on one track now: what was found, what has played,
    /// and where you are.
    ///
    /// It is a separate `View` type, and that is the important part rather than
    /// a tidiness preference.
    ///
    /// `player.currentTime` changes five times a second. Read from a computed
    /// property of `PlayerView`, that read belongs to *`PlayerView`'s* body, so
    /// the whole screen — title, transport, action bar and, fatally, the
    /// contents of the ⋯ menu — was rebuilt five times a second for as long as
    /// an episode was playing. An open `UIMenu` whose contents are replaced
    /// that often draws the new copy over the old one (the ghosting), never
    /// settles long enough to scroll, and drops taps that land mid-rebuild —
    /// which is why a button had to be pressed two or three times.
    ///
    /// Moving the read into its own `View` confines the invalidation to this
    /// subtree. Nothing else on the screen depends on the playhead.
    private struct ScrubberBlock: View {
        @State private var player = PlayerEngine.shared
        @State private var scrubbing = false
        @State private var scrubValue: Double = 0

        private var displayTime: Double {
            scrubbing ? scrubValue : player.currentTime
        }

        var body: some View {
            VStack(spacing: 6) {
                SeekBar(episode: player.currentEpisode,
                        current: displayTime,
                        duration: player.duration,
                        scrubbing: $scrubbing,
                        onScrub: { scrubValue = $0 },
                        onCommit: { player.seek(to: $0) })

                HStack {
                    Text(formatDuration(displayTime))
                    Spacer()
                    Text("−" + formatDuration(max(0, player.duration - displayTime)))
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                // The times were being squeezed out of existence when the
                // layout above ran out of room. A floor means they are
                // always there.
                .frame(minHeight: 14)
            }
        }
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

            // Switches reachable without leaving the player.
            //
            // Ad skipping leads, because it is the one people reach for
            // mid-episode: something got cut that should not have been, or a
            // guest is being introduced over what the detector thought was a
            // read. Turning it off here empties the jump list and leaves the
            // detection intact, so switching it back on is instant and nothing
            // has to be transcribed twice.
            // Nothing to skip until something has been found.
            //
            // The three skip switches used to sit here on every episode,
            // including ones that had never been looked at — three bright
            // pills promising to remove ads from an episode with no ads
            // marked in it. Now the row is either the work or the switches,
            // never both, and never the switches before the work.
            switch skipControlsState {
            case .unprocessed:
                findAdsInPlayer
            case .working:
                processingInPlayer
            case .ready:
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { adSkipToggle; smartSpeedToggle; introToggle }
                    VStack(spacing: 8) {
                        HStack(spacing: 8) { adSkipToggle; smartSpeedToggle }
                        HStack(spacing: 8) { introToggle; outroToggle }
                    }
                }
            }

            SavedLine()
        }
    }

    private enum SkipControls { case unprocessed, working, ready }

    private var skipControlsState: SkipControls {
        guard let episode = player.currentEpisode else { return .ready }
        if pipeline.isProcessing(episode) { return .working }
        return episode.processingState == .ready ? .ready : .unprocessed
    }

    /// Find the ads from here, without going back to the library to do it.
    ///
    /// Smart Speed stays available beside it, because it works off measured
    /// silence and needs no detection at all.
    private var findAdsInPlayer: some View {
        HStack(spacing: 8) {
            Button {
                guard let episode = player.currentEpisode else { return }
                episode.isInQueue = true
                try? context.save()
                Haptics.success()
                Task { await pipeline.process(episode) }
            } label: {
                Label("Find Ads", systemImage: "wand.and.sparkles")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.accentHot))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(pipeline.isRunning)
            .opacity(pipeline.isRunning ? 0.45 : 1)

            smartSpeedToggle
        }
    }

    /// The same progress the library row shows, where you are standing.
    private var processingInPlayer: some View {
        VStack(alignment: .leading, spacing: 6) {
            InlineProcessingRow(pipeline: pipeline)
            Text("You can keep listening while this runs.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 2)
        .transition(.opacity)
    }

    /// Hear the episode as broadcast, without undoing anything.
    private var adSkipToggle: some View {
        quickToggle(title: "Skip Ads",
                    symbol: "scissors",
                    isOn: player.autoSkipEnabled,
                    tint: .green) {
            player.autoSkipEnabled.toggle()
            Haptics.success()
        }
    }

    private var smartSpeedToggle: some View {
        quickToggle(title: "Smart Speed",
                    symbol: "hare.fill",
                    isOn: settings.smartSpeedEnabled,
                    tint: Theme.accentWarm) {
            settings.smartSpeedEnabled.toggle()
            player.applyAudioSettings()
            Haptics.success()
        }
    }

    private var introToggle: some View {
        quickToggle(title: "Skip Intro",
                    symbol: "forward.end.alt.fill",
                    isOn: introActive,
                    tint: Theme.accentHot) {
            toggleIntro()
        }
    }

    private var outroToggle: some View {
        quickToggle(title: "Skip Outro",
                    symbol: "backward.end.alt.fill",
                    isOn: outroActive,
                    tint: Theme.accentHot) {
            toggleOutro()
        }
    }

    private var introActive: Bool {
        player.currentEpisode?.skipsIntro(default: settings.skipIntro) ?? settings.skipIntro
    }

    private var outroActive: Bool {
        player.currentEpisode?.skipsOutro(default: settings.skipOutro) ?? settings.skipOutro
    }

    private func toggleIntro() {
        guard let episode = player.currentEpisode else {
            settings.skipIntro.toggle(); return
        }
        episode.skipIntroOverride = !introActive
        try? context.save()
        player.refreshSkipRanges()
        Haptics.success()
    }

    private func toggleOutro() {
        guard let episode = player.currentEpisode else {
            settings.skipOutro.toggle(); return
        }
        episode.skipOutroOverride = !outroActive
        try? context.save()
        player.refreshSkipRanges()
        Haptics.success()
    }

    /// Compact on/off pill. Filled when active so the state is readable at a
    /// glance rather than needing the label to be read.
    private func quickToggle(title: String, symbol: String, isOn: Bool,
                             tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.footnote)
                Text(title).font(.subheadline.weight(.medium))
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

    /// Its own `View` for the same reason the scrubber is: the running total
    /// of seconds Smart Speed has saved ticks up whenever a pause is jumped,
    /// and read from `PlayerView`'s body that would rebuild the ⋯ menu every
    /// time it moved.
    private struct SavedLine: View {
        @State private var player = PlayerEngine.shared
        @Environment(AppSettings.self) private var settings

        var body: some View {
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
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
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
                    activeSheet = .effects
                }
                GlassIconButton(symbol: showTranscript ? "photo" : "text.alignleft",
                                size: 46,
                                label: showTranscript ? "Artwork" : "Transcript") {
                    withAnimation(.snappy) { showTranscript.toggle() }
                }

                // The one control a podcast player cannot be without, and it
                // was missing entirely. There is no SwiftUI equivalent — the
                // system route picker is a UIKit view, and it has to be the
                // real one so AirPlay, CarPlay and headphones all appear.
                RoutePickerButton(size: 46)

                if let episode = player.currentEpisode {
                    // Its own view, because it holds a query for this
                    // episode's bookmarks and draws their count.
                    BookmarkButton(episodeGUID: episode.guid, size: 46) {
                        bookmarkNote = ""
                        // Captured here rather than read in the alert's
                        // message. Reading it there put `currentTime` in this
                        // view's body.
                        bookmarkAt = player.currentTime
                        showBookmarkNote = true
                    } onHold: {
                        activeSheet = .bookmarks
                    }

                    // Filled when starred. It was the outline whatever the
                    // state, so pressing it looked like it did nothing.
                    GlassIconButton(symbol: episode.isStarred ? "star.fill" : "star",
                                    size: 46,
                                    label: episode.isStarred ? "Unstar" : "Star",
                                    tint: episode.isStarred ? .yellow : nil) {
                        episode.isStarred.toggle()
                        try? context.save()
                        Haptics.toggle(on: episode.isStarred)
                    }
                    .symbolEffect(.bounce, value: episode.isStarred)
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
            // Nothing in this menu may read the playhead.
            //
            // This was `ShareLink(item:)` with "Share at 20:43" in its label,
            // and that is what made the menu ghost. `player.currentTime`
            // changes five times a second; reading it while building the menu
            // made SwiftUI rebuild the menu five times a second; UIKit drew
            // each new copy over the last without taking the old one away. The
            // photograph of it shows every row twice, a second apart — "Share
            // at 20:43" sitting directly on top of "Share at 20:44" — and a
            // menu being rebuilt that fast cannot be scrolled either.
            //
            // A button's *action* may read it freely: closures are not part of
            // the body, so nothing is observed until the moment it is tapped.
            Button {
                activeSheet = .share(shareText(for: episode))
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button("What was skipped", systemImage: "list.bullet.rectangle") {
                activeSheet = .skipReport
            }
            if !episode.chapters.isEmpty {
                Button("Chapters", systemImage: "list.bullet.indent") { activeSheet = .chapters }
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
        context.insert(Bookmark(timestamp: bookmarkAt, note: note, episode: episode))
        try? context.save()
        bookmarkNote = ""
        Haptics.toggle(on: true)
    }

    private func markNotAnAd(start: Double) {
        guard let episode = player.currentEpisode else { return }
        if let segment = episode.adSegments.min(by: {
            abs($0.start - start) < abs($1.start - start)
        }) {
            episode.apply(.notAnAd, to: segment)
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
                .font(.footnote)
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
                    Text(pipeline.stage.label).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Video

/// The picture, and nothing else.
///
/// `AVKit`'s `VideoPlayer` brings its own transport controls, which would sit
/// on top of ours and disagree with them — its scrubber knows nothing about
/// ad segments, and its skip buttons ignore the per-show settings. This is an
/// `AVPlayerLayer` and a Picture in Picture controller, so every control on
/// screen is still the app's own.
struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    /// Bound so the player screen can show whether PiP is running.
    @Binding var pictureInPictureActive: Bool

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
            context.coordinator.attach(to: uiView.playerLayer)
        }
    }

    static func dismantleUIView(_ uiView: PlayerLayerView, coordinator: Coordinator) {
        coordinator.controller = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// A plain UIView whose backing layer is the player layer, so the layer
    /// resizes with the view instead of needing manual frame bookkeeping.
    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    final class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        private let parent: VideoSurface
        var controller: AVPictureInPictureController?

        init(parent: VideoSurface) { self.parent = parent }

        func attach(to layer: AVPlayerLayer) {
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
            let controller = AVPictureInPictureController(playerLayer: layer)
            controller?.delegate = self
            // The whole point of a podcast app: you put the phone down and it
            // keeps going. For video that means the picture follows you out
            // of the app rather than stopping.
            controller?.canStartPictureInPictureAutomaticallyFromInline = true
            self.controller = controller
        }

        func start() {
            guard let controller, controller.isPictureInPicturePossible else { return }
            controller.startPictureInPicture()
        }

        // These are `pictureInPictureController…`, not `pictureInPicture…`.
        // Named the short way they compile, conform to nothing, and are never
        // called, so the app's idea of whether Picture in Picture is running
        // stayed permanently false. The compiler says so — "nearly matches
        // optional requirement" is the warning to read rather than skim.
        func pictureInPictureControllerDidStartPictureInPicture(_: AVPictureInPictureController) {
            parent.pictureInPictureActive = true
        }

        func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
            parent.pictureInPictureActive = false
        }
    }
}

// MARK: - Output routing

/// The system AirPlay button, dressed to match the circles beside it.
///
/// `AVRoutePickerView` is the only way to get the real picker — the one that
/// lists AirPlay speakers, CarPlay and whatever is connected over Bluetooth,
/// and that keeps showing the right icon as routes change. Drawing our own
/// button and presenting something else would give a worse list and a wrong
/// icon.
struct RoutePickerButton: UIViewRepresentable {
    var size: CGFloat

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        // The highlight when a route is active. Left as the default blue it
        // is the only thing on the screen in the wrong accent.
        picker.activeTintColor = UIColor(Theme.accentHot)
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        picker.setContentHuggingPriority(.required, for: .horizontal)
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView: AVRoutePickerView,
                      context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}

// MARK: - Timeline

/// The one thing you drag, and everything it needs to say.
///
/// The track carries what was found (an orange block is an ad, pink the
/// show's own promotion, blue another show, teal an intro or outro, faded
/// means found but not being skipped under your switches), how far through
/// you are, and the handle itself. It replaced a marker bar with a system
/// `Slider` stacked under it — two bars that looked unrelated, and a thumb
/// that rendered half off the screen when the row got squeezed.
///
/// The markers are drawn into a single `Canvas` rather than one `Capsule`
/// view per range. An hour-long episode can have hundreds of measured
/// silences, and a view each meant several hundred view identities recreated
/// five times a second, which showed up as stutter during playback.
struct SeekBar: View {
    let episode: Episode?
    let current: Double
    let duration: Double
    @Binding var scrubbing: Bool
    /// Called continuously while dragging, so the times above update live.
    var onScrub: (Double) -> Void
    /// Called once, on release. Seeking on every drag frame is what makes a
    /// scrub sound like a machine gun.
    var onCommit: (Double) -> Void

    /// Needed to know which kinds are actually being skipped, so a found-but
    /// -ignored segment can be drawn faded rather than as if it were a cut.
    @Environment(AppSettings.self) private var settings

    /// Snapshotted when the episode changes, so the per-tick redraw below
    /// doesn't touch the SwiftData relationship at all.
    private struct Marker {
        var start: Double
        var end: Double
        var color: Color
        /// Nil for a measured silence, which is drawn but is not a thing
        /// anyone wants named.
        var kind: SegmentKind?
        /// Found, but not being skipped under the current switches.
        var ignored: Bool = false
    }

    @State private var markers: [Marker] = []

    /// How much of the episode the bar is showing. 1 is all of it.
    ///
    /// Pinching zooms the time scale, which is the only way a bar 350 points
    /// wide is any use for finding a thirty-second ad in a two-hour episode.
    /// At 1× a point is twenty seconds and the smallest movement you can make
    /// throws you half a minute; at 20× a point is one second.
    ///
    /// The visible window is always centred on the playhead rather than
    /// panned separately. That sounds like a limitation and is actually the
    /// whole trick: there is no second piece of state to drift out of step,
    /// nothing to get lost in, and the way you move around at high zoom is
    /// the thing you were already doing — dragging — which now moves you six
    /// minutes across the full width instead of two hours.
    @State private var zoom: Double = 1
    /// The zoom when the current pinch began, so the gesture is proportional
    /// rather than jumping back to 1× every time a finger moves.
    @State private var zoomAtGestureStart: Double = 1
    @State private var pinching = false
    /// When the last tap that did not move landed.
    ///
    /// A double tap zooms back out, and it has to be recognised here rather
    /// than with `.onTapGesture(count: 2)`, because the drag that does the
    /// scrubbing has `minimumDistance: 0` and swallows taps before any tap
    /// gesture sees them — the double tap did nothing at all, which a
    /// screenshot of a still-zoomed timeline showed plainly. Making the two
    /// gestures exclusive instead would mean every scrub waited out the
    /// double-tap interval first, which is much worse.
    @State private var lastTapAt: Date = .distantPast

    /// The moment in the episode the finger is over, while it is down.
    ///
    /// This is what puts a name on a coloured block. A stripe that is orange
    /// tells you something was found there; it does not tell you whether it
    /// was a sponsor, the show's own Patreon plug, or the theme tune, and
    /// those are three different decisions about whether to skip it.
    @State private var touchTime: Double?

    /// Set once a touch has been held still long enough to mean "look closer".
    ///
    /// While it is set the visible window is pinned around *this* moment
    /// rather than around the playhead, which is what makes the crop feel
    /// like a magnifier held over one spot instead of the bar running away
    /// from under your finger.
    @State private var holdAnchor: Double?
    @State private var zoomBeforeHold: Double = 1
    @State private var holdTimer: Task<Void, Never>?

    // MARK: Peek and snap
    //
    // Reported: brushing the bar while reaching for something else threw the
    // episode to wherever the finger landed. A touch that neither moves nor
    // lingers is now a *peek*: the knob jumps to the spot, springs back to
    // where it was on release, and a small mark stays at the spot for a few
    // seconds so a deliberate glance is not wasted. Two things commit:
    //
    // - dragging, released anywhere — an unmistakable intent; and
    // - holding still until a ring round the knob fills, when it breaks with
    //   a firm click and the seek happens there and then.
    //
    // A hold also still crops the scale after 350ms, so looking closer and
    // committing are one continuous press rather than two gestures to learn.

    /// 0...1 while a still press is building to a commit.
    @State private var tension: Double = 0
    @State private var tensionTask: Task<Void, Never>?
    /// Set when the ring completed during this touch, so release does not
    /// snap back or seek a second time.
    @State private var tensionBroke = false
    /// Where the playhead was when the finger came down.
    @State private var origin: Double?
    /// The fading reminder of a peeked spot, or of where a seek came from.
    @State private var mark: Double?
    @State private var markTask: Task<Void, Never>?
    @State private var moved = false

    private static let tensionDelay: Duration = .milliseconds(180)
    private static let tensionLength: Double = 0.62

    /// Grows under the finger, the way the system scrubber does — and grows
    /// again while a hold has the scale cropped, because that is the moment
    /// the coloured blocks are being read rather than just dragged past.
    private var trackHeight: CGFloat {
        if holdAnchor != nil { return 26 }
        return scrubbing ? 14 : 8
    }
    private var knobSize: CGFloat {
        if holdAnchor != nil { return 26 }
        return scrubbing ? 20 : 14
    }

    /// Never zoom past the point where the window is shorter than this, or the
    /// bar stops being a way to move and starts being a microscope.
    private static let tightestSpan: Double = 20

    private var maxZoom: Double {
        guard duration > Self.tightestSpan else { return 1 }
        return duration / Self.tightestSpan
    }

    /// How far in a press-and-hold goes: enough to see about forty seconds.
    ///
    /// Forty rather than the tightest possible, because the point of holding
    /// is to see a whole ad break and its edges at once, not to land on a
    /// single second.
    private var holdZoom: Double {
        guard duration > 40 else { return 1 }
        return min(maxZoom, duration / 40)
    }

    /// The slice of the episode currently drawn, clamped to its ends.
    ///
    /// Centred on the held moment while a finger is holding one, and on the
    /// playhead otherwise.
    private var visible: ClosedRange<Double> {
        guard duration > 0 else { return 0...1 }
        let span = min(duration, duration / max(1, zoom))
        var start = (holdAnchor ?? current) - span / 2
        start = min(max(0, start), duration - span)
        return start...(start + span)
    }

    /// The segment under a given moment, if it is one worth naming.
    private func marker(at time: Double) -> Marker? {
        markers.first { $0.kind != nil && $0.start <= time && $0.end >= time }
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let window = visible
            let span = max(0.001, window.upperBound - window.lowerBound)
            let fraction: CGFloat = duration > 0
                ? CGFloat(min(1, max(0, (current - window.lowerBound) / span)))
                : 0
            // Kept inside the track at both ends, which is the whole reason
            // the old thumb ended up hanging off the left edge.
            let knobX = (knobSize / 2) + (width - knobSize) * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))

                // Played portion goes down before the markers, not after.
                // Drawn on top it tinted everything already behind the
                // playhead, so the intro and the first ad became one
                // indistinguishable smear.
                Capsule()
                    .fill(Theme.accentHot.opacity(0.55))
                    .frame(width: max(0, width * fraction))
                    .allowsHitTesting(false)

                Canvas { context, size in
                    guard duration > 0 else { return }
                    for marker in markers where marker.end > window.lowerBound
                                             && marker.start < window.upperBound {
                        let x = size.width * ((marker.start - window.lowerBound) / span)
                        let markerWidth = max(1.5, size.width * ((marker.end - marker.start) / span))
                        // Clamped rather than skipped: a segment that starts
                        // before the window still has to be drawn from the
                        // left edge, or a zoomed-in view of the middle of an
                        // ad shows no ad at all.
                        let left = max(0, x)
                        let right = min(size.width, x + markerWidth)
                        guard right > left else { continue }
                        let rect = CGRect(x: left, y: 0, width: right - left, height: size.height)
                        context.fill(Path(roundedRect: rect, cornerRadius: size.height / 2),
                                     with: .color(marker.color))
                    }
                }
                .allowsHitTesting(false)

                Circle()
                    .fill(.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                    .position(x: knobX, y: trackHeight / 2)
            }
            .frame(height: trackHeight)
            .clipShape(Capsule())
            // A generous hit area around a thin bar. The bar is 8pt; the
            // target is 44.
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        // A pinch reports two fingers as a drag as well.
                        // Without this the bar scrubs itself to wherever the
                        // midpoint of the pinch happened to be.
                        guard !pinching, duration > 0, width > knobSize else { return }
                        let at = time(at: value.location.x, width: width, in: window)
                        touchTime = at
                        if !scrubbing {
                            origin = current
                            moved = false
                            tensionBroke = false
                            scrubbing = true
                            Haptics.select()
                            scheduleHold(at: at)
                            scheduleTension()
                        }
                        // A drag is a scrub, not a hold. Moving before the
                        // timer fires cancels it, so pulling the playhead
                        // across the bar never zooms by surprise — and it
                        // lets the tension go, because dragging commits on
                        // its own.
                        if abs(value.translation.width) + abs(value.translation.height) > 10 {
                            if !moved {
                                moved = true
                                cancelTension()
                            }
                            if holdAnchor == nil {
                                holdTimer?.cancel()
                                holdTimer = nil
                            }
                        }
                        onScrub(at)
                    }
                    .onEnded { value in
                        let wasHolding = holdAnchor != nil
                        let at = touchTime ?? time(at: value.location.x, width: width, in: window)
                        let broke = tensionBroke
                        cancelTension()
                        endHold()
                        touchTime = nil
                        guard !pinching, duration > 0, width > knobSize else {
                            scrubbing = false
                            return
                        }

                        // The ring already committed; letting go just lets go.
                        if broke {
                            scrubbing = false
                            return
                        }

                        let distance = abs(value.translation.width) + abs(value.translation.height)
                        if moved || distance >= 10 {
                            // A drag: commit where it was released, and leave
                            // a mark where it came from.
                            scrubbing = false
                            onCommit(time(at: value.location.x, width: width, in: window))
                            if let origin, abs(origin - at) > 5 { showMark(at: origin) }
                            return
                        }

                        // A peek. Snap back with a little overshoot.
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.52)) {
                            scrubbing = false
                        }
                        Haptics.recoil()
                        if !wasHolding {
                            let now = Date()
                            if zoom > 1, now.timeIntervalSince(lastTapAt) < 0.35 {
                                withAnimation(.easeOut(duration: 0.25)) { zoom = 1 }
                                lastTapAt = .distantPast
                                return
                            }
                            lastTapAt = now
                        }
                        showMark(at: at)
                    }
            )
            .simultaneousGesture(
                MagnifyGesture(minimumScaleDelta: 0.01)
                    .onChanged { value in
                        guard duration > Self.tightestSpan else { return }
                        if !pinching {
                            pinching = true
                            zoomAtGestureStart = zoom
                        }
                        let next = min(maxZoom, max(1, zoomAtGestureStart * value.magnification))
                        // A click at each end, so you can feel that you have
                        // run out of zoom without watching for it.
                        if (next <= 1) != (zoom <= 1) || (next >= maxZoom) != (zoom >= maxZoom) {
                            Haptics.select()
                        }
                        zoom = next
                    }
                    .onEnded { _ in
                        pinching = false
                        zoomAtGestureStart = zoom
                    }
            )
            .overlay {
                // A small down-pointing tick over every cut.
                //
                // Needed because the coloured block itself is honest about
                // scale: a 46-second intro in a 90-minute episode is three
                // points wide, which is true and invisible. The tick is a
                // fixed size whatever the zoom, so "something was removed
                // here" reads at a glance and the block underneath still says
                // how much.
                Canvas { context, size in
                    guard duration > 0 else { return }
                    let trackTop = (size.height - trackHeight) / 2
                    for marker in markers where marker.kind != nil
                                             && !marker.ignored
                                             && marker.end > window.lowerBound
                                             && marker.start < window.upperBound {
                        let mid = (marker.start + marker.end) / 2
                        let x = size.width * ((mid - window.lowerBound) / span)
                        let cx = min(size.width - 5, max(5, x))
                        let tip = trackTop - 2.5
                        var arrow = Path()
                        arrow.move(to: CGPoint(x: cx, y: tip))
                        arrow.addLine(to: CGPoint(x: cx - 4.5, y: tip - 6))
                        arrow.addLine(to: CGPoint(x: cx + 4.5, y: tip - 6))
                        arrow.closeSubpath()
                        context.fill(arrow, with: .color(marker.color.opacity(1)))
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                // What is under the finger, named, while the finger is down.
                // Falls back to the two edge times once the bar is cropped,
                // so it always says *something* about what you are looking at.
                if let at = touchTime, let found = marker(at: at) {
                    segmentLabel(found)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if zoom > 1.05, duration > 0 {
                    HStack {
                        Text(formatDuration(window.lowerBound))
                        Spacer(minLength: 4)
                        Text(formatDuration(window.upperBound))
                    }
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                // The ring that fills while a still press builds to a commit.
                if tension > 0 {
                    Circle()
                        .trim(from: 0, to: tension)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: knobSize + 16, height: knobSize + 16)
                        .position(x: knobX, y: 22)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                // Where a peek landed, or where a seek came from.
                if let mark, duration > 0, mark >= window.lowerBound, mark <= window.upperBound {
                    let markFraction = CGFloat((mark - window.lowerBound) / span)
                    let x = (knobSize / 2) + (width - knobSize) * markFraction
                    VStack(spacing: 2) {
                        Text(formatDuration(mark))
                            .font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize()
                        Capsule()
                            .fill(Color.white.opacity(0.85))
                            .frame(width: 2.5, height: trackHeight + 10)
                    }
                    .position(x: x, y: 22 - 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: scrubbing)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityIdentifier("SeekBar")
        .accessibilityLabel("Playback position")
        .accessibilityValue(formatDuration(current) + " of " + formatDuration(duration))
        .accessibilityHint("Drag to move. A tap only marks a spot; hold still until the ring fills to jump there. Pinch to zoom, double tap for the whole episode.")
        .accessibilityAdjustableAction { direction in
            // The step follows the zoom, so VoiceOver gets the same precision
            // a pinch buys everyone else.
            let span = visible.upperBound - visible.lowerBound
            let step = max(1, min(15, span / 20))
            let target = direction == .increment ? current + step : current - step
            onCommit(min(max(0, target), duration))
        }
        .task(id: episode?.guid) {
            rebuildMarkers()
            // A zoom belongs to the episode you set it on. Carried over, the
            // next episode opens showing twenty seconds of itself for no
            // reason anyone could work out.
            zoom = 1
            lastTapAt = .distantPast
        }
        .onChange(of: episode?.adSegments.count ?? 0) { _, _ in rebuildMarkers() }
        // A switch flipped in Settings has to repaint the timeline too,
        // otherwise the bar keeps claiming it will skip something it won't.
        .onChange(of: settings.autoSkipEnabled) { _, _ in rebuildMarkers() }
        .onChange(of: settings.skipSelfPromo) { _, _ in rebuildMarkers() }
        .onChange(of: settings.skipCrossPromo) { _, _ in rebuildMarkers() }
        .onChange(of: settings.skipIntroOutro) { _, _ in rebuildMarkers() }
    }

    /// The name of what is under the finger, and how long it lasts.
    private func segmentLabel(_ marker: Marker) -> some View {
        let seconds = Int((marker.end - marker.start).rounded())
        let length = seconds >= 60
            ? "\(seconds / 60)m \(seconds % 60)s"
            : "\(seconds)s"
        return HStack(spacing: 5) {
            Circle()
                .fill(marker.color.opacity(marker.ignored ? 0.35 : 1))
                .frame(width: 6, height: 6)
            Text(marker.kind?.label ?? "Segment")
                .fontWeight(.semibold)
            Text(length)
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.6))
            if marker.ignored {
                Text("· kept")
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.7))
        .fixedSize()
        .offset(y: -20)
    }

    /// Starts the clock on a press-and-hold.
    ///
    /// Three hundred and fifty milliseconds is the usual iOS long-press feel.
    /// Shorter and an ordinary tap-to-seek starts cropping the bar under you;
    /// longer and it stops feeling like a response to what you did.
    private func scheduleHold(at moment: Double) {
        holdTimer?.cancel()
        guard duration > Self.tightestSpan, holdZoom > 1 else { return }
        holdTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, scrubbing, holdAnchor == nil else { return }
            zoomBeforeHold = zoom
            holdAnchor = moment
            withAnimation(.easeOut(duration: 0.22)) {
                zoom = Swift.max(zoom, holdZoom)
            }
            Haptics.select()
        }
    }

    /// Starts filling the ring. Completing it commits the seek on the spot.
    private func scheduleTension() {
        tensionTask?.cancel()
        tensionTask = Task { @MainActor in
            try? await Task.sleep(for: Self.tensionDelay)
            guard !Task.isCancelled, scrubbing, !moved else { return }
            withAnimation(.linear(duration: Self.tensionLength)) { tension = 1 }
            try? await Task.sleep(for: .seconds(Self.tensionLength))
            guard !Task.isCancelled, scrubbing, !moved, let at = touchTime else { return }
            tensionBroke = true
            onCommit(at)
            Haptics.commit()
            if let origin, abs(origin - at) > 5 { showMark(at: origin) }
            withAnimation(.easeOut(duration: 0.18)) { tension = 0 }
        }
    }

    private func cancelTension() {
        tensionTask?.cancel()
        tensionTask = nil
        if tension > 0 {
            withAnimation(.easeOut(duration: 0.15)) { tension = 0 }
        }
    }

    private func showMark(at time: Double) {
        markTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { mark = time }
        markTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { mark = nil }
        }
    }

    /// Lets go: the bar goes back to whatever scale it was at before the hold.
    private func endHold() {
        holdTimer?.cancel()
        holdTimer = nil
        guard holdAnchor != nil else { return }
        holdAnchor = nil
        withAnimation(.easeOut(duration: 0.28)) { zoom = zoomBeforeHold }
    }

    /// Where a finger at `x` points to, in seconds.
    ///
    /// The knob is inset by half its width at both ends so it never hangs off
    /// the bar, which means the usable track is `width - knobSize` and the
    /// arithmetic has to match — getting this wrong is what used to make the
    /// last few seconds of an episode unreachable by dragging.
    private func time(at x: CGFloat, width: CGFloat, in window: ClosedRange<Double>) -> Double {
        let usable = max(1, width - knobSize)
        let clamped = min(max(x - knobSize / 2, 0), usable)
        let span = window.upperBound - window.lowerBound
        return min(max(0, window.lowerBound + Double(clamped / usable) * span), duration)
    }

    private func rebuildMarkers() {
        guard let episode else {
            markers = []
            return
        }
        var built: [Marker] = []
        // Measured silences are deliberately NOT drawn.
        //
        // They used to be, as thin blue bars, and the result was a timeline
        // that looked like a barcode on an episode where a single 46-second
        // intro had been cut. Every natural pause between sentences became a
        // stripe, so the bar appeared to be reporting hundreds of removals
        // when it was reporting one. Silences are an input to Smart Speed, not
        // a thing that was taken out of the episode, and the timeline is a map
        // of what was taken out.
        for segment in episode.adSegments {
            // Three states, and they are worth telling apart at a glance:
            // rejected, found-but-not-being-skipped under the current
            // switches, and about to be jumped.
            let rejected = segment.userVerdict == .notAnAd
            let active = !rejected && episode.skips(segment.kind, settings: settings)
                && !segment.keptByDelivery(settings)
            let colour: Color = rejected
                ? Color.gray.opacity(0.30)
                : Theme.tint(for: segment.kind).opacity(active ? 0.9 : 0.32)
            built.append(Marker(start: segment.start, end: segment.end,
                                color: colour, kind: segment.kind, ignored: !active))
        }
        // Left in drawing order — silences underneath, segments over them.
        // `marker(at:)` skips the unnamed ones on its own, so there is no
        // need to reorder this and every reason not to.
        markers = built
    }
}

// MARK: - Audio effects

struct EffectsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared

    /// Every audio control as one comparable value.
    ///
    /// Cheap to build and cheap to compare, and it means adding another control
    /// later costs one entry here rather than another layer of generics on the
    /// body. Strings rather than a struct so no `Equatable` conformance has to
    /// be written or kept in step.
    private var audioFingerprint: String {
        [
            settings.smartSpeedEnabled, settings.voiceBoostEnabled,
            settings.deEsserEnabled, settings.rumbleFilterEnabled,
            settings.monoDownmix, settings.equalizerEnabled,
            settings.mudReductionEnabled, settings.bassReductionEnabled,
            settings.clarityEnabled, settings.harshnessReductionEnabled,
            settings.volumeNormalizationEnabled
        ].map { $0 ? "1" : "0" }.joined()
        + "|"
        + [
            settings.deEsserStrength, settings.mudReductionStrength,
            settings.bassReductionStrength, settings.clarityStrength,
            settings.harshnessReductionStrength, settings.smartSpeedAggressiveness
        ].map { String(format: "%.1f", $0) }.joined(separator: ",")
    }

    // The body is split into small pieces on purpose. A single List with a
    // dozen children and a couple of conditionals is enough to make Swift's
    // type checker give up — which is exactly what it did here.
    var body: some View {
        List {
            speechSection
            SpeechRepairSection(settings: settings)
            cleanupSection
            equalizerSection
            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("Speed and Audio")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .toolbar { Button("Done") { dismiss() } }
        // One observer, not thirteen.
        //
        // Each `.onChange` wraps the whole view in another generic type, and a
        // stack of them on top of a multi-child `List` is what made the
        // compiler give up here with "unable to type-check this expression in
        // reasonable time". A SwiftUI body is a single enormous generic
        // expression; the cost is in how many layers deep it goes, not how many
        // lines it runs to.
        //
        // Every audio control folds into one value, and one observer watches
        // that. The preset gets its own because it writes back to the gains
        // rather than only reading them.
        .onChange(of: settings.equalizerPreset) { _, name in
            settings.equalizerGains = EQPreset.resolving(name).gains
            player.applyAudioSettings()
        }
        .onChange(of: audioFingerprint) { _, _ in player.applyAudioSettings() }
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
                Text("Shorten pauses by").font(.footnote)
                Spacer()
                Text("\(percent)%")
                    .font(.footnote.monospacedDigit().weight(.semibold))
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
                .font(.footnote)
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
                                    .font(.footnote.monospacedDigit())
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

// MARK: - Speech repairs

/// The speech repairs, lifted out of `EffectsView` into their own view.
///
/// Not a style choice: with these inline as a fifth `@ViewBuilder` child the
/// compiler gave up on `EffectsView`'s `List` with "unable to type-check this
/// expression in reasonable time". A SwiftUI body is one enormous generic
/// expression, and every child multiplies the work. Splitting a section into a
/// real `View` cuts it out of the enclosing body's inference entirely.
struct SpeechRepairSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Group {
            SectionHeader("Fix How It Sounds")


        RepairRow(title: "Reduce Sibilance",
                  plain: "Softens harsh S, SH and T sounds.",
                  technical: "Narrow cut at 7 kHz.",
                  symbol: "waveform.badge.minus",
                  isOn: $settings.deEsserEnabled,
                  strength: $settings.deEsserStrength,
                  range: 2...12)

        RepairRow(title: "Enhance Dialogue",
                  plain: "For hosts who sound muffled, distant, or like they're talking into a pillow.",
                  technical: "High shelf from 9 kHz, with a level lift to match.",
                  symbol: "person.wave.2",
                  isOn: $settings.clarityEnabled,
                  strength: $settings.clarityStrength,
                  range: 1...8)

        RepairRow(title: "Reduce Boom",
                  plain: "For voices that sound boomy, chesty, or too bass-heavy.",
                  technical: "Low shelf below 220 Hz.",
                  symbol: "speaker.wave.1",
                  isOn: $settings.bassReductionEnabled,
                  strength: $settings.bassReductionStrength,
                  range: 2...12)

        RepairRow(title: "Reduce Muddiness",
                  plain: "Clears up boxy, congested speech that sounds like it was recorded in a cupboard.",
                  technical: "Cut around 300 Hz.",
                  symbol: "aqi.medium",
                  isOn: $settings.mudReductionEnabled,
                  strength: $settings.mudReductionStrength,
                  range: 2...12)

        RepairRow(title: "Reduce Harshness",
                  plain: "Takes the edge off bright, glaring voices. Easier over a long session.",
                  technical: "Cut around 3.2 kHz.",
                  symbol: "moon.zzz",
                  isOn: $settings.harshnessReductionEnabled,
                  strength: $settings.harshnessReductionStrength,
                  range: 1...10)
        }
    }
}
