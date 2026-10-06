//
//  UpdateManager.swift
//  Feather
//
//  Global Updater v3:
//  - scans title + subtitle + description + localized description + release notes
//  - resolves the original source entry for installed apps
//  - inspects local IPA bundle filenames when source metadata is weak
//  - uses weighted variant evidence instead of bundle-ID/title-only matching
//  - refuses unsafe cross-variant automatic updates
//

import AltSourceKit
import CoreData
import CryptoKit
import Foundation
import NimbleJSON
import Zsign

enum UpdateVariantMatch: String, Equatable {
	case metadataEvidence = "Variant metadata match"
	case exactSourceName = "Exact source entry"
	case stockFamily = "Stock app from original source"
	case sameOriginalSource = "Same original source"
	case manual = "Manual choice"
}

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceName: String
	let sourceChanged: Bool
	let matchKind: UpdateVariantMatch
	let variantID: String?
	let variantLabel: String?
	let variantEvidence: String?
	let subtitle: String?
	let summaryDescription: String?
	let releaseNotes: String?
	let developer: String?
	let versionDate: Date?
	let sourceQualityScore: Int
	let sourceQualitySummary: String
	let sourceProvenance: SourceAppProvenance
}

enum BinaryValidationDisposition: String, Codable, Sendable {
	case verified
	case review
	case rejected
}

struct BinaryValidationResult: Equatable, Sendable {
	let disposition: BinaryValidationDisposition
	let score: Int
	let summary: String
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var ambiguousUpdates: [String: [AppUpdate]] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	@Published private(set) var failedSourceCount = 0
	@Published private(set) var checkedSourceCount = 0
	@Published private(set) var isFingerprinting = false
	@Published private(set) var fingerprintCompleted = 0
	@Published private(set) var fingerprintTotal = 0
	@Published private(set) var fingerprintCurrentApp: String?
	@Published private(set) var fingerprintLastRunDate: Date?
	
	private var _fingerprintTask: Task<Void, Never>?
	private let _dataService = NBFetchService()
	private let _variantIDPrefix = "Feather.GlobalUpdater.VariantID."
	private let _variantLabelPrefix = "Feather.GlobalUpdater.VariantLabel."
	private let _variantEvidencePrefix = "Feather.GlobalUpdater.VariantEvidence."
	private let _fingerprintPrefix = "Feather.GlobalUpdater.BinaryFingerprint."
	private let _fingerprintDatePrefix = "Feather.GlobalUpdater.BinaryFingerprintDate."
	private let _fingerprintLastRunKey = "Feather.GlobalUpdater.BinaryFingerprintLastRun"
	private let _fingerprintValidationPrefix = "Feather.GlobalUpdater.BinaryValidation."
	private let _fingerprintValidationDetailPrefix = "Feather.GlobalUpdater.BinaryValidationDetail."
	private let _dismissedUpdatePrefix = "Feather.GlobalUpdater.DismissedUpdate."
	private let _dismissedReviewPrefix = "Feather.GlobalUpdater.DismissedReview."
	private let _sourceReputationPrefix = "Feather.GlobalUpdater.SourceReputation."
	@Published private(set) var dismissalRevision = 0
	
	private init() {
		fingerprintLastRunDate = UserDefaults.standard.object(forKey: _fingerprintLastRunKey) as? Date
	}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid, let update = updates[uuid] else { return nil }
		return _isUpdateDismissed(update) ? nil : update
	}
	
	func ambiguousCandidates(for app: AppInfoPresentable) -> [AppUpdate] {
		guard let uuid = app.uuid, let candidates = ambiguousUpdates[uuid] else { return [] }
		return _isReviewDismissed(localUUID: uuid, candidates: candidates) ? [] : candidates
	}
	
	func variantID(for app: AppInfoPresentable) -> String? {
		guard let uuid = app.uuid else { return nil }
		return UserDefaults.standard.string(forKey: _variantIDPrefix + uuid)
	}
	
	func variantDisplay(for app: AppInfoPresentable) -> String? {
		guard let uuid = app.uuid else { return nil }
		return UserDefaults.standard.string(forKey: _variantLabelPrefix + uuid)
	}
	
	func variantEvidenceSummary(for app: AppInfoPresentable) -> String? {
		guard let uuid = app.uuid else { return nil }
		return UserDefaults.standard.string(forKey: _variantEvidencePrefix + uuid)
	}
	
	func binaryValidationDisplay(for app: AppInfoPresentable) -> String? {
		guard let uuid = app.uuid else { return nil }
		guard let raw = UserDefaults.standard.string(forKey: _fingerprintValidationPrefix + uuid) else {
			return nil
		}
		
		switch raw {
		case BinaryValidationDisposition.verified.rawValue:
			return "Binary fingerprint verified"
		case BinaryValidationDisposition.review.rawValue:
			return "Binary fingerprint needs review"
		case BinaryValidationDisposition.rejected.rawValue:
			return "Binary fingerprint mismatch"
		default:
			return nil
		}
	}
	
	func binaryValidationDetail(for app: AppInfoPresentable) -> String? {
		guard let uuid = app.uuid else { return nil }
		return UserDefaults.standard.string(forKey: _fingerprintValidationDetailPrefix + uuid)
	}
	
	func fingerprintDate(for app: AppInfoPresentable) -> Date? {
		guard let job = _fingerprintJobInput(for: app) else { return nil }
		return UserDefaults.standard.object(
			forKey: _fingerprintDateKey(
				uuid: job.uuid,
				version: job.version,
				contentStamp: job.contentStamp
			)
		) as? Date
	}
	
	func needsFingerprint(_ app: AppInfoPresentable) -> Bool {
		guard let job = _fingerprintJobInput(for: app) else { return false }
		return _cachedFingerprint(for: job) == nil
	}
	
	var visibleUpdates: [AppUpdate] {
		updates.values.filter { !_isUpdateDismissed($0) }
	}
	
	var visibleUpdateCount: Int {
		visibleUpdates.count
	}
	
	var visibleReviewCount: Int {
		ambiguousUpdates.reduce(into: 0) { count, entry in
			if !_isReviewDismissed(localUUID: entry.key, candidates: entry.value) {
				count += 1
			}
		}
	}
	
	func dismissUpdate(for app: AppInfoPresentable) {
		guard let uuid = app.uuid, let update = updates[uuid] else { return }
		UserDefaults.standard.set(update.id, forKey: _dismissedUpdatePrefix + uuid)
		dismissalRevision += 1
	}
	
	func dismissReview(for app: AppInfoPresentable) {
		guard let uuid = app.uuid, let candidates = ambiguousUpdates[uuid], !candidates.isEmpty else { return }
		UserDefaults.standard.set(_reviewToken(candidates), forKey: _dismissedReviewPrefix + uuid)
		dismissalRevision += 1
	}
	
	func dismissAllUpdates() {
		for (uuid, update) in updates {
			UserDefaults.standard.set(update.id, forKey: _dismissedUpdatePrefix + uuid)
		}
		dismissalRevision += 1
	}
	
	func dismissAllReviews() {
		for (uuid, candidates) in ambiguousUpdates where !candidates.isEmpty {
			UserDefaults.standard.set(_reviewToken(candidates), forKey: _dismissedReviewPrefix + uuid)
		}
		dismissalRevision += 1
	}
	
	func resolveUpdate(localUUID: String) {
		updates.removeValue(forKey: localUUID)
		ambiguousUpdates.removeValue(forKey: localUUID)
		UserDefaults.standard.removeObject(forKey: _dismissedUpdatePrefix + localUUID)
		UserDefaults.standard.removeObject(forKey: _dismissedReviewPrefix + localUUID)
		dismissalRevision += 1
	}
	
	func rememberVariant(for appUUID: String, from update: AppUpdate) {
		guard let variantID = update.variantID else { return }
		UserDefaults.standard.set(variantID, forKey: _variantIDPrefix + appUUID)
		if let label = update.variantLabel {
			UserDefaults.standard.set(label, forKey: _variantLabelPrefix + appUUID)
		}
		if let evidence = update.variantEvidence {
			UserDefaults.standard.set(evidence, forKey: _variantEvidencePrefix + appUUID)
		}
	}
	
	func copyFingerprintMetadata(from sourceUUID: String?, to destinationUUID: String) {
		guard let sourceUUID else { return }
		
		let mappings = [
			(_variantIDPrefix, _variantIDPrefix),
			(_variantLabelPrefix, _variantLabelPrefix),
			(_variantEvidencePrefix, _variantEvidencePrefix),
			(_fingerprintValidationPrefix, _fingerprintValidationPrefix),
			(_fingerprintValidationDetailPrefix, _fingerprintValidationDetailPrefix)
		]
		
		for (sourcePrefix, destinationPrefix) in mappings {
			if let value = UserDefaults.standard.object(forKey: sourcePrefix + sourceUUID) {
				UserDefaults.standard.set(value, forKey: destinationPrefix + destinationUUID)
			}
		}
	}
	
	func updateCandidate(for sourceVersionID: String) -> AppUpdate? {
		for update in updates.values where update.sourceProvenance.sourceVersionID == sourceVersionID {
			return update
		}
		for candidates in ambiguousUpdates.values {
			if let match = candidates.first(where: { $0.sourceProvenance.sourceVersionID == sourceVersionID }) {
				return match
			}
		}
		return nil
	}
	
	func updateCandidate(forImportedUUID appUUID: String) -> AppUpdate? {
		guard let metadata = Storage.shared.sourceMetadata(for: appUUID) else {
			return nil
		}
		
		if
			let sourceVersionID = metadata.sourceVersionID,
			let exact = updateCandidate(for: sourceVersionID)
		{
			return exact
		}
		
		let allCandidates = Array(updates.values) + ambiguousUpdates.values.flatMap { $0 }
		
		if let downloadURL = metadata.sourceAppDownloadURL {
			if let byURL = allCandidates.first(where: {
				$0.downloadURL.absoluteString == downloadURL.absoluteString
			}) {
				return byURL
			}
		}
		
		if
			let appIdentifier = metadata.sourceAppIdentifier,
			let version = metadata.sourceAppVersion
		{
			return allCandidates.first {
				$0.bundleIdentifier.caseInsensitiveCompare(appIdentifier) == .orderedSame &&
				$0.remoteVersion == version
			}
		}
		
		return nil
	}
	

	private func _fingerprintCacheKeyV7(
		uuid: String,
		version: String?,
		contentStamp: String
	) -> String {
		let versionPart = _normalizedName(version ?? "unknown")
		return _fingerprintPrefix + uuid + "." + versionPart + "." + contentStamp + ".v7"
	}
	
	private func _fingerprintDateKey(
		uuid: String,
		version: String?,
		contentStamp: String
	) -> String {
		let versionPart = _normalizedName(version ?? "unknown")
		return _fingerprintDatePrefix + uuid + "." + versionPart + "." + contentStamp + ".v7"
	}
	
	private func _cheapContentStamp(for appURL: URL) -> String {
		func stat(_ url: URL) -> String {
			guard
				let values = try? url.resourceValues(
					forKeys: [.contentModificationDateKey, .fileSizeKey]
				)
			else {
				return "0-0"
			}
			
			let modified = Int64(
				(values.contentModificationDate?.timeIntervalSince1970 ?? 0).rounded()
			)
			let size = Int64(values.fileSize ?? 0)
			return "\(modified)-\(size)"
		}
		
		let executableURL = Bundle(url: appURL)?.executableURL
		let infoURL = appURL.appendingPathComponent("Info.plist")
		let frameworksURL = appURL.appendingPathComponent("Frameworks", isDirectory: true)
		
		let material = [
			stat(appURL),
			executableURL.map(stat) ?? "0-0",
			stat(infoURL),
			stat(frameworksURL)
		].joined(separator: "|")
		
		let digest = SHA256.hash(data: Data(material.utf8))
		return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
	}
	
	private func _fingerprintJobInput(for app: AppInfoPresentable) -> FingerprintJobInput? {
		guard
			let uuid = app.uuid,
			let appURL = Storage.shared.getAppDirectory(for: app)
		else {
			return nil
		}
		
		return FingerprintJobInput(
			uuid: uuid,
			appURL: appURL,
			version: app.version,
			name: app.name ?? "Unknown",
			identifier: app.identifier,
			contentStamp: _cheapContentStamp(for: appURL)
		)
	}
	
	private func _cachedFingerprint(for job: FingerprintJobInput) -> BinaryFingerprint? {
		let key = _fingerprintCacheKeyV7(
			uuid: job.uuid,
			version: job.version,
			contentStamp: job.contentStamp
		)
		guard
			let data = UserDefaults.standard.data(forKey: key),
			let fingerprint = try? JSONDecoder().decode(BinaryFingerprint.self, from: data),
			fingerprint.schemaVersion == FingerprintWorker.schemaVersion
		else {
			return nil
		}
		return fingerprint
	}
	
	private func _storeFingerprint(_ fingerprint: BinaryFingerprint, for job: FingerprintJobInput) {
		let key = _fingerprintCacheKeyV7(
			uuid: job.uuid,
			version: job.version,
			contentStamp: job.contentStamp
		)
		if let data = try? JSONEncoder().encode(fingerprint) {
			UserDefaults.standard.set(data, forKey: key)
			UserDefaults.standard.set(
				Date(),
				forKey: _fingerprintDateKey(
					uuid: job.uuid,
					version: job.version,
					contentStamp: job.contentStamp
				)
			)
		}
		
		if fingerprint.variantTokens.count == 1, let canonical = fingerprint.variantTokens.first {
			UserDefaults.standard.set(canonical, forKey: _variantIDPrefix + job.uuid)
			UserDefaults.standard.set(_displayName(forCanonical: canonical), forKey: _variantLabelPrefix + job.uuid)
			UserDefaults.standard.set("binary fingerprint", forKey: _variantEvidencePrefix + job.uuid)
		}
	}
	
	private func _backgroundFingerprint(
		for app: AppInfoPresentable,
		force: Bool = false
	) async -> BinaryFingerprint? {
		guard let job = _fingerprintJobInput(for: app) else { return nil }
		
		if !force, let cached = _cachedFingerprint(for: job) {
			return cached
		}
		
		let result = await Task.detached(priority: .utility) {
			FingerprintWorker.compute(job)
		}.value
		
		if let result {
			_storeFingerprint(result, for: job)
		}
		return result
	}
	
	func cachedFingerprintCount(for apps: [AppInfoPresentable]) -> Int {
		apps.compactMap(_fingerprintJobInput).reduce(into: 0) { count, job in
			if _cachedFingerprint(for: job) != nil {
				count += 1
			}
		}
	}
	
	func cancelFingerprinting() {
		_fingerprintTask?.cancel()
		_fingerprintTask = nil
		isFingerprinting = false
		fingerprintCurrentApp = nil
	}
	
	func startFingerprintLibrary(
		apps: [AppInfoPresentable],
		batchSize requestedBatchSize: Int = 2,
		force: Bool = false
	) {
		guard !isFingerprinting else { return }
		
		let allJobs = apps.compactMap(_fingerprintJobInput)
		guard !allJobs.isEmpty else { return }
		
		let pendingJobs = force
			? allJobs
			: allJobs.filter { _cachedFingerprint(for: $0) == nil }
		
		isFingerprinting = true
		fingerprintTotal = allJobs.count
		fingerprintCompleted = allJobs.count - pendingJobs.count
		fingerprintCurrentApp = nil
		
		guard !pendingJobs.isEmpty else {
			let completedAt = Date()
			fingerprintLastRunDate = completedAt
			UserDefaults.standard.set(completedAt, forKey: _fingerprintLastRunKey)
			isFingerprinting = false
			return
		}
		
		_fingerprintTask = Task { [weak self] in
			guard let self else { return }
			
			var index = 0
			while index < pendingJobs.count, !Task.isCancelled {
				let process = ProcessInfo.processInfo
				let lowPower = process.isLowPowerModeEnabled
				let thermal = process.thermalState
				let thermalConstrained = thermal == .serious || thermal == .critical
				let effectiveBatchSize = max(
					1,
					min(requestedBatchSize, (lowPower || thermalConstrained) ? 1 : 3)
				)
				
				if thermal == .critical {
					self.fingerprintCurrentApp = "Paused — device is thermally constrained"
					try? await Task.sleep(nanoseconds: 2_000_000_000)
					continue
				}
				
				let end = min(index + effectiveBatchSize, pendingJobs.count)
				let batch = Array(pendingJobs[index..<end])
				self.fingerprintCurrentApp = batch.map(\.name).joined(separator: ", ")
				
				let results = await withTaskGroup(
					of: (FingerprintJobInput, BinaryFingerprint?).self,
					returning: [(FingerprintJobInput, BinaryFingerprint?)].self
				) { group in
					for job in batch {
						group.addTask(priority: .utility) {
							if Task.isCancelled { return (job, nil) }
							return (job, FingerprintWorker.compute(job))
						}
					}
					
					var values: [(FingerprintJobInput, BinaryFingerprint?)] = []
					for await value in group {
						values.append(value)
					}
					return values
				}
				
				if Task.isCancelled { break }
				
				for (job, fingerprint) in results {
					if let fingerprint {
						self._storeFingerprint(fingerprint, for: job)
					}
				}
				
				index = end
				self.fingerprintCompleted = allJobs.count - pendingJobs.count + index
				
				await Task.yield()
				let pause: UInt64 = lowPower || thermalConstrained ? 650_000_000 : 120_000_000
				try? await Task.sleep(nanoseconds: pause)
			}
			
			if !Task.isCancelled {
				self.fingerprintCompleted = self.fingerprintTotal
				let completedAt = Date()
				self.fingerprintLastRunDate = completedAt
				UserDefaults.standard.set(completedAt, forKey: self._fingerprintLastRunKey)
			}
			self.fingerprintCurrentApp = nil
			self.isFingerprinting = false
			self._fingerprintTask = nil
		}
	}

	func clearFingerprintCache() {
		cancelFingerprinting()
		let defaults = UserDefaults.standard
		for key in defaults.dictionaryRepresentation().keys {
			if
				key.hasPrefix(_fingerprintPrefix) ||
				key.hasPrefix(_fingerprintDatePrefix) ||
				key == _fingerprintLastRunKey ||
				key.hasPrefix(_fingerprintValidationPrefix) ||
				key.hasPrefix(_fingerprintValidationDetailPrefix)
			{
				defaults.removeObject(forKey: key)
			}
		}
	}
	
	private func _isUpdateDismissed(_ update: AppUpdate) -> Bool {
		UserDefaults.standard.string(
			forKey: _dismissedUpdatePrefix + update.localUUID
		) == update.id
	}
	
	private func _isReviewDismissed(localUUID: String, candidates: [AppUpdate]) -> Bool {
		UserDefaults.standard.string(
			forKey: _dismissedReviewPrefix + localUUID
		) == _reviewToken(candidates)
	}
	
	private func _reviewToken(_ candidates: [AppUpdate]) -> String {
		let value = candidates.map(\.id).sorted().joined(separator: "\n")
		let digest = SHA256.hash(data: Data(value.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
	
	func validateDownloadedUpdate(
		original: AppInfoPresentable,
		downloaded: AppInfoPresentable,
		update: AppUpdate
	) async -> BinaryValidationResult {
		if
			let downloadedIdentifier = downloaded.identifier,
			downloadedIdentifier.caseInsensitiveCompare(update.bundleIdentifier) != .orderedSame
		{
			let result = BinaryValidationResult(
				disposition: .rejected,
				score: -200,
				summary:
					"Bundle ID mismatch: repository expected \(update.bundleIdentifier), " +
					"but the downloaded IPA contains \(downloadedIdentifier)."
			)
			_recordSourceValidation(update.sourceURL, disposition: result.disposition)
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
		async let originalFingerprintTask = _backgroundFingerprint(for: original)
		async let downloadedFingerprintTask = _backgroundFingerprint(for: downloaded, force: true)
		
		guard
			let originalFingerprint = await originalFingerprintTask,
			let downloadedFingerprint = await downloadedFingerprintTask
		else {
			let result = BinaryValidationResult(
				disposition: .review,
				score: 0,
				summary: "Binary fingerprint could not be completed. The IPA was kept in Library, but automatic signing/install should not continue."
			)
			_recordSourceValidation(update.sourceURL, disposition: result.disposition)
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
		let originalVariant = variantID(for: original)
		let remoteVariant = update.variantID
		
		// Explicit source/Library identities outrank broad binary string hits.
		// If both sides have a resolved variant and they disagree, stop here.
		if
			let originalVariant,
			let remoteVariant,
			originalVariant != remoteVariant
		{
			let result = BinaryValidationResult(
				disposition: .rejected,
				score: -150,
				summary:
					"Variant identity conflict: installed app is \(originalVariant), " +
					"but the update candidate is \(remoteVariant)."
			)
			_recordSourceValidation(update.sourceURL, disposition: result.disposition)
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
		let originalBinaryVariants = Set(originalFingerprint.variantTokens)
		let downloadedBinaryVariants = Set(downloadedFingerprint.variantTokens)
		
		// A single unambiguous binary marker that contradicts the semantic
		// identity is also a hard rejection. Multiple markers are treated as
		// ambiguous (for example a source legend embedded in a plist/string).
		if
			let originalVariant,
			originalBinaryVariants.count == 1,
			originalBinaryVariants.first != originalVariant
		{
			let result = BinaryValidationResult(
				disposition: .rejected,
				score: -125,
				summary:
					"Installed app metadata says \(originalVariant), but its binary fingerprint says " +
					"\(originalBinaryVariants.first ?? "unknown")."
			)
			_recordSourceValidation(update.sourceURL, disposition: result.disposition)
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
		if
			let remoteVariant,
			downloadedBinaryVariants.count == 1,
			downloadedBinaryVariants.first != remoteVariant
		{
			let result = BinaryValidationResult(
				disposition: .rejected,
				score: -125,
				summary:
					"Repository metadata says \(remoteVariant), but the downloaded IPA binary says " +
					"\(downloadedBinaryVariants.first ?? "unknown")."
			)
			_recordSourceValidation(update.sourceURL, disposition: result.disposition)
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
		let semanticVariantOverlap =
			originalVariant != nil &&
			remoteVariant != nil &&
			originalVariant == remoteVariant
		
		let binaryVariantOverlap =
			originalBinaryVariants.count == 1 &&
			downloadedBinaryVariants.count == 1 &&
			originalBinaryVariants.first == downloadedBinaryVariants.first
		
		let variantOverlap = semanticVariantOverlap || binaryVariantOverlap
		
		let componentSimilarity = _jaccard(
			Set(originalFingerprint.embeddedComponents),
			Set(downloadedFingerprint.embeddedComponents)
		)
		let loadSimilarity = _jaccard(
			Set(originalFingerprint.nonSystemLoadPaths),
			Set(downloadedFingerprint.nonSystemLoadPaths)
		)
		let bundleSimilarity = _jaccard(
			Set(originalFingerprint.embeddedBundleIDs),
			Set(downloadedFingerprint.embeddedBundleIDs)
		)
		let markerSimilarity = _jaccard(
			Set(originalFingerprint.markerTokens),
			Set(downloadedFingerprint.markerTokens)
		)
		let distinctiveInjectionOverlap = Set(originalFingerprint.distinctiveInjectionIDs)
			.intersection(downloadedFingerprint.distinctiveInjectionIDs)
		
		let exactHashMatches = Set(originalFingerprint.componentHashes.keys)
			.intersection(downloadedFingerprint.componentHashes.keys)
			.reduce(into: 0) { count, key in
				if originalFingerprint.componentHashes[key] == downloadedFingerprint.componentHashes[key] {
					count += 1
				}
			}
		
		let normalizedHashMatches = Set(originalFingerprint.normalizedComponentHashes.keys)
			.intersection(downloadedFingerprint.normalizedComponentHashes.keys)
			.reduce(into: 0) { count, key in
				if originalFingerprint.normalizedComponentHashes[key] == downloadedFingerprint.normalizedComponentHashes[key] {
					count += 1
				}
			}
		
		let structuralMatch =
			!originalFingerprint.structuralHash.isEmpty &&
			originalFingerprint.structuralHash == downloadedFingerprint.structuralHash
		
		var score = 0
		if variantOverlap { score += 55 }
		if structuralMatch { score += 35 }
		score += Int(componentSimilarity * 30.0)
		score += Int(loadSimilarity * 25.0)
		score += Int(bundleSimilarity * 15.0)
		score += Int(markerSimilarity * 15.0)
		score += min(distinctiveInjectionOverlap.count * 25, 50)
		score += min(exactHashMatches * 10, 20)
		score += min(normalizedHashMatches * 15, 30)
		
		let family = originalFingerprint.family ?? downloadedFingerprint.family
		let highCollision = family.map { _highCollisionFamilies.contains($0) } ?? false
		let metadataVersionMismatch: Bool = {
			guard let downloadedVersion = downloaded.version else { return false }
			guard
				_compareVersions(downloadedVersion, update.remoteVersion) != .orderedSame
			else {
				return false
			}
			return true
		}()
		
		let substantialStructuralAgreement =
			componentSimilarity >= 0.35 ||
			loadSimilarity >= 0.35 ||
			bundleSimilarity >= 0.50 ||
			!distinctiveInjectionOverlap.isEmpty ||
			structuralMatch ||
			exactHashMatches > 0 ||
			normalizedHashMatches > 0
		
		let severeStructuralDisagreement =
			!originalFingerprint.embeddedComponents.isEmpty &&
			!downloadedFingerprint.embeddedComponents.isEmpty &&
			componentSimilarity < 0.08 &&
			loadSimilarity < 0.08 &&
			!variantOverlap
		
		var disposition: BinaryValidationDisposition
		if severeStructuralDisagreement {
			disposition = .rejected
		} else if highCollision {
			// For families where many mods deliberately share the official bundle
			// ID, generic app/framework similarity is never sufficient by itself.
			// Require either the same extracted variant identity or at least one
			// distinctive injected dylib/framework identity on both sides.
			let identityAgreement =
				variantOverlap ||
				!distinctiveInjectionOverlap.isEmpty
			disposition =
				(score >= 60 && identityAgreement && substantialStructuralAgreement)
				? .verified
				: .review
		} else {
			disposition = score >= 40 ? .verified : .review
		}
		
		// A repo pointing at an IPA whose actual Info.plist version does not
		// match the advertised version is suspicious enough to stop automation,
		// even if its tweak fingerprint otherwise looks plausible.
		if metadataVersionMismatch, disposition == .verified {
			disposition = .review
		}
		
		var summaryParts = [
			"score \(score)",
			"components \(Int(componentSimilarity * 100))%",
			"load paths \(Int(loadSimilarity * 100))%",
			"bundle IDs \(Int(bundleSimilarity * 100))%",
			"markers \(Int(markerSimilarity * 100))%",
			"distinctive injections \(distinctiveInjectionOverlap.sorted().joined(separator: ","))",
			"exact component hashes \(exactHashMatches)",
			"signature-normalized hashes \(normalizedHashMatches)",
			structuralMatch ? "structural hash match" : "structural hash differs"
		]
		
		if metadataVersionMismatch {
			summaryParts.append(
				"advertised version \(update.remoteVersion) != IPA version \(downloaded.version ?? "unknown")"
			)
		}
		
		let result = BinaryValidationResult(
			disposition: disposition,
			score: score,
			summary: summaryParts.joined(separator: " • ")
		)
		_recordSourceValidation(update.sourceURL, disposition: result.disposition)
		_storeBinaryValidation(result, for: downloaded)
		
		if disposition == .verified, let downloadedUUID = downloaded.uuid {
			if let variant = update.variantID {
				UserDefaults.standard.set(variant, forKey: _variantIDPrefix + downloadedUUID)
			}
			if let label = update.variantLabel {
				UserDefaults.standard.set(label, forKey: _variantLabelPrefix + downloadedUUID)
			}
			UserDefaults.standard.set(
				"binary fingerprint + \(update.variantEvidence ?? "source metadata")",
				forKey: _variantEvidencePrefix + downloadedUUID
			)
		}
		
		return result
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable]
	) async {
		guard !isChecking else { return }
		
		isChecking = true
		failedSourceCount = 0
		checkedSourceCount = 0
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}
		
		let repositories = await _fetchRepositories(
			from: sources,
			localApps: localApps
		)
		checkedSourceCount = repositories.count
		failedSourceCount = max(0, sources.count - repositories.count)
		
		let result = _findUpdates(repositories: repositories, localApps: localApps)
		updates = result.safe
		ambiguousUpdates = result.ambiguous
	}
	
	func sameVariant(_ lhs: AppInfoPresentable, _ rhs: AppInfoPresentable) -> Bool {
		guard
			let lhsIdentifier = _sourceIdentifier(for: lhs),
			let rhsIdentifier = _sourceIdentifier(for: rhs),
			lhsIdentifier.caseInsensitiveCompare(rhsIdentifier) == .orderedSame
		else {
			return false
		}
		
		let lhsStored = variantID(for: lhs)
		let rhsStored = variantID(for: rhs)
		
		if let lhsStored, let rhsStored {
			return lhsStored == rhsStored
		}
		
		let lhsName = _sourceName(for: lhs)
		let rhsName = _sourceName(for: rhs)
		let lhsFamily = _family(from: [lhsName, lhs.name ?? ""])
		let rhsFamily = _family(from: [rhsName, rhs.name ?? ""])
		
		// Do not use a generic TikTok/YouTube/etc. name as proof that two
		// imported IPAs are the same mod. v3 only cleans these up automatically
		// after it has persisted an actual variant fingerprint.
		if
			let lhsFamily,
			let rhsFamily,
			lhsFamily == rhsFamily,
			_highCollisionFamilies.contains(lhsFamily)
		{
			return false
		}
		
		return _normalizedName(lhsName) == _normalizedName(rhsName)
	}
	
	private func _fetchRepositories(
		from sources: [AltSource],
		localApps: [AppInfoPresentable],
		batchSize: Int = 8
	) async -> [(AltSource, ASRepository)] {
		var repositories: [(AltSource, ASRepository)] = []
		
		let originalSources = Set(
			localApps.compactMap { app in
				Storage.shared.sourceMetadata(for: app)?.sourceRepositoryURL
					.map(_normalizedSourceURL)
			}
		)
		
		let sourcesArray = Array(sources).sorted { lhs, rhs in
			let lhsScore = _sourceFetchPriority(lhs, originalSources: originalSources)
			let rhsScore = _sourceFetchPriority(rhs, originalSources: originalSources)
			if lhsScore != rhsScore { return lhsScore > rhsScore }
			return (lhs.name ?? "").localizedCaseInsensitiveCompare(rhs.name ?? "") == .orderedAscending
		}
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = sourcesArray[startIndex..<endIndex]
			
			let batchResults = await withTaskGroup(
				of: (AltSource, ASRepository?).self,
				returning: [(AltSource, ASRepository)].self
			) { group in
				for source in batch {
					group.addTask {
						guard let url = source.sourceURL else {
							return (source, nil)
						}
						
						return await withCheckedContinuation { continuation in
							self._dataService.fetch(from: url) { (result: RepositoryDataHandler) in
								switch result {
								case .success(let repository):
									Task { @MainActor in
										self._recordSourceFetch(source.sourceURL, success: true)
									}
									continuation.resume(returning: (source, repository))
								case .failure:
									Task { @MainActor in
										self._recordSourceFetch(source.sourceURL, success: false)
									}
									continuation.resume(returning: (source, nil))
								}
							}
						}
					}
				}
				
				var results: [(AltSource, ASRepository)] = []
				for await (source, repository) in group {
					if let repository {
						results.append((source, repository))
					}
				}
				return results
			}
			
			repositories.append(contentsOf: batchResults)
		}
		
		return repositories
	}
	
	private func _findUpdates(
		repositories: [(AltSource, ASRepository)],
		localApps: [AppInfoPresentable]
	) -> (safe: [String: AppUpdate], ambiguous: [String: [AppUpdate]]) {
		var safeUpdates: [String: AppUpdate] = [:]
		var ambiguous: [String: [AppUpdate]] = [:]
		
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(into: [String: AppSourceMetadata]()) {
			$0[$1.appUUID] = $1
		}
		
		var representativeByVariant: [String: LocalAppCandidate] = [:]
		
		for localApp in localApps {
			guard let localUUID = localApp.uuid else { continue }
			let metadata = metadataByUUID[localUUID]
			
			let sourceIdentifier = metadata?.sourceAppIdentifier ?? localApp.identifier
			guard let sourceIdentifier, !sourceIdentifier.isEmpty else { continue }
			
			let sourceName = metadata?.sourceAppName ?? localApp.name ?? ""
			let localVersion = localApp.version ?? metadata?.sourceAppVersion
			
			var candidate = LocalAppCandidate(
				appUUID: localUUID,
				app: localApp,
				identifier: sourceIdentifier,
				sourceName: sourceName,
				version: localVersion,
				versionDate: metadata?.sourceAppVersionDate,
				storedSourceURL: metadata?.sourceRepositoryURL ?? localApp.source,
				storedDownloadURL: metadata?.sourceAppDownloadURL,
				evidence: VariantEvidence()
			)
			
			candidate.evidence = _localEvidence(for: candidate, repositories: repositories)
			_rememberLocalEvidence(candidate.evidence, appUUID: localUUID)
			
			let variantKey: String
			if let canonical = candidate.evidence.primaryCanonical {
				variantKey = sourceIdentifier.lowercased() + "|variant|" + canonical
			} else if let downloadURL = candidate.storedDownloadURL {
				variantKey = sourceIdentifier.lowercased() + "|download|" + downloadURL.absoluteString
			} else {
				variantKey = [
					sourceIdentifier.lowercased(),
					"source",
					candidate.storedSourceURL.map(_normalizedSourceURL) ?? "_",
					_normalizedName(sourceName)
				].joined(separator: "|")
			}
			
			if let existing = representativeByVariant[variantKey] {
				if _isLocalCandidate(candidate, newerThan: existing) {
					representativeByVariant[variantKey] = candidate
				}
			} else {
				representativeByVariant[variantKey] = candidate
			}
		}
		
		for local in representativeByVariant.values {
			guard let localVersion = local.version, !localVersion.isEmpty else { continue }
			
			var strongMatches: [(candidate: RemoteAppCandidate, match: UpdateVariantMatch)] = []
			var weakMatches: [RemoteAppCandidate] = []
			
			for (source, repository) in repositories {
				guard let sourceURL = source.sourceURL else { continue }
				
				for remoteApp in repository.apps {
					guard
						let remoteIdentifier = remoteApp.id,
						remoteIdentifier.caseInsensitiveCompare(local.identifier) == .orderedSame
					else {
						continue
					}
					
					for remote in _remoteVersions(
						source: source,
						sourceURL: sourceURL,
						repository: repository,
						app: remoteApp
					) {
						guard _isRemoteCandidate(
							remote,
							newerThanVersion: localVersion,
							localDate: local.versionDate
						) else {
							continue
						}
						
						if let match = _matchKind(local: local, remote: remote) {
							strongMatches.append((remote, match))
						} else {
							weakMatches.append(remote)
						}
					}
				}
			}
			
			if let selected = _bestStrongMatch(strongMatches, local: local) {
				guard let update = _makeUpdate(
					local: local,
					remote: selected.candidate,
					matchKind: selected.match
				) else {
					continue
				}
				safeUpdates[local.appUUID] = update
			} else if !weakMatches.isEmpty {
				let candidates = _ambiguousCandidates(
					weakMatches,
					local: local,
					limit: 12
				)
				if !candidates.isEmpty {
					ambiguous[local.appUUID] = candidates
				}
			}
		}
		
		return (safeUpdates, ambiguous)
	}
	
	private func _matchKind(
		local: LocalAppCandidate,
		remote: RemoteAppCandidate
	) -> UpdateVariantMatch? {
		let sameOriginalSource: Bool = {
			guard let storedSourceURL = local.storedSourceURL else { return false }
			return _normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(remote.sourceURL)
		}()
		
		let localVariant = local.evidence.primaryCanonical
		let remoteVariant = remote.evidence.primaryCanonical
		
		// The central v3 rule: when both sides have a single high-confidence
		// variant identity extracted from any metadata field, it must agree.
		if let localVariant, let remoteVariant {
			return localVariant == remoteVariant ? .metadataEvidence : nil
		}
		
		// If either side has variant evidence and the other side does not, do not
		// silently downgrade to bundle-ID matching.
		if localVariant != nil || remoteVariant != nil {
			return nil
		}
		
		let family = local.evidence.family ?? remote.evidence.family
		
		if let family, _highCollisionFamilies.contains(family) {
			// Generic YouTube/TikTok/etc. is only auto-updated from its original
			// source and only when the same source entry name remains identical.
			if
				sameOriginalSource,
				_normalizedName(local.sourceName) == _normalizedName(remote.app.currentName)
			{
				return .stockFamily
			}
			return nil
		}
		
		if
			!local.sourceName.isEmpty,
			_normalizedName(local.sourceName) == _normalizedName(remote.app.currentName)
		{
			return .exactSourceName
		}
		
		if sameOriginalSource, local.sourceName.isEmpty {
			return .sameOriginalSource
		}
		
		return nil
	}
	
	private func _bestStrongMatch(
		_ matches: [(candidate: RemoteAppCandidate, match: UpdateVariantMatch)],
		local: LocalAppCandidate
	) -> (candidate: RemoteAppCandidate, match: UpdateVariantMatch)? {
		matches.max { lhs, rhs in
			if lhs.match != rhs.match {
				return _matchRank(lhs.match) < _matchRank(rhs.match)
			}
			
			if let comparison = _compareVersions(lhs.candidate.version, rhs.candidate.version) {
				if comparison != .orderedSame {
					return comparison == .orderedAscending
				}
			}
			
			if
				let lhsDate = lhs.candidate.versionDate,
				let rhsDate = rhs.candidate.versionDate,
				lhsDate != rhsDate
			{
				return lhsDate < rhsDate
			}
			
			if let storedSourceURL = local.storedSourceURL {
				let lhsOriginal =
					_normalizedSourceURL(lhs.candidate.sourceURL) ==
					_normalizedSourceURL(storedSourceURL)
				let rhsOriginal =
					_normalizedSourceURL(rhs.candidate.sourceURL) ==
					_normalizedSourceURL(storedSourceURL)
				
				if lhsOriginal != rhsOriginal {
					return !lhsOriginal && rhsOriginal
				}
			}
			
			let lhsQuality = _sourceQuality(remote: lhs.candidate, local: local).score
			let rhsQuality = _sourceQuality(remote: rhs.candidate, local: local).score
			if lhsQuality != rhsQuality {
				return lhsQuality < rhsQuality
			}
			
			return lhs.candidate.sourceURL.absoluteString.localizedCaseInsensitiveCompare(
				rhs.candidate.sourceURL.absoluteString
			) == .orderedDescending
		}
	}
	
	private func _matchRank(_ match: UpdateVariantMatch) -> Int {
		switch match {
		case .metadataEvidence: return 60
		case .exactSourceName: return 40
		case .stockFamily: return 30
		case .sameOriginalSource: return 20
		case .manual: return 10
		}
	}
	
	private func _ambiguousCandidates(
		_ candidates: [RemoteAppCandidate],
		local: LocalAppCandidate,
		limit: Int
	) -> [AppUpdate] {
		var bestByVariantAndSource: [String: RemoteAppCandidate] = [:]
		
		for candidate in candidates {
			let identity =
				candidate.evidence.primaryCanonical ??
				_normalizedName(candidate.app.currentName)
			
			let key = [
				identity,
				_normalizedSourceURL(candidate.sourceURL)
			].joined(separator: "|")
			
			if let existing = bestByVariantAndSource[key] {
				if _isRemoteCandidate(candidate, newerThan: existing) {
					bestByVariantAndSource[key] = candidate
				}
			} else {
				bestByVariantAndSource[key] = candidate
			}
		}
		
		let sorted = bestByVariantAndSource.values.sorted {
			let lhsQuality = _sourceQuality(remote: $0, local: local).score
			let rhsQuality = _sourceQuality(remote: $1, local: local).score
			if lhsQuality != rhsQuality {
				return lhsQuality > rhsQuality
			}
			
			if let comparison = _compareVersions($0.version, $1.version), comparison != .orderedSame {
				return comparison == .orderedDescending
			}
			return ($0.evidence.displayLabel ?? $0.app.currentName)
				.localizedCaseInsensitiveCompare($1.evidence.displayLabel ?? $1.app.currentName) == .orderedAscending
		}
		
		return sorted.prefix(limit).compactMap {
			_makeUpdate(local: local, remote: $0, matchKind: .manual)
		}
	}
	
	private func _makeUpdate(
		local: LocalAppCandidate,
		remote: RemoteAppCandidate,
		matchKind: UpdateVariantMatch
	) -> AppUpdate? {
		guard let provenance = SourceAppProvenance(
			sourceURL: remote.sourceURL,
			repository: remote.repository,
			app: remote.app,
			version: remote.versionObject
		) else {
			return nil
		}
		
		let changedSource: Bool
		if let storedSourceURL = local.storedSourceURL {
			changedSource =
				_normalizedSourceURL(storedSourceURL) !=
				_normalizedSourceURL(remote.sourceURL)
		} else {
			changedSource = false
		}
		
		let sourceName =
			remote.repository.name ??
			remote.source.name ??
			remote.sourceURL.host ??
			"Unknown Source"
		
		let sourceQuality = _sourceQuality(remote: remote, local: local)
		
		return AppUpdate(
			id: [
				local.appUUID,
				remote.app.currentName,
				remote.version,
				remote.sourceURL.absoluteString,
				remote.evidence.primaryCanonical ?? "generic"
			].joined(separator: "|"),
			localUUID: local.appUUID,
			localVersion: local.version,
			remoteVersion: remote.version,
			appName: remote.app.currentName,
			bundleIdentifier: local.identifier,
			downloadURL: remote.downloadURL,
			sourceURL: remote.sourceURL,
			sourceName: sourceName,
			sourceChanged: changedSource,
			matchKind: matchKind,
			variantID: remote.evidence.primaryCanonical,
			variantLabel: remote.evidence.displayLabel,
			variantEvidence: remote.evidence.evidenceSummary,
			subtitle: remote.app.subtitle,
			summaryDescription: remote.app.localizedDescription ?? remote.app.description,
			releaseNotes: remote.versionObject?.localizedDescription ?? remote.app.versionDescription,
			developer: remote.app.developer,
			versionDate: remote.versionDate,
			sourceQualityScore: sourceQuality.score,
			sourceQualitySummary: sourceQuality.summary,
			sourceProvenance: provenance
		)
	}
	
	private func _remoteVersions(
		source: AltSource,
		sourceURL: URL,
		repository: ASRepository,
		app: ASRepository.App
	) -> [RemoteAppCandidate] {
		var candidates: [RemoteAppCandidate] = []
		
		if let versions = app.versions, !versions.isEmpty {
			for version in versions {
				guard !version.version.isEmpty, let downloadURL = version.downloadURL else { continue }
				let evidence = _variantEvidence(
					for: app,
					version: version,
					downloadURL: downloadURL
				)
				
				candidates.append(
					RemoteAppCandidate(
						source: source,
						sourceURL: sourceURL,
						repository: repository,
						app: app,
						versionObject: version,
						version: version.version,
						versionDate: version.date?.date,
						downloadURL: downloadURL,
						evidence: evidence
					)
				)
			}
		} else if
			let version = app.version,
			!version.isEmpty,
			let downloadURL = app.downloadURL
		{
			let evidence = _variantEvidence(
				for: app,
				version: nil,
				downloadURL: downloadURL
			)
			
			candidates.append(
				RemoteAppCandidate(
					source: source,
					sourceURL: sourceURL,
					repository: repository,
					app: app,
					versionObject: nil,
					version: version,
					versionDate: app.currentDate?.date,
					downloadURL: downloadURL,
					evidence: evidence
				)
			)
		}
		
		return candidates
	}
	
	// MARK: - Variant evidence
	
	private var _highCollisionFamilies: Set<String> {
		[
			"youtube", "youtubemusic", "tiktok", "instagram", "spotify",
			"reddit", "twitter", "discord", "twitch", "facebook",
			"messenger", "snapchat"
		]
	}
	
	private func _localEvidence(
		for local: LocalAppCandidate,
		repositories: [(AltSource, ASRepository)]
	) -> VariantEvidence {
		if
			let resolved = _resolveOriginalSourceEntry(for: local, repositories: repositories)
		{
			var evidence = _variantEvidence(
				for: resolved.app,
				version: resolved.version,
				downloadURL: local.storedDownloadURL ?? resolved.app.currentDownloadUrl
			)
			
			// Automatic source checks remain metadata-only. Heavy filesystem and
			// Mach-O inspection is performed only by the explicit batched fingerprint
			// scanner (or when validating a newly downloaded IPA).
			if
				evidence.primaryCanonical == nil,
				let storedVariant = variantID(for: local.app)
			{
				evidence.add(
					canonical: storedVariant,
					display: variantDisplay(for: local.app) ?? _displayName(forCanonical: storedVariant),
					score: 130,
					source: "cached binary fingerprint"
				)
			}
			return evidence
		}
		
		var evidence = VariantEvidence()
		let texts = [local.sourceName, local.app.name ?? ""]
		evidence.family = _family(from: texts)
		_scanVariantText(local.sourceName, score: 100, source: "stored source title", into: &evidence)
		_scanVariantText(local.app.name ?? "", score: 90, source: "IPA display name", into: &evidence)
		
		if
			evidence.primaryCanonical == nil,
			let storedVariant = variantID(for: local.app)
		{
			evidence.add(
				canonical: storedVariant,
				display: variantDisplay(for: local.app) ?? _displayName(forCanonical: storedVariant),
				score: 130,
				source: "cached binary fingerprint"
			)
		}
		return evidence
	}
	
	private func _resolveOriginalSourceEntry(
		for local: LocalAppCandidate,
		repositories: [(AltSource, ASRepository)]
	) -> (app: ASRepository.App, version: ASRepository.App.Version?)? {
		guard let storedSourceURL = local.storedSourceURL else { return nil }
		
		guard let repository = repositories.first(where: {
			guard let url = $0.0.sourceURL else { return false }
			return _normalizedSourceURL(url) == _normalizedSourceURL(storedSourceURL)
		})?.1 else {
			return nil
		}
		
		let apps = repository.apps.filter {
			guard let id = $0.id else { return false }
			return id.caseInsensitiveCompare(local.identifier) == .orderedSame
		}
		
		guard !apps.isEmpty else { return nil }
		
		if let storedDownloadURL = local.storedDownloadURL {
			for app in apps {
				if app.currentDownloadUrl == storedDownloadURL {
					return (app, app.currentAppVersion)
				}
				
				if let version = app.versions?.first(where: { $0.downloadURL == storedDownloadURL }) {
					return (app, version)
				}
			}
		}
		
		let exactName = apps.filter {
			_normalizedName($0.currentName) == _normalizedName(local.sourceName)
		}
		
		if exactName.count == 1 {
			let app = exactName[0]
			let version = app.versions?.first(where: { $0.version == local.version })
			return (app, version ?? app.currentAppVersion)
		}
		
		let versionMatches = apps.filter { app in
			if app.currentVersion == local.version { return true }
			return app.versions?.contains(where: { $0.version == local.version }) == true
		}
		
		if versionMatches.count == 1 {
			let app = versionMatches[0]
			let version = app.versions?.first(where: { $0.version == local.version })
			return (app, version ?? app.currentAppVersion)
		}
		
		return nil
	}
	
	private func _variantEvidence(
		for app: ASRepository.App,
		version: ASRepository.App.Version?,
		downloadURL: URL?
	) -> VariantEvidence {
		var evidence = VariantEvidence()
		
		let allTexts = [
			app.name,
			app.subtitle,
			app.description,
			app.localizedDescription,
			app.versionDescription,
			version?.localizedDescription
		].compactMap { $0 }
		
		evidence.family = _family(from: allTexts)
		
		_scanVariantText(app.name, score: 110, source: "title", into: &evidence)
		_scanVariantText(app.subtitle, score: 95, source: "subtitle", into: &evidence)
		_scanVariantText(app.localizedDescription, score: 70, source: "localized description", into: &evidence)
		_scanVariantText(app.description, score: 60, source: "description", into: &evidence)
		_scanVariantText(app.versionDescription, score: 65, source: "version description", into: &evidence)
		_scanVariantText(version?.localizedDescription, score: 65, source: "release notes", into: &evidence)
		
		if let downloadURL {
			_scanVariantText(
				downloadURL.lastPathComponent,
				score: 45,
				source: "IPA filename",
				into: &evidence
			)
		}
		
		return evidence
	}
	
	private func _localBundleFileEvidence(
		for app: AppInfoPresentable,
		familyHint: String?
	) -> VariantEvidence {
		var evidence = VariantEvidence()
		evidence.family = familyHint
		
		guard let appURL = Storage.shared.getAppDirectory(for: app) else {
			return evidence
		}
		
		guard let enumerator = FileManager.default.enumerator(
			at: appURL,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else {
			return evidence
		}
		
		var inspected = 0
		for case let fileURL as URL in enumerator {
			inspected += 1
			if inspected > 1200 { break }
			
			let ext = fileURL.pathExtension.lowercased()
			guard
				ext == "dylib" ||
				ext == "framework" ||
				ext == "bundle" ||
				ext == "appex" ||
				ext == "plist"
			else {
				continue
			}
			
			_scanVariantText(
				fileURL.lastPathComponent,
				score: 85,
				source: "IPA bundle files",
				into: &evidence
			)
		}
		
		return evidence
	}
	
	private func _scanVariantText(
		_ optionalText: String?,
		score: Int,
		source: String,
		into evidence: inout VariantEvidence
	) {
		guard
			let optionalText,
			!optionalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else {
			return
		}
		
		let normalized = _normalizedSearchText(optionalText)
		let compact = _normalizedName(optionalText)
		
		var aliasHits: [(canonical: String, display: String, alias: String)] = []
		for alias in _variantAliases {
			let aliasNormalized = _normalizedSearchText(alias.alias)
			let aliasCompact = _normalizedName(alias.alias)
			
			if
				normalized.contains(aliasNormalized) ||
				(!aliasCompact.isEmpty && compact.contains(aliasCompact))
			{
				aliasHits.append(alias)
			}
		}
		
		// Prefer the more specific primary mod name when one alias contains another.
		// Example: BHTikTokPlus should not simultaneously become BHTikTok, and
		// YTPlusYTweaks should not simultaneously become YTPlus.
		if aliasHits.contains(where: { $0.canonical == "bhtiktokplus" }) {
			aliasHits.removeAll { $0.canonical == "bhtiktok" }
		}
		if aliasHits.contains(where: { $0.canonical == "ytplusytweaks" }) {
			aliasHits.removeAll { $0.canonical == "ytplus" }
		}
		
		for alias in aliasHits {
			evidence.add(
				canonical: alias.canonical,
				display: alias.display,
				score: score,
				source: source
			)
		}
		
		// Source feeds often hide the actual variant behind a generic app name:
		// "Variant: YTPlus 6.0b2", "Variant: 21.39.4 YouMod 2.0.0", etc.
		if let range = normalized.range(of: "variant ") {
			let tail = String(normalized[range.upperBound...])
			for inferred in _explicitVariantTokens(from: tail) {
				evidence.add(
					canonical: inferred.canonical,
					display: inferred.display,
					score: max(score, 105),
					source: source + " (Variant:)"
				)
			}
		}
		
		// Bracketed titles such as "TikTok [VibeTok]" and "BHTikTokPlus [BHTikTok]".
		for bracket in _contentsBetween("[", "]", in: optionalText) {
			for inferred in _explicitVariantTokens(from: bracket) {
				evidence.add(
					canonical: inferred.canonical,
					display: inferred.display,
					score: 100,
					source: source + " (bracket)"
				)
			}
		}
		
		// iOSDecrypted-style compact variant codes visible in the screenshots.
		let codeMap: [(String, String, String)] = [
			("(rs)", "rustiktok", "RusTikTok"),
			("(rx)", "rxtiktok", "RXTikTok"),
			("(gt)", "gtok", "GTok"),
			("(as)", "asjtiktok", "ASJTikTok"),
			("(in)", "infinitok", "Infinitok"),
			("(bh)", "bhtiktok", "BHTikTok")
		]
		
		let lowercase = optionalText.lowercased()
		for (code, canonical, display) in codeMap where lowercase.contains(code) {
			evidence.add(
				canonical: canonical,
				display: display,
				score: max(score, 115),
				source: source + " " + code.uppercased()
			)
		}
	}
	
	private func _explicitVariantTokens(from text: String) -> [(canonical: String, display: String)] {
		let normalized = _normalizedSearchText(text)
		let words = normalized
			.split(separator: " ")
			.map(String.init)
			.filter { !$0.isEmpty }
		
		var results: [(String, String)] = []
		
		for word in words.prefix(8) {
			if _looksLikeVersion(word) { continue }
			if _variantStopWords.contains(word) { continue }
			
			if let alias = _variantAliases.first(where: {
				_normalizedName($0.alias) == _normalizedName(word)
			}) {
				results.append((alias.canonical, alias.display))
				break
			}
			
			// Unknown-but-explicit variant names are still useful. Only accept
			// tokens that are sufficiently specific and not the base app itself.
			let compact = _normalizedName(word)
			if compact.count >= 4,
			   !_genericBaseNames.contains(compact)
			{
				results.append((compact, _prettyVariantLabel(word)))
				break
			}
		}
		
		return results
	}
	
	private func _family(from texts: [String]) -> String? {
		let joined = texts.map(_normalizedName).joined(separator: " ")
		
		if joined.contains("youtubemusic") { return "youtubemusic" }
		if joined.contains("youtube") || joined.contains("youmod") || joined.contains("ytkace") || joined.contains("ytplus") || joined.contains("maxtube") || joined.contains("uyou") {
			return "youtube"
		}
		if joined.contains("tiktok") || joined.contains("bhtiktok") || joined.contains("vibetok") || joined.contains("infinitok") || joined.contains("gtok") {
			return "tiktok"
		}
		if joined.contains("instagram") { return "instagram" }
		if joined.contains("spotify") { return "spotify" }
		if joined.contains("reddit") { return "reddit" }
		if joined.contains("twitter") { return "twitter" }
		if joined.contains("discord") { return "discord" }
		if joined.contains("twitch") { return "twitch" }
		if joined.contains("facebook") { return "facebook" }
		if joined.contains("messenger") { return "messenger" }
		if joined.contains("snapchat") { return "snapchat" }
		
		return nil
	}
	
	private var _variantAliases: [(canonical: String, display: String, alias: String)] {
		[
			// TikTok family
			("bhtiktokplus", "BHTikTokPlus", "bhtiktokplus"),
			("bhtiktok", "BHTikTok", "bhtiktok"),
			("bhtiktok", "BHTikTok", "tiktok bh"),
			("rustiktok", "RusTikTok", "rustiktok"),
			("rxtiktok", "RXTikTok", "rxtiktok"),
			("gtok", "GTok", "gtok"),
			("asjtiktok", "ASJTikTok", "asjtiktok"),
			("infinitok", "Infinitok", "infinitok"),
			("vibetok", "VibeTok", "vibetok"),
			("tiktokeos", "TikTok EOS", "tiktok eos"),
			
			// YouTube family
			("ytliteplus", "YTLitePlus", "ytliteplus"),
			("uyouenhanced", "uYouEnhanced", "uyouenhanced"),
			("uyouplus", "uYouPlus", "uyouplus"),
			("ytplusytweaks", "YTPlusYTweaks", "ytplusytweaks"),
			("ytkace", "YTKACE", "ytkace"),
			("youmod", "YouMod", "youmod"),
			("ytplus", "YTPlus", "ytplus"),
			("maxtube", "MaxTube", "maxtube"),
			("youtubeplusplus", "YouTube++", "youtube plusplus")
		]
	}
	
	private var _variantStopWords: Set<String> {
		[
			"the", "this", "with", "bonus", "tweaks", "tweak", "mod", "modded",
			"version", "build", "youtube", "tiktok", "app", "ios", "for", "and"
		]
	}
	
	private var _genericBaseNames: Set<String> {
		[
			"youtube", "youtubemusic", "tiktok", "instagram", "spotify",
			"reddit", "twitter", "discord", "twitch", "facebook",
			"messenger", "snapchat"
		]
	}
	
	private func _contentsBetween(_ open: Character, _ close: Character, in text: String) -> [String] {
		var results: [String] = []
		var buffer = ""
		var collecting = false
		
		for character in text {
			if character == open {
				buffer = ""
				collecting = true
				continue
			}
			
			if character == close, collecting {
				if !buffer.isEmpty {
					results.append(buffer)
				}
				buffer = ""
				collecting = false
				continue
			}
			
			if collecting {
				buffer.append(character)
			}
		}
		
		return results
	}
	
	private func _looksLikeVersion(_ value: String) -> Bool {
		guard let first = value.first else { return false }
		return first.isNumber && value.contains(".")
	}
	
	private func _prettyVariantLabel(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	private func _rememberLocalEvidence(_ evidence: VariantEvidence, appUUID: String) {
		guard let canonical = evidence.primaryCanonical else { return }
		UserDefaults.standard.set(canonical, forKey: _variantIDPrefix + appUUID)
		if let display = evidence.displayLabel {
			UserDefaults.standard.set(display, forKey: _variantLabelPrefix + appUUID)
		}
		if let summary = evidence.evidenceSummary {
			UserDefaults.standard.set(summary, forKey: _variantEvidencePrefix + appUUID)
		}
	}
	
	// MARK: - Binary / injection fingerprinting
	
	private func _binaryVariantEvidence(
		for app: AppInfoPresentable,
		familyHint: String?
	) -> VariantEvidence {
		var evidence = VariantEvidence()
		evidence.family = familyHint
		
		guard let fingerprint = _binaryFingerprint(for: app) else {
			return evidence
		}
		
		if evidence.family == nil {
			evidence.family = fingerprint.family
		}
		
		for canonical in fingerprint.variantTokens {
			evidence.add(
				canonical: canonical,
				display: _displayName(forCanonical: canonical),
				score: 125,
				source: "binary injection fingerprint"
			)
		}
		
		return evidence
	}
	
	private func _binaryFingerprint(for app: AppInfoPresentable) -> BinaryFingerprint? {
		guard
			let uuid = app.uuid,
			let appURL = Storage.shared.getAppDirectory(for: app)
		else {
			return nil
		}
		
		let cacheKey = _fingerprintCacheKey(uuid: uuid, version: app.version)
		if
			let data = UserDefaults.standard.data(forKey: cacheKey),
			let cached = try? JSONDecoder().decode(BinaryFingerprint.self, from: data),
			cached.schemaVersion == 6
		{
			return cached
		}
		
		let fileManager = FileManager.default
		let bundle = Bundle(url: appURL)
		let family = _family(from: [app.name ?? "", app.identifier ?? ""])
		
		var embeddedComponents = Set<String>()
		var embeddedBundleIDs = Set<String>()
		var nonSystemLoadPaths = Set<String>()
		var distinctiveInjectionIDs = Set<String>()
		var markerTokens = Set<String>()
		var componentHashes: [String: String] = [:]
		var normalizedComponentHashes: [String: String] = [:]
		var candidateMachOs: [URL] = []
		var textEvidence = VariantEvidence()
		textEvidence.family = family
		
		if let executableURL = bundle?.executableURL {
			candidateMachOs.append(executableURL)
		}
		
		guard let enumerator = fileManager.enumerator(
			at: appURL,
			includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
			options: [.skipsHiddenFiles]
		) else {
			return nil
		}
		
		var visited = 0
		var hashedComponents = 0
		var hashedBytes: Int64 = 0
		let hashBudget: Int64 = 256 * 1024 * 1024
		let perComponentHashLimit: Int64 = 32 * 1024 * 1024
		
		for case let url as URL in enumerator {
			visited += 1
			if visited > 5000 { break }
			
			let ext = url.pathExtension.lowercased()
			let name = url.deletingPathExtension().lastPathComponent
			let relative = _relativePath(url, under: appURL)
			
			if ext == "dylib" {
				embeddedComponents.insert(_normalizedComponent(relative))
				candidateMachOs.append(url)
				if let injectionID = _distinctiveInjectionID(url.lastPathComponent, isDylib: true) {
					distinctiveInjectionIDs.insert(injectionID)
				}
				_scanVariantText(
					url.lastPathComponent,
					score: 120,
					source: "dylib filename",
					into: &textEvidence
				)
				
				if
					hashedComponents < 48,
					let fileSize = _fileSize(url),
					fileSize > 0,
					fileSize <= perComponentHashLimit,
					hashedBytes + fileSize <= hashBudget,
					let hash = _sha256File(url, maximumBytes: fileSize)
				{
					let componentKey = _normalizedComponent(relative)
					componentHashes[componentKey] = hash
					if let normalizedHash = _normalizedMachOHash(url, maximumBytes: perComponentHashLimit) {
						normalizedComponentHashes[componentKey] = normalizedHash
					}
					hashedComponents += 1
					hashedBytes += fileSize
				}
			} else if ext == "framework" {
				embeddedComponents.insert(_normalizedComponent(relative))
				if let injectionID = _distinctiveInjectionID(url.lastPathComponent, isDylib: false) {
					distinctiveInjectionIDs.insert(injectionID)
				}
				_scanVariantText(
					url.lastPathComponent,
					score: 115,
					source: "framework name",
					into: &textEvidence
				)
				
				let executable = url.appendingPathComponent(name)
				if fileManager.fileExists(atPath: executable.path) {
					candidateMachOs.append(executable)
					if
						hashedComponents < 48,
						let fileSize = _fileSize(executable),
						fileSize > 0,
						fileSize <= perComponentHashLimit,
						hashedBytes + fileSize <= hashBudget,
						let hash = _sha256File(executable, maximumBytes: fileSize)
					{
						let componentKey = _normalizedComponent(relative)
						componentHashes[componentKey] = hash
						if let normalizedHash = _normalizedMachOHash(executable, maximumBytes: perComponentHashLimit) {
							normalizedComponentHashes[componentKey] = normalizedHash
						}
						hashedComponents += 1
						hashedBytes += fileSize
					}
				}
			} else if ext == "bundle" || ext == "appex" {
				embeddedComponents.insert(_normalizedComponent(relative))
				_scanVariantText(
					url.lastPathComponent,
					score: 105,
					source: ext + " name",
					into: &textEvidence
				)
			}
			
			if url.lastPathComponent == "Info.plist" || ext == "plist" {
				if
					let data = try? Data(contentsOf: url),
					let plist = try? PropertyListSerialization.propertyList(
						from: data,
						options: [],
						format: nil
					)
				{
					let strings = _plistStrings(plist, limit: 300)
					for string in strings {
						if _looksLikeBundleIdentifier(string) {
							embeddedBundleIDs.insert(string.lowercased())
						}
						_scanVariantText(
							string,
							score: 100,
							source: "embedded plist",
							into: &textEvidence
						)
					}
				}
			}
		}
		
		// LC_LOAD_DYLIB / equivalent load commands. Zsign already exposes the
		// same parser Feather uses in its Existing Dylibs screen, so use that
		// rather than shelling out to otool (which is unavailable on-device).
		var scannedMachOPaths = Set<String>()
		for machoURL in candidateMachOs.prefix(48) {
			let path = machoURL.path
			guard scannedMachOPaths.insert(path).inserted else { continue }
			
			let loadPaths = Zsign.listDylibs(appExecutable: path).map { $0 as String }
			for loadPath in loadPaths {
				guard
					loadPath.hasPrefix("@rpath") ||
					loadPath.hasPrefix("@executable_path") ||
					loadPath.hasPrefix("@loader_path")
				else {
					continue
				}
				
				let normalized = _normalizedComponent(loadPath)
				nonSystemLoadPaths.insert(normalized)
				if let injectionID = _distinctiveInjectionID(
					URL(fileURLWithPath: loadPath).lastPathComponent,
					isDylib: loadPath.lowercased().contains(".dylib")
				) {
					distinctiveInjectionIDs.insert(injectionID)
				}
				_scanVariantText(
					loadPath,
					score: 120,
					source: "Mach-O load command",
					into: &textEvidence
				)
			}
		}
		
		// Selected Mach-O strings. This does not retain arbitrary strings from
		// the app; it only records tweak/variant markers and injection-runtime
		// markers so fingerprints stay small and privacy-preserving.
		let binaryMarkers = _scanBinaryMarkers(in: Array(candidateMachOs.prefix(24)))
		for marker in binaryMarkers {
			markerTokens.insert(marker)
			_scanVariantText(
				marker,
				score: 120,
				source: "Mach-O string",
				into: &textEvidence
			)
		}
		
		for component in embeddedComponents {
			markerTokens.insert("component:" + component)
		}
		for bundleID in embeddedBundleIDs {
			markerTokens.insert("bundle:" + bundleID)
		}
		
		let variantTokens = textEvidence.allCanonicals.sorted()
		for token in variantTokens {
			markerTokens.insert("variant:" + token)
		}
		
		let structuralMaterial = (
			embeddedComponents.sorted() +
			nonSystemLoadPaths.sorted() +
			embeddedBundleIDs.sorted() +
			distinctiveInjectionIDs.sorted() +
			markerTokens.sorted()
		).joined(separator: "\n")
		
		let fingerprint = BinaryFingerprint(
			schemaVersion: 6,
			family: textEvidence.family ?? family,
			variantTokens: variantTokens,
			nonSystemLoadPaths: nonSystemLoadPaths.sorted(),
			embeddedComponents: embeddedComponents.sorted(),
			embeddedBundleIDs: embeddedBundleIDs.sorted(),
			distinctiveInjectionIDs: distinctiveInjectionIDs.sorted(),
			markerTokens: markerTokens.sorted(),
			componentHashes: componentHashes,
			normalizedComponentHashes: normalizedComponentHashes,
			structuralHash: _sha256String(structuralMaterial)
		)
		
		if let encoded = try? JSONEncoder().encode(fingerprint) {
			UserDefaults.standard.set(encoded, forKey: cacheKey)
		}
		
		return fingerprint
	}
	
	private func _fingerprintCacheKey(uuid: String, version: String?) -> String {
		let versionPart = _normalizedName(version ?? "unknown")
		return _fingerprintPrefix + uuid + "." + versionPart + ".v6"
	}
	
	private func _storeBinaryValidation(
		_ result: BinaryValidationResult,
		for app: AppInfoPresentable
	) {
		guard let uuid = app.uuid else { return }
		UserDefaults.standard.set(
			result.disposition.rawValue,
			forKey: _fingerprintValidationPrefix + uuid
		)
		UserDefaults.standard.set(
			result.summary,
			forKey: _fingerprintValidationDetailPrefix + uuid
		)
	}
	
	private func _displayName(forCanonical canonical: String) -> String {
		_variantAliases.first(where: { $0.canonical == canonical })?.display ?? canonical
	}
	
	private func _relativePath(_ url: URL, under root: URL) -> String {
		let rootPath = root.standardizedFileURL.path
		let path = url.standardizedFileURL.path
		
		if path.hasPrefix(rootPath + "/") {
			return String(path.dropFirst(rootPath.count + 1))
		}
		return url.lastPathComponent
	}
	
	private func _normalizedComponent(_ value: String) -> String {
		var value = value
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased()
		
		value = value.replacingOccurrences(of: "@rpath/", with: "")
		value = value.replacingOccurrences(of: "@executable_path/", with: "")
		value = value.replacingOccurrences(of: "@loader_path/", with: "")
		value = value.replacingOccurrences(of: "\\", with: "/")
		
		return value
			.split(separator: "/")
			.map(String.init)
			.filter { !$0.isEmpty }
			.joined(separator: "/")
	}
	
	private func _distinctiveInjectionID(
		_ filename: String,
		isDylib: Bool
	) -> String? {
		let lower = filename
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased()
		let base = _normalizedName(
			URL(fileURLWithPath: lower).deletingPathExtension().lastPathComponent
		)
		
		guard base.count >= 4 else { return nil }
		
		let commonRuntimeNames: Set<String> = [
			"ellekit", "cydiasubstrate", "substrate", "substitute",
			"libhooker", "fishhook", "tweakinject", "tweakloader"
		]
		if commonRuntimeNames.contains(base) { return nil }
		if base.hasPrefix("libswift") { return nil }
		if _genericBaseNames.contains(base) { return nil }
		
		// Bundled dylibs are uncommon in stock iOS apps and are therefore useful
		// injection identities once generic hook runtimes are excluded.
		if isDylib {
			return base
		}
		
		let knownAliasCompacts = _variantAliases.flatMap {
			[_normalizedName($0.alias), _normalizedName($0.canonical)]
		}
		if knownAliasCompacts.contains(where: { !$0.isEmpty && base.contains($0) }) {
			return base
		}
		
		let tweakWords = ["tweak", "inject", "hook", "mod", "plus", "enhanced"]
		if tweakWords.contains(where: { base.contains($0) }) {
			return base
		}
		
		return nil
	}
	
	private func _plistStrings(_ value: Any, limit: Int) -> [String] {
		var results: [String] = []
		
		func walk(_ value: Any, depth: Int) {
			guard results.count < limit, depth < 8 else { return }
			
			switch value {
			case let string as String:
				if !string.isEmpty {
					results.append(string)
				}
			case let dict as [String: Any]:
				for (key, child) in dict {
					if results.count >= limit { break }
					results.append(key)
					walk(child, depth: depth + 1)
				}
			case let array as [Any]:
				for child in array {
					if results.count >= limit { break }
					walk(child, depth: depth + 1)
				}
			default:
				break
			}
		}
		
		walk(value, depth: 0)
		return results
	}
	
	private func _looksLikeBundleIdentifier(_ string: String) -> Bool {
		let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
		guard
			value.count >= 5,
			value.count <= 180,
			value.contains("."),
			!value.contains(" "),
			!value.contains("://")
		else {
			return false
		}
		
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
		return value.unicodeScalars.allSatisfy { allowed.contains($0) }
	}
	
	private func _scanBinaryMarkers(in urls: [URL]) -> Set<String> {
		var markers = Set<String>()
		let aliasNeedles = _variantAliases.flatMap {
			[$0.alias.lowercased(), $0.display.lowercased(), $0.canonical.lowercased()]
		}
		let runtimeNeedles = [
			"ellekit", "substrate", "substitute", "libhooker", "fishhook",
			"tweakinject", "tweakloader", "sideload", "injected"
		]
		let needles = Array(Set(aliasNeedles + runtimeNeedles))
		
		var totalBytesRead: Int64 = 0
		let globalLimit: Int64 = 384 * 1024 * 1024
		
		for url in urls {
			if totalBytesRead >= globalLimit { break }
			guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
			defer { try? handle.close() }
			
			var carry = ""
			var perFileBytes: Int64 = 0
			let perFileLimit: Int64 = 192 * 1024 * 1024
			
			while
				perFileBytes < perFileLimit,
				totalBytesRead < globalLimit
			{
				guard
					let data = try? handle.read(upToCount: 1024 * 1024),
					!data.isEmpty
				else {
					break
				}
				
				perFileBytes += Int64(data.count)
				totalBytesRead += Int64(data.count)
				
				let decoded = String(decoding: data, as: UTF8.self).lowercased()
				let haystack = carry + decoded
				
				for needle in needles where haystack.contains(needle) {
					markers.insert(needle)
				}
				
				carry = String(haystack.suffix(256))
			}
		}
		
		return markers
	}
	
	private func _fileSize(_ url: URL) -> Int64? {
		guard
			let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
			let size = values.fileSize
		else {
			return nil
		}
		return Int64(size)
	}
	
	private func _normalizedMachOHash(_ url: URL, maximumBytes: Int64) -> String? {
		guard
			let fileSize = _fileSize(url),
			fileSize > 0,
			fileSize <= maximumBytes,
			var data = try? Data(contentsOf: url)
		else {
			return nil
		}
		
		// arm64 injected dylibs/framework executables are normally thin
		// MH_MAGIC_64 files. Normalize away LC_CODE_SIGNATURE and its blob so
		// re-signing the same injected component does not destroy hash identity.
		guard data.count >= 32 else { return nil }
		
		func u32(_ offset: Int) -> UInt32? {
			guard offset >= 0, offset + 4 <= data.count else { return nil }
			return data.withUnsafeBytes { raw -> UInt32 in
				let p = raw.baseAddress!.advanced(by: offset)
				return p.loadUnaligned(as: UInt32.self).littleEndian
			}
		}
		
		guard u32(0) == 0xfeedfacf else {
			return nil
		}
		
		guard let ncmds = u32(16) else { return nil }
		var cursor = 32
		var codeSignatureRange: Range<Int>?
		
		for _ in 0..<Int(ncmds) {
			guard
				let cmd = u32(cursor),
				let cmdSizeRaw = u32(cursor + 4)
			else {
				return nil
			}
			
			let cmdSize = Int(cmdSizeRaw)
			guard cmdSize >= 8, cursor + cmdSize <= data.count else {
				return nil
			}
			
			if cmd == 0x1d, cmdSize >= 16 { // LC_CODE_SIGNATURE
				if
					let dataOffsetRaw = u32(cursor + 8),
					let dataSizeRaw = u32(cursor + 12)
				{
					let dataOffset = Int(dataOffsetRaw)
					let dataSize = Int(dataSizeRaw)
					if
						dataOffset >= 0,
						dataSize >= 0,
						dataOffset + dataSize <= data.count
					{
						codeSignatureRange = dataOffset..<(dataOffset + dataSize)
					}
				}
				
				data.replaceSubrange(
					cursor..<(cursor + cmdSize),
					with: repeatElement(UInt8(0), count: cmdSize)
				)
			}
			
			cursor += cmdSize
		}
		
		// Remove the signature payload entirely rather than hashing a variable
		// amount of zero padding. This makes the hash stable across re-signing
		// when the code bytes are otherwise identical.
		if let codeSignatureRange {
			data.removeSubrange(codeSignatureRange)
		}
		
		let digest = SHA256.hash(data: data)
		return digest.map { String(format: "%02x", $0) }.joined()
	}
	
	private func _sha256File(_ url: URL, maximumBytes: Int64) -> String? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		
		var hasher = SHA256()
		var consumed: Int64 = 0
		
		while consumed < maximumBytes {
			let remaining = Int(min(Int64(1024 * 1024), maximumBytes - consumed))
			guard remaining > 0 else { break }
			guard
				let data = try? handle.read(upToCount: remaining),
				!data.isEmpty
			else {
				break
			}
			
			hasher.update(data: data)
			consumed += Int64(data.count)
		}
		
		guard consumed > 0 else { return nil }
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}
	
	private func _sha256String(_ value: String) -> String {
		let digest = SHA256.hash(data: Data(value.utf8))
		return digest.map { String(format: "%02x", $0) }.joined()
	}
	
	private func _jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
		if lhs.isEmpty && rhs.isEmpty {
			return 1.0
		}
		
		let union = lhs.union(rhs)
		guard !union.isEmpty else { return 0.0 }
		return Double(lhs.intersection(rhs).count) / Double(union.count)
	}
	
	// MARK: - Version helpers
	
	private func _isLocalCandidate(_ lhs: LocalAppCandidate, newerThan rhs: LocalAppCandidate) -> Bool {
		guard let lhsVersion = lhs.version else { return false }
		guard let rhsVersion = rhs.version else { return true }
		
		if let comparison = _compareVersions(lhsVersion, rhsVersion) {
			if comparison != .orderedSame {
				return comparison == .orderedDescending
			}
		}
		
		if let lhsDate = lhs.versionDate, let rhsDate = rhs.versionDate {
			return lhsDate > rhsDate
		}
		return false
	}
	
	private func _isRemoteCandidate(
		_ remote: RemoteAppCandidate,
		newerThanVersion localVersion: String,
		localDate: Date?
	) -> Bool {
		if let comparison = _compareVersions(remote.version, localVersion) {
			return comparison == .orderedDescending
		}
		
		if let remoteDate = remote.versionDate, let localDate {
			return remoteDate > localDate &&
				_normalizedVersion(remote.version) != _normalizedVersion(localVersion)
		}
		return false
	}
	
	private func _isRemoteCandidate(_ lhs: RemoteAppCandidate, newerThan rhs: RemoteAppCandidate) -> Bool {
		if let comparison = _compareVersions(lhs.version, rhs.version) {
			if comparison != .orderedSame {
				return comparison == .orderedDescending
			}
		}
		
		if let lhsDate = lhs.versionDate, let rhsDate = rhs.versionDate, lhsDate != rhsDate {
			return lhsDate > rhsDate
		}
		
		return lhs.sourceURL.absoluteString.localizedCaseInsensitiveCompare(
			rhs.sourceURL.absoluteString
		) == .orderedAscending
	}
	
	private func _compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
		let left = _normalizedVersion(lhs)
		let right = _normalizedVersion(rhs)
		guard left != right else { return .orderedSame }
		
		guard left.first?.isNumber == true, right.first?.isNumber == true else {
			return nil
		}
		
		return left.compare(right, options: [.numeric, .caseInsensitive])
	}
	
	private func _normalizedVersion(_ version: String) -> String {
		var value = version.trimmingCharacters(in: .whitespacesAndNewlines)
		if
			value.count > 1,
			(value.first == "v" || value.first == "V"),
			value.dropFirst().first?.isNumber == true
		{
			value.removeFirst()
		}
		return value
	}
	
	private func _sourceIdentifier(for app: AppInfoPresentable) -> String? {
		guard let uuid = app.uuid else { return app.identifier }
		return Storage.shared.sourceMetadata(for: uuid)?.sourceAppIdentifier ?? app.identifier
	}
	
	private func _sourceName(for app: AppInfoPresentable) -> String {
		guard let uuid = app.uuid else { return app.name ?? "" }
		return Storage.shared.sourceMetadata(for: uuid)?.sourceAppName ?? app.name ?? ""
	}
	
	private func _normalizedSearchText(_ text: String) -> String {
		var value = text
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased()
		value = value.replacingOccurrences(of: "++", with: " plusplus ")
		value = value.replacingOccurrences(of: "+", with: " plus ")
		
		let separators = CharacterSet.alphanumerics.inverted
		return value
			.components(separatedBy: separators)
			.filter { !$0.isEmpty }
			.joined(separator: " ")
	}
	
	private func _normalizedName(_ name: String) -> String {
		_normalizedSearchText(name).replacingOccurrences(of: " ", with: "")
	}
	
	private func _sourceReputationKey(_ url: URL) -> String {
		let normalized = _normalizedSourceURL(url)
		let digest = SHA256.hash(data: Data(normalized.utf8))
		let suffix = digest.prefix(10).map { String(format: "%02x", $0) }.joined()
		return _sourceReputationPrefix + suffix
	}
	
	private func _sourceReputation(for url: URL?) -> SourceReputation {
		guard let url else { return SourceReputation() }
		guard
			let data = UserDefaults.standard.data(forKey: _sourceReputationKey(url)),
			let value = try? JSONDecoder().decode(SourceReputation.self, from: data)
		else {
			return SourceReputation()
		}
		return value
	}
	
	private func _saveSourceReputation(_ value: SourceReputation, for url: URL) {
		if let data = try? JSONEncoder().encode(value) {
			UserDefaults.standard.set(data, forKey: _sourceReputationKey(url))
		}
	}
	
	private func _recordSourceFetch(_ url: URL?, success: Bool) {
		guard let url else { return }
		var rep = _sourceReputation(for: url)
		rep.fetchAttempts += 1
		if success {
			rep.fetchSuccesses += 1
		} else {
			rep.fetchFailures += 1
		}
		rep.lastSeen = Date()
		_saveSourceReputation(rep, for: url)
	}
	
	private func _recordSourceValidation(
		_ url: URL,
		disposition: BinaryValidationDisposition
	) {
		var rep = _sourceReputation(for: url)
		switch disposition {
		case .verified:
			rep.verifiedCandidates += 1
		case .review:
			rep.reviewCandidates += 1
		case .rejected:
			rep.rejectedCandidates += 1
		}
		rep.lastSeen = Date()
		_saveSourceReputation(rep, for: url)
	}
	
	private func _sourceFetchPriority(
		_ source: AltSource,
		originalSources: Set<String>
	) -> Int {
		guard let url = source.sourceURL else { return Int.min }
		
		let adaptiveRanking =
			(UserDefaults.standard.object(
				forKey: "Feather.GlobalUpdater.AdaptiveSourceRanking"
			) as? Bool) ?? true
		
		if !adaptiveRanking {
			return originalSources.contains(_normalizedSourceURL(url)) ? 1_000 : 0
		}
		
		var score = 0
		
		if originalSources.contains(_normalizedSourceURL(url)) {
			score += 1_000
		}
		
		let rep = _sourceReputation(for: url)
		if rep.fetchAttempts > 0 {
			let reliability = Double(rep.fetchSuccesses) / Double(max(1, rep.fetchAttempts))
			score += Int(reliability * 100.0)
			score -= min(rep.fetchFailures * 3, 30)
		}
		
		if rep.verifiedCandidates > 0 {
			score += min(rep.verifiedCandidates * 10, 80)
		}
		score -= min(rep.rejectedCandidates * 12, 96)
		
		return score
	}
	
	private func _sourceQuality(
		remote: RemoteAppCandidate,
		local: LocalAppCandidate
	) -> (score: Int, summary: String) {
		let adaptiveRanking =
			(UserDefaults.standard.object(
				forKey: "Feather.GlobalUpdater.AdaptiveSourceRanking"
			) as? Bool) ?? true
		
		var score = 35
		var reasons: [String] = []
		
		if
			let storedSourceURL = local.storedSourceURL,
			_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(remote.sourceURL)
		{
			score += 30
			reasons.append("original source")
		}
		
		if remote.repository.id != nil {
			score += 5
		}
		if remote.repository.name != nil {
			score += 3
		}
		if remote.versionDate != nil {
			score += 5
			reasons.append("dated release")
		}
		if !(remote.app.subtitle ?? "").isEmpty {
			score += 4
		}
		if !(remote.app.localizedDescription ?? remote.app.description ?? "").isEmpty {
			score += 4
		}
		if !(remote.versionObject?.localizedDescription ?? remote.app.versionDescription ?? "").isEmpty {
			score += 6
			reasons.append("release notes")
		}
		if remote.evidence.primaryCanonical != nil {
			score += 12
			reasons.append("variant metadata")
		}
		
		let rep = adaptiveRanking
			? _sourceReputation(for: remote.sourceURL)
			: SourceReputation()
		let validations =
			rep.verifiedCandidates +
			rep.reviewCandidates +
			rep.rejectedCandidates
		
		if validations > 0 {
			let verifiedRate =
				Double(rep.verifiedCandidates) /
				Double(max(1, validations))
			score += Int(verifiedRate * 18.0)
			score -= min(rep.rejectedCandidates * 3, 18)
			
			if rep.verifiedCandidates > 0 {
				reasons.append("\(rep.verifiedCandidates) verified before")
			}
			if rep.rejectedCandidates > 0 {
				reasons.append("\(rep.rejectedCandidates) rejected before")
			}
		}
		
		if rep.fetchAttempts > 0 {
			let fetchRate =
				Double(rep.fetchSuccesses) /
				Double(max(1, rep.fetchAttempts))
			score += Int(fetchRate * 8.0)
		}
		
		score = max(0, min(score, 100))
		let summary = reasons.isEmpty
			? "limited history"
			: reasons.joined(separator: " • ")
		return (score, summary)
	}
	
	private func _normalizedSourceURL(_ url: URL) -> String {
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
		let scheme = components?.scheme?.lowercased()
		let host = components?.host?.lowercased()
		components?.scheme = scheme
		components?.host = host
		components?.fragment = nil
		
		let normalized = components?.url ?? url
		let absoluteString = normalized.absoluteString
		return absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
	}
}

private struct SourceReputation: Codable, Sendable {
	var fetchAttempts = 0
	var fetchSuccesses = 0
	var fetchFailures = 0
	var verifiedCandidates = 0
	var reviewCandidates = 0
	var rejectedCandidates = 0
	var lastSeen: Date?
}

private struct BinaryFingerprint: Codable, Equatable, Sendable {
	let schemaVersion: Int
	let family: String?
	let variantTokens: [String]
	let nonSystemLoadPaths: [String]
	let embeddedComponents: [String]
	let embeddedBundleIDs: [String]
	let distinctiveInjectionIDs: [String]
	let markerTokens: [String]
	let componentHashes: [String: String]
	let normalizedComponentHashes: [String: String]
	let structuralHash: String
}


private struct FingerprintJobInput: Sendable {
	let uuid: String
	let appURL: URL
	let version: String?
	let name: String
	let identifier: String?
	let contentStamp: String
}

private enum FingerprintWorker {
	static let schemaVersion = 7
	
	private static let aliases: [(canonical: String, needles: [String])] = [
		("bhtiktokplus", ["bhtiktokplus"]),
		("bhtiktok", ["bhtiktok", "tiktok bh"]),
		("rustiktok", ["rustiktok"]),
		("rxtiktok", ["rxtiktok"]),
		("gtok", ["gtok"]),
		("asjtiktok", ["asjtiktok"]),
		("infinitok", ["infinitok"]),
		("vibetok", ["vibetok"]),
		("tiktokeos", ["tiktok eos"]),
		("ytliteplus", ["ytliteplus"]),
		("uyouenhanced", ["uyouenhanced"]),
		("uyouplus", ["uyouplus"]),
		("ytplusytweaks", ["ytplusytweaks"]),
		("ytkace", ["ytkace"]),
		("youmod", ["youmod"]),
		("ytplus", ["ytplus"]),
		("maxtube", ["maxtube"]),
		("youtubeplusplus", ["youtube++", "youtube plusplus"])
	]
	
	private static let genericRuntimeNames: Set<String> = [
		"ellekit", "cydiasubstrate", "substrate", "substitute",
		"libhooker", "fishhook", "tweakinject", "tweakloader"
	]
	
	static func compute(_ input: FingerprintJobInput) -> BinaryFingerprint? {
		autoreleasepool {
			let fm = FileManager.default
			guard fm.fileExists(atPath: input.appURL.path) else { return nil }
			
			let bundle = Bundle(url: input.appURL)
			let family = familyFrom([input.name, input.identifier ?? ""])
			
			var embeddedComponents = Set<String>()
			var embeddedBundleIDs = Set<String>()
			var nonSystemLoadPaths = Set<String>()
			var distinctiveInjectionIDs = Set<String>()
			var markerTokens = Set<String>()
			var componentHashes: [String: String] = [:]
			var normalizedComponentHashes: [String: String] = [:]
			var candidateMachOs: [URL] = []
			
			if let executableURL = bundle?.executableURL {
				candidateMachOs.append(executableURL)
			}
			
			guard let enumerator = fm.enumerator(
				at: input.appURL,
				includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
				options: [.skipsHiddenFiles, .skipsPackageDescendants]
			) else {
				return nil
			}
			
			var visited = 0
			var plistCount = 0
			var hashCount = 0
			var hashBytes: Int64 = 0
			let hashBudget: Int64 = 128 * 1024 * 1024
			let maxComponentSize: Int64 = 24 * 1024 * 1024
			
			for case let url as URL in enumerator {
				if Task.isCancelled { return nil }
				visited += 1
				if visited > 2500 { break }
				
				let ext = url.pathExtension.lowercased()
				let relative = relativePath(url, under: input.appURL)
				let componentKey = normalizedComponent(relative)
				
				if ext == "dylib" {
					embeddedComponents.insert(componentKey)
					candidateMachOs.append(url)
					addMarkers(from: url.lastPathComponent, to: &markerTokens)
					if let id = distinctiveInjectionID(url.lastPathComponent, isDylib: true) {
						distinctiveInjectionIDs.insert(id)
					}
					hashComponentIfCheap(
						url,
						key: componentKey,
						maxSize: maxComponentSize,
						hashBudget: hashBudget,
						hashCount: &hashCount,
						hashBytes: &hashBytes,
						exact: &componentHashes,
						normalized: &normalizedComponentHashes
					)
				} else if ext == "framework" {
					embeddedComponents.insert(componentKey)
					addMarkers(from: url.lastPathComponent, to: &markerTokens)
					if let id = distinctiveInjectionID(url.lastPathComponent, isDylib: false) {
						distinctiveInjectionIDs.insert(id)
					}
					
					let executable = url.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
					if fm.fileExists(atPath: executable.path) {
						candidateMachOs.append(executable)
						hashComponentIfCheap(
							executable,
							key: componentKey,
							maxSize: maxComponentSize,
							hashBudget: hashBudget,
							hashCount: &hashCount,
							hashBytes: &hashBytes,
							exact: &componentHashes,
							normalized: &normalizedComponentHashes
						)
					}
				} else if ext == "bundle" || ext == "appex" {
					embeddedComponents.insert(componentKey)
					addMarkers(from: url.lastPathComponent, to: &markerTokens)
				}
				
				if (url.lastPathComponent == "Info.plist" || ext == "plist"), plistCount < 64 {
					plistCount += 1
					guard
						let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
						let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
					else {
						continue
					}
					
					for string in plistStrings(plist, limit: 180) {
						if looksLikeBundleIdentifier(string) {
							embeddedBundleIDs.insert(string.lowercased())
						}
						addMarkers(from: string, to: &markerTokens)
					}
				}
			}
			
			// Feather already links Zsign, which can read Mach-O LC_LOAD_DYLIB
			// commands on-device without shelling out to macOS-only tools.
			var scannedPaths = Set<String>()
			for machoURL in candidateMachOs.prefix(24) {
				if Task.isCancelled { return nil }
				guard scannedPaths.insert(machoURL.path).inserted else { continue }
				
				for raw in Zsign.listDylibs(appExecutable: machoURL.path) {
					let loadPath = raw as String
					guard
						loadPath.hasPrefix("@rpath") ||
						loadPath.hasPrefix("@executable_path") ||
						loadPath.hasPrefix("@loader_path")
					else {
						continue
					}
					
					let normalized = normalizedComponent(loadPath)
					nonSystemLoadPaths.insert(normalized)
					addMarkers(from: loadPath, to: &markerTokens)
					
					if let id = distinctiveInjectionID(
						URL(fileURLWithPath: loadPath).lastPathComponent,
						isDylib: loadPath.lowercased().contains(".dylib")
					) {
						distinctiveInjectionIDs.insert(id)
					}
				}
			}
			
			// Search a bounded amount of binary data for variant/runtime names.
			// The v4 implementation could decode hundreds of MB on the main actor.
			for marker in scanBinaryMarkers(in: Array(candidateMachOs.prefix(12))) {
				markerTokens.insert(marker)
			}
			
			let variantTokens = canonicalVariants(in: markerTokens).sorted()
			let structuralMaterial = (
				embeddedComponents.sorted() +
				nonSystemLoadPaths.sorted() +
				embeddedBundleIDs.sorted() +
				distinctiveInjectionIDs.sorted() +
				markerTokens.sorted()
			).joined(separator: "\n")
			
			return BinaryFingerprint(
				schemaVersion: schemaVersion,
				family: family,
				variantTokens: variantTokens,
				nonSystemLoadPaths: nonSystemLoadPaths.sorted(),
				embeddedComponents: embeddedComponents.sorted(),
				embeddedBundleIDs: embeddedBundleIDs.sorted(),
				distinctiveInjectionIDs: distinctiveInjectionIDs.sorted(),
				markerTokens: markerTokens.sorted(),
				componentHashes: componentHashes,
				normalizedComponentHashes: normalizedComponentHashes,
				structuralHash: sha256String(structuralMaterial)
			)
		}
	}
	
	private static func hashComponentIfCheap(
		_ url: URL,
		key: String,
		maxSize: Int64,
		hashBudget: Int64,
		hashCount: inout Int,
		hashBytes: inout Int64,
		exact: inout [String: String],
		normalized: inout [String: String]
	) {
		guard hashCount < 24 else { return }
		guard let size = fileSize(url), size > 0, size <= maxSize else { return }
		guard hashBytes + size <= hashBudget else { return }
		
		if let hash = sha256File(url, maximumBytes: size) {
			exact[key] = hash
		}
		if let hash = normalizedMachOHash(url, maximumBytes: maxSize) {
			normalized[key] = hash
		}
		
		hashCount += 1
		hashBytes += size
	}
	
	private static func addMarkers(from text: String, to markers: inout Set<String>) {
		let lower = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
		for alias in aliases {
			for needle in alias.needles where lower.contains(needle.lowercased()) {
				markers.insert("variant:" + alias.canonical)
			}
		}
		
		for runtime in genericRuntimeNames where lower.contains(runtime) {
			markers.insert("runtime:" + runtime)
		}
	}
	
	private static func canonicalVariants(in markers: Set<String>) -> Set<String> {
		Set(markers.compactMap { marker in
			guard marker.hasPrefix("variant:") else { return nil }
			return String(marker.dropFirst("variant:".count))
		})
	}
	
	private static func familyFrom(_ texts: [String]) -> String? {
		let value = texts.joined(separator: " ").lowercased()
		if value.contains("youtube music") || value.contains("youtubemusic") { return "youtubemusic" }
		if value.contains("youtube") || value.contains("ytlite") || value.contains("uyou") || value.contains("youmod") || value.contains("ytkace") || value.contains("ytplus") || value.contains("maxtube") { return "youtube" }
		if value.contains("tiktok") || value.contains("vibetok") || value.contains("infinitok") || value.contains("gtok") { return "tiktok" }
		if value.contains("instagram") { return "instagram" }
		if value.contains("spotify") { return "spotify" }
		if value.contains("reddit") { return "reddit" }
		if value.contains("twitter") { return "twitter" }
		if value.contains("discord") { return "discord" }
		if value.contains("twitch") { return "twitch" }
		if value.contains("facebook") { return "facebook" }
		if value.contains("messenger") { return "messenger" }
		if value.contains("snapchat") { return "snapchat" }
		return nil
	}
	
	private static func scanBinaryMarkers(in urls: [URL]) -> Set<String> {
		var found = Set<String>()
		let needlePairs: [(String, String)] =
			aliases.flatMap { alias in alias.needles.map { ($0.lowercased(), "variant:" + alias.canonical) } } +
			genericRuntimeNames.map { ($0.lowercased(), "runtime:" + $0) }
		
		var total: Int64 = 0
		let globalLimit: Int64 = 96 * 1024 * 1024
		let perFileLimit: Int64 = 16 * 1024 * 1024
		
		for url in urls {
			if Task.isCancelled || total >= globalLimit { break }
			guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
			defer { try? handle.close() }
			
			var consumed: Int64 = 0
			var carry = ""
			while consumed < perFileLimit && total < globalLimit {
				if Task.isCancelled { return found }
				guard let data = try? handle.read(upToCount: 512 * 1024), !data.isEmpty else { break }
				consumed += Int64(data.count)
				total += Int64(data.count)
				
				let decoded = String(decoding: data, as: UTF8.self).lowercased()
				let haystack = carry + decoded
				for (needle, marker) in needlePairs where haystack.contains(needle) {
					found.insert(marker)
				}
				carry = String(haystack.suffix(192))
			}
		}
		
		return found
	}
	
	private static func normalizedMachOHash(_ url: URL, maximumBytes: Int64) -> String? {
		guard let size = fileSize(url), size > 0, size <= maximumBytes else { return nil }
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		
		guard let header = try? handle.read(upToCount: Int(min(size, 512 * 1024))), header.count >= 32 else {
			return nil
		}
		
		var headerData = header
		func u32(_ offset: Int) -> UInt32? {
			guard offset >= 0, offset + 4 <= headerData.count else { return nil }
			return headerData.withUnsafeBytes { raw -> UInt32 in
				raw.baseAddress!.advanced(by: offset).loadUnaligned(as: UInt32.self).littleEndian
			}
		}
		
		guard u32(0) == 0xfeedfacf, let ncmds = u32(16) else { return nil }
		var cursor = 32
		var signatureRange: Range<Int64>?
		
		for _ in 0..<Int(ncmds) {
			guard let cmd = u32(cursor), let cmdSizeRaw = u32(cursor + 4) else { return nil }
			let cmdSize = Int(cmdSizeRaw)
			guard cmdSize >= 8, cursor + cmdSize <= headerData.count else { return nil }
			
			if cmd == 0x1d, cmdSize >= 16 {
				if let off = u32(cursor + 8), let len = u32(cursor + 12) {
					signatureRange = Int64(off)..<(Int64(off) + Int64(len))
				}
				headerData.replaceSubrange(cursor..<(cursor + cmdSize), with: repeatElement(UInt8(0), count: cmdSize))
			}
			cursor += cmdSize
		}
		
		var hasher = SHA256()
		var fileOffset: Int64 = 0
		try? handle.seek(toOffset: 0)
		
		while fileOffset < size {
			if Task.isCancelled { return nil }
			guard let chunk = try? handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
			var data = chunk
			let chunkStart = fileOffset
			let chunkEnd = fileOffset + Int64(data.count)
			
			if chunkStart == 0 {
				let replaceCount = min(headerData.count, data.count)
				data.replaceSubrange(0..<replaceCount, with: headerData.prefix(replaceCount))
			}
			
			if let signatureRange {
				let overlapStart = max(chunkStart, signatureRange.lowerBound)
				let overlapEnd = min(chunkEnd, signatureRange.upperBound)
				if overlapStart < overlapEnd {
					let localStart = Int(overlapStart - chunkStart)
					let localEnd = Int(overlapEnd - chunkStart)
					data.removeSubrange(localStart..<localEnd)
				}
			}
			
			hasher.update(data: data)
			fileOffset = chunkEnd
		}
		
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}
	
	private static func sha256File(_ url: URL, maximumBytes: Int64) -> String? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		var hasher = SHA256()
		var consumed: Int64 = 0
		
		while consumed < maximumBytes {
			if Task.isCancelled { return nil }
			let count = Int(min(1024 * 1024, maximumBytes - consumed))
			guard count > 0, let data = try? handle.read(upToCount: count), !data.isEmpty else { break }
			hasher.update(data: data)
			consumed += Int64(data.count)
		}
		
		guard consumed > 0 else { return nil }
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}
	
	private static func fileSize(_ url: URL) -> Int64? {
		guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
		return Int64(size)
	}
	
	private static func relativePath(_ url: URL, under root: URL) -> String {
		let rootPath = root.standardizedFileURL.path
		let path = url.standardizedFileURL.path
		if path.hasPrefix(rootPath + "/") {
			return String(path.dropFirst(rootPath.count + 1))
		}
		return url.lastPathComponent
	}
	
	private static func normalizedComponent(_ value: String) -> String {
		var value = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
		value = value.replacingOccurrences(of: "@rpath/", with: "")
		value = value.replacingOccurrences(of: "@executable_path/", with: "")
		value = value.replacingOccurrences(of: "@loader_path/", with: "")
		value = value.replacingOccurrences(of: "\\", with: "/")
		return value.split(separator: "/").map(String.init).filter { !$0.isEmpty }.joined(separator: "/")
	}
	
	private static func distinctiveInjectionID(_ filename: String, isDylib: Bool) -> String? {
		let base = URL(fileURLWithPath: filename)
			.deletingPathExtension()
			.lastPathComponent
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased()
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.joined()
		
		guard base.count >= 4 else { return nil }
		if genericRuntimeNames.contains(base) || base.hasPrefix("libswift") { return nil }
		if isDylib { return base }
		
		if aliases.contains(where: { alias in
			alias.needles.contains(where: {
				let compact = $0.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
				return !compact.isEmpty && base.contains(compact)
			})
		}) {
			return base
		}
		
		let tweakWords = ["tweak", "inject", "hook", "mod", "plus", "enhanced"]
		return tweakWords.contains(where: { base.contains($0) }) ? base : nil
	}
	
	private static func plistStrings(_ value: Any, limit: Int) -> [String] {
		var results: [String] = []
		func walk(_ value: Any, depth: Int) {
			guard results.count < limit, depth < 7 else { return }
			switch value {
			case let string as String:
				if !string.isEmpty { results.append(string) }
			case let dict as [String: Any]:
				for (key, child) in dict {
					if results.count >= limit { break }
					results.append(key)
					walk(child, depth: depth + 1)
				}
			case let array as [Any]:
				for child in array {
					if results.count >= limit { break }
					walk(child, depth: depth + 1)
				}
			default:
				break
			}
		}
		walk(value, depth: 0)
		return results
	}
	
	private static func looksLikeBundleIdentifier(_ string: String) -> Bool {
		let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
		guard value.count >= 5, value.count <= 180, value.contains("."), !value.contains(" "), !value.contains("://") else {
			return false
		}
		let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
		return value.unicodeScalars.allSatisfy { allowed.contains($0) }
	}
	
	private static func sha256String(_ value: String) -> String {
		SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
	}
}

private struct VariantEvidence {
	var family: String?
	private var items: [String: VariantEvidenceItem] = [:]
	
	var primaryCanonical: String? {
		let primary = primaryItems
		return primary.count == 1 ? primary[0].canonical : nil
	}
	
	var displayLabel: String? {
		guard let primaryCanonical else { return nil }
		return items[primaryCanonical]?.display
	}
	
	var evidenceSummary: String? {
		guard let primaryCanonical, let item = items[primaryCanonical] else { return nil }
		return "\(item.source): \(item.display)"
	}
	
	var allCanonicals: [String] {
		items.values
			.filter { $0.score >= 60 }
			.sorted { $0.score > $1.score }
			.map(\.canonical)
	}
	
	private var primaryItems: [VariantEvidenceItem] {
		guard let maxScore = items.values.map(\.score).max(), maxScore >= 45 else {
			return []
		}
		return items.values
			.filter { $0.score >= maxScore - 8 }
			.sorted { $0.score > $1.score }
	}
	
	mutating func add(
		canonical: String,
		display: String,
		score: Int,
		source: String
	) {
		if let current = items[canonical], current.score >= score {
			return
		}
		items[canonical] = VariantEvidenceItem(
			canonical: canonical,
			display: display,
			score: score,
			source: source
		)
	}
	
	mutating func merge(_ other: VariantEvidence) {
		if family == nil {
			family = other.family
		}
		for item in other.items.values {
			add(
				canonical: item.canonical,
				display: item.display,
				score: item.score,
				source: item.source
			)
		}
	}
}

private struct VariantEvidenceItem {
	let canonical: String
	let display: String
	let score: Int
	let source: String
}

private struct LocalAppCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let identifier: String
	let sourceName: String
	let version: String?
	let versionDate: Date?
	let storedSourceURL: URL?
	let storedDownloadURL: URL?
	var evidence: VariantEvidence
}

private struct RemoteAppCandidate {
	let source: AltSource
	let sourceURL: URL
	let repository: ASRepository
	let app: ASRepository.App
	let versionObject: ASRepository.App.Version?
	let version: String
	let versionDate: Date?
	let downloadURL: URL
	let evidence: VariantEvidence
}
