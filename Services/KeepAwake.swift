import AVFoundation
import Foundation
import UIKit

/// Keeps PodSkipper running while a job he started carries on with the
/// phone locked, by playing silence (pass 22).
///
/// His 28 Sep Diagnostics (build a12b647): eight times the log stops about
/// thirty seconds after he left the app, with 3.3 GB of the app's own memory
/// still free, and the next line is the app starting again. Thirty seconds is
/// when iOS's short grace period for a backgrounded app ends; after that the
/// continued-processing task is all that ranks PodSkipper, and with Apple
/// Intelligence's model loaded (on this phone the largest process in every
/// memory report, `TGOnDeviceInferenceProviderService`) iOS frees memory by
/// closing background apps. Its own daily report on the old copy counted
/// five of those ("memory pressure") in one day. An app playing audio ranks
/// above plain background work and isn't closed that way, and PodSkipper is
/// an audio app — so while his job runs and nothing is playing, it plays
/// silence, mixed under anything else, and stops the moment the job does.
///
/// What it does not do: lift Apple Intelligence's own limit. Apple: the model
/// is rate-limited when the app is in the background and the phone is on
/// battery ("not expected when connected to power"). Playing audio is still
/// the background. The job keeps running and keeps getting answers, more
/// slowly; plugged in, at full speed.
///
/// Guard rails, so it can't become the thing that drains a phone overnight:
/// only for a job he started; never with Low Power Mode on, the battery under
/// 15 % and not charging, or the phone at "critical" heat; never while
/// PodSkipper itself is playing (that already keeps it running); at most
/// three hours in one stretch; and every start and stop is written to
/// Diagnostics with its reason.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    static let settingKey = "keepAwakeWithAudio"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true }

    private var engine: AVAudioEngine?
    private var startedAt: Date?
    private var lastAttempt = Date.distantPast
    private var capReachedForThisStint = false
    private var observer: NSObjectProtocol?

    private static let maxStint: TimeInterval = 3 * 60 * 60

    var isRunning: Bool { engine?.isRunning == true }

    private init() {}

    /// Why it shouldn't run right now, or nil if it should.
    private func blocker(wanted: Bool) -> String? {
        if !wanted { return "no job of yours running" }
        if !Self.isEnabled { return "turned off in Settings" }
        if UIApplication.shared.applicationState != .background { return "PodSkipper is on screen" }
        if PlayerEngine.shared.isPlaying { return "an episode is playing" }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return "Low Power Mode is on" }
        if ProcessInfo.processInfo.thermalState == .critical { return "the phone is too hot" }
        let device = UIDevice.current
        let charging = device.batteryState == .charging || device.batteryState == .full
        if !charging, device.batteryLevel >= 0, device.batteryLevel < 0.15 { return "the battery is under 15 %" }
        if capReachedForThisStint { return "three hours in one stretch" }
        if heldOffByHeadphones { return "your headphones or the Lock Screen asked the iPhone to stop its audio" }
        return nil
    }

    /// Pass 24: set when a pause arrives from headphones, the Lock Screen or
    /// Control Center while the only thing this iPhone is playing is the
    /// silence. His 29 Sep report (81eb4a3): Bose QC Ultra headphones joined
    /// to his iPhone and iPad at once (multipoint) kept pausing the iPad's TV
    /// show. The silence is real audio to the headphones, so they switched to
    /// the iPhone; pressing play on the iPad makes them send the iPhone a
    /// pause — which pass 23 turned into "play the paused episode", so the
    /// iPhone took the headphones straight back (the log's "an episode
    /// started playing" three times in two minutes). Now a pause pauses, and
    /// the silence stays off until this line of jobs is done or he opens
    /// PodSkipper (pass 25: see `remotePauseArrived`). The job carries on
    /// under iOS's own continued-processing time.
    private var heldOffByHeadphones = false

    /// Whether the silence is on, or was on and is waiting to start again
    /// after a call or Siri.
    var isActive: Bool { engine != nil || startedAt != nil }

    /// A pause (or a play/pause toggle) from headphones, the Lock Screen or
    /// Control Center, whatever was playing, while a job of his runs with the
    /// app off screen.
    ///
    /// Pass 25, his 29 Sep Diagnostics (95f96f0): the silence stopped at
    /// 06:36:46 on a pause from his Bose headphones (joined to his iPad) and
    /// was back at 06:37:05, taking the headphones again — the hold-off ended
    /// the moment the episode played for an instant (multipoint headphones
    /// send the iPhone a play or a toggle when they hand themselves over), and
    /// a pause that arrived while the episode itself was playing didn't count
    /// at all. Now any such pause holds the silence off for the rest of his
    /// line of jobs, until he opens PodSkipper. The jobs carry on under iOS's
    /// continued-processing time; since pass 25 they no longer load Apple's
    /// model, whose memory was the reason iOS closed a backgrounded app.
    func remotePauseArrived() {
        guard UIApplication.shared.applicationState != .active, BackgroundWork.hisWorkOutstanding,
              !heldOffByHeadphones else { return }
        heldOffByHeadphones = true
        let reason = "your headphones, the Lock Screen or Control Center asked the iPhone to stop its audio — another device may want the headphones; your jobs carry on without it until you open PodSkipper"
        if isActive {
            stop(reason: reason)
        } else {
            BackgroundLog.shared.note("Won't start silent audio for the rest of this line of jobs (\(reason))")
        }
    }

    /// Called once a second while work is outstanding, and at the moment the
    /// app leaves the screen. `wanted`: a job he started is running or lined up.
    func update(wanted: Bool) {
        if !wanted || UIApplication.shared.applicationState != .background { capReachedForThisStint = false }
        // Pass 25: not when an episode plays — multipoint headphones play
        // the iPhone for an instant as they hand themselves over.
        if !wanted || UIApplication.shared.applicationState == .active {
            heldOffByHeadphones = false
        }
        if let started = startedAt, Date().timeIntervalSince(started) > Self.maxStint {
            capReachedForThisStint = true
        }
        let reason = blocker(wanted: wanted)
        if let reason {
            if engine != nil || startedAt != nil { stop(reason: reason) }
            return
        }
        guard !isRunning else { return }
        // A call or Siri stops the engine; try again, but not every second.
        guard Date().timeIntervalSince(lastAttempt) > 15 else { return }
        lastAttempt = .now
        start()
    }

    /// Whether PodSkipper is the app the Lock Screen player and his AirPods
    /// are talking to: an episode is loaded and he paused it (not another
    /// app taking the audio away — that arrives as an interruption), and
    /// nothing else is playing now.
    ///
    /// His 29 Sep report (build 37c0c02): he paused an episode while a job
    /// ran in the background, and the Lock Screen player vanished; AirPods
    /// play did nothing. Silent audio had switched the session to "mix with
    /// others", and iOS gives the Lock Screen player and headphone buttons
    /// only to an app whose audio does not mix. So while PodSkipper owns the
    /// player, the silence plays in the player's own session, unmixed, and
    /// the Lock Screen and AirPods keep controlling the episode.
    private static var ownsNowPlaying: Bool {
        let player = PlayerEngine.shared
        guard player.currentEpisode != nil else { return false }
        switch player.phase {
        case .paused, .stopped, .buffering, .loading: break
        default: return false
        }
        return !AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    /// How the running silence shares the audio, for the log.
    private var unmixed = false

    private func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            let owns = Self.ownsNowPlaying
            if owns {
                // The player's own setup: the Lock Screen player stays his.
                try session.setCategory(.playback, mode: .spokenAudio, options: [])
            } else {
                // Mixed: never stops or ducks what he's listening to
                // elsewhere, and leaves that app the Lock Screen's controls.
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            unmixed = owns
            try session.setActive(true)
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            let silence = Self.silentSource(format: format)
            engine.attach(silence)
            engine.connect(silence, to: engine.mainMixerNode, format: format)
            try engine.start()
            self.engine = engine
            if startedAt == nil { startedAt = .now }
            failureLogged = false
            observeInterruptions()
            BackgroundLog.shared.note("Keeping PodSkipper running with silent audio while your job carries on"
                                      + (owns ? ", Lock Screen player kept" : ", mixed with other audio")
                                      + " (\(Diagnostics.thermalName) heat, battery \(Self.batteryText), to \(Self.outputName))")
        } catch {
            engine = nil
            // A call in progress refuses the session every 15 s; once is enough.
            if !failureLogged {
                failureLogged = true
                BackgroundLog.shared.note("Couldn't keep PodSkipper running with audio: \(error.localizedDescription)")
            }
        }
    }

    private var failureLogged = false

    /// Zeros, on the audio thread. Built outside the main actor so the render
    /// block carries no actor of its own.
    nonisolated private static func silentSource(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { isSilence, _, _, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            isSilence.pointee = true
            return noErr
        }
    }

    /// Ends it and gives the audio session back the way the player sets it.
    func stop(reason: String) {
        let ran = startedAt.map { Int(Date().timeIntervalSince($0)) }
        engine?.stop()
        engine = nil
        startedAt = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Self.restorePlayerSession(deactivate: !PlayerEngine.shared.isPlaying)
        BackgroundLog.shared.note("Stopped keeping PodSkipper running (\(reason))" + (ran.map { " after \($0 / 60) min" } ?? ""))
    }

    /// The player is about to play: it needs the session as it set it up
    /// (not mixed, so the Lock Screen and AirPods control it).
    func yieldToPlayer() {
        guard engine != nil else { return }
        engine?.stop()
        engine = nil
        startedAt = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        Self.restorePlayerSession(deactivate: false)
        BackgroundLog.shared.note("Stopped keeping PodSkipper running (an episode started playing, which keeps it running itself)")
    }

    private static func restorePlayerSession(deactivate: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        if deactivate { try? session.setActive(false, options: [.notifyOthersOnDeactivation]) }
    }

    private func observeInterruptions() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: AVAudioSession.sharedInstance(), queue: .main) { note in
            let began = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            guard began else { return }
            // A call or Siri: the engine has stopped. `update` starts it again
            // once the session can be had (tried at most every 15 s).
            MainActor.assumeIsolated {
                guard KeepAwake.shared.engine != nil else { return }
                KeepAwake.shared.engine?.stop()
                KeepAwake.shared.engine = nil
                BackgroundLog.shared.note("The silent audio was interrupted (a call, Siri or another app); trying again in 15 s")
            }
        }
    }

    /// Where the silence goes, for the log (pass 24: headphones joined to
    /// two devices treat it as the iPhone playing).
    private static var outputName: String {
        switch AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType {
        case .bluetoothA2DP?, .bluetoothHFP?, .bluetoothLE?: return "Bluetooth headphones"
        case .headphones?: return "wired headphones"
        case .builtInSpeaker?: return "the speaker"
        case .airPlay?: return "AirPlay"
        case .carAudio?: return "the car"
        case nil: return "nothing"
        default: return "other"
        }
    }

    private static var batteryText: String {
        let device = UIDevice.current
        let level = device.batteryLevel >= 0 ? "\(Int(device.batteryLevel * 100)) %" : "?"
        let charging = device.batteryState == .charging || device.batteryState == .full
        return level + (charging ? ", charging" : "")
    }
}
