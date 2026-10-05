import Foundation

/// How a model read behaves when the phone is warm (pass 29, his 5 Oct test).
///
/// Before: at "serious" the read stopped and waited for the phone to cool,
/// with no limit. On his phone "serious" lasted the whole session, so the job
/// sat on "Waiting for iPhone to cool" holding the model, the shared heavy-work
/// slot and the line behind it, and every other job and model test waited too.
///
/// Apple's guidance for `ProcessInfo.ThermalState`: at serious, reduce work;
/// at critical, stop. So now:
/// - nominal / fair: read at full pace.
/// - serious: keep reading, with a short rest between parts so the chip cools
///   a little each time. Slower, but it finishes.
/// - critical: pause, up to `criticalLimit`. Still critical after that, the
///   model read gives up for now (`TooHot`); the reader's cuts are saved and
///   the model reads the episode again later. Nothing waits forever.
///
/// Every wait beats the job heartbeat so the "No progress" watchdog knows the
/// job is resting on purpose, and checks for cancellation every second so
/// Pause, Stop and Restart take effect at once.
enum ThermalPacing {
    struct TooHot: LocalizedError {
        var errorDescription: String? {
            "iPhone stayed too hot to run the ad model; the reader's cuts are kept and the model reads it again later"
        }
    }

    static let seriousRest: Duration = .seconds(20)
    nonisolated(unsafe) static var criticalLimit: TimeInterval = 5 * 60

    /// Test hook: overrides the real thermal state.
    nonisolated(unsafe) static var stateOverride: ProcessInfo.ThermalState?

    static var state: ProcessInfo.ThermalState { stateOverride ?? ProcessInfo.processInfo.thermalState }

    /// Called before each part of a model read.
    static func beforePart(status: @escaping @Sendable (String) -> Void,
                           sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        try Task.checkCancellation()
        switch state {
        case .critical:
            let started = Date()
            status("Paused: iPhone is too hot · carries on when it cools")
            while state == .critical {
                try Task.checkCancellation()
                if Date().timeIntervalSince(started) > criticalLimit { throw TooHot() }
                JobHeartbeat.shared.beat()
                try await sleep(.seconds(1))
            }
            if state == .serious { try await rest(status: status, sleep: sleep) }
        case .serious:
            try await rest(status: status, sleep: sleep)
        default:
            break
        }
        try Task.checkCancellation()
    }

    private static func rest(status: @escaping @Sendable (String) -> Void,
                             sleep: (Duration) async throws -> Void) async throws {
        let seconds = Int(seriousRest.components.seconds)
        for left in stride(from: seconds, to: 0, by: -1) {
            try Task.checkCancellation()
            // Cooled during the rest: no need to finish it.
            if state != .serious && state != .critical { return }
            status("iPhone is warm · resting \(left) s between parts")
            JobHeartbeat.shared.beat()
            try await sleep(.seconds(1))
        }
    }
}
