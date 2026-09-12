import SwiftUI
import SwiftData
import Charts

// MARK: - Statistics

struct StatsView: View {
    @Query(sort: \ListeningSession.startedAt, order: .reverse) private var sessions: [ListeningSession]
    @Environment(\.modelContext) private var context

    /// `summarize` walks every session and every episode. As a computed
    /// property fed by a `@Query` it re-ran on every render of a scrolling
    /// screen with charts on it.
    @State private var summary = StatsService.Summary()

    private func reload() {
        let episodes = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
        summary = StatsService.summarize(sessions: sessions, episodes: episodes)
    }

    var body: some View {
        Group {
            if sessions.isEmpty {
                ContentUnavailableView("No listening yet",
                    systemImage: "chart.bar",
                    description: Text("Play something and this fills in."))
            } else {
                content
            }
        }
        .navigationTitle("Statistics")
        .amoledScreen()
        .task { reload() }
        .onChange(of: sessions.count) { _, _ in reload() }
    }

    private var content: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    HStack {
                        bigStat(formatMinutes(summary.totalListened), "listened", .green)
                        Divider().frame(height: 40)
                        bigStat(summary.timeSavedText, "saved", Theme.accentHot)
                    }
                    HStack {
                        bigStat("\(summary.episodesFinished)", "finished", Theme.accentWarm)
                        Divider().frame(height: 40)
                        bigStat("\(summary.currentStreak)", "day streak", .blue)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentRow()
            }

            if !summary.byDay.isEmpty {
                Section {
                    Chart(summary.byDay) { entry in
                        BarMark(
                            x: .value("Day", entry.day, unit: .day),
                            y: .value("Minutes", entry.seconds / 60)
                        )
                        .foregroundStyle(Theme.accentGradient)
                        .cornerRadius(3)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 160)
                    .contentRow()
                }
            }

            if !summary.topShows.isEmpty {
                Section {
                    ForEach(summary.topShows) { entry in
                        HStack {
                            Text(entry.show).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text(formatMinutes(entry.seconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentRow()
                    }
                }
            }

            Section {
                HStack {
                    Text("Longest streak")
                    Spacer()
                    Text("\(summary.longestStreak) days").foregroundStyle(.secondary)
                }
                .contentRow()
                HStack {
                    Text("Ads skipped")
                    Spacer()
                    Text(formatMinutes(summary.adsSkipped)).foregroundStyle(.secondary)
                }
                .contentRow()
                HStack {
                    Text("Silence trimmed")
                    Spacer()
                    Text(formatMinutes(summary.silenceSkipped)).foregroundStyle(.secondary)
                }
                .contentRow()
            }

            Section {
                NavigationLink("Listening history") { HistoryView() }
                    .contentRow()
            }
        }
        .listStyle(.plain)
    }

    private func bigStat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.bold()).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct HistoryView: View {
    @Query(sort: \ListeningSession.startedAt, order: .reverse) private var sessions: [ListeningSession]
    @Environment(\.modelContext) private var context

    private struct DayGroup: Identifiable {
        let day: Date
        let items: [ListeningSession]
        var id: Date { day }
    }

    private var grouped: [DayGroup] {
        let buckets = Dictionary(grouping: sessions) { $0.day }
        return buckets.keys.sorted(by: >).map { DayGroup(day: $0, items: buckets[$0] ?? []) }
    }

    var body: some View {
        List {
            ForEach(grouped) { group in
                Section {
                    ForEach(group.items) { session in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(session.episodeTitle).font(.subheadline).lineLimit(2)
                            HStack(spacing: 6) {
                                Text(session.showTitle).lineLimit(1)
                                Text("·")
                                Text(formatMinutes(session.seconds))
                                if session.adSecondsSkipped > 30 {
                                    Text("· \(Int(session.adSecondsSkipped / 60))m ads cut")
                                        .foregroundStyle(.green)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .contentRow()
                    }
                } header: {
                    Text(group.day, format: .dateTime.weekday(.wide).month().day())
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .toolbar {
            Button("Clear", role: .destructive) {
                for session in sessions { context.delete(session) }
                try? context.save()
            }
            .font(.caption)
        }
    }
}

// MARK: - Bookmarks

struct BookmarksView: View {
    @Query(sort: \Bookmark.createdAt, order: .reverse) private var bookmarks: [Bookmark]
    @Environment(\.modelContext) private var context
    @State private var player = PlayerEngine.shared

    var body: some View {
        Group {
            if bookmarks.isEmpty {
                ContentUnavailableView("No bookmarks",
                    systemImage: "bookmark",
                    description: Text("Tap More → Bookmark while listening to save the moment."))
            } else {
                list
            }
        }
        .navigationTitle("Bookmarks")
        .amoledScreen()
    }

    private var list: some View {
        List {
            ForEach(bookmarks) { bookmark in
                Button {
                    jump(to: bookmark)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(formatDuration(bookmark.timestamp))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Theme.accentHot)
                            Text(bookmark.showTitle).font(.caption2)
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(bookmark.episodeTitle).font(.subheadline).lineLimit(2)
                            .foregroundStyle(.primary)
                        if !bookmark.note.isEmpty {
                            Text(bookmark.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentRow()
                .swipeActions {
                    Button(role: .destructive) {
                        context.delete(bookmark); try? context.save()
                    } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
    }

    /// Fetched by guid on demand. Holding a `@Query` over every episode in the
    /// store just to resolve a tap is what this replaces.
    private func jump(to bookmark: Bookmark) {
        let guid = bookmark.episodeGUID
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        guard let episode = (try? context.fetch(descriptor))?.first else { return }
        if player.currentEpisode !== episode {
            player.load(episode, autoplay: false)
        }
        player.seek(to: bookmark.timestamp)
        player.play()
    }
}

// MARK: - Chapters

struct ChapterListView: View {
    let episode: Episode
    @State private var player = PlayerEngine.shared

    private var chapters: [Chapter] {
        episode.chapters.sorted { $0.start < $1.start }
    }

    var body: some View {
        Group {
            if chapters.isEmpty {
                ContentUnavailableView("No chapters",
                    systemImage: "list.bullet.indent",
                    description: Text("This episode's audio doesn't carry chapter markers."))
            } else {
                list
            }
        }
        .navigationTitle("Chapters")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
    }

    private var list: some View {
        List {
            ForEach(chapters) { chapter in
                Button {
                    if player.currentEpisode !== episode { player.load(episode, autoplay: false) }
                    player.seek(to: chapter.start)
                    player.play()
                } label: {
                    HStack(spacing: 12) {
                        Text(formatDuration(chapter.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 52, alignment: .leading)
                        Text(chapter.title)
                            .font(.subheadline)
                            .foregroundStyle(isCurrent(chapter) ? Theme.accentHot : .primary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        if isCurrent(chapter) {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2).foregroundStyle(Theme.accentHot)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contentRow()
            }
        }
        .listStyle(.plain)
    }

    private func isCurrent(_ chapter: Chapter) -> Bool {
        guard player.currentEpisode === episode else { return false }
        return ChapterService.chapter(at: player.currentTime, in: chapters) === chapter
    }
}
