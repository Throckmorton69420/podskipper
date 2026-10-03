import XCTest
@testable import PodSkipper

@MainActor
final class HeavyWorkCoordinatorTests: XCTestCase {
    func testExclusiveLeaseAndStaleRelease() throws {
        let coordinator = HeavyWorkCoordinator()
        let first = try XCTUnwrap(coordinator.tryAcquire(owner: "first"))
        XCTAssertNil(coordinator.tryAcquire(owner: "second"))
        coordinator.release(first)
        let second = try XCTUnwrap(coordinator.tryAcquire(owner: "second"))
        coordinator.release(first)
        XCTAssertEqual(coordinator.current, second)
        coordinator.release(second)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testUserWorkPrecedesMaintenanceAndEqualPriorityIsFIFO() async throws {
        let coordinator = HeavyWorkCoordinator()
        let held = try XCTUnwrap(coordinator.tryAcquire(owner: "held"))
        let maintenance = Task { try await coordinator.acquire(owner: "maintenance", priority: .maintenance) }
        try await waitUntil { coordinator.waitingOwners == ["maintenance"] }
        let first = Task { try await coordinator.acquire(owner: "user1", priority: .user) }
        try await waitUntil { coordinator.waitingOwners.count == 2 }
        let second = Task { try await coordinator.acquire(owner: "user2", priority: .user) }
        try await waitUntil { coordinator.waitingOwners.count == 3 }
        coordinator.release(held)
        let a = try await first.value
        XCTAssertEqual(coordinator.current?.owner, "user1")
        coordinator.release(a)
        let b = try await second.value
        XCTAssertEqual(coordinator.current?.owner, "user2")
        coordinator.release(b)
        let c = try await maintenance.value
        XCTAssertEqual(coordinator.current?.owner, "maintenance")
        coordinator.release(c)
        XCTAssertFalse(coordinator.isBusy)
    }

    func testCancelledWaiterDoesNotClaimOrReleaseSomeoneElsesLease() async throws {
        let coordinator = HeavyWorkCoordinator()
        let held = try XCTUnwrap(coordinator.tryAcquire(owner: "held"))
        let waiting = Task { try await coordinator.acquire(owner: "cancelled", priority: .user) }
        try await waitUntil { coordinator.waitingOwners.count == 1 }
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled work acquired a lease") }
        catch is CancellationError {}
        XCTAssertEqual(coordinator.current, held)
        XCTAssertTrue(coordinator.waitingOwners.isEmpty)
        coordinator.release(held)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(condition())
    }
}
