import Foundation
import AVFoundation

/// The playback graph.
///
///   player → timePitch → equalizer → mixer → output
///
/// Everything except speed lives in the equalizer node. A ten-band parametric
/// EQ can be a shelf, a notch, a high-pass or a presence lift depending on how
/// you set each band, which is how Voice Boost, the de-esser, the rumble filter
/// and the mud cut are all built here without dragging in extra audio units.
///
/// This engine only plays local files. That's deliberate: the app downloads
/// every episode it processes anyway, and file-based playback is what makes
/// sample-accurate seeking and Smart Speed possible.
final class AudioEngine: PlaybackEngine {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EQBand.count)
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

    /// Called when playback reaches the end of the file.
    var onFinished: (() -> Void)?
    /// Part of `PlaybackEngine` and never fired here: an `AVAudioFile` knows
    /// its length the moment it opens, so `duration` is right immediately.
    /// Only the video path has to report it late.
    var onDurationResolved: ((Double) -> Void)?
    /// Raised when the graph has been torn down by the system and rebuilt, so
    /// the player can put the audio back where it was.
    var onEngineReset: (() -> Void)?

    // MARK: - Band layout

    /// Named positions inside the equalizer.
    ///
    /// The first ten are the sliders a listener can drag. The rest are
    /// individual speech repairs, each owning exactly one band so a control can
    /// be switched on without disturbing any other.
    enum EQBand {
        static let userRange = 0..<10
        static let rumble = 10          // high-pass, removes room and handling
        static let deEsser = 11         // narrow cut at sibilance
        static let voiceLowCut = 12     // trims below speech
        static let voicePresence = 13   // lifts articulation
        static let mud = 14             // cuts boxiness
        static let bassTame = 15        // shelves off chestiness
        static let airLift = 16         // gentle top for distant voices
        static let harshCut = 17        // tames upper-mid glare
        static let count = 18
    }

    private var eqBands: [AVAudioUnitEQFilterParameters] { equalizer.bands }

    init() {
        buildGraph()
        observeMediaServicesReset()
    }

    private func buildGraph() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(equalizer)
        engine.attach(downmix)

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
        engine.stop()
        engine.detach(player)
        engine.detach(timePitch)
        engine.detach(equalizer)
        engine.detach(downmix)
        buildGraph()
        // Re-open the file so the format and frame counts match the new graph.
        if let url = file?.url, let reopened = try? AVAudioFile(forReading: url) {
            file = reopened
            sampleRate = reopened.processingFormat.sampleRate
            totalFrames = reopened.length
            rebuildConnections(format: reopened.processingFormat)
        }
        onEngineReset?()
    }

    // MARK: - Band setup

    private func configureBandDefaults() {
        for (index, frequency) in EQPreset.frequencies.enumerated() where index < eqBands.count {
            let band = eqBands[index]
            band.filterType = index == 0 ? .lowShelf
                            : (index == EQPreset.frequencies.count - 1 ? .highShelf : .parametric)
            band.frequency = frequency
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }

        // Rumble: high-pass at 80 Hz. Traffic, air conditioning, mic handling.
        configure(EQBand.rumble, .highPass, frequency: 80, bandwidth: 1.0, gain: 0)

        // De-esser: narrow cut where sibilance lives. 7 kHz is where "s" and
        // "sh" concentrate on a close-mic'd voice.
        configure(EQBand.deEsser, .parametric, frequency: 7000, bandwidth: 0.5, gain: -6)

        // Voice Boost: trim what isn't speech, lift what is.
        configure(EQBand.voiceLowCut, .lowShelf, frequency: 180, bandwidth: 1.0, gain: -4)
        configure(EQBand.voicePresence, .parametric, frequency: 3000, bandwidth: 1.4, gain: 5)

        // Mud: the 250–400 Hz region that makes a voice sound like it is coming
        // from inside a cardboard box.
        configure(EQBand.mud, .parametric, frequency: 300, bandwidth: 1.2, gain: -5)

        // Bass tame: a shelf rather than a cut, for chesty voices where the
        // whole bottom end is heavy rather than one resonance.
        configure(EQBand.bassTame, .lowShelf, frequency: 220, bandwidth: 1.0, gain: -6)

        // Air: a little top for a voice recorded far from the microphone.
        configure(EQBand.airLift, .highShelf, frequency: 9000, bandwidth: 1.0, gain: 3)

        // Harsh: the 2.5–4 kHz glare that makes long sessions tiring.
        configure(EQBand.harshCut, .parametric, frequency: 3200, bandwidth: 1.0, gain: -4)
    }

    private func configure(_ index: Int,
                           _ type: AVAudioUnitEQFilterType,
                           frequency: Float,
                           bandwidth: Float,
                           gain: Float) {
        guard index < eqBands.count else { return }
        let band = eqBands[index]
        band.filterType = type
        band.frequency = frequency
        band.bandwidth = bandwidth
        band.gain = gain
        band.bypass = true
    }

    private func rebuildConnections(format: AVAudioFormat?) {
        currentFormat = format
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(equalizer)
        engine.disconnectNodeOutput(downmix)

        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: downmix, format: format)

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

    func apply(settings: AppSettings, normalizationGain: Double) {
        timePitch.rate = Float(min(3.0, max(0.5, settings.defaultPlaybackSpeed)))

        // Changing channel count means rewiring, so only do it when it flips.
        if settings.monoDownmix != wantsMono {
            wantsMono = settings.monoDownmix
            let wasRunning = engine.isRunning
            if wasRunning { engine.pause() }
            rebuildConnections(format: currentFormat)
            if wasRunning { try? engine.start() }
        }

        // Ten user bands
        for index in EQBand.userRange where index < eqBands.count {
            let gain = settings.equalizerEnabled && index < settings.equalizerGains.count
                ? Float(settings.equalizerGains[index]) : 0
            eqBands[index].gain = max(-12, min(12, gain))
            eqBands[index].bypass = !settings.equalizerEnabled
        }

        // Speech repairs. Each is one band, switched independently, so a
        // listener can fix sibilance without also changing the bottom end.
        eqBands[EQBand.rumble].bypass = !settings.rumbleFilterEnabled

        eqBands[EQBand.deEsser].bypass = !settings.deEsserEnabled
        eqBands[EQBand.deEsser].gain = -Float(max(0, min(12, settings.deEsserStrength)))

        eqBands[EQBand.voiceLowCut].bypass = !settings.voiceBoostEnabled
        eqBands[EQBand.voicePresence].bypass = !settings.voiceBoostEnabled

        eqBands[EQBand.mud].bypass = !settings.mudReductionEnabled
        eqBands[EQBand.mud].gain = -Float(max(0, min(12, settings.mudReductionStrength)))

        eqBands[EQBand.bassTame].bypass = !settings.bassReductionEnabled
        eqBands[EQBand.bassTame].gain = -Float(max(0, min(12, settings.bassReductionStrength)))

        eqBands[EQBand.airLift].bypass = !settings.clarityEnabled
        eqBands[EQBand.airLift].gain = Float(max(0, min(8, settings.clarityStrength)))

        eqBands[EQBand.harshCut].bypass = !settings.harshnessReductionEnabled
        eqBands[EQBand.harshCut].gain = -Float(max(0, min(10, settings.harshnessReductionStrength)))

        // Cutting bands takes energy out, so put some back. Normalization is
        // applied on top, per episode.
        var gain = settings.volumeNormalizationEnabled ? Float(normalizationGain) : 1.0
        if settings.voiceBoostEnabled { gain *= 1.25 }
        if settings.clarityEnabled { gain *= 1.10 }
        if settings.bassReductionEnabled { gain *= 1.10 }
        equalizer.globalGain = 0
        player.volume = min(2.0, max(0.2, gain))

        engine.mainMixerNode.pan = 0
        engine.mainMixerNode.outputVolume = 1.0
    }

    func setRate(_ rate: Double) {
        timePitch.rate = Float(min(3.0, max(0.5, rate)))
    }

    var rate: Double { Double(timePitch.rate) }

    // MARK: - Loading

    func load(fileURL: URL) throws {
        stop()
        let audioFile = try AVAudioFile(forReading: fileURL)
        file = audioFile
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
        file = audioFile
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

        player.stop()

        // Clamp rather than fall off the end. Pressing play on an episode that
        // has just finished used to schedule past the last frame, fire
        // `onFinished` immediately and leave a player that claimed to be
        // playing while nothing happened. Starting over is the useful answer.
        var start = max(0, seconds)
        if start >= duration - 0.5 { start = 0 }

        let startFrame = AVAudioFramePosition(start * sampleRate)
        guard startFrame < totalFrames else { throw PlaybackError.positionPastEnd }

        scheduleOriginFrame = startFrame
        lastMeasuredTime = start
        let frameCount = AVAudioFrameCount(totalFrames - startFrame)

        player.scheduleSegment(file, startingFrame: startFrame,
                               frameCount: frameCount, at: nil) { [weak self] in
            guard let self else { return }
            // scheduleSegment's completion also fires on stop, so only treat
            // it as "finished" if we actually reached the end.
            DispatchQueue.main.async {
                if self.isRunning && self.currentTime >= self.duration - 0.6 {
                    self.onFinished?()
                }
            }
        }

        try startEngineIfNeeded()
        player.play()
        isRunning = true
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
        player.stop()
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
        return min(measured, duration)
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
