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
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self)
        let context = container.mainContext

        let pipeline = ProcessingPipeline.shared
        pipeline.configure(context: context, settings: AppSettings())
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
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self)
        let context = container.mainContext

        let settings = AppSettings()
        let pipeline = ProcessingPipeline.shared
        pipeline.configure(context: context, settings: settings)

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

        let all = (try? context.fetch(FetchDescriptor<Episode>())) ?? []
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
        let container = try ModelContainer(for: Podcast.self, Episode.self, AdSegment.self)
        let context = container.mainContext

        let wanted = showTitle
        let descriptor = FetchDescriptor<Podcast>(
            predicate: #Predicate { $0.title.localizedStandardContains(wanted) }
        )
        guard let podcast = try? context.fetch(descriptor).first else {
            return .result(dialog: "Couldn't find a show matching that.")
        }

        let settings = AppSettings()
        let pipeline = ProcessingPipeline.shared
        pipeline.configure(context: context, settings: settings)
        let publisher = FeedPublisher.shared
        publisher.configure(context: context, pipeline: pipeline)

        let result = try await publisher.publish(podcast)
        return .result(dialog: "Published \(result.episodesPublished) episodes. Feed: \(result.feedURL.absoluteString)")
    }
}
