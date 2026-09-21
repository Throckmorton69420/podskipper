import Foundation
import Network
import Observation

/// Whether there is a connection, for work that needs one.
///
/// Reported from a train: a download failed with no signal, and the activity
/// bar said both "failed" and "finished". Work that needs the network now asks
/// here first and waits for the connection to come back instead of failing,
/// and says "Waiting for a connection" while it does.
@MainActor
@Observable
final class NetworkStatus {
    static let shared = NetworkStatus()

    private(set) var isOffline = false
    private(set) var isExpensive = false

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            let expensive = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.update(offline: offline, expensive: expensive) }
        }
        monitor.start(queue: DispatchQueue(label: "PodSkipper.network", qos: .utility))
    }

    /// Call once at launch so the first answer is ready when it is asked for.
    func start() {}

    private func update(offline: Bool, expensive: Bool) {
        if isOffline != offline { isOffline = offline }
        if isExpensive != expensive { isExpensive = expensive }
        if !offline {
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }

    /// Returns at once when online; otherwise when the connection returns.
    func waitUntilOnline() async {
        guard isOffline else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Whether an error is the kind that means "no connection" rather than a
    /// real failure, so the caller can wait and retry instead of giving up.
    nonisolated static func isConnectivity(_ error: Error) -> Bool {
        let codes: Set<Int> = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                               NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                               NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                               NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff]
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain, codes.contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isConnectivity(underlying) }
        return false
    }
}
