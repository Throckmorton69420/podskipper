import Foundation
import Observation

/// Processing, maintenance and benchmarks share one heavy-work slot. A
/// cancelled job keeps its lease until its actual work has unwound, even if
/// its UI has already moved on to Waiting or Stopped.
@MainActor
@Observable
final class HeavyWorkCoordinator {
    static let shared = HeavyWorkCoordinator()

    enum Priority: Int, Sendable { case user, preparation, maintenance }
    struct Lease: Equatable, Sendable {
        let id: UUID
        let owner: String
    }
    private struct Waiter {
        let id: UUID
        let owner: String
        let priority: Priority
        let continuation: CheckedContinuation<Lease, Error>
    }

    private(set) var current: Lease?
    @ObservationIgnored private var waiters: [Waiter] = []
    var isBusy: Bool { current != nil }
    var waitingOwners: [String] { waiters.map(\.owner) }

    func tryAcquire(owner: String) -> Lease? {
        guard current == nil, waiters.isEmpty else { return nil }
        let lease = Lease(id: UUID(), owner: owner)
        current = lease
        return lease
    }

    func acquire(owner: String, priority: Priority) async throws -> Lease {
        try Task.checkCancellation()
        if let lease = tryAcquire(owner: owner) { return lease }
        let id = UUID()
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, owner: owner, priority: priority, continuation: continuation))
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        if Task.isCancelled {
            release(lease)
            throw CancellationError()
        }
        return lease
    }

    func release(_ lease: Lease) {
        guard current?.id == lease.id else { return }
        current = nil
        guard let priority = waiters.map(\.priority.rawValue).min(),
              let index = waiters.firstIndex(where: { $0.priority.rawValue == priority }) else { return }
        let next = waiters.remove(at: index)
        let lease = Lease(id: UUID(), owner: next.owner)
        current = lease
        next.continuation.resume(returning: lease)
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
