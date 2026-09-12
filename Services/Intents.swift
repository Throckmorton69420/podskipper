import AppIntents
import SwiftData
import UIKit

/// Exposes the pipeline to Shortcuts.
///
/// A word on what Shortcuts can and can't do here, because it shapes the
/// design: iOS will not let an app transcribe an hour of audio in a headless
/// background intent. It hands you a short window and then kills you.
///
/// So these intents come in two flavours:
///   • `RefreshFeedsIntent` — light work only. Safe to run headless from a
///     time-of-day automation. Fetches feeds, queues new episodes, and asks
///     iOS to schedule the heavy work.
///   • `ProcessAndPublishIntent` — opens the app, which gives it full
///     foreground runtime. Use this from a "when charger connects"
///     automation, or as a Home Screen button.
///
/// The engine is still `BGProcessingTask`. Shortcuts is a nudge, not the motor.

struct PodSkipperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshFeedsIntent(),
            phrases: ["Refresh \(.applicationName) feeds"],
            shortTitle: "Refresh feeds",
            systemImageName: "arrow.clockwise"
        )
        AppShortcut(
            intent: ProcessAndPublishIntent(),
            phrases: ["Process episodes in \(.applicationName)"],
            shortTitle: "Process & publish",
            systemImageName: "wand.and.sparkles"
        )
        AppShortcut(
            intent: PlayNextIntent(),
            phrases: ["Play next in \(.applicationName)",
                      "Play my next podcast in \(.applicationName)"],
            shortTitle: "Play next",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: TogglePlaybackIntent(),
            phrases: ["Pause \(.applicationName)", "Resume \(.applicationName)"],
            shortTitle: "Play or pause",
            systemImageName: "playpause.fill"
        )
        AppShortcut(
            intent: SkipCurrentSegmentIntent(),
            phrases: ["Skip this bit in \(.applicationName)",
                      "Skip the ad in \(.applicationName)"],
            shortTitle: "Skip this bit",
            systemImageName: "forward.end.fill"
        )
    }
}

// MARK: - Light: refresh + queue + schedule

struct RefreshFeedsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh feeds"
    static var description = IntentDescription(
        "Checks subscribed shows for new episodes, queues them, and asks iOS to process them in the background."
    )
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentContext = try AppLibrary.resolvedContext()

        let pipeline = ProcessingPipeline.shared
        pipeline.configure(context: intentContext, settings: AppSettings())
        let added = await pipeline.refreshAllFeeds(queueNewEpisodes: true)

        // Hand the heavy lifting to the scheduler.
        ProcessingPipeline.scheduleNext()

        return .result(dialog: added == 0
                       ? "No new episodes."
                       : "Queued \(added) new episode\(added == 1 ? "" : "s") for processing.")
    }
}

// MARK: - Heavy: needs foreground time

struct ProcessAndPublishIntent: AppIntent {
    static var title: LocalizedStringResource = "Process and publish"
    static var description = IntentDescription(
        "Transcribes queued episodes, removes the ads, uploads them, and updates your private feed. Opens the app, because this takes real time."
    )
    /// This is deliberate. Transcription plus dozens of on-device model calls
    /// plus an upload will not survive a headless intent's execution budget.
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentContext = try AppLibrary.resolvedContext()

        let settings = AppSettings()
        let pipeline = ProcessingPipeline.shared
        pipeline.configure(context: intentContext, settings: settings)

        // Ask for extra runtime in case the user backgrounds the app mid-way.
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(withName: "process-publish") {
            UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
        defer {
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }

        let publisher = FeedPublisher.shared
        publisher.configure(context: context, pipeline: pipeline)
        await publisher.processAndPublishAll()

        let all = (try? intentContext.fetch(FetchDescriptor<Episode>())) ?? []
        let ready = all.filter { $0.processingState == .ready }.count

        return .result(dialog: "Done. \(ready) episode\(ready == 1 ? "" : "s") ready in your feed.")
    }
}

// MARK: - Publish a single show

struct PublishShowIntent: AppIntent {
    static var title: LocalizedStringResource = "Publish one show"
    static var openAppWhenRun = true

    @Parameter(title: "Show title")
    var showTitle: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentContext = try AppLibrary.resolvedContext()

        let wanted = showTitle
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.title.localizedStandardContains(wanted) }
        )
        guard let podcast = try? intentContext.fetch(descriptor).first else {
            return .result(dialog: "Couldn't find a show matching that.")
        }

        let settings = AppSettings()
        let pipeline = ProcessingPipeline.shared
        pipeline.configure(context: intentContext, settings: settings)
        let publisher = FeedPublisher.shared
        publisher.configure(context: context, pipeline: pipeline)

        let result = try await publisher.publish(podcast)
        return .result(dialog: "Published \(result.episodesPublished) episodes. Feed: \(result.feedURL.absoluteString)")
    }
}

// MARK: - Playback and the queue

/// An episode, as Siri and Shortcuts see it.
///
/// Needed so "play the latest episode of Quiet Hours" can resolve to
/// something specific rather than a string the app has to guess at, and so a
/// Shortcut can pass an episode from one action to the next.
struct EpisodeEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Episode"
    static var defaultQuery = EpisodeQuery()

    var id: String              // the episode's guid
    var title: String
    var showTitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(showTitle)")
    }
}

struct EpisodeQuery: EntityStringQuery {

    /// Only downloaded, unplayed episodes are offered.
    ///
    /// Suggesting something that cannot play is worse than suggesting
    /// nothing: the app is download-only, so an episode with no file is a
    /// dead end whatever Siri says about it.
    @MainActor
    private func candidates() throws -> [Episode] {
        let intentContext = try AppLibrary.resolvedContext()
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { !$0.isArchived },
            sortBy: [SortDescriptor(\.publishedAt, order: .reverse)]
        )
        let all = (try? intentContext.fetch(descriptor)) ?? []
        return all.filter { $0.isDownloaded }
    }

    private func entity(_ episode: Episode) -> EpisodeEntity {
        EpisodeEntity(id: episode.guid,
                      title: episode.title,
                      showTitle: episode.podcast?.title ?? "")
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [EpisodeEntity] {
        try candidates().filter { identifiers.contains($0.guid) }.map(entity)
    }

    @MainActor
    func entities(matching string: String) async throws -> [EpisodeEntity] {
        let needle = string.lowercased()
        return try candidates()
            .filter {
                $0.title.lowercased().contains(needle)
                    || ($0.podcast?.title.lowercased().contains(needle) ?? false)
            }
            .prefix(20)
            .map(entity)
    }

    @MainActor
    func suggestedEntities() async throws -> [EpisodeEntity] {
        try candidates().filter { !$0.isPlayed }.prefix(10).map(entity)
    }
}

/// The running app's own store, when there is one.
///
/// An intent must not fetch through a container it made itself while the app
/// is open. That is a second, detached view of the same database: the Episode
/// it hands to the player would be a different object from the one every
/// `@Query` in the app is watching, so playback would start and no screen
/// would ever notice. The app publishes its context here at launch; an intent
/// running headless still falls back to its own.
@MainActor
enum AppLibrary {
    private(set) static var context: ModelContext?

    static func use(_ context: ModelContext) { Self.context = context }

    static func resolvedContext() throws -> ModelContext {
        if let context { return context }
        return try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self).mainContext
    }
}

/// Shared lookup, so every playback intent resolves an episode the same way.
private enum IntentLibrary {
    @MainActor
    static func episode(withGUID guid: String) throws -> Episode? {
        let intentContext = try AppLibrary.resolvedContext()
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        return try? intentContext.fetch(descriptor).first
    }
}

/// Play a specific episode.
///
/// Opens the app. Playback needs the audio graph, the ad ranges and the
/// per-show settings, all of which live in the running app — a headless
/// intent would have to build a second player that behaves differently, and
/// the one thing worse than not skipping an ad is skipping the wrong thing.
struct PlayEpisodeIntent: AppIntent {
    static var title: LocalizedStringResource = "Play episode"
    static var description = IntentDescription("Plays a downloaded episode, skipping what you've asked it to skip.")
    static var openAppWhenRun = true

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    init() {}
    init(episode: EpisodeEntity) { self.episode = episode }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let found = try IntentLibrary.episode(withGUID: episode.id) else {
            return .result(dialog: "I couldn't find that episode.")
        }
        guard found.isDownloaded else {
            return .result(dialog: "\(found.title) isn't downloaded yet.")
        }
        PlayerEngine.shared.load(found)
        return .result(dialog: "Playing \(found.title).")
    }
}

/// Play whatever is at the top of Up Next.
struct PlayNextIntent: AppIntent {
    static var title: LocalizedStringResource = "Play next in queue"
    static var description = IntentDescription("Starts the next episode in Up Next.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentContext = try AppLibrary.resolvedContext()
        guard let next = NextUpProvider.next(in: intentContext) else {
            return .result(dialog: "Nothing downloaded is queued.")
        }
        PlayerEngine.shared.load(next)
        return .result(dialog: "Playing \(next.title).")
    }
}

/// Add an episode to Up Next without interrupting what is playing.
struct AddToQueueIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to Up Next"
    static var description = IntentDescription("Queues an episode to play later.")
    /// The only one here that does not need the app: it writes a flag.
    static var openAppWhenRun = false

    @Parameter(title: "Episode")
    var episode: EpisodeEntity

    @Parameter(title: "Play next", default: false)
    var playNext: Bool

    init() {}
    init(episode: EpisodeEntity, playNext: Bool = false) {
        self.episode = episode
        self.playNext = playNext
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let intentContext = try AppLibrary.resolvedContext()
        let descriptor = FetchDescriptor<Episode>(predicate: #Predicate { !$0.isArchived })
        let all = (try? intentContext.fetch(descriptor)) ?? []
        guard let found = all.first(where: { $0.guid == episode.id }) else {
            return .result(dialog: "I couldn't find that episode.")
        }

        found.isInQueue = true
        if playNext {
            // One below whatever is currently first, so "play next" means next
            // rather than eventually.
            let lowest = all.filter { $0.isInQueue }.map(\.queueOrder).min() ?? 0
            found.queueOrder = lowest - 1
        } else {
            let highest = all.filter { $0.isInQueue }.map(\.queueOrder).max() ?? 0
            found.queueOrder = highest + 1
        }
        try? context.save()
        LibraryTotals.shared.invalidate()

        return .result(dialog: playNext
                       ? "\(found.title) is up next."
                       : "Added \(found.title) to Up Next.")
    }
}

/// Pause or resume, for a Shortcut or a button.
struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or pause"
    static var description = IntentDescription("Pauses playback, or resumes it.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = PlayerEngine.shared
        guard player.currentEpisode != nil else {
            return .result(dialog: "Nothing is loaded.")
        }
        player.togglePlayPause()
        return .result(dialog: player.isPlaying ? "Playing." : "Paused.")
    }
}

/// Jump the break you are sitting in.
///
/// For the case the whole app exists for and cannot fully automate: a spot
/// the detector missed, or one you told it to leave in and have changed your
/// mind about.
struct SkipCurrentSegmentIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip this bit"
    static var description = IntentDescription("Jumps forward past the ad or promo playing right now.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = PlayerEngine.shared
        guard let episode = player.currentEpisode else {
            return .result(dialog: "Nothing is playing.")
        }
        let now = player.currentTime
        if let segment = episode.adSegments.first(where: { $0.start <= now && $0.end >= now }) {
            player.seek(to: segment.end)
            return .result(dialog: "Skipped the \(segment.kind.label.lowercased()).")
        }
        player.skipForward()
        return .result(dialog: "Skipped forward.")
    }
}
