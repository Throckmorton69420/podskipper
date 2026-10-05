//
//  UpdateManager.swift
//  Feather
//
//  Global cross-repository updater variant for Shashank.
//  Based on Feather's upstream updater; scans every enabled source.
//

import AltSourceKit
import CoreData
import Foundation
import NimbleJSON

struct AppUpdate: Identifiable, Equatable {
	let id: String
	let localUUID: String
	let localVersion: String?
	let remoteVersion: String
	let appName: String
	let bundleIdentifier: String
	let remoteBundleIdentifier: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceName: String
	let sourceChanged: Bool
	let matchedByName: Bool
	let sourceProvenance: SourceAppProvenance
}

@MainActor
final class UpdateManager: ObservableObject {
	static let shared = UpdateManager()
	
	typealias RepositoryDataHandler = Result<ASRepository, Error>
	
	@Published private(set) var updates: [String: AppUpdate] = [:]
	@Published private(set) var isChecking = false
	@Published private(set) var lastCheckedDate: Date?
	@Published private(set) var sourcesChecked = 0
	@Published private(set) var sourcesFailed = 0
	
	private let _dataService = NBFetchService()
	
	private init() {}
	
	var uniqueUpdates: [AppUpdate] {
		var bestByBundle: [String: AppUpdate] = [:]
		
		for update in updates.values {
			let key = update.bundleIdentifier.lowercased()
			guard let existing = bestByBundle[key] else {
				bestByBundle[key] = update
				continue
			}
			
			if
				let comparison = _compareVersions(update.remoteVersion, existing.remoteVersion),
				comparison == .orderedDescending
			{
				bestByBundle[key] = update
			}
		}
		
		return bestByBundle.values.sorted {
			$0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
		}
	}
	
	var availableUpdateCount: Int {
		uniqueUpdates.count
	}
	
	func update(for app: AppInfoPresentable) -> AppUpdate? {
		guard let uuid = app.uuid else { return nil }
		return updates[uuid]
	}
	
	func checkForUpdates(
		sources: [AltSource],
		localApps: [AppInfoPresentable]
	) async {
		guard !isChecking else { return }
		
		isChecking = true
		sourcesChecked = 0
		sourcesFailed = 0
		
		defer {
			isChecking = false
			lastCheckedDate = Date()
		}
		
		let repositories = await _fetchRepositories(from: sources)
		sourcesChecked = repositories.count
		sourcesFailed = max(0, sources.count - repositories.count)
		updates = _findUpdates(repositories: repositories, localApps: localApps)
	}
	
	private func _fetchRepositories(
		from sources: [AltSource],
		batchSize: Int = 8
	) async -> [(AltSource, ASRepository)] {
		var repositories: [(AltSource, ASRepository)] = []
		let sourcesArray = Array(sources)
		
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = Array(sourcesArray[startIndex..<endIndex])
			
			let batchResults = await withTaskGroup(
				of: (AltSource, ASRepository?).self,
				returning: [(AltSource, ASRepository)].self
			) { group in
				for source in batch {
					group.addTask { [self] in
						guard let url = source.sourceURL else {
							return (source, nil)
						}
						
						let repository = await _fetchRepository(from: url)
						return (source, repository)
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
	
	private func _fetchRepository(from url: URL) async -> ASRepository? {
		await withCheckedContinuation { continuation in
			_dataService.fetch(from: url) { (result: RepositoryDataHandler) in
				switch result {
				case .success(let repository):
					continuation.resume(returning: repository)
				case .failure:
					continuation.resume(returning: nil)
				}
			}
		}
	}
	
	private func _findUpdates(
		repositories: [(AltSource, ASRepository)],
		localApps: [AppInfoPresentable]
	) -> [String: AppUpdate] {
		var foundUpdates: [String: AppUpdate] = [:]
		
		let metadataByUUID = Storage.shared.getSourceMetadata().reduce(into: [String: AppSourceMetadata]()) {
			$0[$1.appUUID] = $1
		}
		
		let metadataCandidates = localApps.compactMap { app -> SourceMetadataCandidate? in
			guard
				let uuid = app.uuid,
				let metadata = metadataByUUID[uuid]
			else {
				return nil
			}
			return SourceMetadataCandidate(appUUID: uuid, app: app, metadata: metadata)
		}
		
		// If Feather has multiple library entries for the same bundle identifier,
		// compare against the highest version already present so an older duplicate
		// does not create a false-positive update.
		var highestLocalVersionByBundle: [String: String] = [:]
		for app in localApps {
			guard
				let identifier = app.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
				!identifier.isEmpty,
				let version = app.version?.trimmingCharacters(in: .whitespacesAndNewlines),
				!version.isEmpty
			else {
				continue
			}
			
			let key = identifier.lowercased()
			if let existing = highestLocalVersionByBundle[key] {
				if
					let comparison = _compareVersions(version, existing),
					comparison == .orderedDescending
				{
					highestLocalVersionByBundle[key] = version
				}
			} else {
				highestLocalVersionByBundle[key] = version
			}
		}
		
		for localApp in localApps {
			guard
				let localUUID = localApp.uuid,
				let localIdentifier = localApp.identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
				!localIdentifier.isEmpty
			else {
				continue
			}
			
			var storedSourceURL: URL?
			var preferredSourceAppIdentifier: String?
			
			if let directMetadata = metadataByUUID[localUUID] {
				storedSourceURL = directMetadata.sourceRepositoryURL
				preferredSourceAppIdentifier = directMetadata.sourceAppIdentifier
			} else if let fallback = _fallbackMetadataCandidate(
				for: localApp,
				localUUID: localUUID,
				candidates: metadataCandidates
			) {
				storedSourceURL = fallback.metadata.sourceRepositoryURL
				preferredSourceAppIdentifier = fallback.metadata.sourceAppIdentifier
				
				Storage.shared.copySourceMetadata(
					from: fallback.appUUID,
					to: localUUID,
					kind: localApp.isSigned ? .signed : .imported
				)
			} else {
				storedSourceURL = localApp.source
			}
			
			let bundleKey = localIdentifier.lowercased()
			let baselineVersion = highestLocalVersionByBundle[bundleKey] ?? localApp.version
			let localNameKey = _normalizedAppName(localApp.name)
			
			var exactCandidates: [RemoteCandidate] = []
			var nameCandidates: [RemoteCandidate] = []
			
			for (source, repository) in repositories {
				guard let sourceURL = source.sourceURL else { continue }
				let sourceName = source.name ?? sourceURL.host ?? sourceURL.absoluteString
				
				for remoteApp in repository.apps {
					guard
						let remoteVersion = remoteApp.currentVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
						!remoteVersion.isEmpty,
						let remoteIdentifier = remoteApp.id?.trimmingCharacters(in: .whitespacesAndNewlines),
						!remoteIdentifier.isEmpty,
						let downloadURL = remoteApp.currentDownloadUrl,
						let provenance = SourceAppProvenance(
							sourceURL: sourceURL,
							repository: repository,
							app: remoteApp
						)
					else {
						continue
					}
					
					let metadataIdentifierMatch = preferredSourceAppIdentifier.map {
						remoteIdentifier.caseInsensitiveCompare($0) == .orderedSame
					} ?? false
					let exactIdentifierMatch =
						remoteIdentifier.caseInsensitiveCompare(localIdentifier) == .orderedSame ||
						metadataIdentifierMatch
					
					let candidate = RemoteCandidate(
						appName: remoteApp.currentName,
						remoteIdentifier: remoteIdentifier,
						version: remoteVersion,
						downloadURL: downloadURL,
						sourceURL: sourceURL,
						sourceName: sourceName,
						provenance: provenance
					)
					
					if exactIdentifierMatch {
						exactCandidates.append(candidate)
					} else if
						!localNameKey.isEmpty,
						_normalizedAppName(remoteApp.currentName) == localNameKey
					{
						nameCandidates.append(candidate)
					}
				}
			}
			
			let matchedByName = exactCandidates.isEmpty
			let candidates = matchedByName ? nameCandidates : exactCandidates
			
			guard let best = _bestCandidate(
				from: candidates,
				newerThan: baselineVersion,
				preferredSourceURL: storedSourceURL
			) else {
				continue
			}
			
			let sourceChanged: Bool
			if let storedSourceURL {
				sourceChanged = !_matchesStoredRepository(
					storedSourceURL: storedSourceURL,
					sourceURL: best.sourceURL
				)
			} else {
				sourceChanged = false
			}
			
			foundUpdates[localUUID] = AppUpdate(
				id: localUUID,
				localUUID: localUUID,
				localVersion: baselineVersion ?? localApp.version,
				remoteVersion: best.version,
				appName: best.appName,
				bundleIdentifier: localIdentifier,
				remoteBundleIdentifier: best.remoteIdentifier,
				downloadURL: best.downloadURL,
				sourceURL: best.sourceURL,
				sourceName: best.sourceName,
				sourceChanged: sourceChanged,
				matchedByName: matchedByName,
				sourceProvenance: best.provenance
			)
		}
		
		return foundUpdates
	}
	
	private func _bestCandidate(
		from candidates: [RemoteCandidate],
		newerThan localVersion: String?,
		preferredSourceURL: URL?
	) -> RemoteCandidate? {
		let newer = candidates.filter { candidate in
			guard
				let localVersion,
				!localVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
			else {
				return true
			}
			
			guard let comparison = _compareVersions(candidate.version, localVersion) else {
				return false
			}
			return comparison == .orderedDescending
		}
		
		return newer.max { lhs, rhs in
			if let comparison = _compareVersions(lhs.version, rhs.version), comparison != .orderedSame {
				return comparison == .orderedAscending
			}
			
			// For the same version, prefer the repository the app originally came from.
			if let preferredSourceURL {
				let lhsPreferred = _matchesStoredRepository(
					storedSourceURL: preferredSourceURL,
					sourceURL: lhs.sourceURL
				)
				let rhsPreferred = _matchesStoredRepository(
					storedSourceURL: preferredSourceURL,
					sourceURL: rhs.sourceURL
				)
				
				if lhsPreferred != rhsPreferred {
					return !lhsPreferred && rhsPreferred
				}
			}
			
			return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedDescending
		}
	}
	
	private func _compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult? {
		let left = _normalizedVersion(lhs)
		let right = _normalizedVersion(rhs)
		
		if left.caseInsensitiveCompare(right) == .orderedSame {
			return .orderedSame
		}
		
		guard
			left.first?.isNumber == true,
			right.first?.isNumber == true
		else {
			return nil
		}
		
		let leftParts = left.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		let rightParts = right.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
		
		let leftCore = String(leftParts[0])
		let rightCore = String(rightParts[0])
		let coreComparison = leftCore.compare(
			rightCore,
			options: [.numeric, .caseInsensitive]
		)
		
		if coreComparison != .orderedSame {
			return coreComparison
		}
		
		let leftPre = leftParts.count > 1 ? String(leftParts[1]) : nil
		let rightPre = rightParts.count > 1 ? String(rightParts[1]) : nil
		
		switch (leftPre, rightPre) {
		case (nil, nil):
			return .orderedSame
		case (nil, _):
			return .orderedDescending
		case (_, nil):
			return .orderedAscending
		case (let l?, let r?):
			return l.compare(r, options: [.numeric, .caseInsensitive])
		}
	}

	private func _normalizedVersion(_ version: String) -> String {
		var result = version.trimmingCharacters(in: .whitespacesAndNewlines)
		if
			result.count > 1,
			(result.first == "v" || result.first == "V"),
			result.dropFirst().first?.isNumber == true
		{
			result.removeFirst()
		}
		if let plus = result.firstIndex(of: "+") {
			result = String(result[..<plus])
		}
		return result
	}
	
	private func _normalizedAppName(_ name: String?) -> String {
		guard let name else { return "" }
		return name
			.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
			.components(separatedBy: CharacterSet.alphanumerics.inverted)
			.joined()
			.lowercased()
	}
	
	private func _matchesStoredRepository(
		storedSourceURL: URL,
		sourceURL: URL
	) -> Bool {
		_normalizedSourceURL(storedSourceURL) == _normalizedSourceURL(sourceURL)
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
	
	private func _fallbackMetadataCandidate(
		for localApp: AppInfoPresentable,
		localUUID: String,
		candidates: [SourceMetadataCandidate]
	) -> SourceMetadataCandidate? {
		guard
			localApp.isSigned,
			let localIdentifier = localApp.identifier,
			let localVersion = localApp.version
		else {
			return nil
		}
		
		return candidates.first {
			$0.appUUID != localUUID &&
			!$0.app.isSigned &&
			$0.app.identifier == localIdentifier &&
			$0.app.version == localVersion
		}
	}
}

private struct RemoteCandidate {
	let appName: String
	let remoteIdentifier: String
	let version: String
	let downloadURL: URL
	let sourceURL: URL
	let sourceName: String
	let provenance: SourceAppProvenance
}

private struct SourceMetadataCandidate {
	let appUUID: String
	let app: AppInfoPresentable
	let metadata: AppSourceMetadata
}
