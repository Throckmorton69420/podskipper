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
    @Environment(\.modelContext) private var context
    @State private var moreFromShow: [Episode] = []
    @State private var similar: [PodcastSearchResult] = []
    @State private var previewShow: PodcastSearchResult?
    /// "Weekly", "Daily"… worked out from the show's recent release dates.
    @State private var frequency: String?
    /// The transcript's opening lines, read from its file once.
    @State private var transcriptPreview = ""
    @State private var chapterEditor: ChapterEditorRequest?

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
                        GlassButtonLabel(title: isCurrent && player.isPlaying ? "Pause" : (episode.playbackPosition > 1 ? "Resume" : "Play"),
                                         systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill",
                                         font: .headline)
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
                // Pass 30 (his 5 Oct request): the same Activity bar as at the
                // top of the other screens, so a tap opens every step, the
                // time spent and left, and Stop / Restart — the slim progress
                // line here couldn't be opened.
                if pipeline.isProcessing(episode) || pipeline.isWaiting(episode.guid) {
                    ProcessingBanner(pipeline: pipeline, inList: true)
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
                // The raw HTML, not `plainDescription` — this page's whole
                // point is to read the notes, and Apple's own episode page
                // keeps their links tappable.
                EpisodeNotesText(html: episode.episodeDescription, id: episode.guid)
                    .contentRow()
            }
            // Apple's episode page, 27.2 beta 2 (his 24 Sep ask, pass 21):
            // Hosts & Guests with photos, From This Episode, the transcript,
            // then more from the show and Information at the end.
            if !people.isEmpty {
                SectionHeader("Hosts & Guests")
                HostsAndGuestsShelf(people: people).fullWidthRow()
            }
            EpisodeChaptersSection(episode: episode, chapterEditor: $chapterEditor)
            if episode.hasTranscript {
                SectionHeader("Transcript")
                NavigationLink { TranscriptView(episode: episode) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(transcriptPreview).font(.subheadline).lineLimit(3)
                            .foregroundStyle(.secondary)
                        Text("Made on your iPhone").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("episode.transcript")
                .contentRow()
            }

            // Apple's episode page carries on into the show; so does this.
            if !moreFromShow.isEmpty {
                SectionHeader("More from \(episode.podcast?.title ?? "This Show")")
                ForEach(moreFromShow) { other in
                    // The row opens the episode itself (EpisodeRoute); wrapping
                    // it in a second link put a chevron beside every one.
                    EpisodeCompactRow(episode: other)
                        .contentRow()
                }
            }

            if !similar.isEmpty {
                SectionHeader("You Might Also Like")
                NavigationShelf(items: similar, artwork: { $0.artworkURL }, size: Metrics.artStrip) { show in
                    Text(show.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                } onTap: { show in
                    previewShow = show
                }
                .fullWidthRow()
            }
            informationSection
            BottomClearance()
        }
        .listStyle(.plain)
        .accessibilityIdentifier("EpisodePage")
        .scrollContentBackground(.hidden)
        .amoledScreen()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $previewShow) { ShowPreviewView(show: $0) }
        .sheet(item: $chapterEditor) { request in
            ChapterEditorView(episode: episode, chapter: request.chapter)
        }
        .task(id: episode.guid) { await loadAround() }
    }

    /// Hosts and guests the feed names on this episode, then the show's.
    private var people: [PersonEntry] {
        PersonEntry.list([episode.people, episode.podcast?.people ?? ""])
    }



    /// Apple's Information block: show, how often it comes out, when this
    /// one was published (date and time), length, rating.
    @ViewBuilder
    private var informationSection: some View {
        SectionHeader("Information")
        VStack(spacing: 0) {
            if let show = episode.podcast {
                NavigationLink(value: ShowRoute(show)) {
                    InfoRow(title: "Show", value: show.title)
                }
                .buttonStyle(.plain)
                Divider()
            }
            if let frequency {
                InfoRow(title: "Frequency", value: frequency)
                Divider()
            }
            InfoRow(title: "Published", value: episode.publishedAt.formatted(date: .long, time: .shortened))
            let length = episode.duration > 0 ? episode.duration : episode.publishedDuration
            if length > 0 {
                Divider()
                InfoRow(title: "Length", value: formatMinutes(length))
            }
            if episode.cleanDuration > 0, length - episode.cleanDuration > 5 {
                Divider()
                InfoRow(title: "Without Inserted Ads", value: formatMinutes(episode.cleanDuration))
            }
            if !episode.numberLabel.isEmpty {
                Divider()
                InfoRow(title: "Episode", value: episode.numberLabel)
            }
            Divider()
            InfoRow(title: "Rating", value: episode.isExplicit ? "Explicit" : "Clean")
        }
        .contentRow()
        .accessibilityIdentifier("episode.information")
    }

    private func loadAround() async {
        if episode.hasTranscript, transcriptPreview.isEmpty {
            let text = episode.transcriptText ?? ""
            transcriptPreview = text.isEmpty
                ? episode.timedTranscript.prefix(8).map(\.text).joined(separator: " ")
                : String(text.prefix(240))
        }
        if let show = episode.podcast {
            let feedURL = show.feedURL
            let guid = episode.guid
            let published = episode.publishedAt
            // The ones either side of this episode, newest first.
            var descriptor = FetchDescriptor<Episode>(
                predicate: #Predicate {
                    $0.podcast?.feedURL == feedURL && $0.guid != guid && $0.publishedAt < published
                },
                sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            descriptor.fetchLimit = 5
            moreFromShow = (try? context.fetch(descriptor)) ?? []
            if moreFromShow.isEmpty {
                var newer = FetchDescriptor<Episode>(
                    predicate: #Predicate { $0.podcast?.feedURL == feedURL && $0.guid != guid },
                    sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
                newer.fetchLimit = 5
                moreFromShow = (try? context.fetch(newer)) ?? []
            }
            var recent = FetchDescriptor<Episode>(predicate: #Predicate { $0.podcast?.feedURL == feedURL },
                                                  sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
            recent.fetchLimit = 13
            frequency = Self.frequency(of: ((try? context.fetch(recent)) ?? []).map(\.publishedAt))
            similar = (try? await DiscoverService.related(to: show, limit: 12)) ?? []
        }
    }

    /// The typical gap between releases, in Apple's words where it has them.
    static func frequency(of dates: [Date]) -> String? {
        guard dates.count >= 4 else { return nil }
        let gaps = zip(dates, dates.dropFirst()).map { $0.timeIntervalSince($1) / 86_400 }.sorted()
        let median = gaps[gaps.count / 2]
        switch median {
        case ..<1.5: return "Daily"
        case ..<4.5: return "Twice a Week"
        case ..<9: return "Weekly"
        case ..<18: return "Every Two Weeks"
        case ..<40: return "Monthly"
        default: return "Occasionally"
        }
    }

    /// Seconds under a minute, minutes above — "0m removed" said nothing.
    private var removedText: String {
        let seconds = episode.adSecondsRemoved
        return seconds < 60 ? "\(Int(seconds.rounded()))s" : formatMinutes(seconds)
    }

    private var metaLine: String {
        var parts = [episode.publishedAt.formatted(.dateTime.month(.wide).day().year())]
        if !episode.numberLabel.isEmpty { parts.append(episode.numberLabel) }
        if episode.hasKnownVideo { parts.append("Video") }
        let length = episode.duration > 0 ? episode.duration : episode.publishedDuration
        if length > 0 { parts.append(formatMinutes(length)) }
        if episode.isPlayed { parts.append("Played") }
        return parts.joined(separator: " · ")
    }
}

/// One line of the Information block: label on the left, value on the right.
private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}
