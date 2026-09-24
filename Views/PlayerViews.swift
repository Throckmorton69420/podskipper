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
                // The cover in both placements, the way Apple Podcasts does
                // it — smaller when collapsed beside the tab bar. It was left
                // out of the collapsed pill to give the title room, and was
                // reported missing.
                Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL,
                        size: inline ? UIScale.pt(28) : Metrics.artMiniLarge)

                VStack(alignment: .leading, spacing: 0) {
                    // Scrolls itself when the title is too long. Apple does not
                    // do this — there is no marquee anywhere in its app — but
                    // it was asked for, and this version waits two seconds at
                    // each end and honours Reduce Motion.
                    Marquee(text: episode.title,
                            font: .system(size: inline ? UIScale.pt(13) : Metrics.subtitleSize),
                            weight: .semibold,
                            moving: player.isPlaying)
                    if inline {
                        Text(episode.publishedAt, format: .dateTime.month(.abbreviated).day())
                            .font(.system(size: UIScale.pt(11)))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        MiniSubtitle(published: episode.publishedAt)
                    }
                }

                Spacer(minLength: 4)

                if !inline {
                    transportButton("gobackward.15", label: "Skip back", size: 15)
                        { player.skipBackward(); Haptics.select() }
                }

                Button {
                    player.togglePlayPause()
                    Haptics.select()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: UIScale.pt(19)))
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
                        { player.skipForward(); Haptics.select() }
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
        /// The release date leads the line, as it does in Apple Podcasts.
        let published: Date
        @State private var player = PlayerEngine.shared

        var body: some View {
            Text(text)
                .font(.system(size: UIScale.pt(12)))
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
            let date = published.formatted(.dateTime.month(.abbreviated).day())
            return date + " · " + formatDuration(max(0, player.duration - player.currentTime)) + " left"
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
        case youtube(YouTubeVideo, start: Double, wasPlaying: Bool)

        var id: String {
            switch self {
            case .youtube(let video, _, _): return "yt-\(video.id)"
            case .effects:      return "effects"
            case .chapters:     return "chapters"
            case .skipReport:   return "report"
            case .bookmarks:    return "bookmarks"
            case .share(let s): return "share-\(s)"
            }
        }
    }

    @State private var activeSheet: PlayerSheet?
    /// Sheets opened from a button grow out of that button.
    @Namespace private var sheetSource
    @State private var showBookmarkNote = false
    @State private var bookmarkNote = ""
    @State private var bookmarkAt: Double = 0
    @State private var showTranscript = false
    @State private var pictureInPicture = false
    @State private var fullScreenVideo = false

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
                // Second in line for height, after the controls and before
                // the spacer: it gets everything the controls leave.
                stage(artSize: artworkSize(in: geo.size), width: geo.size.width)
                    .layoutPriority(0.5)
                Spacer(minLength: 4)
                VStack(spacing: 12) {
                    titleBlock
                    ScrubberBlock()
                    speedRow
                    transport
                    actionBar
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 16)
                .readableWidth(560)
                // Everything below the cover has a floor it will not go
                // under, and the cover absorbs the difference.
                .layoutPriority(1)
            }
            // Top-aligned: if the page is ever taller than the sheet (the
            // largest text sizes on a small phone), the overflow goes off the
            // bottom edge, into the home-indicator margin, and the close
            // button stays where a thumb expects it. Centred, it went off the
            // top — the clipped corner buttons of passes 13–15.
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            // For the UI test: the area the page has to fit inside.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("PlayerPage")
        }
        // The keyboard covers the controls instead of squeezing the page.
        // Typing in the transcript's search box shrank everything above the
        // keyboard until the transcript itself — what was being searched —
        // had no height left and vanished.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background { background }
        // On iPad a sheet is otherwise a small fixed-size card. The player is
        // a whole screen's worth of controls, so it gets the page size.
        .presentationSizing(.page)
        .presentationDetents([.large])
        .fullScreenCover(isPresented: $fullScreenVideo) {
            FullScreenVideo(pictureInPictureActive: $pictureInPicture)
        }
        .sheet(item: $activeSheet) { which in
            switch which {
            case .effects:
                NavigationStack { EffectsView().amoledScreen() }
                    .glassSheet()
                    .navigationTransition(.zoom(sourceID: "audio", in: sheetSource))
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
                        .navigationTransition(.zoom(sourceID: "bookmarks", in: sheetSource))
                }
            case .share(let text):
                ShareSheet(text: text)
            case .youtube(let video, let start, let wasPlaying):
                if let episode = player.currentEpisode {
                    YouTubeWatchView(episode: episode, video: video, startAt: start) { videoTime, resume in
                        // Back to the ad-free audio at the same moment.
                        if let videoTime {
                            player.seek(to: YouTubeLink.audioTime(fromVideo: videoTime,
                                                                  insertedAds: Self.insertedAds(episode)))
                        }
                        // Not when the video went on to another app: two
                        // things talking at once.
                        if wasPlaying && resume { player.play() }
                    }
                }
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
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            // No `.clipShape` after a glass button: the material is drawn
            // outside the label's frame and a clip shaves it off.
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close player")
            .accessibilityIdentifier("PlayerClose")

            Spacer(minLength: 0)
            topAccessory
            Spacer(minLength: 0)

            if let episode = player.currentEpisode {
                Menu {
                    moreMenuContent
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: UIScale.pt(15), weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More")
                .accessibilityIdentifier("PlayerMore")
                .id(episode.guid)
            }
        }
        // The handle sits above the row, not in it, so the middle of the row
        // is free for the Video/Audio switch.
        .overlay(alignment: .top) {
            Capsule().fill(Color.white.opacity(0.28))
                .frame(width: 40, height: 5)
                .offset(y: -9)
                .accessibilityHidden(true)
        }
        // Why these buttons were cut off (pass 16, from his screenshot).
        //
        // It was never the sheet's corner and never a clip. The player's
        // content was taller than the sheet: on an iPhone 16 Pro the controls
        // plus a fixed-size cover or a fixed 16:9 picture came to about 90pt
        // more than there was. The outer frame centred the overflow, so 45pt
        // went off the top — taking the top padding and the tops of these
        // buttons with it — and 45pt off the bottom. Each earlier "fix" added
        // top padding, which only made the content taller.
        //
        // The fix is in `body` and `stage`: the stage (cover or picture) now
        // takes whatever height is left and nothing else can grow, and the
        // outer frame is top-aligned so any overflow that remains goes off
        // the bottom, never the top. 14pt keeps the glass well inside the
        // sheet's corner curve (checked for radii up to 55pt).
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    /// The middle of the top row: the Video/Audio switch for a video episode,
    /// or "Watch on YouTube" when the show's channel has this episode.
    ///
    /// It used to sit above the cover, costing a row of height the controls
    /// needed; here it uses space the top row had spare.
    @ViewBuilder
    private var topAccessory: some View {
        if showTranscript {
            EmptyView()
        } else if player.hasVideo {
            VideoModeToggle(showsProblem: false)
        } else if let episode = player.currentEpisode {
            YouTubeWatchButton(episode: episode) { video in watchOnYouTube(video, episode: episode) }
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
                            // …and while the video is up: it covers the
                            // backdrop's busiest part, and decoding video and
                            // animating a blur at once is the hottest this
                            // screen gets.
                            paused: activeSheet != nil || showBookmarkNote
                                || fullScreenVideo || player.videoOutput != nil
                                || !player.isPlaying)
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

    /// The cover, the picture or the transcript: whatever height the top row
    /// and the controls leave, and never more.
    ///
    /// This is the one flexible part of the screen. Before pass 16 the cover
    /// had a size worked out from the screen alone and the picture was a fixed
    /// 16:9 of the full width, so when the controls were tall (a Skip Intro /
    /// Skip Outro row, a loading-error line) the page came out taller than the
    /// sheet and the top of it — the corner buttons — went off screen.
    @ViewBuilder
    private func stage(artSize: CGFloat, width: CGFloat) -> some View {
        if showTranscript {
            LiveTranscript(episode: player.currentEpisode)
                .transition(.opacity)
        } else if let output = player.videoOutput {
            // Edge to edge, as Apple Podcasts shows it, and tapping it goes
            // full screen. The screen's width when the height allows — it does
            // on every iPhone now the Video/Audio switch lives in the top row —
            // and otherwise as wide as 16:9 fits, which beats pushing the page
            // off the screen. High priority inside the stage, so the spacers
            // around it get what is left over rather than half of everything
            // (which is what made it shrink in pass 14).
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                VideoSurface(player: output, pictureInPictureActive: $pictureInPicture)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        Haptics.select()
                        fullScreenVideo = true
                    }
                    // Before the frame, so the test measures the picture
                    // itself rather than the full-width box around it.
                    .accessibilityIdentifier("PlayerVideo")
                    .accessibilityLabel("Video. Double tap for full screen.")
                    .frame(maxWidth: width)
                    .layoutPriority(1)
                if let problem = player.videoSync.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 24)
                }
                Spacer(minLength: 0)
            }
            .frame(width: width)
            .transition(.opacity)
        } else {
            // The cover at its preferred size, or smaller if that is all the
            // room there is. A GeometryReader here is safe: this is not a
            // List row, and taking all the offered height is the point.
            GeometryReader { box in
                let side = max(96, min(artSize, box.size.height - 16, box.size.width - 88))
                cover(size: side)
                    .frame(width: box.size.width, height: box.size.height)
            }
            .transition(.opacity)
        }
    }

    private func cover(size: CGFloat) -> some View {
        // No drag gesture on the artwork.
        //
        // Scrubbing by dragging across the cover sounded good, but the
        // artwork is the biggest target on the screen and it sits right where
        // you grab to pull the player down — so half the time a dismiss
        // became an accidental thirty-second jump. The scrubber below is the
        // only place that seeks now.
        Artwork(url: player.currentEpisode?.artworkURL
                ?? player.currentEpisode?.podcast?.artworkURL,
                size: size)
            .shadow(color: .black.opacity(0.65), radius: 30, y: 16)
            .scaleEffect(player.isPlaying ? 1.0 : 0.92)
            .animation(.spring(response: 0.45, dampingFraction: 0.78),
                       value: player.isPlaying)
            // As in Apple Podcasts: when the episode has a picture, tapping
            // the cover shows it.
            .onTapGesture {
                guard player.hasVideo, !player.prefersVideo else { return }
                Haptics.select()
                withAnimation(.easeInOut(duration: 0.25)) { player.prefersVideo = true }
            }
            // One accessibility element, so VoiceOver (and the UI test) can
            // find it: a decorative image on its own isn't.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Cover")
            .accessibilityAddTraits(player.hasVideo ? .isButton : [])
            .accessibilityHint(player.hasVideo ? "Shows the video" : "")
            .accessibilityIdentifier("PlayerArtwork")
    }

    // MARK: Title — fixed height so nothing jumps

    private var showAndDate: String {
        guard let episode = player.currentEpisode else { return "" }
        let show = episode.podcast?.title ?? ""
        let date = RelativeDate.release(episode.publishedAt)
        return show.isEmpty ? date : "\(show) · \(date)"
    }

    private var titleBlock: some View {
        VStack(spacing: 3) {
            // The show and the day it came out, the same line the episode
            // had in the list it was started from.
            Text(showAndDate)
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                .accessibilityIdentifier("PlayerShowAndDate")
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
                        jumpOrigin: player.jumpOrigin,
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
                            .frame(width: 44, height: 44).contentShape(Rectangle())
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
                                .frame(maxWidth: .infinity, minHeight: 44)
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
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Faster")
                }
                .padding(.horizontal, 6)
                // No vertical padding: the buttons are 44 pt tall now (HIG,
                // D9), and the row keeps its old 44 pt height so the video
                // above it stays the full width (testVideoPlayer).
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
                Haptics.success()
                Task { await pipeline.processNow(episode) }
            } label: {
                Label(pipeline.isWaiting(player.currentEpisode?.guid) ? "Starting…" : "Find Ads",
                      systemImage: "wand.and.sparkles")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .fixedSize()
                    .font(.system(size: UIScale.pt(15), weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.accentHot))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

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
                GlassIconButton(symbol: "gobackward.15", size: UIScale.pt(58), label: "Skip back") {
                    player.skipBackward()
                    Haptics.select()
                }
                .simultaneousGesture(LongPressGesture().onEnded { _ in player.seekChapter(-1) })
                .accessibilityHint("Long press for previous chapter")

                Button {
                    player.togglePlayPause()
                    Haptics.select()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: UIScale.pt(30), weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 80, height: 80)
                        .background(Circle().fill(Theme.accentGradient))
                        .contentShape(Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                GlassIconButton(symbol: "goforward.30", size: UIScale.pt(58), label: "Skip forward") {
                    player.skipForward()
                    Haptics.select()
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
                GlassIconButton(symbol: "slider.horizontal.3", size: UIScale.pt(46), label: "Audio") {
                    activeSheet = .effects
                }
                .matchedTransitionSource(id: "audio", in: sheetSource)
                GlassIconButton(symbol: showTranscript ? "photo" : "text.alignleft",
                                size: UIScale.pt(46),
                                label: showTranscript ? "Artwork" : "Transcript") {
                    withAnimation(.snappy) { showTranscript.toggle() }
                }

                // The one control a podcast player cannot be without, and it
                // was missing entirely. There is no SwiftUI equivalent — the
                // system route picker is a UIKit view, and it has to be the
                // real one so AirPlay, CarPlay and headphones all appear.
                RoutePickerButton(size: UIScale.pt(46))

                if let episode = player.currentEpisode {
                    // Its own view, because it holds a query for this
                    // episode's bookmarks and draws their count.
                    BookmarkButton(episodeGUID: episode.guid, size: UIScale.pt(46)) {
                        bookmarkNote = ""
                        // Captured here rather than read in the alert's
                        // message. Reading it there put `currentTime` in this
                        // view's body.
                        bookmarkAt = player.currentTime
                        showBookmarkNote = true
                    } onHold: {
                        activeSheet = .bookmarks
                    }
                    .matchedTransitionSource(id: "bookmarks", in: sheetSource)

                    StarButton(episode: episode, size: UIScale.pt(46))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("PlayerActionBar")
    }

    /// Menus use Buttons with checkmarks, never Toggles. A Toggle inside a
    /// Menu, driven by a custom Binding, is what made Smart Speed need two or
    /// three taps before it registered.
    @ViewBuilder
    private var moreMenuContent: some View {
        if let episode = player.currentEpisode {
            // The same episode actions as its row and its page (his rule:
            // one set, everywhere) — Find Ads Again among them.
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
            // Apple's "Share from 12:34…": a podcasts.apple.com link that
            // opens the episode at this moment. The time is read when tapped
            // (see above), and the link found in Apple's directory then —
            // falling back to the title and time when it isn't listed.
            EpisodeMenuItems(episode: episode, player: .init(
                shareFromHere: {
                    let at = player.currentTime
                    let text = shareText(for: episode, at: at)
                    Task {
                        let link = await EpisodeLink.apple(for: episode, at: at)
                        activeSheet = .share(link.map { text + "\n" + $0.absoluteString } ?? text)
                    }
                },
                whatWasSkipped: { activeSheet = .skipReport },
                chapters: { activeSheet = .chapters }))
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
                // "Volume Normalization" wrapped mid-word in the menu (D9).
                Label("Normalize Volume",
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

    /// Ads PodSkipper found that were produced spots, stitched into the feed's
    /// audio — the ones a YouTube upload of the same episode won't have.
    static func insertedAds(_ episode: Episode) -> [(start: Double, end: Double)] {
        episode.insertedAdRanges
    }

    private func watchOnYouTube(_ video: YouTubeVideo, episode: Episode) {
        let wasPlaying = player.isPlaying
        let start = YouTubeLink.videoTime(fromAudio: player.currentTime, insertedAds: Self.insertedAds(episode))
        if wasPlaying { player.pause() }
        activeSheet = .youtube(video, start: start, wasPlaying: wasPlaying)
    }

    private func shareText(for episode: Episode, at seconds: Double) -> String {
        "\(episode.title) — \(episode.podcast?.title ?? "") from \(formatDuration(seconds))"
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

    /// Searching inside the transcript. While a search is open the list stops
    /// following the playhead, so a match stays put under your finger.
    @State private var query = ""
    @State private var matches: [Int] = []
    @State private var matchSet: Set<Int> = []
    @State private var matchPosition = 0
    @FocusState private var searchFocused: Bool

    private var searching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

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

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search transcript", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("TranscriptSearch")
            if searching {
                Text(matches.isEmpty ? "None" : "\(matchPosition + 1) of \(matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(matches.isEmpty)
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(matches.isEmpty)
                Button { query = ""; searchFocused = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 20)
    }

    private func findMatches() {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { matches = []; matchSet = []; matchPosition = 0; return }
        matches = lines.indices.filter {
            lines[$0].text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        matchSet = Set(matches)
        // Start from the first match after where you are, as a find-in-page does.
        let now = player.currentTime
        matchPosition = matches.firstIndex { lines[$0].start >= now } ?? 0
    }

    private func step(_ by: Int) {
        guard !matches.isEmpty else { return }
        matchPosition = (matchPosition + by + matches.count) % matches.count
        Haptics.select()
    }

    private var transcript: some View {
        VStack(spacing: 8) {
            searchBar
            transcriptList
        }
        .onChange(of: query) { findMatches() }
    }

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        let isCurrent = index == activeIndex
                        let isMatch = searching && matchSet.contains(index)
                        let isFocusedMatch = isMatch && matches.indices.contains(matchPosition)
                            && matches[matchPosition] == index
                        Text(highlighted(line.text, on: isMatch))
                            .font(.system(size: UIScale.pt(20), weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent
                                             ? Color.primary : Color.secondary.opacity(0.5))
                            .padding(.horizontal, isFocusedMatch ? 8 : 0)
                            .padding(.vertical, isFocusedMatch ? 4 : 0)
                            .background {
                                if isFocusedMatch {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.white.opacity(0.12))
                                }
                            }
                            .id(line.start)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("TranscriptLine")
                            .accessibilityAddTraits(.isButton)
                            .onTapGesture {
                                // `jump`, not `seek`: the scrubber below
                                // marks where you were, for a while, and a
                                // tap on the mark takes you back.
                                player.jump(to: line.start)
                                if !player.isPlaying { player.play() }
                                if searching { query = ""; searchFocused = false }
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
            // The playhead is watched by a view of its own, which draws
            // nothing. Here, `.onChange(of: player.currentTime)` made this
            // whole list depend on the playhead: every line of the transcript
            // was rebuilt and diffed five times a second for as long as it was
            // open.
            .background {
                PlayheadLineWatcher(episode: episode, lines: lines, activeIndex: $activeIndex)
            }
            .onChange(of: activeIndex) { _, index in
                guard !searching, let index, lines.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lines[index].start, anchor: .center)
                }
            }
            .onChange(of: matchPosition) { _, position in
                guard searching, matches.indices.contains(position) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lines[matches[position]].start, anchor: .center)
                }
            }
            .onChange(of: matches) { _, found in
                guard searching, found.indices.contains(matchPosition) else { return }
                proxy.scrollTo(lines[found[matchPosition]].start, anchor: .center)
            }
        }
    }

    /// The searched words in bold and full brightness, so a match can be
    /// spotted inside a long line.
    private func highlighted(_ text: String, on: Bool) -> AttributedString {
        var result = AttributedString(text)
        guard on else { return result }
        let needle = query.trimmingCharacters(in: .whitespaces)
        var searchRange = result.startIndex..<result.endIndex
        while let range = result[searchRange].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            result[range].foregroundColor = Theme.accentHot
            result[range].inlinePresentationIntent = .stronglyEmphasized
            searchRange = range.upperBound..<result.endIndex
        }
        return result
    }

    /// The transcript button used to be disabled with no explanation when an
    /// episode hadn't been processed. Now it says why, and offers to fix it.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.alignleft")
                .font(.system(size: UIScale.pt(40))).foregroundStyle(.tertiary)
            Text("No transcript for this episode")
                .font(.headline)
            Text("Transcription runs on your iPhone when an episode is processed. It takes a few minutes for an hour of audio.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if let episode, !pipeline.isRunning {
                Button {
                    Task { await pipeline.processNow(episode) }
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
            Task { @MainActor in PlayerEngine.shared.pictureInPictureActive = true }
        }

        func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
            parent.pictureInPictureActive = false
            Task { @MainActor in PlayerEngine.shared.pictureInPictureActive = false }
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
    /// A jump made from elsewhere — the transcript — that should leave the
    /// same "where you were" ring a drag leaves.
    var jumpOrigin: PlayerEngine.JumpOrigin? = nil
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
        var sponsor: String = ""
        var rejected: Bool = false
    }

    @State private var markers: [Marker] = []
    /// The marked stretch last tapped, named in a glass tag above the bar
    /// (his request, 23 Sep: the marks didn't say what they were).
    @State private var tagged: Int?
    @State private var tagTask: Task<Void, Never>?

    /// How much of the episode the bar is showing. 1 is all of it. Pinch to
    /// change it; double-tap to go back to the whole episode.
    @State private var zoom: Double = 1
    @State private var zoomAtGestureStart: Double = 1
    @State private var pinching = false
    @State private var lastTapAt: Date = .distantPast

    // MARK: The loupe, the tether and the break
    //
    // What the bar has to do at once: let you *look* at a 15-second segment
    // in a two-hour episode — two points wide on the phone — without ever
    // losing your place by brushing it. Two layers, never in each other's way.
    //
    // Looking (spatial). Touch the bar and a glass loupe rises above it,
    // showing ninety seconds around the finger with the segments drawn wide,
    // tick marks every ten seconds and the segment named. Drag along the bar
    // and you move at the whole bar's scale; slide up onto the loupe and you
    // move at the loupe's scale — fine enough to put the dot on a single
    // second — and further up, a quarter of that. Near a segment's edge the
    // dot catches on it, with a soft click, so skipping to exactly where an ad
    // ends is easy. Pinch still zooms the bar itself.
    //
    // Deciding (kinetic). Everything you do while dragging is a *preview*:
    // playback is untouched and a thin tether stretches from the dot back to
    // where you were. Let go and it springs back — nothing changed. To move,
    // stop and hold still: after 0.4 s the tether breaks with a firm click and
    // playback jumps there. A ring left where you came from stays for five
    // seconds; tap it to go back. A plain tap shows the time at that spot and
    // moves nothing; a press held still on a spot jumps there.
    //
    // Every value is relative (the value moves by the finger's distance times
    // the current scale), and the window is frozen while a finger is down, so
    // nothing about a scale change can make the dot jump — the defect behind
    // the reports of 6:03 becoming 6:37 and 13:38 becoming 13:32.

    @State private var frozenWindow: ClosedRange<Double>?
    /// The previewed value, after edge-catching.
    @State private var dragValue: Double = 0
    /// The value before edge-catching, so a caught dot can be pulled free.
    @State private var rawValue: Double = 0
    @State private var lastX: CGFloat = 0
    @State private var moved = false
    @State private var zone: Zone = .bar
    @State private var touchTime: Double?
    /// Where playback was when the finger came down.
    @State private var origin: Double?
    /// Set once the tether has broken during this touch.
    @State private var committed: Double?
    @State private var dwellTask: Task<Void, Never>?
    @State private var tension: Double = 0
    @State private var caughtEdge: Double?
    @State private var loupeOpen = false
    /// Where playback was before the last commit, for five seconds.
    @State private var ghost: Double?
    @State private var ghostTask: Task<Void, Never>?
    /// A jump whose ring has timed out or been tapped.
    @State private var expiredJump: UUID?
    @State private var mark: Double?
    @State private var markTask: Task<Void, Never>?
    @State private var lean: CGFloat = 0

    private enum Zone: Equatable { case bar, loupe, fine }

    private static let dwell: Duration = .milliseconds(400)
    private static let loupeSpan: Double = 90
    private static let loupeHeight: CGFloat = 58
    private static let loupeGap: CGFloat = 14

    private var trackHeight: CGFloat { scrubbing ? 12 : 8 }
    private var knobSize: CGFloat { scrubbing ? 18 : 14 }
    private static let tightestSpan: Double = 20

    private var maxZoom: Double {
        guard duration > Self.tightestSpan else { return 1 }
        return duration / Self.tightestSpan
    }

    private func window(around time: Double) -> ClosedRange<Double> {
        guard duration > 0 else { return 0...1 }
        let span = min(duration, duration / max(1, zoom))
        var start = time - span / 2
        start = min(max(0, start), duration - span)
        return start...(start + span)
    }

    private var visible: ClosedRange<Double> { frozenWindow ?? window(around: current) }

    private var loupeWindow: ClosedRange<Double> {
        let span = min(duration, Self.loupeSpan)
        let centre = scrubbing ? dragValue : current
        var start = centre - span / 2
        start = min(max(0, start), max(0, duration - span))
        return start...(start + span)
    }

    private var zoneLabel: String? {
        switch zone {
        case .loupe: return "Fine Scrubbing"
        case .fine:  return "Quarter-Speed Scrubbing"
        case .bar:   return nil
        }
    }

    private func marker(at time: Double) -> Marker? {
        markers.first { $0.kind != nil && $0.start <= time && $0.end >= time }
    }

    private func x(for time: Double, width: CGFloat, in window: ClosedRange<Double>) -> CGFloat {
        let span = max(0.001, window.upperBound - window.lowerBound)
        let fraction = CGFloat(min(1, max(0, (time - window.lowerBound) / span)))
        return (knobSize / 2) + (width - knobSize) * fraction
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let window = visible
            let span = max(0.001, window.upperBound - window.lowerBound)
            let fraction: CGFloat = duration > 0
                ? CGFloat(min(1, max(0, (current - window.lowerBound) / span)))
                : 0
            let knobX = (knobSize / 2) + (width - knobSize) * fraction

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))

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
                    .position(x: knobX + lean, y: trackHeight / 2)
            }
            .frame(height: trackHeight)
            .clipShape(Capsule())
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: width, window: window, knobX: knobX))
            .simultaneousGesture(pinchGesture)
            .overlay { tickMarks(window: window, span: span) }
            .overlay { tether(width: width, window: window) }
            .overlay { originRing(width: width, window: window) }
            .overlay { markView(width: width, window: window) }
            .overlay(alignment: .topLeading) { segmentTag(width: width, window: window) }
            .overlay(alignment: .top) {
                if loupeOpen, duration > 0 {
                    loupe(width: width)
                        .offset(y: -(Self.loupeHeight + Self.loupeGap))
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                } else if zoom > 1.05, duration > 0 {
                    HStack {
                        Text(formatDuration(window.lowerBound))
                        Spacer(minLength: 4)
                        Text(formatDuration(window.upperBound))
                    }
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.45))
                    .allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.78), value: loupeOpen)
            .animation(.easeOut(duration: 0.15), value: scrubbing)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityIdentifier("SeekBar")
        .accessibilityLabel("Playback position")
        .accessibilityValue(spokenValue)
        .accessibilityHint("Drag to preview; hold still to jump there. Slide up onto the loupe for finer control. Pinch to zoom.")
        .accessibilityAdjustableAction { direction in
            let span = visible.upperBound - visible.lowerBound
            let step = max(1, min(15, span / 20))
            let target = direction == .increment ? current + step : current - step
            onCommit(min(max(0, target), duration))
        }
        .task(id: episode?.guid) {
            rebuildMarkers()
            zoom = 1
            lastTapAt = .distantPast
            // A still of a gesture cannot be taken mid-gesture, so a test run
            // can ask for the loupe to be shown open.
            if DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("-LoupePreview") { loupeOpen = true }
            // …and for the tag a tap on a marked stretch shows.
            if DemoData.isEnabled, ProcessInfo.processInfo.arguments.contains("-SegmentTagPreview") {
                tagged = markers.firstIndex { $0.kind != nil && !$0.ignored }
            }
        }
        // A jump from the transcript leaves the ring for a while. Worked out
        // from the jump itself rather than copied into `ghost` on change, so
        // it is there however this bar came to be on screen.
        .task(id: jumpOrigin?.id) {
            guard let jump = jumpOrigin else { return }
            let left = Self.jumpRingSeconds - Date.now.timeIntervalSince(jump.at)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { expiredJump = jump.id }
        }
        .onChange(of: episode?.adSegments.count ?? 0) { _, _ in rebuildMarkers() }
        .onChange(of: settings.autoSkipEnabled) { _, _ in rebuildMarkers() }
        .onChange(of: settings.skipSelfPromo) { _, _ in rebuildMarkers() }
        .onChange(of: settings.skipCrossPromo) { _, _ in rebuildMarkers() }
        .onChange(of: settings.skipIntroOutro) { _, _ in rebuildMarkers() }
    }

    // MARK: Gestures

    private func scrubGesture(width: CGFloat, window: ClosedRange<Double>, knobX: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !pinching, duration > 0, width > knobSize else { return }
                let usable = max(1, width - knobSize)
                if !scrubbing {
                    origin = current
                    committed = nil
                    frozenWindow = window
                    dragValue = current
                    rawValue = current
                    lastX = value.location.x
                    moved = false
                    zone = .bar
                    caughtEdge = nil
                    touchTime = time(at: value.startLocation.x, width: width, in: window)
                    scrubbing = true
                    onScrub(current)
                    Haptics.select()
                    loupeOpen = true
                    restartDwell()
                }
                if !moved, abs(value.translation.width) > 6 || abs(value.translation.height) > 24 {
                    moved = true
                    lastX = value.location.x
                }
                guard moved, let frame = frozenWindow else { return }

                // Which scale the finger is on: the bar, the loupe above it,
                // or higher still.
                let above = -(value.location.y - 22)
                let newZone: Zone = above < 34 ? .bar : (above < 120 ? .loupe : .fine)
                if newZone != zone {
                    zone = newZone
                    Haptics.select()
                }
                let frameSpan = frame.upperBound - frame.lowerBound
                let secondsPerPoint: Double
                switch zone {
                case .bar:   secondsPerPoint = frameSpan / Double(usable)
                case .loupe: secondsPerPoint = min(frameSpan, Self.loupeSpan) / Double(usable)
                case .fine:  secondsPerPoint = min(frameSpan, Self.loupeSpan) / Double(usable) / 4
                }
                let dx = value.location.x - lastX
                lastX = value.location.x
                if abs(dx) > 0.5 { restartDwell() }
                rawValue = min(max(0, rawValue + Double(dx) * secondsPerPoint), duration)

                // Catch on a segment edge within six points at the current
                // scale — the end of an ad is the spot people are aiming for.
                let catchRadius = 6 * secondsPerPoint
                let edge = markers.lazy
                    .filter { $0.kind != nil }
                    .flatMap { [$0.start, $0.end] }
                    .min { abs($0 - rawValue) < abs($1 - rawValue) }
                if let edge, abs(edge - rawValue) <= catchRadius {
                    if caughtEdge != edge { Haptics.detent() }
                    caughtEdge = edge
                    dragValue = edge
                } else {
                    caughtEdge = nil
                    dragValue = rawValue
                }

                if frameSpan < duration {
                    var lower = frame.lowerBound
                    if dragValue < lower { lower = dragValue }
                    if dragValue > lower + frameSpan { lower = dragValue - frameSpan }
                    lower = min(max(0, lower), duration - frameSpan)
                    if lower != frame.lowerBound { frozenWindow = lower...(lower + frameSpan) }
                }
                touchTime = dragValue
                onScrub(dragValue)
            }
            .onEnded { value in
                dwellTask?.cancel()
                dwellTask = nil
                withAnimation(.easeOut(duration: 0.15)) { tension = 0 }
                let wasMoved = moved
                let tapAt = touchTime
                let kept = committed
                defer {
                    frozenWindow = nil
                    touchTime = nil
                    moved = false
                    zone = .bar
                    caughtEdge = nil
                    committed = nil
                    loupeOpen = false
                }
                guard !pinching, duration > 0, width > knobSize else {
                    scrubbing = false
                    return
                }

                if !wasMoved {
                    // A tap on the "where you were" ring goes back there.
                    if let ring = ringSpot, abs(value.location.x - x(for: ring, width: width, in: window)) < 22 {
                        scrubbing = false
                        onCommit(ring)
                        Haptics.commit()
                        clearGhost()
                        if let jumpOrigin { expiredJump = jumpOrigin.id }
                        return
                    }
                    if kept != nil {
                        // A press held still on a spot: it already jumped.
                        scrubbing = false
                        return
                    }
                    scrubbing = false
                    let toward = max(-26, min(26, (value.location.x - knobX) * 0.3))
                    withAnimation(.easeOut(duration: 0.1)) { lean = toward }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.45).delay(0.1)) { lean = 0 }
                    Haptics.recoil()
                    let now = Date()
                    if zoom > 1, now.timeIntervalSince(lastTapAt) < 0.35 {
                        withAnimation(.easeOut(duration: 0.25)) { zoom = 1 }
                        lastTapAt = .distantPast
                        return
                    }
                    lastTapAt = now
                    // On a marked stretch: say what it is. Anywhere else: the time.
                    if let tapAt, let index = markers.firstIndex(where: {
                        $0.kind != nil && $0.start <= tapAt && $0.end >= tapAt
                    }) {
                        showTag(index)
                    } else if let tapAt {
                        showMark(at: tapAt)
                    }
                    return
                }

                if let kept, abs(kept - dragValue) < 0.5 {
                    // Broke the tether and let go where it broke: stay.
                    scrubbing = false
                    return
                }

                // A preview that was never committed: spring back.
                let home = kept ?? PlayerEngine.shared.currentTime
                withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) {
                    onScrub(home)
                    scrubbing = false
                }
                Haptics.recoil()
            }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                guard duration > Self.tightestSpan else { return }
                if !pinching {
                    pinching = true
                    zoomAtGestureStart = zoom
                    dwellTask?.cancel()
                    loupeOpen = false
                }
                let next = min(maxZoom, max(1, zoomAtGestureStart * value.magnification))
                if (next <= 1) != (zoom <= 1) || (next >= maxZoom) != (zoom >= maxZoom) {
                    Haptics.select()
                }
                zoom = next
                frozenWindow = nil
            }
            .onEnded { _ in
                pinching = false
                zoomAtGestureStart = zoom
            }
    }

    /// Starts, or starts again, the hold-still clock. When it runs out the
    /// tether breaks and playback moves to the previewed spot — or, for a
    /// press that never moved, to the spot under the finger.
    private func restartDwell() {
        dwellTask?.cancel()
        if tension > 0 { withAnimation(.easeOut(duration: 0.1)) { tension = 0 } }
        dwellTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, scrubbing else { return }
            let target = moved ? dragValue : (touchTime ?? current)
            let from = committed ?? origin ?? current
            guard abs(target - from) > 1 else { return }
            withAnimation(.linear(duration: 0.28)) { tension = 1 }
            try? await Task.sleep(for: Self.dwell - .milliseconds(120))
            guard !Task.isCancelled, scrubbing else { return }
            if let origin { showGhost(at: origin) }
            committed = target
            dragValue = target
            rawValue = target
            onScrub(target)
            onCommit(target)
            Haptics.commit()
            withAnimation(.easeOut(duration: 0.2)) { tension = 0 }
        }
    }

    // MARK: Drawing

    /// The loupe: ninety seconds around the dot, segments drawn wide.
    private func loupe(width: CGFloat) -> some View {
        let lw = loupeWindow
        let span = max(0.001, lw.upperBound - lw.lowerBound)
        let value = scrubbing ? dragValue : current
        let segment = marker(at: value)
        return VStack(spacing: 3) {
            HStack {
                Text(formatDuration(lw.lowerBound))
                Spacer(minLength: 4)
                if let segment {
                    HStack(spacing: 4) {
                        Circle().fill(segment.color).frame(width: 6, height: 6)
                        Text(segment.kind?.label ?? "Segment").fontWeight(.semibold)
                        Text("· \(formatDuration(max(0, segment.end - value))) left")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else if let zoneLabel {
                    Text(zoneLabel).fontWeight(.semibold)
                } else {
                    Text(formatDuration(value)).fontWeight(.semibold).monospacedDigit()
                }
                Spacer(minLength: 4)
                Text(formatDuration(lw.upperBound))
            }
            .font(.system(size: UIScale.pt(10), weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12)

            Canvas { context, size in
                let track = CGRect(x: 0, y: size.height / 2 - 7, width: size.width, height: 14)
                context.fill(Path(roundedRect: track, cornerRadius: 7), with: .color(.white.opacity(0.14)))
                for marker in markers where marker.end > lw.lowerBound && marker.start < lw.upperBound {
                    let left = max(0, size.width * ((marker.start - lw.lowerBound) / span))
                    let right = min(size.width, size.width * ((marker.end - lw.lowerBound) / span))
                    guard right > left else { continue }
                    let rect = CGRect(x: left, y: track.minY, width: right - left, height: track.height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(marker.color))
                }
                // Ticks every ten seconds, taller every thirty.
                var tick = (lw.lowerBound / 10).rounded(.up) * 10
                while tick <= lw.upperBound {
                    let x = size.width * ((tick - lw.lowerBound) / span)
                    let tall = Int(tick) % 30 == 0
                    let rect = CGRect(x: x - 0.5, y: track.maxY + 2, width: 1, height: tall ? 7 : 4)
                    context.fill(Path(rect), with: .color(.white.opacity(tall ? 0.7 : 0.4)))
                    tick += 10
                }
                // Where you were.
                if let origin, origin >= lw.lowerBound, origin <= lw.upperBound {
                    let x = size.width * ((origin - lw.lowerBound) / span)
                    context.stroke(Path(ellipseIn: CGRect(x: x - 5, y: size.height / 2 - 5, width: 10, height: 10)),
                                   with: .color(.white.opacity(0.8)), lineWidth: 1.5)
                }
                // The dot.
                let x = size.width * ((value - lw.lowerBound) / span)
                let head = CGRect(x: x - 1.5, y: track.minY - 6, width: 3, height: track.height + 12)
                context.fill(Path(roundedRect: head, cornerRadius: 1.5), with: .color(.white))
            }
            .frame(height: 30)
            .padding(.horizontal, 12)
            .overlay {
                if tension > 0 {
                    Circle()
                        .trim(from: 0, to: tension)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 26, height: 26)
                        .position(x: 12 + (width - 24) * CGFloat((value - lw.lowerBound) / span), y: 15)
                }
            }
        }
        .frame(width: width, height: Self.loupeHeight)
        // Solid underneath, glass on top. Plain regular glass is mostly
        // clear by design, and the loupe opens over the episode title — the
        // lettering read straight through it. A near-opaque dark fill under a
        // dark-tinted glass keeps the Liquid Glass edge and highlight while
        // hiding what is behind.
        // Reported as a little too solid after the first fix: 0.86 black
        // under the glass. 0.62 still hides the title's letters behind it but
        // lets the colour of the page through, so it reads as glass again.
        .background(Color.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
    }

    /// The small ticks over each cut on the bar.
    private func tickMarks(window: ClosedRange<Double>, span: Double) -> some View {
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

    /// A line from the previewed dot back to where you were, thinning as it
    /// stretches. Gone the moment the tether breaks.
    @ViewBuilder
    private func tether(width: CGFloat, window: ClosedRange<Double>) -> some View {
        if scrubbing, moved, committed == nil, let origin {
            let from = x(for: origin, width: width, in: window)
            let to = x(for: dragValue, width: width, in: window)
            let stretch = abs(to - from)
            if stretch > 4 {
                Path { path in
                    path.move(to: CGPoint(x: from, y: 22))
                    path.addQuadCurve(to: CGPoint(x: to, y: 22),
                                      control: CGPoint(x: (from + to) / 2, y: 22 + min(12, stretch / 10)))
                }
                .stroke(Color.white.opacity(0.55),
                        style: StrokeStyle(lineWidth: max(1, 3.5 - stretch / 90), lineCap: .round))
                .allowsHitTesting(false)
            }
        }
    }

    /// The ring left where you were, while a touch is down or for five seconds
    /// after a jump. Tapping it goes back.
    @ViewBuilder
    private func originRing(width: CGFloat, window: ClosedRange<Double>) -> some View {
        let spot = ringSpot ?? (scrubbing ? origin : nil)
        if let spot, spot >= window.lowerBound, spot <= window.upperBound {
            Circle()
                .strokeBorder(Color.white.opacity(0.85), lineWidth: 2)
                .background(Circle().fill(.ultraThinMaterial))
                .frame(width: 18, height: 18)
                .position(x: x(for: spot, width: width, in: window), y: 22)
                .allowsHitTesting(false)
                .transition(.opacity)
                .accessibilityElement()
                .accessibilityLabel("Where you were, \(formatDuration(spot))")
                .accessibilityIdentifier("WhereYouWere")
        }
    }

    @ViewBuilder
    private func markView(width: CGFloat, window: ClosedRange<Double>) -> some View {
        if let mark, duration > 0, mark >= window.lowerBound, mark <= window.upperBound {
            VStack(spacing: 2) {
                Text(formatDuration(mark))
                    .font(.system(size: UIScale.pt(10), weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize()
                Capsule()
                    .fill(Color.white.opacity(0.85))
                    .frame(width: 2.5, height: trackHeight + 10)
            }
            .position(x: x(for: mark, width: width, in: window), y: 22 - 6)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
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
        .font(.system(size: UIScale.pt(11)))
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.7))
        .fixedSize()
        .offset(y: -20)
    }

    /// How long the ring stays after a jump from the transcript. Longer than
    /// after a drag: you are reading, not looking at the bar.
    ///
    /// Longer under the screenshot run: the simulator's test driver waits for
    /// the app to go idle after every tap, and with a video and a scrolling
    /// title on screen that wait alone can use up ten seconds.
    private static let jumpRingSeconds: Double = DemoData.isEnabled ? 40 : 10

    /// "0:53 of 1:59", and ", was at 0:41" while the ring is up.
    private var spokenValue: String {
        var value = "\(formatDuration(current)) of \(formatDuration(duration))"
        if let ring = ringSpot { value += ", was at \(formatDuration(ring))" }
        return value
    }

    /// Where the ring is: after a drag, or after a jump made elsewhere that
    /// has not timed out or been used.
    private var ringSpot: Double? {
        if let ghost { return ghost }
        guard let jump = jumpOrigin, jump.id != expiredJump,
              Date.now.timeIntervalSince(jump.at) < Self.jumpRingSeconds else { return nil }
        return jump.time
    }

    private func showGhost(at time: Double, for seconds: Double = 5) {
        ghostTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { ghost = time }
        ghostTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.8)) { ghost = nil }
        }
    }

    private func clearGhost() {
        ghostTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { ghost = nil }
    }

    private func showTag(_ index: Int) {
        tagTask?.cancel()
        markTask?.cancel()
        mark = nil
        Haptics.select()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { tagged = index }
        tagTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { tagged = nil }
        }
    }

    /// The glass tag over a tapped stretch: what kind, whose ad, how long,
    /// and whether it is being skipped. Liquid Glass, as the system draws its
    /// own floating labels; it rises from the mark it names.
    @ViewBuilder
    private func segmentTag(width: CGFloat, window: ClosedRange<Double>) -> some View {
        if let tagged, markers.indices.contains(tagged), duration > 0, !scrubbing {
            let marker = markers[tagged]
            let seconds = Int((marker.end - marker.start).rounded())
            let length = seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
            let status = marker.rejected ? "Not an ad — plays" : (marker.ignored ? "Kept — plays" : "Skipped")
            let centre = x(for: (marker.start + marker.end) / 2, width: width, in: window)
            let tagWidth: CGFloat = 232
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(marker.color.opacity(1))
                        .frame(width: 8, height: 8)
                    Text(marker.kind?.label ?? "Segment")
                        .fontWeight(.semibold)
                    if !marker.sponsor.isEmpty {
                        Text(marker.sponsor)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                }
                .font(.system(size: UIScale.pt(15)))
                Text("\(formatDuration(marker.start))–\(formatDuration(marker.end)) · \(length) · \(status)")
                    .font(.system(size: UIScale.pt(12)).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(width: tagWidth, alignment: .leading)
            // Tinted dark: it floats over the episode title, and clear glass
            // over text read as two lines of text on top of each other.
            .glassEffect(.regular.tint(.black.opacity(0.5)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .offset(x: min(max(0, centre - tagWidth / 2), max(0, width - tagWidth)), y: -64)
            .transition(.scale(scale: 0.5, anchor: .bottom).combined(with: .opacity))
            .onTapGesture {
                tagTask?.cancel()
                withAnimation(.easeOut(duration: 0.2)) { self.tagged = nil }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("SegmentTag")
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
                                color: colour, kind: segment.kind, ignored: !active,
                                sponsor: segment.kind == .ad ? segment.sponsor : "", rejected: rejected))
        }
        // Left in drawing order — silences underneath, segments over them.
        // `marker(at:)` skips the unnamed ones on its own, so there is no
        // need to reorder this and every reason not to.
        markers = built
        tagged = nil
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
                    .font(.system(size: UIScale.pt(16)))
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
                        .font(.system(size: UIScale.pt(9)).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { gains.indices.contains(index) ? gains[index] : 0 },
                        set: { if gains.indices.contains(index) { gains[index] = $0 } }
                    ), in: -12...12)
                    .rotationEffect(.degrees(-90))
                    .frame(width: 130, height: 20)
                    .frame(width: 24, height: 140)
                    .tint(Theme.accentHot)
                    Text(labels[index]).font(.system(size: UIScale.pt(9))).foregroundStyle(.secondary)
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
                            player.jump(to: line.start)
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


/// The player's star.
///
/// Reported as lagging before it filled. The icon waited on the save: the tap
/// changed the episode, saved the whole store on the spot — which also sets
/// every list watching episodes re-fetching — and only then drew. Now the icon
/// flips from its own state the instant it is pressed, and the save follows a
/// moment later, off the tap.
///
/// White when filled, like the bookmark beside it. Every control on the Now
/// Playing screen is one colour, and on/off is carried by the filled glyph —
/// a yellow star was the only coloured control there.
struct StarButton: View {
    let episode: Episode
    let size: CGFloat
    @Environment(\.modelContext) private var context
    @State private var starred: Bool?

    private var isOn: Bool { starred ?? episode.isStarred }

    var body: some View {
        GlassIconButton(symbol: isOn ? "star.fill" : "star",
                        size: size,
                        label: isOn ? "Unstar" : "Star") {
            let new = !isOn
            starred = new
            Haptics.toggle(on: new)
            episode.isStarred = new
            DeferredSave.request(context)
        }
        .symbolEffect(.bounce.up, options: .speed(1.6), value: isOn)
        .onChange(of: episode.guid) { _, _ in starred = nil }
        .onChange(of: episode.isStarred) { _, value in
            if starred != nil, starred != value { starred = value }
        }
    }
}

/// A save a moment after the last change, rather than on the tap.
@MainActor
enum DeferredSave {
    private static var pending: Task<Void, Never>?

    static func request(_ context: ModelContext, after delay: Duration = .milliseconds(700)) {
        pending?.cancel()
        pending = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            try? context.save()
            LibraryIndexStatus.shared.refreshCounts()
        }
    }
}


/// Video or audio only, for a video episode.
///
/// The sound is always the audio engine's — every audio setting applies —
/// and the picture follows it (`VideoSync`). Switching never touches the
/// sound, so it is instant and cannot fall out of step; with Audio chosen the
/// picture is not decoded at all. Ad skipping is seeking, so the picture
/// jumps with the sound.
struct VideoModeToggle: View {
    /// False in the player's top bar, which has one row of height to give;
    /// the player shows the problem line under the picture instead.
    var showsProblem = true
    @State private var player = PlayerEngine.shared
    @Namespace private var glass

    var body: some View {
        VStack(spacing: 6) {
            toggle
            if showsProblem, let problem = player.videoSync.problem, player.prefersVideo {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
    }

    private var toggle: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                option("Video", symbol: "play.rectangle.fill", selected: player.prefersVideo) {
                    player.prefersVideo = true
                }
                option("Audio", symbol: "waveform", selected: !player.prefersVideo) {
                    player.prefersVideo = false
                }
            }
            .padding(3)
            .glassEffect(.regular, in: Capsule())
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("VideoModeToggle")
    }

    private func option(_ title: String, symbol: String, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button {
            guard !selected else { return }
            Haptics.select()
            withAnimation(.snappy(duration: 0.3)) { action() }
        } label: {
            Label(title, systemImage: symbol)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Color.black : Color.white)
                .background {
                    if selected {
                        Capsule().fill(.white).matchedGeometryEffect(id: "pick", in: glass)
                    }
                }
        }
        .buttonStyle(.plain)
        // Not just "Audio": the Speed and Audio button already answers to
        // that, and a test tapping "Audio" opened the wrong thing.
        .accessibilityLabel(title == "Audio" ? "Audio Only" : "Show Video")
        .accessibilityIdentifier(title == "Audio" ? "VideoModeAudio" : "VideoModeVideo")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Full screen video

/// The picture, filling the screen, with the app's own transport over it.
///
/// Not `AVPlayerViewController`: its controls would drive the muted video
/// player, which follows the sound rather than leading it, so its scrubber
/// would fight `VideoSync` and know nothing about the ad cuts. These are the
/// same controls as the player screen, drawn over the picture, and they act on
/// the sound as everything else in the app does.
struct FullScreenVideo: View {
    @Binding var pictureInPictureActive: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var player = PlayerEngine.shared
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    /// How far the picture has been pulled down, in points. Zero at rest.
    @State private var pull: CGFloat = 0
    /// Whether the current drag is a pull-down (decided once, on its first
    /// movement), so a sideways drag never starts one halfway through.
    @State private var pulling: Bool?

    /// Past this, or with a fast enough flick, letting go leaves full screen.
    private static let dismissDistance: CGFloat = 120
    private static let dismissFlick: CGFloat = 900

    /// 0 at rest, 1 when pulled about a third of the way down the screen.
    private var pullProgress: CGFloat { min(1, pull / 320) }

    var body: some View {
        ZStack {
            // Fades as the picture is pulled, so the player shows through
            // behind it — the same cue Apple's video player gives.
            Color.black
                .opacity(1 - 0.85 * pullProgress)
                .ignoresSafeArea()
            if let output = player.videoOutput {
                VideoSurface(player: output, pictureInPictureActive: $pictureInPictureActive)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    // Follows the finger down and shrinks a little.
                    .scaleEffect(1 - 0.18 * pullProgress)
                    .offset(y: pull)
            } else {
                ProgressView().tint(.white)
            }
            if showControls && pull == 0 { controls.transition(.opacity) }
        }
        .presentationBackground(.clear)
        .statusBarHidden(!showControls)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) { showControls.toggle() }
            Haptics.select()
            if showControls { scheduleHide() }
        }
        // A plain `.gesture`, not simultaneous: the transport buttons still
        // take their taps (a drag needs 12pt of movement to begin), and a
        // pull that starts on a button pulls the picture rather than also
        // pressing it.
        .gesture(pullToDismiss)
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .persistentSystemOverlays(showControls ? .automatic : .hidden)
        // VoiceOver's two-finger scrub leaves, as the chevron does.
        .accessibilityAction(.escape) { dismiss() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FullScreenVideo")
    }

    /// Swipe down to leave full screen (pass 16). A `.fullScreenCover` has no
    /// interactive dismissal of its own; only the chevron worked.
    private var pullToDismiss: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                if pulling == nil {
                    let t = value.translation
                    pulling = t.height > 0 && t.height > abs(t.width)
                }
                guard pulling == true else { return }
                // A little resistance upward, none downward.
                let dy = value.translation.height
                pull = dy > 0 ? dy : dy / 4
            }
            .onEnded { value in
                defer { pulling = nil }
                guard pulling == true else { return }
                let flick = value.predictedEndTranslation.height - value.translation.height
                if pull > Self.dismissDistance || (pull > 30 && flick > Self.dismissFlick) {
                    Haptics.select()
                    dismiss()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { pull = 0 }
                }
            }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showControls = false }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Leave full screen")
                .accessibilityIdentifier("LeaveFullScreen")
                Spacer()
                Text(player.currentEpisode?.title ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 16)
            Spacer()
            FullScreenTransport()
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
    }
}

/// Its own view: it reads the playhead, which changes five times a second.
private struct FullScreenTransport: View {
    @State private var player = PlayerEngine.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 28) {
                Button { player.skipBackward(); Haptics.select() } label: {
                    Image(systemName: "gobackward.15").font(.title2.weight(.semibold))
                }
                Button { player.togglePlayPause(); Haptics.select() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 60, height: 60)
                }
                Button { player.skipForward(); Haptics.select() } label: {
                    Image(systemName: "goforward.30").font(.title2.weight(.semibold))
                }
            }
            HStack(spacing: 10) {
                Text(formatDuration(player.currentTime)).font(.caption.monospacedDigit())
                Capsule().fill(.white.opacity(0.25)).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(.white)
                                .frame(width: proxy.size.width * CGFloat(min(1, max(0, player.duration > 0 ? player.currentTime / player.duration : 0))))
                        }
                    }
                    .frame(height: 4)
                Text(formatDuration(player.duration)).font(.caption.monospacedDigit())
            }
        }
        .foregroundStyle(.white)
    }
}


/// Watches the playhead for the live transcript and reports which line it is
/// in. Draws nothing: it exists so that the five-times-a-second read of
/// `currentTime` belongs to this body and not to the transcript's.
struct PlayheadLineWatcher: View {
    let episode: Episode?
    let lines: [TimedLine]
    @Binding var activeIndex: Int?
    @State private var player = PlayerEngine.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: player.currentTime, initial: true) { _, now in
                let found = player.currentEpisode === episode ? Self.line(at: now, in: lines) : nil
                if found != activeIndex { activeIndex = found }
            }
    }

    /// Lines are in time order: a binary search, not a walk.
    static func line(at time: Double, in lines: [TimedLine]) -> Int? {
        var low = 0, high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if time < lines[mid].start { high = mid - 1 }
            else if time >= lines[mid].end { low = mid + 1 }
            else { return mid }
        }
        return nil
    }
}
