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
    var stageDescription: String?
    var progress: Double = 0
    var isRunning = false

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
        defer {
            isRunning = false
            currentEpisodeTitle = nil
            stageDescription = nil
            progress = 0
        }

        do {
            // 1. Download
            if episode.localFileURL == nil || !FileManager.default.fileExists(atPath: episode.localFileURL!.path) {
                episode.processingState = .downloading
                stageDescription = "Downloading"
                progress = 0
                let filename = try await download(episode)
                episode.localFilename = filename
                try? context.save()
            }
            guard let fileURL = episode.localFileURL else { return }

            // 2. Transcribe
            episode.processingState = .transcribing
            stageDescription = "Transcribing"
            progress = 0
            let segments = try await transcriber.transcribe(fileURL: fileURL) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
            episode.transcriptText = segments.map(\.text).joined(separator: " ")
            try? context.save()

            // 3. Detect ads
            episode.processingState = .detecting
            stageDescription = "Finding ads"
            progress = 0
            let windows = segments.windows()
            let ads = try await detector.detect(
                windows: windows,
                minimumConfidence: settings.minimumConfidence,
                padding: settings.boundaryPadding
            ) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }

            // 4. Save, preserving any manual corrections the user already made
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
        let pending = queued.filter { $0.processingState != .ready }
        for episode in pending.prefix(limit) {
            await process(episode)
        }
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
