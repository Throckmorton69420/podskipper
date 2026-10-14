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

    private var lastNotice = Date.distantPast

    private init() {}

    /// Always false: PodSkipper no longer creates fake audio for processing.
    var isActive: Bool { false }
    var isRunning: Bool { false }

    /// Kept for callers that previously polled the audio keepalive.
    /// BackgroundWork/ProcessingPipeline now rely on the system's processing
    /// task rather than an artificial audio session.
    func update(wanted: Bool) {
        guard wanted, UIApplication.shared.applicationState == .background else { return }
        guard Date().timeIntervalSince(lastNotice) >= 60 else { return }
        lastNotice = .now
        BackgroundLog.shared.note("Processing uses iOS background/continued processing; no silent audio session is started")
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

/// Pass 37: keeps the screen from locking by itself while a model test runs.
/// Core AI and MLX can't use the graphics chip once PodSkipper leaves the
/// screen (no background GPU in his signing), so a test that outlasts the
/// auto-lock failed: his 14 Oct Nemotron 3 Nano test read for 5 min, the
/// screen locked, and Core AI reported "Insufficient Permission (to submit
/// GPU work from background)". This is iOS's own idle-timer switch, held only
/// while a test he started runs and the app is open — not a background trick.
@MainActor
enum ScreenAwake {
    private static var holders: Set<String> = []

    static func hold(_ reason: String) {
        holders.insert(reason)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    static func release(_ reason: String) {
        holders.remove(reason)
        if holders.isEmpty { UIApplication.shared.isIdleTimerDisabled = false }
    }

    static var isHeld: Bool { !holders.isEmpty }
}
