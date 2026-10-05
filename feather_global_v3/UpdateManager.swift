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
	let sourceProvenance: SourceAppProvenance
}

enum BinaryValidationDisposition: String, Codable {
	case verified
	case review
	case rejected
}

struct BinaryValidationResult: Equatable {
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
	
	private let _dataService = NBFetchService()
	private let _variantIDPrefix = "Feather.GlobalUpdater.VariantID."
	private let _variantLabelPrefix = "Feather.GlobalUpdater.VariantLabel."
	private let _variantEvidencePrefix = "Feather.GlobalUpdater.VariantEvidence."
	private let _fingerprintPrefix = "Feather.GlobalUpdater.BinaryFingerprint."
	private let _fingerprintValidationPrefix = "Feather.GlobalUpdater.BinaryValidation."
	private let _fingerprintValidationDetailPrefix = "Feather.GlobalUpdater.BinaryValidationDetail."
	
	private init() {}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}
	
	func ambiguousCandidates(for app: AppInfoPresentable) -> [AppUpdate] {
		guard let uuid = app.uuid else { return [] }
		return ambiguousUpdates[uuid] ?? []
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
	
	func validateDownloadedUpdate(
		original: AppInfoPresentable,
		downloaded: AppInfoPresentable,
		update: AppUpdate
	) -> BinaryValidationResult {
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
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
		guard
			let originalFingerprint = _binaryFingerprint(for: original),
			let downloadedFingerprint = _binaryFingerprint(for: downloaded)
		else {
			let result = BinaryValidationResult(
				disposition: .review,
				score: 0,
				summary: "Binary fingerprint could not be completed. The IPA was kept in Library, but automatic signing/install should not continue."
			)
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
		let originalVariant = variantID(for: original)
		let remoteVariant = update.variantID
		
		let originalTokens = Set(originalFingerprint.variantTokens + [originalVariant].compactMap { $0 })
		let downloadedTokens = Set(downloadedFingerprint.variantTokens + [remoteVariant].compactMap { $0 })
		
		if
			!originalTokens.isEmpty,
			!downloadedTokens.isEmpty,
			originalTokens.isDisjoint(with: downloadedTokens)
		{
			let result = BinaryValidationResult(
				disposition: .rejected,
				score: -100,
				summary:
					"Variant conflict: installed fingerprint = \(originalTokens.sorted().joined(separator: ", ")); " +
					"downloaded fingerprint = \(downloadedTokens.sorted().joined(separator: ", "))."
			)
			_storeBinaryValidation(result, for: downloaded)
			return result
		}
		
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
		
		let exactHashMatches = Set(originalFingerprint.componentHashes.keys)
			.intersection(downloadedFingerprint.componentHashes.keys)
			.reduce(into: 0) { count, key in
				if originalFingerprint.componentHashes[key] == downloadedFingerprint.componentHashes[key] {
					count += 1
				}
			}
		
		let variantOverlap = !originalTokens.intersection(downloadedTokens).isEmpty
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
		score += min(exactHashMatches * 10, 20)
		
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
			structuralMatch ||
			exactHashMatches > 0
		
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
			disposition =
				(score >= 60 && (variantOverlap || substantialStructuralAgreement))
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
			"exact component hashes \(exactHashMatches)",
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
		
		let repositories = await _fetchRepositories(from: sources)
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
		batchSize: Int = 8
	) async -> [(AltSource, ASRepository)] {
		var repositories: [(AltSource, ASRepository)] = []
		let sourcesArray = Array(sources)
		
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
									continuation.resume(returning: (source, repository))
								case .failure:
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
			
			let fileEvidence = _localBundleFileEvidence(for: local.app, familyHint: evidence.family)
			evidence.merge(fileEvidence)
			
			if evidence.primaryCanonical == nil, evidence.family != nil {
				let binaryEvidence = _binaryVariantEvidence(for: local.app, familyHint: evidence.family)
				evidence.merge(binaryEvidence)
			}
			return evidence
		}
		
		var evidence = VariantEvidence()
		let texts = [local.sourceName, local.app.name ?? ""]
		evidence.family = _family(from: texts)
		_scanVariantText(local.sourceName, score: 100, source: "stored source title", into: &evidence)
		_scanVariantText(local.app.name ?? "", score: 90, source: "IPA display name", into: &evidence)
		
		let fileEvidence = _localBundleFileEvidence(for: local.app, familyHint: evidence.family)
		evidence.merge(fileEvidence)
		
		if evidence.primaryCanonical == nil, evidence.family != nil {
			let binaryEvidence = _binaryVariantEvidence(for: local.app, familyHint: evidence.family)
			evidence.merge(binaryEvidence)
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
			cached.schemaVersion == 4
		{
			return cached
		}
		
		let fileManager = FileManager.default
		let bundle = Bundle(url: appURL)
		let family = _family(from: [app.name ?? "", app.identifier ?? ""])
		
		var embeddedComponents = Set<String>()
		var embeddedBundleIDs = Set<String>()
		var nonSystemLoadPaths = Set<String>()
		var markerTokens = Set<String>()
		var componentHashes: [String: String] = [:]
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
		
		for case let url as URL in enumerator {
			visited += 1
			if visited > 5000 { break }
			
			let ext = url.pathExtension.lowercased()
			let name = url.deletingPathExtension().lastPathComponent
			let relative = _relativePath(url, under: appURL)
			
			if ext == "dylib" {
				embeddedComponents.insert(_normalizedComponent(relative))
				candidateMachOs.append(url)
				_scanVariantText(
					url.lastPathComponent,
					score: 120,
					source: "dylib filename",
					into: &textEvidence
				)
				
				if hashedComponents < 32,
				   let hash = _sha256File(url, maximumBytes: 96 * 1024 * 1024)
				{
					componentHashes[_normalizedComponent(relative)] = hash
					hashedComponents += 1
				}
			} else if ext == "framework" {
				embeddedComponents.insert(_normalizedComponent(relative))
				_scanVariantText(
					url.lastPathComponent,
					score: 115,
					source: "framework name",
					into: &textEvidence
				)
				
				let executable = url.appendingPathComponent(name)
				if fileManager.fileExists(atPath: executable.path) {
					candidateMachOs.append(executable)
					if hashedComponents < 32,
					   let hash = _sha256File(executable, maximumBytes: 96 * 1024 * 1024)
					{
						componentHashes[_normalizedComponent(relative)] = hash
						hashedComponents += 1
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
			markerTokens.sorted()
		).joined(separator: "\n")
		
		let fingerprint = BinaryFingerprint(
			schemaVersion: 4,
			family: textEvidence.family ?? family,
			variantTokens: variantTokens,
			nonSystemLoadPaths: nonSystemLoadPaths.sorted(),
			embeddedComponents: embeddedComponents.sorted(),
			embeddedBundleIDs: embeddedBundleIDs.sorted(),
			markerTokens: markerTokens.sorted(),
			componentHashes: componentHashes,
			structuralHash: _sha256String(structuralMaterial)
		)
		
		if let encoded = try? JSONEncoder().encode(fingerprint) {
			UserDefaults.standard.set(encoded, forKey: cacheKey)
		}
		
		return fingerprint
	}
	
	private func _fingerprintCacheKey(uuid: String, version: String?) -> String {
		let versionPart = _normalizedName(version ?? "unknown")
		return _fingerprintPrefix + uuid + "." + versionPart + ".v4"
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
				totalBytesRead < globalLimit,
				let data = try? handle.read(upToCount: 1024 * 1024),
				let data,
				!data.isEmpty
			{
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
	
	private func _sha256File(_ url: URL, maximumBytes: Int64) -> String? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }
		
		var hasher = SHA256()
		var consumed: Int64 = 0
		
		while consumed < maximumBytes {
			let remaining = Int(min(Int64(1024 * 1024), maximumBytes - consumed))
			guard
				remaining > 0,
				let data = try? handle.read(upToCount: remaining),
				let data,
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

private struct BinaryFingerprint: Codable, Equatable {
	let schemaVersion: Int
	let family: String?
	let variantTokens: [String]
	let nonSystemLoadPaths: [String]
	let embeddedComponents: [String]
	let embeddedBundleIDs: [String]
	let markerTokens: [String]
	let componentHashes: [String: String]
	let structuralHash: String
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
