import Foundation
import Observation
import SwiftData
import BackgroundTasks
import UIKit

/// Downloads an episode, transcribes it, finds the ads, saves the ranges.
///
/// The design decision that matters here: this runs *ahead of playback*, not
/// during it. Apps that classify live always leak the first second or two of
/// every ad, because the model can't know a break started until it hears it.
/// Pre-processing overnight means playback is instant and the cuts are clean.
@MainActor
@Observable
final class ProcessingPipeline {

    /// One shared instance. Views and intents all talk to this one.
    static let shared = ProcessingPipeline()

    static let backgroundTaskID = "com.yourname.podskipper.process"

    var currentEpisodeTitle: String?
    var stage: Stage = .idle
    var stageFraction: Double = 0
    var isRunning = false

    /// How many episodes are left in this batch, not counting the current one.
    var queueRemaining = 0

    private var jobStartedAt: Date?

    /// Weighted across the four steps, because transcription takes far longer
    /// than the others and a naive "step 2 of 4 = 50%" bar would lie.
    var overallFraction: Double {
        guard stage != .idle else { return 0 }
        let done = Stage.ordered.prefix(while: { $0 != stage }).reduce(0) { $0 + $1.weight }
        return min(1, done + stage.weight * stageFraction)
    }

    /// Extrapolated from how long we've taken to get this far. Deliberately
    /// absent for the first few percent, where the estimate would be nonsense.
    var etaSeconds: Double? {
        guard let jobStartedAt, isRunning else { return nil }
        let fraction = overallFraction
        guard fraction > 0.04 else { return nil }
        let elapsed = Date().timeIntervalSince(jobStartedAt)
        return elapsed / fraction * (1 - fraction)
    }

    var stageDescription: String? { stage == .idle ? nil : stage.label }

    enum Stage: Equatable {
        case idle, downloading, transcribing, detecting, analyzing, saving

        static let ordered: [Stage] = [.downloading, .transcribing, .detecting, .analyzing, .saving]

        var label: String {
            switch self {
            case .idle:         return ""
            case .downloading:  return "Downloading audio"
            case .transcribing: return "Transcribing on device"
            case .detecting:    return "Finding ads"
            case .analyzing:    return "Measuring silence and loudness"
            case .saving:       return "Saving results"
            }
        }

        /// Rough share of total wall time. Transcription dominates.
        var weight: Double {
            switch self {
            case .idle:         return 0
            case .downloading:  return 0.11
            case .transcribing: return 0.52
            case .detecting:    return 0.25
            case .analyzing:    return 0.08
            case .saving:       return 0.04
            }
        }

        var number: Int { (Stage.ordered.firstIndex(of: self) ?? 0) + 1 }
        static var count: Int { ordered.count }
    }

    private let transcriber = TranscriptionService()
    private let detector = AdDetector()
    private var modelContext: ModelContext?
    private var settings: AppSettings?

    func configure(context: ModelContext, settings: AppSettings) {
        self.modelContext = context
        self.settings = settings
    }

    // MARK: - Public entry points

    /// Process one episode end to end.
    func process(_ episode: Episode) async {
        guard let context = modelContext, let settings else { return }
        isRunning = true
        currentEpisodeTitle = episode.title
        jobStartedAt = Date()
        defer {
            isRunning = false
            currentEpisodeTitle = nil
            stage = .idle
            stageFraction = 0
            jobStartedAt = nil
        }

        do {
            // 1. Download
            if episode.localFileURL == nil || !FileManager.default.fileExists(atPath: episode.localFileURL!.path) {
                episode.processingState = .downloading
                stage = .downloading
                stageFraction = 0
                let filename = try await download(episode)
                episode.localFilename = filename
                try? context.save()
            }
            guard let fileURL = episode.localFileURL else { return }

            // Chapters live in the audio file, so this is the first moment
            // we can read them.
            await ChapterService.extract(for: episode, context: context)

            // 2. Transcribe
            stage = .downloading
            stageFraction = 1

            episode.processingState = .transcribing
            stage = .transcribing
            stageFraction = 0
            let segments = try await transcriber.transcribe(fileURL: fileURL) { [weak self] p in
                Task { @MainActor in self?.stageFraction = p }
            }
            episode.transcriptText = segments.map(\.text).joined(separator: " ")
            episode.storeTranscript(segments.map {
                TimedLine(text: $0.text, start: $0.start, end: $0.end)
            })
            try? context.save()

            // 3. Detect ads
            stage = .transcribing
            stageFraction = 1

            episode.processingState = .detecting
            stage = .detecting
            stageFraction = 0
            let windows = segments.windows()
            let ads = try await detector.detect(
                windows: windows,
                minimumConfidence: settings.minimumConfidence,
                padding: settings.boundaryPadding
            ) { [weak self] p in
                Task { @MainActor in self?.stageFraction = p }
            }

            // 4. Measure silence and loudness for Smart Speed and normalisation.
            if settings.analyzeSilence {
                episode.processingState = .analyzing
                stage = .analyzing
                stageFraction = 0
                if let analysis = try? AudioAnalyzer.analyze(fileURL: fileURL, progress: { [weak self] p in
                    Task { @MainActor in self?.stageFraction = p }
                }) {
                    episode.storeSilence(analysis.silences)
                    episode.normalizationGain = analysis.normalizationGain
                }
                stageFraction = 1
            }

            // 5. Save, preserving any manual corrections the user already made
            stage = .saving
            stageFraction = 0.5
            let rejected = episode.adSegments.filter { $0.userVerdict == .notAnAd }
            for old in episode.adSegments where old.userVerdict != .notAnAd {
                context.delete(old)
            }
            for ad in ads {
                let overlapsRejected = rejected.contains { $0.start < ad.end && $0.end > ad.start }
                guard !overlapsRejected else { continue }
                let segment = AdSegment(start: ad.start, end: ad.end,
                                        sponsor: ad.sponsor, confidence: ad.confidence)
                segment.episode = episode
                context.insert(segment)
            }

            episode.processingState = .ready
            episode.lastProcessedAt = .now
            episode.processingError = nil
            try? context.save()

        } catch {
            episode.processingState = .failed
            episode.processingError = error.localizedDescription
            try? context.save()
        }
    }

    /// Process an explicit set of episodes, in order. Used by the batch
    /// selection on the Publish screen.
    func process(_ episodes: [Episode]) async {
        for (index, episode) in episodes.enumerated() {
            queueRemaining = episodes.count - index - 1
            await process(episode)
        }
        queueRemaining = 0
    }

    /// Check every subscribed show for new episodes. Returns how many were added.
    @discardableResult
    func refreshAllFeeds(queueNewEpisodes: Bool = false) async -> Int {
        guard let context = modelContext else { return 0 }
        guard let podcasts = try? context.fetch(FetchDescriptor<Podcast>()) else { return 0 }

        var added: [Episode] = []
        for podcast in podcasts where !podcast.isArchived {
            guard let feed = try? await FeedParser.fetch(podcast.feedURL) else { continue }
            let existing = Set(podcast.episodes.map(\.guid))
            for item in feed.items.prefix(20) where !existing.contains(item.guid) {
                let episode = Episode(guid: item.guid, title: item.title,
                                      episodeDescription: item.description,
                                      audioURL: item.audioURL, publishedAt: item.publishedAt,
                                      duration: item.duration, artworkURL: item.artworkURL)
                episode.podcast = podcast
                // Per-show setting wins over the global one.
                episode.isInQueue = podcast.autoQueueNew && queueNewEpisodes
                context.insert(episode)
                added.append(episode)
            }
            podcast.lastRefreshed = .now
        }
        try? context.save()

        if !added.isEmpty {
            await NotificationService.notifyNewEpisodes(added, settings: settings ?? AppSettings())
        }

        // Honour the per-show "download automatically" setting. Downloads
        // only, not full processing — that stays on the background schedule.
        let toDownload = added.filter { $0.podcast?.autoDownloadNew == true }
        for episode in toDownload.prefix(5) {
            guard !episode.isDownloaded else { continue }
            if let filename = try? await download(episode) {
                episode.localFilename = filename
            }
        }
        if !toDownload.isEmpty { try? context.save() }

        return added.count
    }

    /// Total bytes of downloaded audio sitting on disk.
    static func downloadedBytes() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: FileStore.episodesDirectory,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Delete downloaded audio. Transcripts and detected ads are kept, so a
    /// cleared episode only needs re-downloading, not re-analysing.
    func clearDownloads() {
        guard let context = modelContext else { return }
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: FileStore.episodesDirectory,
                                                   includingPropertiesForKeys: nil) {
            for file in files { try? fm.removeItem(at: file) }
        }
        if let episodes = try? context.fetch(FetchDescriptor<Episode>()) {
            for episode in episodes { episode.localFilename = nil }
        }
        try? context.save()
    }

    /// Work through everything queued that hasn't been processed yet.
    func processPending(limit: Int = 5) async {
        guard let context = modelContext else { return }
        // Note: SwiftData predicates are unreliable with enum comparisons,
        // so we fetch the queue and filter in memory instead.
        let descriptor = FetchDescriptor<Episode>(
            predicate: #Predicate { $0.isInQueue },
            sortBy: [SortDescriptor(\.queueOrder)]
        )
        guard let queued = try? context.fetch(descriptor) else { return }
        let pending = Array(queued.filter { $0.processingState != .ready }.prefix(limit))
        for (index, episode) in pending.enumerated() {
            queueRemaining = pending.count - index - 1
            await process(episode)
        }
        queueRemaining = 0
    }

    // MARK: - Download

    private func download(_ episode: Episode) async throws -> String {
        guard let url = URL(string: episode.audioURL) else {
            throw URLError(.badURL)
        }
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        // Keep the original extension; AVAudioFile cares.
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let filename = "\(UUID().uuidString).\(ext)"
        let destination = FileStore.episodesDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return filename
    }

    // MARK: - Background scheduling

    /// Register at launch. iOS decides when to actually run this — typically
    /// overnight while charging on Wi-Fi, which is exactly when you want an
    /// hour of transcription happening.
    static func registerBackgroundTask(handler: @escaping @Sendable () async -> Void) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            let work = Task {
                await handler()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = {
                work.cancel()
                task.setTaskCompleted(success: false)
            }
            scheduleNext()
        }
    }

    static func scheduleNext(requiresPower: Bool = true) {
        let request = BGProcessingTaskRequest(identifier: backgroundTaskID)
        request.requiresNetworkConnectivity = true   // downloads
        request.requiresExternalPower = requiresPower
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
