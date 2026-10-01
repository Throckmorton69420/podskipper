import Foundation
import UIKit

/// Compatibility shim for the old silent-audio background keepalive.
///
/// Processing used to create an AVAudioEngine that played literal silence so
/// iOS would treat PodSkipper as an active audio app. That is not legitimate
/// podcast playback: Bluetooth multipoint devices can see the iPhone as the
/// active audio source and move their connection away from another device.
///
/// Model work must instead use iOS background/continued-processing APIs and
/// checkpoint its progress. Actual podcast playback remains owned by
/// PlayerEngine and its normal AVAudioSession.
@MainActor
final class KeepAwake {
    static let shared = KeepAwake()

    /// Kept only so existing settings/migrations remain harmless.
    static let settingKey = "keepAwakeWithAudio"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? false
    }

    private init() {}

    /// Always false: PodSkipper no longer creates fake audio for processing.
    var isActive: Bool { false }
    var isRunning: Bool { false }

    /// Kept for callers that previously polled the audio keepalive.
    /// BackgroundWork/ProcessingPipeline now rely on the system's processing
    /// task rather than an artificial audio session.
    func update(wanted: Bool) {
        if wanted, UIApplication.shared.applicationState == .background {
            BackgroundLog.shared.note("Processing keepalive uses iOS background/continued processing; no silent audio session is started")
        }
    }

    /// Headphone/Lock Screen pauses no longer control a fake audio session.
    func remotePauseArrived() {}

    /// PlayerEngine calls this before it takes ownership of the real audio
    /// session. There is no fake engine to yield.
    func yieldToPlayer() {}

    /// Compatibility for existing cleanup paths.
    func stop(reason: String) {}

    /// Retained as a no-op API so older call sites remain source-compatible.
    func stop() {}
}
