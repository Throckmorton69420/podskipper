import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the Lock Screen card for finding ads (pass 21).
///
/// His 27 Sep ask: see on the Lock Screen, without unlocking, whether ads
/// are still being found and what the app is doing. iOS's own card for a
/// carried-on job exists only while iOS lets the job run; this one is
/// PodSkipper's, stays up whether or not iOS's is showing, and says how it
/// ended ("Ads found", or "Paused by iOS").
///
/// Battery: checked every 3 s while a job of his runs, sent only when
/// something he'd see has changed — the step, a whole percent, or the time
/// left by more than a minute (the countdown runs by itself on the card).
/// A card not updated for three minutes is marked stale and reads "Paused".
@MainActor
final class ProcessingActivityController {
    static let shared = ProcessingActivityController()
    static let enabledKey = "processingOnLockScreen"

    var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    private var activity: Activity<ProcessingAttributes>?
    private var loop: Task<Void, Never>?
    private var last: ProcessingAttributes.ContentState?
    private var lastSent = Date.distantPast
    private var thumbnails: [String: Data] = [:]
    private var finishedState: ProcessingAttributes.ContentState?

    private init() {
        // Anything left from a run that ended without warning.
        // Only the ones there now, not one this launch is about to start.
        let leftovers = Activity<ProcessingAttributes>.activities
        Task { for old in leftovers { await old.end(nil, dismissalPolicy: .immediate) } }
    }

    /// A job of his started (or resumed). Cheap to call again.
    func jobStarted() {
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled, loop == nil else { return }
        finishedState = nil
        loop = Task { @MainActor [weak self] in
            var idle = 0
            while !Task.isCancelled, let self {
                if self.tick() { idle = 0 } else { idle += 1 }
                // Nothing of his running or waiting for ~15 s: the line is done.
                if idle >= 5 { self.finish(); return }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// One of his jobs finished: remembered for the card's last word.
    func noteFinished(_ episode: Episode) {
        let cuts = episode.adSegments.filter { $0.userVerdict != .notAnAd }
        finishedState = .init(phase: .done, title: episode.title, show: episode.podcast?.title ?? "",
                              step: "Ads found", fraction: 1, position: 0, total: 0, endsAt: nil,
                              cuts: cuts.count, cutSeconds: cuts.reduce(0) { $0 + $1.duration },
                              artwork: last?.title == episode.title ? last?.artwork : nil)
    }

    /// iOS ended the carried-on task: the card says so straight away.
    func notePaused() {
        guard var state = last, let activity else { return }
        state.phase = .paused
        state.step = "Paused by iOS · opens where it stopped"
        state.endsAt = nil
        last = state
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }
}

extension ProcessingActivityController {
    /// Brings the card up to date. False when nothing of his is running or
    /// waiting.
    private func tick() -> Bool {
        let pipeline = ProcessingPipeline.shared
        var state: ProcessingAttributes.ContentState
        let total = max(1, pipeline.batchTotal)
        if pipeline.isRunning, pipeline.currentOrigin == .user, let episode = pipeline.currentEpisode {
            let eta = pipeline.etaSeconds
            state = .init(phase: .working, title: episode.title, show: episode.podcast?.title ?? "",
                          step: pipeline.stage.label, fraction: min(1, max(0, pipeline.overallFraction)),
                          position: min(total, pipeline.batchDone + 1), total: total,
                          endsAt: eta.map { Date().addingTimeInterval($0) })
            state.artwork = artwork(for: episode)
        } else if !pipeline.waitingQueue.isEmpty {
            state = last ?? .init(phase: .waiting, title: "Next in line", show: "", step: "", fraction: 0,
                                  position: 0, total: total, endsAt: nil)
            state.phase = .waiting
            state.step = "Starting the next one"
            state.endsAt = nil
        } else {
            return false
        }
        send(state)
        return true
    }

    private func artwork(for episode: Episode) -> Data? {
        guard let url = episode.artworkURL ?? episode.podcast?.artworkURL else { return nil }
        if let data = thumbnails[url] { return data }
        thumbnails[url] = Data()   // asked once
        Task { [weak self] in
            if let data = await NowPlayingActivityController.thumbnail(for: url) { self?.thumbnails[url] = data }
        }
        return nil
    }

    private func send(_ raw: ProcessingAttributes.ContentState) {
        var state = raw
        if state.artwork?.isEmpty == true { state.artwork = nil }
        let stale = Date().addingTimeInterval(180)
        guard let activity else {
            // Only possible with the app on screen; in the background the
            // next tick after he opens it starts the card.
            guard UIApplication.shared.applicationState != .background else { return }
            activity = try? Activity.request(attributes: ProcessingAttributes(startedAt: .now),
                                             content: .init(state: state, staleDate: stale), pushType: nil)
            last = state
            lastSent = .now
            return
        }
        let drift = abs((state.endsAt ?? .distantPast).timeIntervalSince(last?.endsAt ?? .distantPast))
        let changed = state.title != last?.title || state.step != last?.step || state.phase != last?.phase
            || Int(state.fraction * 100) != Int((last?.fraction ?? -1) * 100)
            || state.position != last?.position || state.artwork != last?.artwork
            || drift > 60 || Date().timeIntervalSince(lastSent) > 90
        guard changed else { return }
        last = state
        lastSent = .now
        Task { await activity.update(.init(state: state, staleDate: stale)) }
    }

    /// The line is done: "Ads found" for twenty minutes, then gone.
    private func finish() {
        loop = nil
        guard let activity else { return }
        self.activity = nil
        let final = finishedState ?? last
        last = nil
        Task {
            if let final, final.phase == .done {
                await activity.end(.init(state: final, staleDate: nil),
                                   dismissalPolicy: .after(Date().addingTimeInterval(20 * 60)))
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// The setting was turned off.
    func endNow() {
        loop?.cancel()
        loop = nil
        let current = activity
        activity = nil
        last = nil
        Task { await current?.end(nil, dismissalPolicy: .immediate) }
    }
}
