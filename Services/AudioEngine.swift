import Foundation
import AVFoundation

/// The playback graph.
///
///   player → timePitch → equalizer → mixer → output
///
/// Everything except speed lives in the equalizer node. A ten-band parametric
/// EQ can be a shelf, a notch, a high-pass or a presence lift depending on how
/// you set each band, which is how Voice Boost, the de-esser and the rumble
/// filter are all built here without dragging in extra audio units.
///
/// This engine only plays local files. That's deliberate: the app downloads
/// every episode it processes anyway, and file-based playback is what makes
/// sample-accurate seeking and Smart Speed possible.
final class AudioEngine {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 14)

    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    /// Where in the file the current schedule began, so position maths works
    /// after a seek.
    private var scheduleOriginFrame: AVAudioFramePosition = 0

    private(set) var isRunning = false

    /// Called when playback reaches the end of the file.
    var onFinished: (() -> Void)?

    // Band layout inside the 14-band EQ.
    private var eqBands: [AVAudioUnitEQFilterParameters] { equalizer.bands }
    private let userBandRange = 0..<10        // the ten visible sliders
    private let rumbleBand = 10
    private let deEsserBand = 11
    private let voiceLowCut = 12
    private let voicePresence = 13

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.attach(equalizer)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)

        configureBandDefaults()
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
        eqBands[rumbleBand].filterType = .highPass
        eqBands[rumbleBand].frequency = 80
        eqBands[rumbleBand].bypass = true

        // De-esser: narrow cut where sibilance lives.
        eqBands[deEsserBand].filterType = .parametric
        eqBands[deEsserBand].frequency = 7000
        eqBands[deEsserBand].bandwidth = 0.5
        eqBands[deEsserBand].gain = -6
        eqBands[deEsserBand].bypass = true

        // Voice Boost: trim what isn't speech, lift what is.
        eqBands[voiceLowCut].filterType = .lowShelf
        eqBands[voiceLowCut].frequency = 180
        eqBands[voiceLowCut].gain = -4
        eqBands[voiceLowCut].bypass = true

        eqBands[voicePresence].filterType = .parametric
        eqBands[voicePresence].frequency = 3000
        eqBands[voicePresence].bandwidth = 1.4
        eqBands[voicePresence].gain = 5
        eqBands[voicePresence].bypass = true
    }

    // MARK: - Effects

    func apply(settings: AppSettings, normalizationGain: Double) {
        timePitch.rate = Float(min(3.0, max(0.5, settings.defaultPlaybackSpeed)))

        // Ten user bands
        for index in userBandRange where index < eqBands.count {
            let gain = settings.equalizerEnabled && index < settings.equalizerGains.count
                ? Float(settings.equalizerGains[index]) : 0
            eqBands[index].gain = max(-12, min(12, gain))
            eqBands[index].bypass = !settings.equalizerEnabled
        }

        eqBands[rumbleBand].bypass = !settings.rumbleFilterEnabled
        eqBands[deEsserBand].bypass = !settings.deEsserEnabled
        eqBands[voiceLowCut].bypass = !settings.voiceBoostEnabled
        eqBands[voicePresence].bypass = !settings.voiceBoostEnabled

        // Voice Boost also lifts the overall level, since cutting the low end
        // takes energy out. Normalization is applied on top, per episode.
        var gain = settings.volumeNormalizationEnabled ? Float(normalizationGain) : 1.0
        if settings.voiceBoostEnabled { gain *= 1.25 }
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

        // Reconnect at the file's own rate so nothing gets resampled twice.
        let format = audioFile.processingFormat
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.disconnectNodeOutput(equalizer)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: equalizer, format: format)
        engine.connect(equalizer, to: engine.mainMixerNode, format: format)
    }

    var duration: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(totalFrames) / sampleRate
    }

    // MARK: - Transport

    func play(from seconds: Double) throws {
        guard let file else { return }
        player.stop()

        let startFrame = AVAudioFramePosition(max(0, seconds) * sampleRate)
        guard startFrame < totalFrames else {
            onFinished?()
            return
        }
        scheduleOriginFrame = startFrame
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

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
        isRunning = true
    }

    func pause() {
        player.pause()
        isRunning = false
    }

    func resume() throws {
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        player.play()
        isRunning = true
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
        isRunning = false
    }

    /// Position in the file, in seconds, accounting for where the current
    /// schedule started.
    var currentTime: Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              sampleRate > 0 else {
            return Double(scheduleOriginFrame) / max(1, sampleRate)
        }
        let played = Double(playerTime.sampleTime) / playerTime.sampleRate
        return Double(scheduleOriginFrame) / sampleRate + played
    }
}
