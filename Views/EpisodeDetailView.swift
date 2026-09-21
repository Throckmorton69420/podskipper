import SwiftUI
import SwiftData

/// One episode on its own page: cover, show, date, length, what was found,
/// the whole description, and the same actions as its row.
///
/// Apple Podcasts has an episode page; PodSkipper had nowhere to go when you
/// tapped an episode outside its show — reported from Up Next's "Getting the
/// next 2 ready" card, where tapping showed nothing.
struct EpisodeDetailView: View {
    let episode: Episode
    @Environment(ProcessingPipeline.self) private var pipeline
    @Environment(AppSettings.self) private var settings
    @State private var player = PlayerEngine.shared

    private var isCurrent: Bool { player.currentEpisode?.guid == episode.guid }

    var body: some View {
        List {
            VStack(spacing: 14) {
                Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: Metrics.artHero)
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
                VStack(spacing: 6) {
                    // Plain text: a link inside a list row gets the list's
                    // disclosure chevron at the far edge and pulls the name
                    // off-centre.
                    if let show = episode.podcast?.title, !show.isEmpty {
                        Text(show)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accentHot)
                    }
                    Text(episode.title)
                        .font(.title3.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(metaLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        if isCurrent { player.togglePlayPause() }
                        else { PlayCoordinator.play(episode, settings: settings, pipeline: pipeline) }
                    } label: {
                        Label(isCurrent && player.isPlaying ? "Pause" : (episode.playbackPosition > 1 ? "Resume" : "Play"),
                              systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accentHot)

                    if episode.processingState != .ready {
                        Button {
                            Task { await pipeline.processNow(episode) }
                        } label: {
                            Label(pipeline.isProcessing(episode) ? "Finding…" : "Find Ads",
                                  systemImage: "wand.and.sparkles")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        .disabled(pipeline.isProcessing(episode))
                    }

                    Menu {
                        EpisodeMenuItems(episode: episode, offersDetails: false)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.headline)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                }
                if pipeline.isProcessing(episode) {
                    InlineProcessingRow(pipeline: pipeline)
                }
            }
            .frame(maxWidth: .infinity)
            .readableWidth(520)
            .plainRow(top: 8, bottom: 12)

            if episode.processingState == .ready {
                let cuts = episode.adSegments.filter { $0.userVerdict != .notAnAd }
                Label("\(cuts.count) cut\(cuts.count == 1 ? "" : "s") · \(removedText) removed",
                      systemImage: "wand.and.sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .contentRow()
            }

            if !episode.plainDescription.isEmpty {
                Text(episode.plainDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentRow()
            }
            BottomClearance()
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .amoledScreen()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Seconds under a minute, minutes above — "0m removed" said nothing.
    private var removedText: String {
        let seconds = episode.adSecondsRemoved
        return seconds < 60 ? "\(Int(seconds.rounded()))s" : formatMinutes(seconds)
    }

    private var metaLine: String {
        var parts = [episode.publishedAt.formatted(.dateTime.month(.wide).day().year())]
        if !episode.numberLabel.isEmpty { parts.append(episode.numberLabel) }
        let length = episode.duration > 0 ? episode.duration : episode.publishedDuration
        if length > 0 { parts.append(formatMinutes(length)) }
        if episode.isPlayed { parts.append("Played") }
        return parts.joined(separator: " · ")
    }
}
