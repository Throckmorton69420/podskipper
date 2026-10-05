//
//  UpdateManager.swift
//  Feather
//
//  Global Updater v2:
//  - cross-repository scanning
//  - strict mod/variant matching
//  - ambiguous candidate review instead of unsafe auto-matching
//  - duplicate-local handling by bundle + variant
//

import AltSourceKit
import CoreData
import Foundation
import NimbleJSON

enum UpdateVariantMatch: String, Equatable {
	case exactSourceName = "Exact variant name"
	case exactVariant = "Exact mod variant"
	case stockFamily = "Stock app family"
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
	let sourceProvenance: SourceAppProvenance
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
	
	private init() {}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}
	
	func ambiguousCandidates(for app: AppInfoPresentable) -> [AppUpdate] {
		guard let uuid = app.uuid else { return [] }
		return ambiguousUpdates[uuid] ?? []
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
		
		let lhsName = _sourceName(for: lhs)
		let rhsName = _sourceName(for: rhs)
		
		if _normalizedName(lhsName) == _normalizedName(rhsName) {
			return true
		}
		
		let left = _variantIdentity(lhsName)
		let right = _variantIdentity(rhsName)
		
		if
			let leftFamily = left.family,
			let rightFamily = right.family,
			leftFamily == rightFamily
		{
			if left.variant.isEmpty && right.variant.isEmpty {
				return true
			}
			return !left.variant.isEmpty && left.variant == right.variant
		}
		
		return false
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
			let identity = _variantIdentity(sourceName)
			let variantKey = [
				sourceIdentifier.lowercased(),
				identity.family ?? "_",
				identity.variant.isEmpty ? identity.normalized : identity.variant
			].joined(separator: "|")
			
			let localVersion = localApp.version ?? metadata?.sourceAppVersion
			let candidate = LocalAppCandidate(
				appUUID: localUUID,
				app: localApp,
				identifier: sourceIdentifier,
				sourceName: sourceName,
				identity: identity,
				version: localVersion,
				versionDate: metadata?.sourceAppVersionDate,
				storedSourceURL: metadata?.sourceRepositoryURL ?? localApp.source
			)
			
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
					
					let remoteIdentity = _variantIdentity(remoteApp.currentName)
					let match = _matchKind(
						local: local,
						remoteName: remoteApp.currentName,
						remoteIdentity: remoteIdentity,
						remoteSourceURL: sourceURL
					)
					
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
						
						if let match {
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
					limit: 10
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
		remoteName: String,
		remoteIdentity: VariantIdentity,
		remoteSourceURL: URL
	) -> UpdateVariantMatch? {
		let localNormalized = local.identity.normalized
		let remoteNormalized = remoteIdentity.normalized
		
		let sameOriginalSource: Bool = {
			guard let storedSourceURL = local.storedSourceURL else { return false }
			return _normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(remoteSourceURL)
		}()
		
		// High-collision families need stricter handling than ordinary apps.
		// BHTikTok vs RSTikTok and the many YouTube mods often deliberately share
		// the same bundle identifier. A non-empty mod suffix must match exactly.
		// A generic/stock name such as "TikTok" or "YouTube" is only trusted from
		// the app's original repository because a different repo may use that same
		// generic display name for a completely different injected build.
		if
			let localFamily = local.identity.family,
			let remoteFamily = remoteIdentity.family,
			localFamily == remoteFamily
		{
			if local.identity.variant.isEmpty && remoteIdentity.variant.isEmpty {
				return sameOriginalSource ? .stockFamily : nil
			}
			
			if
				!local.identity.variant.isEmpty,
				local.identity.variant == remoteIdentity.variant
			{
				return .exactVariant
			}
			
			return nil
		}
		
		// For ordinary apps, an exact repository app/variant name is a strong
		// cross-repository match and is substantially safer than bundle ID alone.
		if !localNormalized.isEmpty && localNormalized == remoteNormalized {
			return .exactSourceName
		}
		
		// If there is no usable source/app name at all, fall back only to the
		// original repository rather than guessing across unrelated repos.
		if
			local.sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			sameOriginalSource
		{
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
		case .exactSourceName: return 50
		case .exactVariant: return 40
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
			let key = [
				_normalizedName(candidate.app.currentName),
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
			return $0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending
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
				remote.sourceURL.absoluteString
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
				candidates.append(
					RemoteAppCandidate(
						source: source,
						sourceURL: sourceURL,
						repository: repository,
						app: app,
						versionObject: version,
						version: version.version,
						versionDate: version.date?.date,
						downloadURL: downloadURL
					)
				)
			}
		} else if
			let version = app.version,
			!version.isEmpty,
			let downloadURL = app.downloadURL
		{
			candidates.append(
				RemoteAppCandidate(
					source: source,
					sourceURL: sourceURL,
					repository: repository,
					app: app,
					versionObject: nil,
					version: version,
					versionDate: app.currentDate?.date,
					downloadURL: downloadURL
				)
			)
		}
		
		return candidates
	}
	
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
	
	private func _variantIdentity(_ name: String) -> VariantIdentity {
		let normalized = _normalizedName(name)
		guard !normalized.isEmpty else {
			return VariantIdentity(family: nil, variant: "", normalized: "")
		}
		
		let families: [(family: String, aliases: [String])] = [
			("youtubemusic", ["youtubemusic"]),
			("youtube", ["youtube"]),
			("tiktok", ["tiktok"]),
			("instagram", ["instagram"]),
			("spotify", ["spotify"]),
			("reddit", ["reddit"]),
			("twitter", ["twitter"]),
			("discord", ["discord"]),
			("twitch", ["twitch"]),
			("facebook", ["facebook"]),
			("messenger", ["messenger"]),
			("snapchat", ["snapchat"])
		]
		
		for entry in families {
			for alias in entry.aliases where normalized.contains(alias) {
				let variant = normalized.replacingOccurrences(of: alias, with: "")
				return VariantIdentity(
					family: entry.family,
					variant: variant,
					normalized: normalized
				)
			}
		}
		
		return VariantIdentity(
			family: nil,
			variant: normalized,
			normalized: normalized
		)
	}
	
	private func _normalizedName(_ name: String) -> String {
		var value = name
			.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
			.lowercased()
		
		// Preserve symbolic mod names such as YouTube++ / TikTok+ before
		// stripping punctuation; otherwise they collapse to the stock app name.
		value = value.replacingOccurrences(of: "++", with: "plusplus")
		value = value.replacingOccurrences(of: "+", with: "plus")
		
		return value
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.joined()
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

private struct VariantIdentity {
	let family: String?
	let variant: String
	let normalized: String
}

private struct LocalAppCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let identifier: String
	let sourceName: String
	let identity: VariantIdentity
	let version: String?
	let versionDate: Date?
	let storedSourceURL: URL?
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
}
