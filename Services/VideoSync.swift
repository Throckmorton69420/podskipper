import AVFoundation
import Observation

/// The picture for a video episode, following the sound.
///
/// The sound of a video episode is played exactly like any other episode — by
/// the audio engine, from the episode's own audio track — so Smart Speed,
/// Voice Boost, the equaliser, normalisation and ad skipping all work on it.
/// The picture is a muted `AVPlayer` that follows that sound: it is started,
/// stopped and moved whenever the sound is, and a few times a second it is
/// checked against the sound's position and nudged back into step — a small
/// speed change for a small drift, a jump for a large one (an ad skip, a Smart
/// Speed jump, a seek).
///
/// This is how the Video / Audio switch stays in sync: switching never
/// touches the sound at all. Only the picture comes and goes, and with it off
/// nothing is decoded.
@MainActor
@Observable
final class VideoSync {

    let player: AVPlayer = {
        let player = AVPlayer()
        player.isMuted = true
        player.allowsExternalPlayback = false
        player.preventsDisplaySleepDuringVideoPlayback = true
        // Show whatever is buffered straight away rather than wait for
        // AVFoundation to judge the stream safe to play (task 06: the lag
        // after tapping the cover). The picture is muted and follows the
        // sound, so a brief freeze is corrected by the next check; a blank
        // wait of several seconds is what people noticed.
        player.automaticallyWaitsToMinimizeStalling = false
        return player
    }()

    /// The source currently loaded, if any.
    private(set) var sourceURL: URL?
    /// Ready to show a picture.
    private(set) var isReady = false
    /// Why a video could not be shown, in words, when that happens.
    private(set) var problem: String?

    // Where the sound is, supplied by `PlayerEngine`.
    @ObservationIgnored var soundTime: () -> Double = { 0 }
    @ObservationIgnored var soundRate: () -> Double = { 1 }
    @ObservationIgnored var soundPlaying: () -> Bool = { false }
    /// Seconds between the sound engine playing a moment and it being heard
    /// — see `AudioEngine.outputLatency`. Supplied by `PlayerEngine`.
    @ObservationIgnored var soundLatency: () -> Double = { 0 }
    /// Whether the picture may be loaded and kept near the sound while it is
    /// hidden — only with the app on screen. Supplied by `PlayerEngine`.
    @ObservationIgnored var mayPreload: () -> Bool = { false }
    /// A line for Settings → Diagnostics' background log: the timings.
    @ObservationIgnored var log: (String) -> Void = { _ in }
    /// Ads stitched into the audio that the video doesn't have — the produced
    /// spots a host inserts per download. Supplied by `PlayerEngine` from the
    /// breaks PodSkipper found.
    @ObservationIgnored var insertedAdCandidates: () -> [[(start: Double, end: Double)]] = { [] }

    /// How a moment in the sound maps to a moment in the picture.
    private enum Timeline {
        /// The same recording, second for second. The usual case: on the
        /// feeds checked (Transistor's Primary Technology, the Podcast
        /// Standards Project demo) the HLS video and the audio matched to
        /// within a second.
        case same
        /// The audio has ads the video doesn't; take them out to find the
        /// picture's time. Inside one of them there is no picture to show.
        case withoutInserted([(start: Double, end: Double)])
    }
    @ObservationIgnored private var timeline: Timeline = .same

    /// The picture's time for a moment in the sound, or nil when the sound is
    /// in an ad the video doesn't have.
    private func pictureTime(forSound t: Double) -> Double? {
        switch timeline {
        case .same:
            return t
        case .withoutInserted(let ads):
            if ads.contains(where: { t >= $0.start && t < $0.end }) { return nil }
            return YouTubeLink.videoTime(fromAudio: t, insertedAds: ads)
        }
    }
    /// The picture was paused or played from outside — Picture in Picture's
    /// own buttons. The sound follows.
    @ObservationIgnored var onExternalPlayPause: ((Bool) -> Void)?
    /// Whether anything the listener can touch is driving this player
    /// directly — only Picture in Picture's own buttons do.
    ///
    /// Without this, *any* pause of the video player that we did not make was
    /// taken for the listener's, and the sound was paused to match. But
    /// AVFoundation pauses a video player on its own when the audio route
    /// changes — AirPods taken out, put back, switched — so resuming with
    /// AirPods started the sound, found the picture paused by the system, and
    /// paused the sound again. That is the AirPods bug that came back when
    /// episodes started having video (pass 13).
    @ObservationIgnored var externalControlsActive: () -> Bool = { false }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var attachmentID = UUID()
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var lastRateWeSet: Float = 0
    @ObservationIgnored private var active = false
    @ObservationIgnored private var expectedDuration: Double = 0
    @ObservationIgnored private var warmLoop: Task<Void, Never>?

    // Timings for the log (task 06), in the order a switch to video goes:
    // the item is loaded, then the picture jumps to where the sound is.
    /// When the current item was attached.
    @ObservationIgnored private var attachedAt: Date?
    /// How long it took to become ready, once it has.
    @ObservationIgnored private var loadSeconds: Double?
    /// When the picture was asked to show and has not shown yet.
    @ObservationIgnored private var askedAt: Date?

    /// Buffer ahead while hidden: enough to cover where the parked picture
    /// will be sent on a switch (see `warm`), little enough that a picture
    /// nobody watches costs little data.
    private static let hiddenBuffer: TimeInterval = 8
    private static let shownBuffer: TimeInterval = 20

    // MARK: Source

    /// Load a picture. `expectedDuration` is the sound's length; a remote
    /// stream whose length differs by more than a few seconds has different
    /// ad breaks from the audio and cannot be kept in step.
    func attach(_ url: URL, expectedDuration: Double) {
        guard url != sourceURL else { return }
        let wasActive = active
        detach()
        sourceURL = url
        let id = attachmentID
        self.expectedDuration = expectedDuration
        problem = nil
        let item = AVPlayerItem(url: url)
        // Only the picture is used; the audio track is never heard.
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : (active ? Self.shownBuffer : Self.hiddenBuffer)
        attachedAt = .now
        loadSeconds = nil
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let status = observed.status
            let seconds = observed.duration.seconds
            let message = observed.error?.localizedDescription
            Task { @MainActor in
                guard let self, self.attachmentID == id else { return }
                self.itemChanged(status: status, duration: seconds, error: message)
            }
        }
        player.replaceCurrentItem(with: item)
        // A new source while Video is showing (found late, or lined up
        // after the ads were measured): keep following.
        if wasActive { setActive(true) }
    }

    func detach() {
        attachmentID = UUID()
        // Off as well as unloaded: `setActive(true)` for the next episode
        // then starts the checks again. They used to stay cancelled after
        // an episode change while watching, so nothing kept the picture in
        // step until Video was switched off and on (task 09).
        if active { reportWatching() }
        active = false
        loop?.cancel(); loop = nil
        warmLoop?.cancel(); warmLoop = nil
        attachedAt = nil
        loadSeconds = nil
        statusObservation?.invalidate(); statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        sourceURL = nil
        isReady = false
        lastRateWeSet = 0
        snapWhenLanded = false
        // A seek on the old item ends with it; its completion finds nothing
        // active and does nothing.
        seeking = false
    }

    private func itemChanged(status: AVPlayerItem.Status, duration: Double, error: String?) {
        switch status {
        case .readyToPlay:
            if loadSeconds == nil, let attachedAt { loadSeconds = Date.now.timeIntervalSince(attachedAt) }
            timeline = .same
            if let url = sourceURL, !url.isFileURL, duration.isFinite, duration > 0,
               expectedDuration > 0, abs(duration - expectedDuration) > 4 {
                // The two differ in length. If the difference is the ads
                // stitched into the audio, the picture can still follow: skip
                // over those when working out where it should be.
                // Try each way the audio might carry extra ads, best first:
                // the ad-free comparison's exact spans, then the breaks found.
                let options = insertedAdCandidates()
                let fits = options.first { set in
                    let removed = set.reduce(0) { $0 + ($1.end - $1.start) }
                    return removed > 0 && abs(duration - (expectedDuration - removed)) <= 8
                }
                let ads = options.first ?? []
                if let fits {
                    timeline = .withoutInserted(fits)
                } else {
                    // Longer than the audio, or shorter by something other
                    // than the ads found: the video has its own breaks.
                    // Showing it would put the picture minutes from the sound.
                    problem = ads.isEmpty
                        ? "This episode's video is a different length from its audio — usually ads added to one and not the other. Find Ads first and PodSkipper can often line them up. Playing audio only for now."
                        : "This episode's video has different ad breaks from its audio, so PodSkipper can't keep the two in step. Playing audio only."
                    detach()
                    return
                }
            }
            isReady = true
            if active { snap(force: true) } else { startWarming() }
        case .failed:
            problem = "The video couldn't be loaded" + (error.map { ": \($0)" } ?? ".")
            isReady = false
            if let askedAt {
                log("Video failed after \(Self.seconds(since: askedAt)) s: \(error ?? "no reason given")")
                self.askedAt = nil
            }
        default:
            break
        }
    }

    // MARK: Following

    /// Run while the picture can be seen; stop decoding when it cannot.
    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        if on {
            warmLoop?.cancel(); warmLoop = nil
            player.currentItem?.preferredForwardBufferDuration = sourceURL?.isFileURL == true ? 0 : Self.shownBuffer
            askedAt = .now
            watchStartedAt = .now
            nudges = 0; reseeks = 0
            snap(force: true)
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    // Twice a second, not four times: the picture is already
                    // within a frame or two, and this loop runs for as long as
                    // the video is on screen.
                    try? await Task.sleep(for: .milliseconds(500))
                    self?.correct()
                }
            }
        } else {
            loop?.cancel(); loop = nil
            player.pause()
            lastRateWeSet = 0
            askedAt = nil
            reportWatching()
            player.currentItem?.preferredForwardBufferDuration = sourceURL?.isFileURL == true ? 0 : Self.hiddenBuffer
            startWarming()
        }
    }

    // MARK: Where the sound is heard

    /// What the sound engine has played is not yet what anyone hears: the
    /// output adds its own delay — a few hundredths on the speaker, a fifth
    /// of a second or more on Bluetooth. The picture used to follow what had
    /// been played, so it ran ahead of the sound by exactly that (his report,
    /// 30 Sep). It follows what is heard now. Paused, nothing is in flight.
    private func heardSoundTime() -> Double {
        let played = soundTime()
        guard soundPlaying() else { return played }
        return max(0, played - currentOffset())
    }

    /// The hold-back in the episode's own seconds: the delay times the speed.
    private func currentOffset() -> Double {
        let offset = max(0, soundLatency()) * max(0.5, soundRate())
        appliedOffset = offset
        return offset
    }

    /// How far the picture at `picture` is ahead of the sound being heard,
    /// in picture seconds. Nil when the sound is in an ad the video lacks.
    private func lead(of picture: Double) -> Double? {
        if let heard = pictureTime(forSound: heardSoundTime()) { return picture - heard }
        // Just past a cut, the moment being heard can still be inside the
        // ad the video doesn't have while the moment played is already out
        // of it; measure from the played one and add the delay back.
        guard soundPlaying(), let played = pictureTime(forSound: soundTime()) else { return nil }
        return picture - played + currentOffset()
    }

    // MARK: Hidden, but ready

    /// While the picture is loaded but hidden (Audio chosen) and the app is
    /// on screen, keep the paused picture parked at or just behind the
    /// sound, with the next several seconds buffered after it. Switching to
    /// Video is then a seek into data already on the phone (task 09: the lag
    /// when switching). Only in the foreground; a paused episode costs one
    /// seek and nothing after.
    private func startWarming() {
        guard warmLoop == nil, !active, isReady else { return }
        warmLoop = Task { [weak self] in
            while !Task.isCancelled {
                self?.warm()
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func warm() {
        guard !active, isReady, !seeking, player.currentItem != nil, mayPreload(),
              let target = pictureTime(forSound: heardSoundTime()) else { return }
        let now = player.currentTime().seconds
        // The buffer runs forward from the parked frame, so the frame must
        // not pass the sound; and once the sound is most of a buffer past
        // it, move it up.
        if now.isFinite {
            let behind = target - now
            if behind >= 0, behind < (soundPlaying() ? 5 : 2) { return }
        }
        seeking = true
        let attachment = attachmentID
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600),
                    toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.attachmentID == attachment else { return }
                self.seeking = false
                // Video was chosen while this seek was under way.
                if self.active { self.snap(force: true) }
            }
        }
    }

    /// "0.8", for the log.
    private static func seconds(since start: Date) -> String {
        String(format: "%.1f", Date.now.timeIntervalSince(start))
    }

    /// Once, when a picture that was asked for is first in place.
    private func reportReady() {
        guard let askedAt else { return }
        self.askedAt = nil
        lastReadySeconds = Date.now.timeIntervalSince(askedAt)
        let loadedAhead = (attachedAt ?? .now) < askedAt
        let detail = loadedAhead
            ? "loaded ahead of time"
            : "loading took \(String(format: "%.1f", loadSeconds ?? 0)) s"
        log("Video ready in \(Self.seconds(since: askedAt)) s (\(detail); held back \(Self.milliseconds(appliedOffset)) ms for the sound's delay)")
    }

    /// Once, when the picture is put away: how well it kept in step.
    private func reportWatching() {
        guard let started = watchStartedAt else { return }
        watchStartedAt = nil
        let minutes = Date.now.timeIntervalSince(started) / 60
        guard minutes >= 0.5 else { return }
        log("Video watched \(String(format: "%.1f", minutes)) min: held back \(Self.milliseconds(appliedOffset)) ms, "
            + "\(String(format: "%.1f", Double(nudges) / minutes)) speed nudges a minute, \(reseeks) re-seeks")
    }

    private static func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }

    // MARK: Diagnostics (task 09)

    /// The sound's delay being allowed for, in the episode's seconds.
    @ObservationIgnored private(set) var appliedOffset: Double = 0
    /// How long the last switch to Video took to show a picture in step.
    @ObservationIgnored private(set) var lastReadySeconds: Double?
    @ObservationIgnored private var watchStartedAt: Date?
    @ObservationIgnored private var nudges = 0
    @ObservationIgnored private var reseeks = 0
    /// Small speed changes made per minute of watching, to close a gap.
    var nudgesPerMinute: Double {
        guard let started = watchStartedAt else { return 0 }
        let minutes = max(1.0 / 60, Date.now.timeIntervalSince(started) / 60)
        return Double(nudges) / minutes
    }

    // MARK: Jumps

    /// How long a seek takes to land, learned as it goes: the picture is
    /// sent that far ahead of the sound, so it is ready and waiting when the
    /// sound gets there rather than arriving late.
    @ObservationIgnored private var seekSeconds: Double = 0.25

    /// Put the picture exactly where the sound will be heard — after a seek,
    /// a skipped ad or a switch to Video, rather than waiting for the next
    /// check. `force` is for a jump in the sound, which must be followed at
    /// once whatever the last seek was.
    @discardableResult
    func snap(force: Bool = false) -> Bool {
        guard active, isReady else { return false }
        if seeking {
            // One is in flight; follow the latest jump when it lands.
            if force { snapWhenLanded = true }
            return false
        }
        // Seeking a streamed video is expensive — it decodes from the last
        // keyframe — and doing it repeatedly is what made the picture stutter
        // on Stavvy's World. One seek every few seconds at most, unless the
        // sound itself jumped.
        if !force, Date.now.timeIntervalSince(lastSnap) < 3, abs(lastDrift) < 3 { return false }
        lastSnap = .now
        let playing = soundPlaying()
        let ahead = playing ? seekSeconds * max(0.5, soundRate()) : 0
        let target = pictureTime(forSound: heardSoundTime() + ahead)
            ?? (playing ? pictureTime(forSound: soundTime() + ahead) : nil)
        guard var target else {
            holdFrame()
            return true
        }
        // Just after a jump, what is heard for a moment is still the sound
        // from before it, draining out of the headphones. The picture goes
        // straight to the far side and waits there, rather than showing a
        // sliver of the ad that was skipped.
        if let floor = jumpFloor.flatMap({ pictureTime(forSound: $0) }) { target = max(target, floor) }
        jumpFloor = nil
        if !force { reseeks += 1 }
        seeking = true
        snapWhenLanded = false
        // Hold the frame while the seek is under way rather than let it run
        // on from the old place.
        if player.rate != 0 { player.pause() }
        lastRateWeSet = 0
        // Never land behind the target — a picture behind the sound can only
        // catch up by running fast — but let AVFoundation use a keyframe up
        // to half a second after it rather than decode forward to an exact
        // frame. The picture then waits, still, for the sound to reach it.
        let slack = CMTime(seconds: sourceURL?.isFileURL == true ? 0.2 : 0.5, preferredTimescale: 600)
        let started = Date.now
        let attachment = attachmentID
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: slack) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.attachmentID == attachment else { return }
                self.seeking = false
                if finished {
                    let took = Date.now.timeIntervalSince(started)
                    self.seekSeconds = max(0.05, min(1, self.seekSeconds * 0.6 + took * 0.4))
                }
                if self.snapWhenLanded {
                    self.snapWhenLanded = false
                    self.snap(force: true)
                    return
                }
                self.startInStep()
            }
        }
        return true
    }

    @ObservationIgnored private var snapWhenLanded = false
    @ObservationIgnored private var jumpFloor: Double?

    /// The sound jumped — a skipped ad, a seek, Smart Speed. The picture
    /// jumps with it now, to land as the new sound is first heard.
    func soundJumped() {
        guard active, isReady else { return }
        // A hop the picture is already within a quarter-second of (a short
        // Smart Speed trim, a resume that rescheduled in place) is left to
        // the checks: a seek on a stream costs a stutter.
        if !seeking, player.currentItem?.status == .readyToPlay,
           let target = pictureTime(forSound: soundTime()) {
            let now = player.currentTime().seconds
            if now.isFinite, abs(now - target) <= 0.25 {
                if soundPlaying() { startInStep() }
                return
            }
        }
        jumpFloor = soundTime()
        snap(force: true)
    }

    /// Start the still picture so that the frame showing is on screen at the
    /// moment its sound is heard.
    ///
    /// This uses the clock both players share (the host clock) rather than a
    /// seek: the frame shown now is where the picture is; the sound reaches
    /// it some fraction of a second from now, and `setRate(_:time:atHostTime:)`
    /// starts the picture at exactly that moment. If the sound is already a
    /// little past it, the same call moves the picture on to match.
    private func startInStep() {
        guard active, isReady, !seeking, player.currentItem?.status == .readyToPlay else { return }
        guard soundPlaying() else {
            if player.rate != 0 { player.pause() }
            lastRateWeSet = 0
            reportReady()
            return
        }
        let picture = player.currentTime().seconds
        guard picture.isFinite, let ahead = lead(of: picture) else {
            holdFrame()
            return
        }
        let rate = Float(max(0.5, soundRate()))
        // Far out either way: the sound moved while the seek was landing.
        if ahead > 2 || ahead < -1 {
            snap(force: true)
            return
        }
        let wait = ahead / Double(rate)
        let clock = CMClockGetHostTimeClock()
        let when = CMTimeAdd(CMClockGetTime(clock), CMTime(seconds: wait, preferredTimescale: 1_000_000_000))
        // `automaticallyWaitsToMinimizeStalling` is off (see `player`); this
        // call raises an exception if it were on.
        player.setRate(rate, time: CMTime(seconds: picture, preferredTimescale: 600), atHostTime: when)
        lastRateWeSet = rate
        reportReady()
    }

    /// The sound was started or paused. The picture follows now rather than
    /// at the next check, and when starting, it starts when the sound is
    /// heard, not when it is played.
    func soundStateChanged() {
        guard active, isReady, !seeking else { return }
        if soundPlaying() {
            startInStep()
        } else {
            if player.rate != 0 { player.pause() }
            lastRateWeSet = 0
        }
    }

    /// The output changed (headphones on or off, AirPods switched), and with
    /// it the sound's delay: put the picture back in step with the new one.
    func outputChanged() {
        guard active, isReady, !seeking, soundPlaying() else { return }
        startInStep()
    }

    private func correct() {
        guard active, isReady, !seeking, player.currentItem != nil else { return }

        // Picture in Picture's play and pause buttons act on this player, and
        // only while Picture in Picture is up is a change we didn't make the
        // listener's. Any other time it was the system (a route change), and
        // the picture simply follows the sound again below.
        if externalControlsActive() {
            if lastRateWeSet > 0, player.rate == 0, player.timeControlStatus == .paused, soundPlaying() {
                lastRateWeSet = 0
                onExternalPlayPause?(false)
                return
            }
            if lastRateWeSet == 0, player.rate > 0, !soundPlaying() {
                lastRateWeSet = player.rate
                onExternalPlayPause?(true)
                return
            }
        }

        guard let target = pictureTime(forSound: heardSoundTime()) else {
            holdFrame()
            return
        }
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        // Buffering: leave it alone. Seeking or changing rate while it is
        // filling its buffer is how a stream ends up stalling for seconds.
        if let item = player.currentItem, !item.isPlaybackLikelyToKeepUp, player.rate > 0 { return }
        // Sound playing, picture still (a resume, or the system paused it on
        // a route change): start it in step rather than at a guessed rate.
        if soundPlaying(), player.rate == 0 {
            startInStep()
            return
        }
        let drift = now - target
        lastDrift = drift
        // A quarter of a second is past what a small speed change can close
        // in reasonable time: jump. Below that, ease back in.
        if abs(drift) > 0.25, snap() { return }
        applyRate(drift: drift)
    }

    /// The sound is in an ad the video doesn't have (only when skipping is
    /// off, or while previewing a cut): keep the last picture still until the
    /// programme comes back.
    private func holdFrame() {
        if player.rate != 0 { player.pause() }
        lastRateWeSet = 0
    }

    private var lastSnap = Date.distantPast
    private var lastDrift: Double = 0

    /// The sound's speed, plus up to 2% either way to close a small gap.
    private func applyRate(drift: Double) {
        guard soundPlaying() else {
            if player.rate != 0 { player.pause() }
            lastRateWeSet = 0
            return
        }
        let base = Float(max(0.5, soundRate()))
        let correction = Float(max(-0.02, min(0.02, -drift * 0.4)))
        // Within a few hundredths — about a frame — leave the rate alone: on
        // a streamed video every rate change risks a rebuffer.
        let rate = abs(drift) < 0.04 ? base : base * (1 + correction)
        if abs(player.rate - rate) > 0.001 {
            if rate != base { nudges += 1 }
            player.rate = rate
        }
        lastRateWeSet = rate
    }
}
