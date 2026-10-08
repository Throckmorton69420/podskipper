import Foundation

private final class Probe: @unchecked Sendable {
	private let lock = NSLock()
	private var active = 0
	private(set) var peak = 0
	private(set) var starts = 0
	func start() { lock.lock(); defer { lock.unlock() }; active += 1; starts += 1; peak = max(peak, active) }
	func finish() { lock.lock(); defer { lock.unlock() }; active -= 1 }
	var started: Bool { lock.lock(); defer { lock.unlock() }; return starts > 0 }
}

@main
private struct UpdaterRuntimePolicyTests {
	static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
		if !condition() { fatalError(message) }
	}
	static func main() async {
		for legacy in 0...4 {
			let name = "Feather.Runtime.Tests." + UUID().uuidString
			let defaults = UserDefaults(suiteName: name)!
			defer { defaults.removePersistentDomain(forName: name) }
			defaults.set(legacy, forKey: "Feather.GlobalUpdater.CleanupMode")
			defaults.set(true, forKey: "Feather.GlobalUpdater.AutoFingerprint")
			defaults.set(true, forKey: "Feather.GlobalUpdater.AutoDownload")
			defaults.set(3, forKey: "Feather.GlobalUpdater.MaxConcurrentDownloads")
			defaults.set(false, forKey: "Feather.GlobalUpdater.StrictSequentialPipeline")
			UpdaterRuntimePolicy.migrate(defaults)
			require(!defaults.bool(forKey: "Feather.GlobalUpdater.AutoFingerprint"), "Legacy automatic full scans must be retired")
			require(defaults.integer(forKey: "Feather.GlobalUpdater.MaxConcurrentDownloads") == 1, "Legacy parallel downloads must migrate")
			require(defaults.bool(forKey: "Feather.GlobalUpdater.StrictSequentialPipeline"), "Migration must serialize updates")
			require(defaults.bool(forKey: "Feather.GlobalUpdater.AutoDownload"), "Preserve the user's download choice")
			require(defaults.integer(forKey: UpdaterRuntimePolicy.cleanupKey) == (legacy == 0 ? 0 : 1), "Never migrate into automatic deletion")
			defaults.set(2, forKey: UpdaterRuntimePolicy.cleanupKey)
			UpdaterRuntimePolicy.migrate(defaults)
			require(defaults.integer(forKey: UpdaterRuntimePolicy.cleanupKey) == 2, "Migration must be idempotent")
		}
		let lane = UpdaterSerialWorkLane()
		let probe = Probe()
		await withTaskGroup(of: Void.self) { group in
			for _ in 0..<40 {
				group.addTask {
					let result: Bool? = await lane.run {
						probe.start(); defer { probe.finish() }
						Thread.sleep(forTimeInterval: 0.003)
						return true
					}
					require(result == true, "Queued work must complete")
				}
			}
		}
		require(probe.peak == 1 && probe.starts == 40, "All fingerprint entry points must share exactly one worker")
		let cancellationProbe = Probe()
		let running = Task {
			await lane.run { () -> Bool? in
				cancellationProbe.start(); defer { cancellationProbe.finish() }
				while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.001) }
				return nil
			}
		}
		while !cancellationProbe.started { try? await Task.sleep(nanoseconds: 1_000_000) }
		let queuedProbe = Probe()
		let queued = Task {
			await lane.run { queuedProbe.start(); queuedProbe.finish(); return true }
		}
		try? await Task.sleep(nanoseconds: 10_000_000)
		queued.cancel()
		running.cancel()
		let runningResult = await running.value
		let queuedResult = await queued.value
		require(runningResult == nil && queuedResult == nil, "Cancellation must propagate to running and queued jobs")
		require(queuedProbe.starts == 0, "Canceled waiting work must never run")
		let recovered: Bool? = await lane.run { true }
		require(recovered == true, "Cancellation must not poison the next job")
		let throttle = UpdaterProgressThrottle()
		var publications = 0
		for index in 0..<4000 {
			if throttle.shouldPublish("large-ipa", now: Double(index) / 1000) { publications += 1 }
		}
		require(publications <= 17, "Progress must coalesce before reaching the main queue")
		require(throttle.shouldPublish("large-ipa", now: 4, complete: true), "The final progress event must never be dropped")
		UpdaterActivityState.shared.setActive(false)
		require(!UpdaterActivityState.shared.isActive, "Background work must observe inactivity")
		UpdaterActivityState.shared.setActive(true)
		require(UpdaterActivityState.shared.isActive, "Foreground state must recover")
		print("Runtime regression tests passed: migration, serialization, cancellation, progress throttling, foreground state")
	}
}
