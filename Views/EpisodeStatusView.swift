import SwiftUI
import SwiftData

/// Where one episode's ad finding stands, right now.
///
/// Opened by tapping a notification about that episode. It reads the live
/// state rather than repeating the notification, so a job that has since
/// finished says so, one still running shows its progress, and one still
/// stuck says why and offers to try again.
struct EpisodeStatusView: View {
    let guid: String

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings
    @Environment(ProcessingPipeline.self) private var pipeline
    @State private var episode: Episode?
    @State private var looked = false

    var body: some View {
        NavigationStack {
            Group {
                if let episode {
                    content(episode)
                } else if looked {
                    ContentUnavailableView("Episode not found",
                                           systemImage: "questionmark.circle",
                                           description: Text("It may have been removed from your library."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Finding Ads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task(id: guid) {
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
            descriptor.fetchLimit = 1
            episode = try? context.fetch(descriptor).first
            looked = true
        }
    }

    @ViewBuilder
    private func content(_ episode: Episode) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    Artwork(url: episode.artworkURL ?? episode.podcast?.artworkURL, size: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(episode.podcast?.title ?? "")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(episode.title)
                            .font(.headline)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }

                StatusCard(episode: episode, pipeline: pipeline)
                    .accessibilityIdentifier("EpisodeStatusCard")

                actions(episode)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func actions(_ episode: Episode) -> some View {
        let running = pipeline.isProcessing(episode) || pipeline.waitingToProcess == episode.guid
        VStack(spacing: 10) {
            if pipeline.isProcessing(episode), let minutes = pipeline.stalledMinutes {
                StalledLine(pipeline: pipeline, minutes: minutes)
                    .padding(.horizontal, 4)
            }
            if !running && episode.processingState != .ready {
                Button {
                    Task { await pipeline.processNow(episode) }
                } label: {
                    Label(pipeline.isPaused(episode) ? "Resume"
                          : episode.processingState == .failed ? "Try Again" : "Find Ads Now",
                          systemImage: pipeline.isPaused(episode) ? "play.circle.fill" : "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accentHot)
                .accessibilityIdentifier("StatusRetry")
            }
            Button {
                dismiss()
                PlayCoordinator.play(episode, settings: settings, pipeline: pipeline)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glass)
        }
    }
}

/// The state line. Its own view, because while the job runs it reads the
/// progress several times a second — that read belongs in a small body, not
/// the sheet's.
private struct StatusCard: View {
    let episode: Episode
    let pipeline: ProcessingPipeline

    var body: some View {
        let state = current
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title2)
                .foregroundStyle(state.tint)
                .frame(width: 30)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 6) {
                Text(state.title).font(.headline)
                if let detail = state.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if pipeline.isProcessing(episode) {
                    ProgressView(value: min(1, max(0, pipeline.overallFraction)))
                        .tint(Theme.accentHot)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.snappy, value: state.title)
    }

    private var current: (title: String, detail: String?, symbol: String, tint: Color) {
        if pipeline.isProcessing(episode) {
            let percent = Int(min(1, max(0, pipeline.overallFraction)) * 100)
            if pipeline.stalledSince != nil {
                return ("Stuck at \(percent)%", "\(pipeline.stage.label) has made no progress for a couple of minutes. Restart keeps the transcript and the answers so far.",
                        "exclamationmark.triangle.fill", .orange)
            }
            return ("Working on it — \(percent)%", pipeline.stage.label, "waveform.badge.magnifyingglass", Theme.accentWarm)
        }
        if pipeline.waitingToProcess == episode.guid {
            return ("Waiting its turn", "Starts as soon as the job ahead of it steps aside.", "clock", .secondary)
        }
        if pipeline.isPaused(episode) {
            return ("Paused",
                    "iOS paused it while the app was away. The transcript and every answer so far are kept — Resume carries on from there.",
                    "pause.circle.fill", .orange)
        }
        switch episode.processingState {
        case .ready:
            let count = episode.adSegments.filter { $0.userVerdict != .notAnAd }.count
            let when = episode.lastProcessedAt.map { " " + $0.formatted(.relative(presentation: .named)) } ?? ""
            return ("Done — it went through",
                    (count == 1 ? "1 break found" : "\(count) breaks found") + when + ". Ready to play without them.",
                    "checkmark.circle.fill", .green)
        case .failed:
            return ("Still not done",
                    (episode.processingError ?? "It stopped before finishing.") + " Try again below.",
                    "exclamationmark.triangle.fill", .orange)
        case .notStarted:
            return ("Not finished",
                    "It stopped part-way. Anything already transcribed is kept, so trying again is quicker.",
                    "pause.circle.fill", .orange)
        default:
            return ("Partly done", "It stopped part-way through. Try again to finish it.", "pause.circle.fill", .orange)
        }
    }
}
