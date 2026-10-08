import Foundation

enum OlderDownloadPolicy: Int, CaseIterable, Identifiable {
	case keep = 0
	case ask = 1
	case remove = 2
	var id: Int { rawValue }
	var title: String {
		switch self {
		case .keep: return "Keep"
		case .ask: return "Ask"
		case .remove: return "Remove"
		}
	}
}

enum UpdaterRuntimePolicy {
	static let migrationKey = "Feather.GlobalUpdater.RuntimePolicyVersion"
	static let cleanupKey = "Feather.GlobalUpdater.OlderDownloadPolicy"

	// Once only. Keep the user's automation choices, but retire the expensive
	// scan/concurrency controls and never translate an old destructive policy
	// into a newly enabled destructive policy without their explicit selection.
	static func migrate(_ defaults: UserDefaults) {
		guard defaults.integer(forKey: migrationKey) < 8 else { return }
		defaults.set(false, forKey: "Feather.GlobalUpdater.AutoFingerprint")
		defaults.set(1, forKey: "Feather.GlobalUpdater.FingerprintBatchSize")
		defaults.set(1, forKey: "Feather.GlobalUpdater.MaxConcurrentDownloads")
		defaults.set(true, forKey: "Feather.GlobalUpdater.StrictSequentialPipeline")
		if defaults.object(forKey: cleanupKey) == nil {
			let oldMode = defaults.integer(forKey: "Feather.GlobalUpdater.CleanupMode")
			defaults.set(oldMode == 0 ? 0 : 1, forKey: cleanupKey)
		}
		if !defaults.bool(forKey: "Feather.GlobalUpdater.FingerprintingEnabled"),
			defaults.object(forKey: "Feather.GlobalUpdater.FingerprintingEnabled") != nil {
			defaults.set(false, forKey: "Feather.GlobalUpdater.AutoSign")
			defaults.set(false, forKey: "Feather.GlobalUpdater.AutoInstall")
		}
		if !defaults.bool(forKey: "Feather.GlobalUpdater.AutoSign") {
			defaults.set(false, forKey: "Feather.GlobalUpdater.AutoInstall")
		}
		defaults.set(8, forKey: migrationKey)
	}
}

// All full-library and candidate fingerprint work uses the same serial lane.
// A canceled queued request cannot cancel its predecessor or run its own work.
// Canceling a running request is propagated to its detached worker.
actor UpdaterSerialWorkLane {
	private var tail: Task<Void, Never>?
	private var lastTicket: UUID?

	func run<T: Sendable>(_ work: @escaping @Sendable () -> T?) async -> T? {
		guard !Task.isCancelled else { return nil }
		let predecessor = tail
		let ticket = UUID()
		let worker = Task.detached(priority: .utility) {
			await predecessor?.value
			guard !Task.isCancelled else { return nil as T? }
			return work()
		}
		tail = Task { _ = await worker.value }
		lastTicket = ticket
		let result = await withTaskCancellationHandler {
			await worker.value
		} onCancel: {
			worker.cancel()
		}
		if lastTicket == ticket { tail = nil; lastTicket = nil }
		return Task.isCancelled ? nil : result
	}
}

final class UpdaterActivityState: @unchecked Sendable {
	static let shared = UpdaterActivityState()
	private let lock = NSLock()
	private var active = true
	var isActive: Bool {
		lock.lock(); defer { lock.unlock() }
		return active
	}
	func setActive(_ value: Bool) {
		lock.lock(); defer { lock.unlock() }
		active = value
	}
}

final class UpdaterProgressThrottle: @unchecked Sendable {
	private let lock = NSLock()
	private var lastPublication: [String: TimeInterval] = [:]
	func shouldPublish(_ id: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime, complete: Bool = false) -> Bool {
		lock.lock(); defer { lock.unlock() }
		if complete { lastPublication.removeValue(forKey: id); return true }
		if let last = lastPublication[id], now - last < 0.25 { return false }
		lastPublication[id] = now
		return true
	}
	func remove(_ id: String) {
		lock.lock(); defer { lock.unlock() }
		lastPublication.removeValue(forKey: id)
	}
}
