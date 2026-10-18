import Foundation
import AVFoundation
import AudioToolbox

/// The playback graph.
///
///   player → timePitch → equalizer → mixer → output
///
/// Everything except speed lives in the equalizer node. What its bands are set
/// to comes from `EQMath.plan` (SoundModel.swift) — the same numbers the
/// equalizer screen draws — so this file only copies them across.
///
/// This engine only plays local files. That's deliberate: the app downloads
/// every episode it processes anyway, and file-based playback is what makes
/// sample-accurate seeking and Smart Speed possible.
final class AudioEngine: PlaybackEngine {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EQBand.count)
    /// Even Out Volume (pass 29): Apple's dynamics processor as a gentle
    /// speech leveller. Bypassed when the switch is off.
    private let leveller = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    /// Sits between the EQ and the output purely so the connection format can
    /// be switched to one channel. A mixer node performs channel-count
    /// conversion, which is how mono downmix is done without a custom unit.
    private let downmix = AVAudioMixerNode()
    private var wantsMono = false
    private var currentFormat: AVAudioFormat?

    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    /// Where in the file the current schedule began, so position maths works
    /// after a seek.
    private var scheduleOriginFrame: AVAudioFramePosition = 0

    /// The last position we were actually able to measure, in seconds.
    ///
    /// This exists because of a bug that made resuming lose your place.
    /// `AVAudioPlayerNode.lastRenderTime` returns nil whenever the node is not
    /// rendering — which is to say, the entire time you are paused. The old
    /// `currentTime` fell back to `scheduleOriginFrame` in that case, so
    /// pausing forty minutes into an episode reported the position as wherever
    /// the current segment had started. Resume then picked up from there, and
    /// with ad skipping the segment origin is often minutes behind.
    ///
    /// Now the measured value is remembered and handed back while paused, so
    /// the position a listener sees and the position a resume uses are the same
    /// number they were looking at a moment earlier.
    private var lastMeasuredTime: Double = 0

    private(set) var isRunning = false
    /// The engine and the player node both running: false once a call or
    /// another app has stopped them, whatever `isRunning` still says.
    ///
    /// Pass 42: true is not proof of sound. Both flags stayed true through
    /// eight silent minutes on his phone; `health()` is what says whether the
    /// node still has audio to play and whether the engine's clock moves.
    var isRendering: Bool { isRunning && engine.isRunning && player.isPlaying }

    // MARK: - Feeding the player (Pass 42)

    /// Pass 42 (his 18 Oct report): during a Bonsai 27B model test, with the
    /// phone at serious and iOS closing the app twice for memory, the sound
    /// stopped while the player kept counting — engine running, node playing,
    /// position advancing — until Skip Back brought it back. Skip Back is a
    /// reschedule; nothing else in the graph changes.
    ///
    /// The whole rest of the file used to be handed to the node as one
    /// segment, and the node read and decoded it a little ahead of the
    /// speaker on a thread of its own. How far ahead it was can't be asked,
    /// so when that reading fell behind there was nothing to notice: the
    /// node's clock runs on over silence.
    ///
    /// Now this reads the file itself, a second at a time, keeping
    /// `aheadSeconds` decoded ahead of the speaker on a queue of its own. A
    /// stall in reading has that long to pass before anything is heard, and
    /// how much the node was given is known exactly — so a node playing past
    /// the end of it is a fact, not a guess (`health()`).
    private let feedQueue = DispatchQueue(label: "PodSkipper.audio.feed", qos: .userInteractive)
    private struct Feed {
        /// Bumped by every reschedule; a buffer's completion from an older
        /// schedule is ignored.
        var generation = 0
        /// File frame this schedule began at (= `scheduleOriginFrame`).
        var origin: AVAudioFramePosition = 0
        /// Next file frame to read: everything before it has been given to
        /// the node.
        var next: AVAudioFramePosition = 0
        /// Buffers given and not yet consumed.
        var queued = 0
        var reachedEnd = false
        var readFailure: String?
        /// This schedule's slowest one-second read, and how many times the
        /// node briefly ran dry before the next second arrived.
        var slowestRead: Double = 0
        var shortGaps = 0
    }
    private let feedLock = NSLock()
    private var feed = Feed()
    /// Seconds decoded ahead of the speaker. Twenty seconds of 48 kHz stereo
    /// is 7.7 MB.
    let aheadSeconds: Double
    static let chunkSeconds = 1.0
    /// A node this far past what it was given is starved, not jittering.
    static let starvedAfter = 0.25
    /// Test hook: while true the reader schedules nothing, as if its thread
    /// got no time at all.
    var holdsReadingForTesting = false

    private func withFeed<T>(_ body: (inout Feed) -> T) -> T {
        feedLock.lock(); defer { feedLock.unlock() }
        return body(&feed)
    }

    /// Called when playback reaches the end of the file.
    var onFinished: (() -> Void)?
    /// Part of `PlaybackEngine` and never fired here: an `AVAudioFile` knows
    /// its length the moment it opens, so `duration` is right immediately.
    /// Only the video path has to report it late.
    var onDurationResolved: ((Double) -> Void)?
    /// Raised when the graph has been torn down by the system and rebuilt, so
    /// the player can put the audio back where it was.
    var onEngineReset: (() -> Void)?
    /// Raised (on the main queue) when iOS stopped the engine because the
    /// output's format changed — a Bluetooth headset switching profile when
    /// any app opens its microphone, a sample-rate change, AirPods handing
    /// over. Pass 33: nothing listened for this before, so the engine stayed
    /// stopped until something else happened to restart it.
    var onConfigurationChanged: (() -> Void)?

    // MARK: - Band layout

    /// Named positions inside the equalizer.
    ///
    /// The first ten are the ISO bands: the preset plus the repairs that fit
    /// one-octave bands (boom, mud, dialogue, harshness). The last two do
    /// what those bands can't: a high-pass and a narrow notch.
    enum EQBand {
        static let userRange = 0..<10
        static let rumble = 10          // high-pass, removes room and handling
        static let deEsser = 11         // narrow cut at sibilance
        static let count = 12
    }

    private var eqBands: [AVAudioUnitEQFilterParameters] { equalizer.bands }

    init(aheadSeconds: Double = 20) {
        self.aheadSeconds = max(2, aheadSeconds)
        buildGraph()
        observeMediaServicesReset()
        observeRouteForLatency()
        observeConfigurationChange()
    }

    /// The engine stops itself when the output hardware's channel count or
    /// sample rate changes, and posts this. Apple's guidance is to restart
    /// it; the player decides whether it should be playing.
    private func observeConfigurationChange() {
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChanged?()
        }
    }

    /// For diagnostics: what the engine itself reports.
    var stateDescription: String {
        "engine \(engine.isRunning ? "running" : "stopped"), node \(player.isPlaying ? "playing" : "not playing")"
            + ", output \(Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)) Hz"
            + feedDescription
    }

    /// Pass 42: how much the node has left, and how reading has gone since
    /// the last reschedule. Read only at trace events.
    private var feedDescription: String {
        let f = withFeed { $0 }
        guard file != nil, sampleRate > 0 else { return "" }
        var text = ", given to \(String(format: "%.1f", Double(f.next) / sampleRate)) s"
        if let rendered = renderedFrames() {
            let ahead = Double(f.next - f.origin - rendered) / sampleRate
            text += " (\(String(format: "%.1f", ahead)) s ahead)"
        }
        text += ", slowest read \(Int((f.slowestRead * 1000).rounded())) ms"
        if f.shortGaps > 0 { text += ", ran dry \(f.shortGaps)×" }
        if f.reachedEnd { text += ", end given" }
        if let failure = f.readFailure { text += ", read failed: \(failure)" }
        return text
    }

    // MARK: - Output latency (task 09)

    /// How long after the engine plays a sample it is actually heard, in
    /// seconds: the output device's own delay plus one I/O buffer plus what
    /// the speed and EQ units hold back. A few hundredths on the speaker,
    /// ~0.15–0.3 on Bluetooth. A video's picture is held back by this much;
    /// without it the picture ran ahead of the sound by exactly this.
    ///
    /// Read once and again whenever the route changes, not per frame:
    /// asking the session is not free and the answer only changes with the
    /// route.
    private(set) var outputLatency: Double = 0
    /// The output's name as iOS gives it ("AirPods Pro", "Speaker").
    private(set) var outputRouteName = ""
    /// Fired on the main queue when either of the two above changes.
    var onLatencyChanged: (() -> Void)?

    private func observeRouteForLatency() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.measureLatency()
        }
        measureLatency()
    }

    /// On the main queue only, so the player reads a settled value.
    private func measureLatency() {
        let session = AVAudioSession.sharedInstance()
        let units = timePitch.latency + equalizer.latency + leveller.latency
        var seconds = session.outputLatency + session.ioBufferDuration + units
        // A nonsense reading (a route half torn down) is worse than none.
        if !seconds.isFinite || seconds < 0 || seconds > 1 { seconds = 0 }
        let name = session.currentRoute.outputs.first?.portName ?? ""
        guard abs(seconds - outputLatency) > 0.001 || name != outputRouteName else { return }
        outputLatency = seconds
        outputRouteName = name
        onLatencyChanged?()
    }

    private func buildGraph() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(equalizer)
        engine.attach(leveller)
        engine.attach(downmix)
        leveller.bypass = true

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        rebuildConnections(format: format)
        configureBandDefaults()
    }

    // MARK: - Media services reset

    /// iOS can tear down the entire audio stack — after a bad route change, a
    /// hardware hiccup, or `mediaserverd` restarting. Every node in the graph
    /// becomes invalid, and an app that does not rebuild simply goes silent
    /// forever with no error and no way back except relaunching.
    private func observeMediaServicesReset() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let audio = self else { return }
            audio.rebuildAfterReset()
        }
    }

    private func rebuildAfterReset() {
        isRunning = false
        feedQueue.sync { _ = withFeed { $0.generation += 1 } }
        engine.stop()
        engine.detach(player)
        engine.detach(timePitch)
        engine.detach(equalizer)
        engine.detach(leveller)
        engine.detach(downmix)
        buildGraph()
        // Re-open the file so the format and frame counts match the new graph.
        if let url = file?.url, let reopened = try? AVAudioFile(forReading: url) {
            feedQueue.sync { file = reopened }
            sampleRate = reopened.processingFormat.sampleRate
            totalFrames = reopened.length
            rebuildConnections(format: reopened.processingFormat)
        }
        onEngineReset?()
    }

    // MARK: - Band setup

    private func configureBandDefaults() {
        let flat = EQMath.plan(SoundSettings(base: EQPreset.flat.gains, repairs: [:], normalizationDB: 0))
        set(flat)
    }

    /// Copy a plan onto the bands. The ten ISO bands are never bypassed —
    /// at 0 dB they are transparent, and flipping bypass mid-playback can
    /// click — while the two dedicated bands switch in and out.
    private func set(_ plan: SoundPlan) {
        for (index, spec) in plan.bands.enumerated() where index < eqBands.count {
            write(spec, to: eqBands[index])
        }
        if EQBand.rumble < eqBands.count { write(plan.rumble, to: eqBands[EQBand.rumble]) }
        if EQBand.deEsser < eqBands.count { write(plan.sibilanceNotch, to: eqBands[EQBand.deEsser]) }
    }

    private func write(_ spec: FilterSpec, to band: AVAudioUnitEQFilterParameters) {
        let type: AVAudioUnitEQFilterType
        switch spec.kind {
        case .lowShelf:  type = .lowShelf
        case .highShelf: type = .highShelf
        case .peak:      type = .parametric
        case .highPass:  type = .highPass
        }
        // Only write what changed. A slider drag re-applies many times a
        // second, and there's no reason to touch a parameter that is already
        // right.
        if band.filterType != type { band.filterType = type }
        if band.frequency != Float(spec.frequency) { band.frequency = Float(spec.frequency) }
        if band.bandwidth != Float(spec.bandwidth) { band.bandwidth = Float(spec.bandwidth) }
        if band.gain != Float(spec.gain) { band.gain = Float(spec.gain) }
        if band.bypass != !spec.isOn { band.bypass = !spec.isOn }
    }

    private func rebuildConnections(format: AVAudioFormat?) {
        currentFormat = format
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(equalizer)
        engine.disconnectNodeOutput(leveller)
        engine.disconnectNodeOutput(downmix)

        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: leveller, format: format)
        engine.connect(leveller, to: downmix, format: format)

        let outputFormat: AVAudioFormat?
        if wantsMono, let format {
            outputFormat = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate,
                                         channels: 1)
        } else {
            outputFormat = format
        }
        engine.connect(downmix, to: engine.mainMixerNode, format: outputFormat)
    }

    // MARK: - Effects

    func apply(settings: AppSettings, sound: SoundSettings) {
        timePitch.rate = Float(min(3.0, max(0.5, settings.defaultPlaybackSpeed)))

        // Changing channel count means rewiring, so only do it when it flips.
        if settings.monoDownmix != wantsMono {
            wantsMono = settings.monoDownmix
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            rebuildConnections(format: currentFormat)
            if wasRunning { try? engine.start() }
        }

        // Preset, repairs and level, all from the one model the equalizer
        // screen draws.
        let plan = EQMath.plan(sound)
        set(plan)
        equalizer.globalGain = 0
        player.volume = min(2.0, max(0.2, Float(pow(10, plan.levelDB / 20))))
        // Pass 33: resolved for the show, like the rest of the sound.
        applyLeveller(on: sound.levelling, strength: sound.levellingStrength)

        engine.mainMixerNode.pan = 0
        engine.mainMixerNode.outputVolume = 1.0
    }

    /// A slow, gentle compressor for speech: it turns loud passages down
    /// and makes the difference back up, so a quiet guest and a loud host end
    /// up closer. Strength 0…1 goes from about 2:1 on peaks to about 4:1.
    /// Slow attack and release so it rides voices, not syllables.
    private func applyLeveller(on: Bool, strength: Double) {
        if leveller.bypass == on { leveller.bypass = !on }
        guard on else { return }
        let s = min(1, max(0, strength))
        let tree = leveller.auAudioUnit.parameterTree
        func set(_ id: AudioUnitParameterID, _ value: Double) {
            tree?.parameter(withAddress: AUParameterAddress(id))?.value = AUValue(value)
        }
        set(kDynamicsProcessorParam_Threshold, -20 - 12 * s)      // −20 … −32 dB
        set(kDynamicsProcessorParam_HeadRoom, 12 - 7 * s)         // 12 … 5 dB above threshold
        set(kDynamicsProcessorParam_ExpansionRatio, 1)            // no gating of quiet parts
        set(kDynamicsProcessorParam_ExpansionThreshold, -100)
        set(kDynamicsProcessorParam_AttackTime, 0.02)
        set(kDynamicsProcessorParam_ReleaseTime, 0.4)
        set(kDynamicsProcessorParam_OverallGain, 3 + 5 * s)       // make-up gain
    }

    func setRate(_ rate: Double) {
        timePitch.rate = Float(min(3.0, max(0.5, rate)))
    }

    var rate: Double { Double(timePitch.rate) }

    // MARK: - Loading

    func load(fileURL: URL) throws {
        stop()
        let audioFile = try AVAudioFile(forReading: fileURL)
        feedQueue.sync { file = audioFile }
        sampleRate = audioFile.processingFormat.sampleRate
        totalFrames = audioFile.length
        scheduleOriginFrame = 0
        lastMeasuredTime = 0

        // Reconnect at the file's own rate so nothing gets resampled twice.
        rebuildConnections(format: audioFile.processingFormat)
    }

    /// Open the file without blocking whoever asked.
    ///
    /// `AVAudioFile(forReading:)` reads and parses the container, and for a
    /// two-hour episode that is not instant — it is seconds, and it was
    /// happening on the main actor because `PlayerEngine.load` is main-actor
    /// isolated and called straight into it. That is the gap between pressing
    /// play and hearing anything: not the engine starting, the file opening,
    /// with the whole UI frozen behind it.
    ///
    /// Opening happens off the main actor now and only the resulting handle
    /// comes back, which is cheap to hand over.
    nonisolated static func openFile(at url: URL) async throws -> AVAudioFile {
        try await Task.detached(priority: .userInitiated) {
            try AVAudioFile(forReading: url)
        }.value
    }

    /// Adopt a file that was opened elsewhere.
    func adopt(_ audioFile: AVAudioFile) {
        stop()
        feedQueue.sync { file = audioFile }
        sampleRate = audioFile.processingFormat.sampleRate
        totalFrames = audioFile.length
        scheduleOriginFrame = 0
        lastMeasuredTime = 0
        rebuildConnections(format: audioFile.processingFormat)
    }

    var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    // MARK: - Transport

    func play(from seconds: Double) throws {
        guard let file else { throw PlaybackError.noFileLoaded }

        // Clamp rather than fall off the end. Pressing play on an episode that
        // has just finished used to schedule past the last frame, fire
        // `onFinished` immediately and leave a player that claimed to be
        // playing while nothing happened. Starting over is the useful answer.
        var start = seconds.isFinite ? max(0, seconds) : 0
        if start >= duration { start = 0 }

        let startFrame = AVAudioFramePosition(start * sampleRate)
        guard startFrame < totalFrames else { throw PlaybackError.positionPastEnd }

        scheduleOriginFrame = startFrame
        lastMeasuredTime = start
        clockWatch = RenderClockWatch()

        // On the reader's queue, so no buffer from the old schedule can be
        // given after the node is flushed. The first half-second is read
        // here, before the node starts, so its clock and the audio begin
        // together; the rest follows on the reader's queue.
        let generation: Int = feedQueue.sync {
            let generation = withFeed { feed -> Int in
                feed = Feed(generation: feed.generation + 1, origin: startFrame, next: startFrame)
                return feed.generation
            }
            player.stop()
            fill(generation, file: file, upTo: max(1, Int(0.5 * sampleRate)))
            return generation
        }

        try startEngineIfNeeded()
        player.play()
        isRunning = true
        feedQueue.async { [weak self] in self?.fill(generation, file: file) }
    }

    /// Give the node up to `aheadSeconds` (or `limit` frames, for the first
    /// read) of decoded audio. On `feedQueue` only.
    private func fill(_ generation: Int, file: AVAudioFile, upTo limit: Int? = nil) {
        let chunk = AVAudioFrameCount(max(1_024, (sampleRate * Self.chunkSeconds).rounded()))
        let aheadFrames = AVAudioFramePosition(aheadSeconds * sampleRate)
        var givenNow = 0
        while !holdsReadingForTesting {
            let state = withFeed { $0 }
            guard state.generation == generation, !state.reachedEnd, state.readFailure == nil else { return }
            let rendered = renderedFrames() ?? 0
            let given = state.next - state.origin
            if limit == nil, given - rendered >= aheadFrames { return }
            if let limit, givenNow >= limit { return }
            // Already past everything it had by more than a blip: leave it
            // starved for the player to put right from where sound stopped
            // (`health`), rather than give it audio its clock has run past.
            if state.queued == 0, given > 0, Double(rendered - given) / sampleRate > Self.starvedAfter { return }

            let remaining = totalFrames - state.next
            guard remaining > 0 else { _ = withFeed { $0.reachedEnd = true }; return }
            let frames = min(limit.map { AVAudioFrameCount(max(1, $0 - givenNow)) } ?? chunk, chunk,
                             AVAudioFrameCount(remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return }
            let began = DispatchTime.now().uptimeNanoseconds
            do {
                if file.framePosition != state.next { file.framePosition = state.next }
                try file.read(into: buffer, frameCount: frames)
            } catch {
                withFeed { if $0.generation == generation { $0.readFailure = error.localizedDescription } }
                return
            }
            let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
            let length = AVAudioFramePosition(buffer.frameLength)
            guard length > 0 else { _ = withFeed { $0.reachedEnd = true }; return }
            let isLast = state.next + length >= totalFrames
            let ranDry = state.queued == 0 && given > 0 && rendered > given
            let accepted = withFeed { feed -> Bool in
                guard feed.generation == generation else { return false }
                feed.next += length
                feed.queued += 1
                feed.reachedEnd = isLast
                feed.slowestRead = max(feed.slowestRead, took)
                if ranDry { feed.shortGaps += 1 }
                return true
            }
            guard accepted else { return }
            givenNow += Int(length)
            // The last buffer reports when it has been heard, so the episode
            // ends when its sound does; the others as soon as the node is
            // done with them, so the next second is read straight away.
            player.scheduleBuffer(buffer, completionCallbackType: isLast ? .dataPlayedBack : .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.feedQueue.async { self.finished(generation, isLast: isLast, file: file) }
            }
        }
    }

    private func finished(_ generation: Int, isLast: Bool, file: AVAudioFile) {
        let current = withFeed { feed -> Bool in
            guard feed.generation == generation else { return false }
            feed.queued = max(0, feed.queued - 1)
            return true
        }
        guard current else { return }
        guard isLast else { fill(generation, file: file); return }
        // A flush also completes buffers, so only reaching the end counts.
        DispatchQueue.main.async {
            if self.isRunning && self.currentTime >= self.duration - 0.6 {
                self.onFinished?()
            }
        }
    }

    /// The node's own clock since this schedule began, in file frames
    /// (it counts on over silence). Nil while it isn't rendering.
    private func renderedFrames() -> AVAudioFramePosition? {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return nil }
        return playerTime.sampleTime
    }

    // MARK: - Is sound actually coming out? (Pass 42)

    enum Health: Equatable {
        case fine
        /// The node played everything it was given and its clock ran on
        /// over silence. `heardUntil` is where the sound stopped.
        case starved(heardUntil: Double, behind: Double)
        /// Engine and node say they are running, and the render clock hasn't
        /// moved for `seconds`.
        case clockStopped(seconds: Double)
    }

    private var clockWatch = RenderClockWatch()

    /// Asked by the player's tick while it believes it is playing. Cheap:
    /// two clock reads and a lock.
    func health(at now: Date = .now) -> Health {
        guard isRunning, engine.isRunning, player.isPlaying, sampleRate > 0 else {
            clockWatch = RenderClockWatch()
            return .fine
        }
        if let stalled = clockWatch.observe(player.lastRenderTime?.sampleTime, at: now) {
            return .clockStopped(seconds: stalled)
        }
        let f = withFeed { $0 }
        // Only a node with nothing left can be starved; a reschedule's first
        // stale clock reading can't trip this, as the new audio is queued.
        guard f.queued == 0, !f.reachedEnd, let rendered = renderedFrames() else { return .fine }
        let given = f.next - f.origin
        let behind = Double(rendered - given) / sampleRate
        guard behind > Self.starvedAfter else { return .fine }
        return .starved(heardUntil: Double(f.next) / sampleRate, behind: behind)
    }

    /// Pick up exactly where `pause` left off, without rescheduling.
    ///
    /// `AVAudioPlayerNode` keeps its scheduled segment across a pause, so this
    /// is both cheaper and more reliable than tearing the schedule down and
    /// rebuilding it — which is what every resume used to do, and which loses
    /// the node's own sample clock in the process.
    func resume() throws {
        guard file != nil else { throw PlaybackError.noFileLoaded }
        try startEngineIfNeeded()
        clockWatch = RenderClockWatch()
        player.play()
        isRunning = true
    }

    /// Start the `AVAudioEngine` if it is not already producing audio, and
    /// prove that it did.
    ///
    /// `engine.isRunning` is not trustworthy on its own after the session has
    /// been taken away and given back: the object can still claim to be running
    /// over a graph that produces nothing. Stopping first costs a few
    /// milliseconds and removes the whole class of silent failure.
    private func startEngineIfNeeded() throws {
        if engine.isRunning, engine.outputNode.engine != nil, player.engine != nil {
            return
        }
        if engine.isRunning { engine.stop() }
        engine.prepare()
        try engine.start()
        guard engine.isRunning else { throw PlaybackError.engineWouldNotStart }
        // The buffer size and the device's delay are only final once the
        // session is active and the engine running.
        if Thread.isMainThread { measureLatency() }
    }

    func pause() {
        // Measure before stopping, because the moment the node stops rendering
        // there is nothing left to ask.
        lastMeasuredTime = currentTime
        player.pause()
        // Pausing the engine as well releases the render thread while keeping
        // every node, connection and scheduled buffer intact, which is what
        // makes `resume` a real resume.
        if engine.isRunning { engine.pause() }
        isRunning = false
    }

    func stop() {
        lastMeasuredTime = currentTime
        feedQueue.sync {
            _ = withFeed { $0.generation += 1 }
            player.stop()
        }
        if engine.isRunning { engine.stop() }
        isRunning = false
    }

    /// Position in the file, in seconds.
    ///
    /// While the node is rendering this is measured from its own sample clock,
    /// which is sample-accurate. While it is not — paused, interrupted, stopped
    /// — `lastRenderTime` is nil, and the answer is the last position we were
    /// able to measure rather than the start of the current segment.
    var currentTime: Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              sampleRate > 0 else {
            return lastMeasuredTime
        }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        let measured = Double(scheduleOriginFrame) / sampleRate + played
        // A node that has been re-scheduled but has not rendered yet can report
        // a sample time from the previous segment for one buffer. Never let the
        // position run past the file.
        guard measured.isFinite, measured >= 0 else { return lastMeasuredTime }
        // Pass 42: never past the audio the node was given. A starved node's
        // clock runs on over silence; the listener hasn't heard that.
        let givenUntil = Double(withFeed { $0.next }) / sampleRate
        return min(measured, givenUntil, duration)
    }
}

/// Pass 42: says when a render clock that should be moving has stopped.
/// Fed the node's last render sample at each tick; a clock read as nil or
/// unchanged for `limit` seconds in a row is stopped. One healthy reading
/// clears it.
struct RenderClockWatch {
    static let limit = 1.5
    private var lastSample: AVAudioFramePosition?
    private var unchangedSince: Date?

    /// Seconds the clock has been still, once that reaches `limit`.
    mutating func observe(_ sample: AVAudioFramePosition?, at now: Date) -> Double? {
        if let sample, sample != lastSample {
            lastSample = sample
            unchangedSince = nil
            return nil
        }
        guard let since = unchangedSince else { unchangedSince = now; return nil }
        let still = now.timeIntervalSince(since)
        return still >= Self.limit ? still : nil
    }
}

/// Pass 42: how often the player may restart sound on its own. Three times
/// in two minutes; past that something is wrong that a restart won't fix,
/// and the player pauses (Play then starts it again) rather than loop.
struct SoundRecoveryBudget {
    static let limit = 3
    static let window: TimeInterval = 120
    private(set) var recent: [Date] = []

    mutating func take(at now: Date = .now) -> Bool {
        recent.removeAll { now.timeIntervalSince($0) >= Self.window }
        guard recent.count < Self.limit else { return false }
        recent.append(now)
        return true
    }
}

/// Why playback could not start, in terms the player can turn into a sentence.
enum PlaybackError: LocalizedError {
    case noFileLoaded
    case positionPastEnd
    case engineWouldNotStart

    var errorDescription: String? {
        switch self {
        case .noFileLoaded:
            return "This episode's audio isn't ready yet."
        case .positionPastEnd:
            return "This episode has already finished."
        case .engineWouldNotStart:
            return "Audio couldn't start. Another app may be using it."
        }
    }
}
