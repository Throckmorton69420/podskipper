import Foundation
import SwiftUI

/// Pass 55 (his 30 Oct phone, build 1c40b4f): iOS ended PodSkipper three
/// times with "scene-update watchdog … exhausted 10.00 seconds" — twice in
/// the foreground within 35 s of a relaunch, with the main thread laying out
/// SwiftUI text, once going to the background with it inside SQLite. MetricKit
/// says where the main thread was, not which screen was showing.
///
/// So a timer off the main thread asks the main thread to answer once a
/// second. When it hasn't for 3 s, what was showing is written down at once
/// (iOS may end the app before the main thread comes back); when it answers
/// again, the stall goes into the background log. A note left behind means
/// iOS ended the app during the stall, and the next launch says so.
final class MainThreadWatch: @unchecked Sendable {
    static let shared = MainThreadWatch()

    static let threshold: Double = 3
    private static let key = "mainThread.stall"

    private let lock = NSLock()
    private var lastAnswer = Date.now
    private var stallStarted: Date?
    private var written = false
    private var timer: DispatchSourceTimer?
    /// The screen last shown, set on the main thread by `watchName`.
    private var screen = "Library"

    var currentScreen: String {
        get { lock.withLock { screen } }
        set { lock.withLock { screen = newValue } }
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        let now = Date.now
        let (silent, screen) = lock.withLock { (now.timeIntervalSince(lastAnswer), self.screen) }
        if silent >= Self.threshold {
            let first = lock.withLock { () -> Bool in
                if stallStarted == nil { stallStarted = lastAnswer }
                defer { written = true }
                return !written
            }
            if first || Int(silent) % 2 == 0 {
                UserDefaults.standard.set(["screen": screen, "seconds": silent,
                                           "at": lock.withLock { stallStarted ?? now }.timeIntervalSince1970],
                                          forKey: Self.key)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.answered() }
    }

    private func answered() {
        let now = Date.now
        let stall: (Date, String)? = lock.withLock {
            defer { lastAnswer = now; stallStarted = nil; written = false }
            guard let started = stallStarted else { return nil }
            return (started, screen)
        }
        guard let (started, screen) = stall else { return }
        UserDefaults.standard.removeObject(forKey: Self.key)
        let seconds = now.timeIntervalSince(started)
        MainActor.assumeIsolated {
            BackgroundLog.shared.note(String(format: "The screen stopped responding for %.0f s (%@)", seconds, screen))
        }
    }

    /// A note from a launch that ended during a stall, said once.
    @MainActor
    static func noteEarlierStall(defaults: UserDefaults = .standard) {
        guard let note = defaults.dictionary(forKey: key) else { return }
        defaults.removeObject(forKey: key)
        let seconds = note["seconds"] as? Double ?? 0
        let screen = note["screen"] as? String ?? "?"
        let at = Date(timeIntervalSince1970: note["at"] as? Double ?? 0)
        BackgroundLog.shared.note(String(format: "Last time the screen had stopped responding for at least %.0f s (%@, from %@) when PodSkipper closed — iOS ends an app whose screen doesn't respond for 10 s",
                                         seconds, screen, at.formatted(date: .omitted, time: .standard)))
    }
}

extension View {
    /// Names the screen for `MainThreadWatch`.
    func watchName(_ name: String) -> some View {
        onAppear { MainThreadWatch.shared.currentScreen = name }
    }
}
