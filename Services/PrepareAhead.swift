import Foundation
import Observation
import SwiftData

/// Keeps the next few episodes ready, and says so.
///
/// "Prepare 2 episodes ahead" was reported as doing nothing, three times. The
/// work itself ran — but only at the instant an episode was loaded into the
/// player. Queue something afterwards, reorder Up Next, finish a Find Ads job,
/// come back to the app: nothing asked again. And nothing on screen said
/// which episodes it meant or whether they were done, so there was no way to
/// tell a working feature from a broken one.
///
/// So this asks again whenever the answer could have changed — the app
/// becoming active, an episode loading, Up Next changing, a job finishing, and
/// once a minute while something plays — and publishes what it found for Up
/// Next to show, with a button that makes it happen now.
@MainActor
@Observable
final class PrepareAhead {

    static let shared = PrepareAhead()

    /// The episodes it is keeping ready, in play order.
    private(set) var targets: [Episode] = []

    private var context: ModelContext?
    private var settings: AppSettings?
    private var ticker: Task<Void, Never>?

    private init() {}

    func configure(context: ModelContext, settings: AppSettings) {
        self.context = context
        self.settings = settings
        guard ticker == nil else { return }
        // Once a minute while the app is open, playing or not: ask again, and
        // restart the background job if it has sat without starting
        // anything. Reported: two episodes in Up Next said "Waiting" and
        // never began, and nothing asked again until something else changed.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                guard !PlayerEngine.shared.isInBackground || PlayerEngine.shared.isPlaying else { continue }
                ProcessingPipeline.shared.restartBackgroundWorkIfStalled()
                self.refresh()
            }
        }
    }

    var limit: Int { settings?.preprocessAhead ?? 0 }

    var pending: [Episode] { targets.filter { $0.processingState != .ready } }

    /// What a target is doing, in words, for its row in Up Next.
    func status(of episode: Episode) -> String? {
        guard targets.contains(where: { $0.guid == episode.guid }) else { return nil }
        let pipeline = ProcessingPipeline.shared
        if episode.processingState == .ready { return nil }
        if pipeline.isProcessing(episode) { return nil }
        if episode.processingState == .failed { return "Couldn't find ads — tap Find Ads to retry" }
        if let reason = pipeline.speculativePausedReason { return reason }
        if pipeline.isRunning { return "Getting ready next — after the current job" }
        return "Getting ready next"
    }

    /// Work out what should be ready and quietly start on what is not.
    func refresh() {
        guard let context, limit > 0 else {
            targets = []
            return
        }
        // From what is playing, or — with nothing loaded — from the top of Up
        // Next, which is what Play would start.
        let current = PlayerEngine.shared.currentEpisode
        var list = NextUpProvider.upcoming(in: context, after: current, limit: limit)
        if current == nil, let first = list.first, list.count < limit {
            list = [first] + NextUpProvider.upcoming(in: context, after: first, limit: limit - 1)
        }
        targets = list
        // Unplayed first. Everything here gets prepared, but an episode queued
        // to hear again can wait behind one not heard yet.
        let open = list.filter { $0.processingState != .ready && $0.processingState != .failed }
        let waiting = open.filter { !$0.isPlayed } + open.filter(\.isPlayed)
        if !waiting.isEmpty {
            ProcessingPipeline.shared.enqueueBackground(waiting)
        }
    }

    /// The button: do it now, as a job someone is watching.
    func prepareNow() {
        refresh()
        let list = pending
        guard !list.isEmpty else { return }
        ProcessingPipeline.shared.cancelBackgroundWork()
        Task { await ProcessingPipeline.shared.process(list) }
    }
}
