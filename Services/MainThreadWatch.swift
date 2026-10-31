import Foundation
import SwiftUI
import UIKit

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
///
/// Pass 56 (his 31 Oct phone, da0c477): every stall it logged — 65 s and
/// 621 s on Compare models, 1,433 s and 203 s on Library — began at an
/// audio interruption or a pause and ended when the app came back: iOS had
/// suspended PodSkipper, the timer couldn't run either, and the wall-clock
/// gap was counted as the screen not responding. So time is counted only
/// while the timer itself keeps running: a gap of more than `suspendedGap`
/// between its own ticks means the process was suspended, and the count
/// starts again. The app's state is noted with each stall.
final class MainThreadWatch: @unchecked Sendable {
    static let shared = MainThreadWatch()

    static let threshold: Double = 3
    /// The timer ticks once a second; a longer gap than this between its
    /// own ticks means iOS suspended the process.
    static let suspendedGap: Double = 2.5
    private static let key = "mainThread.stall"

    private let lock = NSLock()
    private var lastAnswer = Date.now
    private var lastTick = Date.now
    /// Seconds counted while the process ran; reset after a suspension.
    private var silentRunning: Double = 0
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
        if Thread.isMainThread {
            MainActor.assumeIsolated { noteState(UIApplication.shared.applicationState != .background) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in self?.noteState(true) }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in self?.noteState(false) }
    }

    private func tick() {
        let now = Date.now
        let (silent, screen) = lock.withLock { () -> (Double, String) in
            let gap = now.timeIntervalSince(lastTick)
            lastTick = now
            silentRunning = Self.counted(silent: silentRunning, gap: gap, active: state == "active")
            if silentRunning == 0 {
                // Suspended: not a stall. Wait for the next answer afresh.
                lastAnswer = now; stallStarted = nil; written = false
            }
            return (silentRunning, self.screen)
        }
        if silent >= Self.threshold {
            let first = lock.withLock { () -> Bool in
                if stallStarted == nil { stallStarted = lastAnswer }
                defer { written = true }
                return !written
            }
            if first || Int(silent) % 2 == 0 {
                UserDefaults.standard.set(["screen": screen, "seconds": silent,
                                           "at": lock.withLock { stallStarted ?? now }.timeIntervalSince1970,
                                           "state": appState],
                                          forKey: Self.key)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.answered() }
    }

    private func answered() {
        let now = Date.now
        let stall: (Double, String)? = lock.withLock {
            defer { lastAnswer = now; stallStarted = nil; written = false; silentRunning = 0 }
            guard stallStarted != nil else { return nil }
            // What the timer counted while running, plus the last tick's
            // part second: never the time the process was suspended.
            return (silentRunning + min(1, now.timeIntervalSince(lastTick)), screen)
        }
        guard let (seconds, screen) = stall else { return }
        UserDefaults.standard.removeObject(forKey: Self.key)
        MainActor.assumeIsolated {
            let state = UIApplication.shared.applicationState == .active ? "" : ", app not in front"
            BackgroundLog.shared.note(String(format: "The screen stopped responding for %.0f s (%@%@)", seconds, screen, state))
        }
    }

    /// Seconds without an answer, counted only while the process ran. Off
    /// screen, a gap between ticks longer than `suspendedGap` was a
    /// suspension and starts the count again (0). In front, iOS doesn't
    /// suspend the app, so a late tick (the CPU busy) counts in full.
    static func counted(silent: Double, gap: Double, active: Bool) -> Double {
        !active && gap > suspendedGap ? 0 : silent + gap
    }

    /// Read off the main thread from the last value the main thread set.
    private var appState: String { lock.withLock { state } }
    private var state = "active"

    /// Set on the main thread as the app comes and goes.
    func noteState(_ active: Bool) { lock.withLock { state = active ? "active" : "background" } }

    /// A note from a launch that ended during a stall, said once.
    @MainActor
    static func noteEarlierStall(defaults: UserDefaults = .standard) {
        guard let note = defaults.dictionary(forKey: key) else { return }
        defaults.removeObject(forKey: key)
        let seconds = note["seconds"] as? Double ?? 0
        let screen = note["screen"] as? String ?? "?"
        let at = Date(timeIntervalSince1970: note["at"] as? Double ?? 0)
        let away = (note["state"] as? String).map { $0 == "active" ? "" : ", app not in front" } ?? ""
        BackgroundLog.shared.note(String(format: "Last time the screen had stopped responding for at least %.0f s (%@%@, from %@) when PodSkipper closed — iOS ends an app whose screen doesn't respond for 10 s",
                                         seconds, screen, away, at.formatted(date: .omitted, time: .standard)))
    }
}

extension View {
    /// Names the screen for `MainThreadWatch`.
    func watchName(_ name: String) -> some View {
        onAppear { MainThreadWatch.shared.currentScreen = name }
    }
}
