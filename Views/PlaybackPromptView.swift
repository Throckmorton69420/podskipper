import SwiftUI
import SwiftData

/// The sheet that appears when you press play on an episode whose ads have not
/// been found yet.
///
/// It does not block: the countdown runs and lands on **play**, so ignoring it
/// entirely gets you listening. Swiping it away cancels — nothing plays, and
/// autoplay stops there (a Settings switch makes a swipe play instead).
struct PlaybackPromptView: View {
    @Bindable var request: PlaybackRequest
    let episode: Episode

    @Environment(AppSettings.self) private var settings

    private var fraction: Double {
        let total = max(1, settings.playPromptCountdown)
        return max(0, min(1, request.secondsLeft / total))
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.tertiary)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 18)

            HStack(alignment: .top, spacing: Metrics.rowTextGap) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.reason.headline)
                        .font(.system(size: Metrics.titleSize, weight: .semibold))
                        .lineSpacing(Metrics.titleLineSpacing)
                    Text(episode.title)
                        .font(.system(size: Metrics.subtitleSize))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL,
                        size: Metrics.artRow)
            }
            .padding(.horizontal, Metrics.gutter)

            Text(request.reason.detail)
                .font(.system(size: Metrics.subtitleSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Metrics.gutter)
                .padding(.top, 14)

            Spacer(minLength: 20)

            VStack(spacing: 10) {
                // The default, and the one the countdown lands on. Prominent
                // glass so it reads as the answer rather than as one of two
                // equal options — because it is the answer nine times out of
                // ten, and the whole complaint was having to wait.
                Button {
                    request.choosePlayNow()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("Play now")
                        Text(countdownLabel)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: Metrics.bodySize, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accentHot)

                Button {
                    request.chooseProcessFirst()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.sparkles")
                        Text("Find ads first")
                    }
                    .font(.system(size: Metrics.bodySize, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(.glass)

                Text("Swipe down to cancel. You can change the default in Settings.")
                    .font(.system(size: Metrics.metaSize))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, 16)

            // A thin bar rather than a spinner. It shows the same thing the
            // number does, without asking anyone to watch a digit.
            GeometryReader { proxy in
                Capsule()
                    .fill(Theme.accentHot.opacity(0.7))
                    .frame(width: proxy.size.width * fraction)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.linear(duration: 0.1), value: fraction)
            }
            .frame(height: 3)
        }
        .frame(maxWidth: Metrics.readableMax)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.thinMaterial)
        .interactiveDismissDisabled(false)
    }

    private var countdownLabel: String {
        let seconds = Int(request.secondsLeft.rounded(.up))
        return seconds > 0 ? "· \(seconds)" : ""
    }
}

// MARK: - Routing every play through the question

/// One place that decides what pressing play means.
///
/// Every play in the app used to call `player.load(episode)` directly, which is
/// why there was nowhere to ask the question and no way to say "just play it".
/// They go through here now: already processed, or ad skipping off for this
/// episode, and it plays immediately exactly as before. Otherwise it raises the
/// request and the sheet appears.
@MainActor
enum PlayCoordinator {

    static func play(_ episode: Episode,
                     settings: AppSettings,
                     pipeline: ProcessingPipeline,
                     reason: PlaybackRequest.Reason = .tapped) {
        let player = PlayerEngine.shared

        guard PlaybackRequest.needsAsking(episode, settings: settings) else {
            player.load(episode)
            return
        }

        // The listener has already said they do not want to be asked.
        guard !settings.playUnprocessedByDefault || settings.playPromptCountdown > 0 else {
            player.load(episode)
            return
        }

        PlaybackRequest.shared.ask(
            for: episode,
            reason: reason,
            countdownSeconds: settings.playPromptCountdown,
            playNow: { episode in
                player.load(episode)
            },
            processFirst: { episode in
                Task {
                    await pipeline.processNow(episode)
                    // Only start it if nothing else has taken over the player
                    // in the meantime — a wait of several minutes is long
                    // enough for someone to have started something else.
                    if player.currentEpisode == nil {
                        player.load(episode)
                    }
                }
            }
        )
    }
}
