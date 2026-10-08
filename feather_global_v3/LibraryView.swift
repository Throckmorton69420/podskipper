//
//  ContentView.swift
//  Feather
//
//  Global Updater v2:
//  strict variant-aware update workflow, cleanup, auto-sign, and install queue.
//

import SwiftUI
import CoreData
import NimbleViews

private struct GlobalUpdateCleanupPrompt: Identifiable {
	let id = UUID()
	let newAppUUID: String
	let newName: String
	let newVersion: String
	let oldUUIDs: [String]
}

struct LibraryView: View {
	@Environment(\.scenePhase) private var scenePhase
	@State private var _thermalConstrained = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var updateManager = UpdateManager.shared
	
	@AppStorage("Feather.GlobalUpdater.AutoDownload") private var _autoDownload = false
	@AppStorage("Feather.GlobalUpdater.AutoSign") private var _autoSign = false
	@AppStorage("Feather.GlobalUpdater.AutoInstall") private var _autoInstall = false
	@AppStorage("Feather.GlobalUpdater.OlderDownloadPolicy") private var _cleanupPolicy = 0
	@AppStorage("Feather.GlobalUpdater.CheckIntervalHours") private var _checkIntervalHours = 6
	@AppStorage("Feather.GlobalUpdater.FingerprintingEnabled") private var _fingerprintingEnabled = true
	private let _strictSequentialPipeline = true
	
	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	@State private var _alertDownloadString: String = ""
	@State private var _updateCheckRotation = 0.0
	@State private var _isUpdateCheckCompleteVisible = false
	
	@State private var _cleanupPrompt: GlobalUpdateCleanupPrompt?
	@State private var _cleanupPromptQueue: [GlobalUpdateCleanupPrompt] = []
	@State private var _autoSignQueue: [String] = []
	@State private var _isAutoSigning = false
	@State private var _activeVerifications = 0
	@State private var _queuedInstallUUIDs: [String] = []
	@State private var _installSeenUUIDs: Set<String> = []
	@State private var _updaterInstallUUIDs: Set<String> = []
	@State private var _activeInstallUUID: String?
	@State private var _startedUpdateIDs: Set<String> = []
	@State private var _processedUpdateImportUUIDs: Set<String> = []
	@State private var _pendingBatchUpdates: [AppUpdate] = []
	@State private var _activeBatchDownloads = 0
	@State private var _activeUpdateLocalUUID: String?
	
	@State private var _selectedAppUUIDs: Set<String> = []
	@State private var _editMode: EditMode = .inactive
	
	@State private var _searchText = ""
	@State private var _selectedScope: Scope = .all
	
	@Namespace private var _namespace
	
	private let _automaticCheckKey = "Feather.GlobalUpdater.LastAutomaticCheck"
	
	private func filteredAndSortedApps<T>(from apps: FetchedResults<T>) -> [T] where T: NSManagedObject {
		apps.filter {
			_searchText.isEmpty ||
				(($0.value(forKey: "name") as? String)?.localizedCaseInsensitiveContains(_searchText) ?? false)
		}
	}
	
	private var _filteredSignedApps: [Signed] {
		filteredAndSortedApps(from: _signedApps)
	}
	
	private var _filteredImportedApps: [Imported] {
		filteredAndSortedApps(from: _importedApps)
	}
	
	private var _ambiguousAppCount: Int {
		updateManager.visibleReviewCount
	}
	
	private var _matchedUpdateCount: Int {
		updateManager.visibleUpdateCount
	}
	
	private var _effectiveMaxConcurrentDownloads: Int {
		1
	}
	
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>
	
	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>
	
	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>
	
	var body: some View {
		NBNavigationView(.localized("Library")) {
			NBListAdaptable {
				if _thermalConstrained {
					Section { Label("Automatic updates paused while your phone cools", systemImage: "thermometer.medium").font(.footnote) }
				}
				if
					!_filteredSignedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .signed
				{
					NBSection(
						.localized("Signed"),
						secondary: _filteredSignedApps.count.description
					) {
						ForEach(_filteredSignedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								selectedInfoAppPresenting: $_selectedInfoAppPresenting,
								selectedSigningAppPresenting: $_selectedSigningAppPresenting,
								selectedInstallAppPresenting: $_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs
							)
							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						}
					}
				}
				
				if
					!_filteredImportedApps.isEmpty,
					_selectedScope == .all || _selectedScope == .imported
				{
					NBSection(
						.localized("Imported"),
						secondary: _filteredImportedApps.count.description
					) {
						ForEach(_filteredImportedApps, id: \.uuid) { app in
							LibraryCellView(
								app: app,
								selectedInfoAppPresenting: $_selectedInfoAppPresenting,
								selectedSigningAppPresenting: $_selectedSigningAppPresenting,
								selectedInstallAppPresenting: $_selectedInstallAppPresenting,
								selectedAppUUIDs: $_selectedAppUUIDs
							)
							.compatMatchedTransitionSource(id: app.uuid ?? "", ns: _namespace)
						}
					}
				}
			}
			.searchable(text: $_searchText, placement: .platform())
			.compatSearchScopes($_selectedScope) {
				ForEach(Scope.allCases, id: \.displayName) { scope in
					Text(scope.displayName).tag(scope)
				}
			}
			.scrollDismissesKeyboard(.interactively)
			.overlay {
				if _filteredSignedApps.isEmpty, _filteredImportedApps.isEmpty {
					if #available(iOS 17, *) {
						ContentUnavailableView {
							Label(.localized("No Apps"), systemImage: "questionmark.app.fill")
						} description: {
							Text(.localized("Get started by importing your first IPA file."))
						} actions: {
							Menu {
								_importActions()
							} label: {
								NBButton(.localized("Import"), style: .text)
							}
						}
					}
				}
			}
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					EditButton()
				}
				
				if _editMode.isEditing {
					NBToolbarButton(
						.localized("Delete"),
						systemImage: "trash",
						isDisabled: _selectedAppUUIDs.isEmpty
					) {
						_bulkDeleteSelectedApps()
					}
				} else {
					ToolbarItem(placement: .topBarTrailing) {
						Menu {
							Button("Check All Sources", systemImage: "arrow.triangle.2.circlepath") {
								Task {
									await _checkForUpdates()
								}
							}
							.disabled(updateManager.isChecking)
							
							if updateManager.isFingerprinting {
								Button(
									"Fingerprinting \(updateManager.fingerprintCompleted)/\(updateManager.fingerprintTotal)",
									systemImage: "waveform.path.ecg"
								) {}
								.disabled(true)
								
								if let current = updateManager.fingerprintCurrentApp {
									Button(current, systemImage: "hourglass") {}
										.disabled(true)
								}
								
								Button("Cancel Fingerprinting", systemImage: "xmark.circle", role: .destructive) {
									updateManager.cancelFingerprinting()
								}
							} else {
								Button("Prepare Library Fingerprints", systemImage: "waveform.path.ecg.rectangle") {
									updateManager.startFingerprintLibrary(
										apps: _allLibraryApps()
									)
								}
								
								let cached = updateManager.cachedFingerprintCount(for: _allLibraryApps())
								Button(
									"Previously scanned: \(cached)/\(_allLibraryApps().count)",
									systemImage: "checkmark.shield"
								) {}
								.disabled(true)
								
								if let lastRun = updateManager.fingerprintLastRunDate {
									Button(
										"Last fingerprint pass: \(lastRun.formatted(date: .abbreviated, time: .shortened))",
										systemImage: "clock"
									) {}
									.disabled(true)
								}
							}
							
							if _matchedUpdateCount > 0 {
								Button(
									"Download \(_matchedUpdateCount) Matched Update\(_matchedUpdateCount == 1 ? "" : "s")",
									systemImage: "arrow.down.circle"
								) {
									_downloadAllUpdates()
								}
								
								Button("Dismiss Matched Updates", systemImage: "eye.slash") {
									updateManager.dismissAllUpdates()
								}
							}
							
							if _ambiguousAppCount > 0 {
								Button(
									"\(_ambiguousAppCount) App\(_ambiguousAppCount == 1 ? "" : "s") Need Variant Review",
									systemImage: "exclamationmark.triangle"
								) {}
								.disabled(true)
								
								Button("Dismiss Review Suggestions", systemImage: "eye.slash") {
									updateManager.dismissAllReviews()
								}
							}
							
							if let lastChecked = updateManager.lastCheckedDate {
								Section {
									Button(
										"Last check: \(lastChecked.formatted(date: .omitted, time: .shortened)) • \(updateManager.checkedSourceCount) sources" +
										(updateManager.failedSourceCount > 0 ? " • \(updateManager.failedSourceCount) failed" : "")
									) {}
									.disabled(true)
								}
							}
						} label: {
							_toolbarUpdaterStatusLabel()
						}
						.accessibilityLabel(
							"Global Updates: \(_matchedUpdateCount) matched, \(_ambiguousAppCount) need review"
						)
					}
					
					NBToolbarMenu(
						systemImage: "plus",
						style: .icon,
						placement: .topBarTrailing
					) {
						_importActions()
					}
				}
			}
			.environment(\.editMode, $_editMode)
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(
				item: $_selectedInstallAppPresenting,
				onDismiss: {
					let dismissedUUID = _activeInstallUUID
					_activeInstallUUID = nil
					
					// InstallPreview posts a terminal success/failure event first.
					// If the user manually dismisses before that happens, treat it
					// as a cancellation and release the serialized pipeline exactly once.
					if
						let dismissedUUID,
						_updaterInstallUUIDs.remove(dismissedUUID) != nil,
						_strictSequentialPipeline
					{
						_pumpUpdateDownloadQueue()
					}
					
					_presentNextQueuedInstall()
					_processAutoSignQueue()
				}
			) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.fullScreenCover(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
					.compatNavigationTransition(id: app.base.uuid ?? "", ns: _namespace)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						
						for url in urls {
							let id = "FeatherManualDownload_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							try? downloadManager.handlePachageFile(url: url, dl: dl)
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert(.localized("Import from URL"), isPresented: $_isDownloadingPresenting) {
				TextField(.localized("URL"), text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button(.localized("Cancel"), role: .cancel) {
					_alertDownloadString = ""
				}
				Button(.localized("OK")) {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(
							from: url,
							id: "FeatherManualDownload_\(UUID().uuidString)"
						)
					}
				}
			}
			.alert(item: $_cleanupPrompt) { prompt in
				Alert(
					title: Text("Delete Older IPA?"),
					message: Text(
						"\(prompt.newName) \(prompt.newVersion) is ready. " +
						"Delete \(prompt.oldUUIDs.count) older imported cop\(prompt.oldUUIDs.count == 1 ? "y" : "ies") from Feather's Library? Signed copies are preserved."
					),
					primaryButton: .destructive(Text("Delete Older")) {
						_deleteUUIDs(prompt.oldUUIDs)
						_advanceCleanupPrompt()
					},
					secondaryButton: .cancel(Text("Keep")) {
						_advanceCleanupPrompt()
					}
				)
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.GlobalUpdater.Imported"))) { notification in
				guard let uuid = notification.object as? String else { return }
				let downloadID = notification.userInfo?["downloadID"] as? String
				Task { @MainActor in
					try? await Task.sleep(nanoseconds: 250_000_000)
					await _handleGlobalUpdateImported(uuid, downloadID: downloadID)
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.GlobalUpdater.QueueUpdate"))) { notification in
				guard let update = notification.object as? AppUpdate else { return }
				_queueUpdate(update)
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.GlobalUpdater.CancelQueuedUpdate"))) { notification in
				guard let uuid = notification.object as? String else { return }
				_pendingBatchUpdates.removeAll { $0.localUUID == uuid }
				_startedUpdateIDs = Set(_startedUpdateIDs.filter { !$0.hasPrefix(uuid + "|") })
				updateManager.forgetQueuedCandidate(localUUID: uuid)
				_pumpUpdateDownloadQueue()
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.GlobalUpdater.InstallFinished"))) { notification in
				guard let uuid = notification.object as? String else { return }
				let success = notification.userInfo?["success"] as? Bool ?? false
				let confirmedForSignedCleanup =
					notification.userInfo?["confirmedForSignedCleanup"] as? Bool ?? false
				
				guard _updaterInstallUUIDs.remove(uuid) != nil else {
					return
				}
				
				if success, confirmedForSignedCleanup,
					let signed = _signedApps.first(where: { $0.uuid == uuid })
				{
					_applyOlderDownloadPolicy(relativeTo: signed)
				}
				
				if _activeInstallUUID == uuid {
					_activeInstallUUID = nil
				}
				
				if _strictSequentialPipeline {
					_pumpUpdateDownloadQueue()
				}
				_processAutoSignQueue()
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.GlobalUpdater.DownloadTerminated"))) { notification in
				guard
					let downloadID = notification.object as? String,
					let uuid = _localUUID(fromUpdateDownloadID: downloadID)
				else {
					return
				}
				
				if let error = notification.userInfo?["error"] as? String {
					UIAlertController.showAlertWithOk(
						title: "Update Download Failed",
						message: error
					)
				}

				let wasBatchDownload = _startedUpdateIDs.contains {
					$0.hasPrefix(uuid + "|")
				}
				
				guard wasBatchDownload else {
					// A manually selected review candidate can use the same updater
					// download ID format. It must not consume a batch-concurrency slot.
					return
				}
				
				_pendingBatchUpdates.removeAll { $0.localUUID == uuid }
				updateManager.forgetQueuedCandidate(localUUID: uuid)
				_startedUpdateIDs = Set(
					_startedUpdateIDs.filter { !$0.hasPrefix(uuid + "|") }
				)
				
				if _activeBatchDownloads > 0 {
					_activeBatchDownloads -= 1
				}
				_pumpUpdateDownloadQueue()
			}
			.onChange(of: _editMode) { mode in
				if mode == .inactive {
					_selectedAppUUIDs.removeAll()
				}
			}
			.onChange(of: updateManager.isChecking) { isChecking in
				_handleUpdateCheckStateChange(isChecking)
			}
			.task {
				UpdaterRuntimePolicy.migrate(UserDefaults.standard)
				UpdaterActivityState.shared.setActive(scenePhase == .active)
				await _automaticallyCheckForUpdatesIfNeeded()
			}
			.onChange(of: scenePhase) { phase in
				UpdaterActivityState.shared.setActive(phase == .active)
				if phase != .active { updateManager.cancelFingerprinting() }
				else { _pumpUpdateDownloadQueue(); _processAutoSignQueue() }
			}
			.onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
				let thermal = ProcessInfo.processInfo.thermalState
				_thermalConstrained = thermal == .serious || thermal == .critical
				if !_thermalConstrained { _pumpUpdateDownloadQueue(); _processAutoSignQueue() }
			}
		}
	}
}

extension LibraryView {
	@ViewBuilder
	private func _toolbarUpdaterStatusLabel() -> some View {
		if updateManager.isChecking {
			Image(systemName: "arrow.triangle.2.circlepath")
				.rotationEffect(.degrees(_updateCheckRotation))
				.animation(
					.linear(duration: 0.8).repeatForever(autoreverses: false),
					value: _updateCheckRotation
				)
		} else {
			HStack(spacing: 7) {
				if _matchedUpdateCount > 0 {
					_updaterBadge(
						systemImage: "arrow.down.circle.fill",
						count: _matchedUpdateCount,
						badgeColor: .red
					)
				}
				
				if _ambiguousAppCount > 0 {
					_updaterBadge(
						systemImage: "exclamationmark.triangle.fill",
						count: _ambiguousAppCount,
						badgeColor: .orange
					)
				}
				
				if _matchedUpdateCount == 0, _ambiguousAppCount == 0 {
					Image(
						systemName: _isUpdateCheckCompleteVisible
							? "checkmark.circle.fill"
							: "arrow.triangle.2.circlepath"
					)
				}
			}
		}
	}
	
	private func _updaterBadge(
		systemImage: String,
		count: Int,
		badgeColor: Color
	) -> some View {
		ZStack(alignment: .topTrailing) {
			Image(systemName: systemImage)
			Text(count.description)
				.font(.system(size: 8, weight: .bold, design: .rounded))
				.foregroundStyle(.white)
				.padding(.horizontal, 4)
				.padding(.vertical, 2)
				.background(Capsule().fill(badgeColor))
				.offset(x: 8, y: -7)
		}
	}
	
	@ViewBuilder
	private func _importActions() -> some View {
		Button(.localized("Import from Files"), systemImage: "folder") {
			_isImportingPresenting = true
		}
		Button(.localized("Import from URL"), systemImage: "globe") {
			_isDownloadingPresenting = true
		}
	}
}

extension LibraryView {
	private func _bulkDeleteSelectedApps() {
		let selectedApps = _getAllApps().filter { app in
			guard let uuid = app.uuid else { return false }
			return _selectedAppUUIDs.contains(uuid)
		}
		
		for app in selectedApps {
			Storage.shared.deleteApp(for: app)
		}
		
		_selectedAppUUIDs.removeAll()
	}
	
	private func _allLibraryApps() -> [AppInfoPresentable] {
		_signedApps.map { $0 as AppInfoPresentable } +
		_importedApps.map { $0 as AppInfoPresentable }
	}
	
	private func _getAllApps() -> [AppInfoPresentable] {
		var allApps: [AppInfoPresentable] = []
		
		if _selectedScope == .all || _selectedScope == .signed {
			allApps.append(contentsOf: _filteredSignedApps)
		}
		
		if _selectedScope == .all || _selectedScope == .imported {
			allApps.append(contentsOf: _filteredImportedApps)
		}
		
		return allApps
	}
	
	private func _checkForUpdates() async {
		let localApps =
			_signedApps.map { $0 as AppInfoPresentable } +
			_importedApps.map { $0 as AppInfoPresentable }
		
		await updateManager.checkForUpdates(
			sources: Array(_sources),
			localApps: localApps
		)
		
	}
	
	private func _automaticallyCheckForUpdatesIfNeeded() async {
		guard !updateManager.isChecking, _checkIntervalHours > 0, !_thermalConstrained, scenePhase == .active else { return }
		
		let interval = TimeInterval(_checkIntervalHours) * 60 * 60
		if
			let lastCheck = UserDefaults.standard.object(forKey: _automaticCheckKey) as? Date,
			Date().timeIntervalSince(lastCheck) < interval
		{
			return
		}
		
		await _checkForUpdates()
		guard !Task.isCancelled, updateManager.lastCheckCompleted else { return }
		UserDefaults.standard.set(Date(), forKey: _automaticCheckKey)
	}
	
	private func _localUUID(fromUpdateDownloadID id: String) -> String? {
		let prefix = "FeatherManualDownload_Update_"
		guard id.hasPrefix(prefix) else { return nil }
		
		let remainder = String(id.dropFirst(prefix.count))
		guard remainder.count >= 36 else { return nil }
		let candidate = String(remainder.prefix(36))
		guard UUID(uuidString: candidate) != nil else { return nil }
		return candidate
	}
	
	private func _downloadAllUpdates() {
		let newUpdates = updateManager.visibleUpdates
			.sorted(by: {
				$0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
			})
			.filter { !_startedUpdateIDs.contains($0.id) }
		
		for update in newUpdates {
			_queueUpdate(update)
		}
		
		_pumpUpdateDownloadQueue()
	}

	private func _queueUpdate(_ update: AppUpdate) {
		let pipelineBusy = _activeBatchDownloads > 0 || _activeVerifications > 0 || _isAutoSigning ||
			!_autoSignQueue.isEmpty || _activeInstallUUID != nil || !_queuedInstallUUIDs.isEmpty
		guard !(pipelineBusy && _activeUpdateLocalUUID == update.localUUID) else { return }
		guard !_startedUpdateIDs.contains(where: { $0.hasPrefix(update.localUUID + "|") }) else { return }
		_startedUpdateIDs.insert(update.id)
		updateManager.markQueued(update)
		_pendingBatchUpdates.append(update)
		_pumpUpdateDownloadQueue()
	}
	
	private func _pumpUpdateDownloadQueue() {
		guard _activeBatchDownloads == 0, !_thermalConstrained, scenePhase == .active, !_isAutoSigning, _activeInstallUUID == nil,
			_activeVerifications == 0, _autoSignQueue.isEmpty, _queuedInstallUUIDs.isEmpty else { return }
		_activeUpdateLocalUUID = nil
		while
			_activeBatchDownloads < _effectiveMaxConcurrentDownloads,
			!_pendingBatchUpdates.isEmpty
		{
			let update = _pendingBatchUpdates.removeFirst()
			_activeUpdateLocalUUID = update.localUUID
			updateManager.markDownloadStarted(update)
			_activeBatchDownloads += 1
			
			_ = downloadManager.startDownload(
				from: update.downloadURL,
				id: "FeatherManualDownload_Update_\(update.localUUID)_\(UUID().uuidString)",
				sourceProvenance: update.sourceProvenance
			)
		}
	}
	
	private func _handleUpdateCheckStateChange(_ isChecking: Bool) {
		if isChecking {
			_isUpdateCheckCompleteVisible = false
			_updateCheckRotation = 0
			withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
				_updateCheckRotation = 360
			}
		} else {
			withAnimation(.none) {
				_updateCheckRotation = 0
			}
			
			_isUpdateCheckCompleteVisible = true
			
			if _autoDownload, updateManager.lastCheckCompleted, _matchedUpdateCount > 0 {
				_downloadAllUpdates()
			}
			
			Task { @MainActor in
				try? await Task.sleep(nanoseconds: 900_000_000)
				if !updateManager.isChecking {
					_isUpdateCheckCompleteVisible = false
				}
			}
		}
	}
}

// MARK: - Update import cleanup / automation
extension LibraryView {
	private func _handleGlobalUpdateImported(
		_ uuid: String,
		downloadID: String?
	) async {
		_activeVerifications += 1
		defer { _activeVerifications -= 1; _pumpUpdateDownloadQueue() }
		let queuedLocalUUID = downloadID.flatMap(_localUUID(fromUpdateDownloadID:))
		let wasQueuedBatchDownload = queuedLocalUUID.map { localUUID in
			_startedUpdateIDs.contains(where: { $0.hasPrefix(localUUID + "|") })
		} ?? false
		
		if wasQueuedBatchDownload {
			if _activeBatchDownloads > 0 {
				_activeBatchDownloads -= 1
			}
			
			if let queuedLocalUUID {
				_startedUpdateIDs = Set(
					_startedUpdateIDs.filter { !$0.hasPrefix(queuedLocalUUID + "|") }
				)
			}
			
			if !_strictSequentialPipeline {
				_pumpUpdateDownloadQueue()
			}
		}
		
		guard let newApp = await _waitForImportedApp(uuid: uuid) else {
			UIAlertController.showAlertWithOk(
				title: "Update Import Incomplete",
				message: "The IPA finished unpacking, but Feather could not confirm its new Library entry. Automatic cleanup, signing, and installation were stopped."
			)
			if _strictSequentialPipeline, wasQueuedBatchDownload {
				_pumpUpdateDownloadQueue()
			}
			return
		}
		
		guard let update = updateManager.updateCandidate(forImportedUUID: uuid) else {
			UIAlertController.showAlertWithOk(
				title: "Update Needs Review",
				message: "Feather could not reconnect this downloaded IPA to the exact update candidate that requested it. The IPA was kept in Library, but automatic cleanup, signing, and installation were stopped."
			)
			if _strictSequentialPipeline, wasQueuedBatchDownload {
				_pumpUpdateDownloadQueue()
			}
			return
		}
		defer { updateManager.forgetQueuedCandidate(localUUID: update.localUUID) }
		
		guard _processedUpdateImportUUIDs.insert(uuid).inserted else {
			return
		}
		
		// Download completion resolves the source suggestion immediately. Any
		// later fingerprint warning is attached to the imported IPA itself.
		updateManager.resolveUpdate(localUUID: update.localUUID)
		
		let allExistingApps: [AppInfoPresentable] =
			_signedApps.map { $0 as AppInfoPresentable } +
			_importedApps
				.filter { $0.uuid != uuid }
				.map { $0 as AppInfoPresentable }
		
		guard let originalApp = allExistingApps.first(where: { $0.uuid == update.localUUID }) else {
			UIAlertController.showAlertWithOk(
				title: "Update Needs Review",
				message: "The original Library entry for \(update.appName) could not be located. The new IPA was kept in Library, but automatic cleanup, signing, and installation were stopped."
			)
			if _strictSequentialPipeline, wasQueuedBatchDownload {
				_pumpUpdateDownloadQueue()
			}
			return
		}
		
		guard _fingerprintingEnabled else {
			if _autoSign || _autoInstall {
				UIAlertController.showAlertWithOk(
					title: "Binary Verification Disabled",
					message: "\(update.appName) \(update.remoteVersion) was downloaded and kept in Library. Automatic cleanup, signing, and installation were stopped because binary fingerprinting is disabled."
				)
			}
			if _strictSequentialPipeline, wasQueuedBatchDownload {
				_pumpUpdateDownloadQueue()
			}
			return
		}

		let binaryValidation = await updateManager.validateDownloadedUpdate(
			original: originalApp,
			downloaded: newApp,
			update: update
		)

		guard binaryValidation.disposition == .verified else {
			let title =
				binaryValidation.disposition == .rejected
				? "Binary Fingerprint Mismatch"
				: "Binary Fingerprint Needs Review"

			UIAlertController.showAlertWithOk(
				title: title,
				message:
					"\(update.appName) \(update.remoteVersion) was downloaded, but Feather did not automatically clean up, sign, or install it. " +
					binaryValidation.summary +
					" A match only confirms continuity with the Library app; it is not a malware or source-trust guarantee. You can inspect the IPA and sign it manually if you determine it is correct."
			)
			if _strictSequentialPipeline, wasQueuedBatchDownload {
				_pumpUpdateDownloadQueue()
			}
			return
		}
		
		updateManager.rememberVariant(for: uuid, from: update)

		// Old packages are retained until the exact replacement is signed (or,
		// when auto-install is enabled, until direct installation is confirmed).
		if _autoSign {
			_enqueueAutoSign(uuid)
		} else if _strictSequentialPipeline, wasQueuedBatchDownload {
			_pumpUpdateDownloadQueue()
		}
	}

	private func _waitForImportedApp(uuid: String) async -> Imported? {
		for _ in 0..<50 {
			if let app = _importedApps.first(where: { $0.uuid == uuid }) {
				return app
			}
			if Task.isCancelled { return nil }
			try? await Task.sleep(nanoseconds: 100_000_000)
		}
		return nil
	}

	private func _applyOlderDownloadPolicy(relativeTo app: AppInfoPresentable) {
		guard let policy = OlderDownloadPolicy(rawValue: _cleanupPolicy), policy != .keep else { return }
		let oldUUIDs = _olderCopyUUIDs(relativeTo: app)
		guard !oldUUIDs.isEmpty else { return }
		if policy == .remove {
			_deleteUUIDs(oldUUIDs)
		} else if let uuid = app.uuid {
			_enqueueCleanupPrompt(GlobalUpdateCleanupPrompt(newAppUUID: uuid,
				newName: app.name ?? "App", newVersion: app.version ?? "Unknown", oldUUIDs: oldUUIDs))
		}
	}

	private func _olderCopyUUIDs(
		relativeTo newApp: AppInfoPresentable
	) -> [String] {
		guard let newVersion = newApp.version else { return [] }
		
		let imported: [AppInfoPresentable] = _importedApps.map { $0 as AppInfoPresentable }
		return imported.compactMap { candidate in
			guard
				candidate.uuid != newApp.uuid,
				let uuid = candidate.uuid,
				let oldVersion = candidate.version,
				updateManager.sameVariant(newApp, candidate),
				_isOlderVersion(oldVersion, than: newVersion)
			else {
				return nil
			}
			return uuid
		}
	}
	
	private func _isOlderVersion(_ lhs: String, than rhs: String) -> Bool {
		func normalized(_ value: String) -> String {
			var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
			if
				result.count > 1,
				(result.first == "v" || result.first == "V"),
				result.dropFirst().first?.isNumber == true
			{
				result.removeFirst()
			}
			return result
		}
		
		let left = normalized(lhs)
		let right = normalized(rhs)
		guard left.first?.isNumber == true, right.first?.isNumber == true else {
			return false
		}
		
		return left.compare(right, options: [.numeric, .caseInsensitive]) == .orderedAscending
	}
	
	private func _deleteUUIDs(_ uuids: [String]) {
		let targets = Set(uuids)
		let imported = _importedApps.filter { $0.uuid.map(targets.contains) ?? false }
		Task { await updateManager.removeOlderUnsigned(imported) }
	}

	private func _enqueueCleanupPrompt(_ prompt: GlobalUpdateCleanupPrompt) {
		if _cleanupPrompt == nil {
			_cleanupPrompt = prompt
		} else {
			_cleanupPromptQueue.append(prompt)
		}
	}
	
	private func _advanceCleanupPrompt() {
		if _cleanupPromptQueue.isEmpty {
			_cleanupPrompt = nil
		} else {
			_cleanupPrompt = _cleanupPromptQueue.removeFirst()
		}
	}
	
	private func _enqueueAutoSign(_ uuid: String) {
		guard !_autoSignQueue.contains(uuid) else { return }
		_autoSignQueue.append(uuid)
		_processAutoSignQueue()
	}
	
	private func _processAutoSignQueue() {
		guard
			!_thermalConstrained, scenePhase == .active,
			!_isAutoSigning,
			_activeInstallUUID == nil,
			let uuid = _autoSignQueue.first
		else {
			return
		}
		
		guard let app = _importedApps.first(where: { $0.uuid == uuid }) else {
			_autoSignQueue.removeFirst()
			if _strictSequentialPipeline { _pumpUpdateDownloadQueue() }
			_processAutoSignQueue()
			return
		}
		
		let certificateIndex = UserDefaults.standard.integer(forKey: "feather.selectedCert")
		guard let certificate = Storage.shared.getCertificate(for: certificateIndex) else {
			_autoSignQueue.removeFirst()
			UIAlertController.showAlertWithOk(
				title: "Global Updater",
				message: "Auto-sign is enabled, but Feather has no selected signing certificate."
			)
			if _strictSequentialPipeline { _pumpUpdateDownloadQueue() }
			_processAutoSignQueue()
			return
		}
		
		_isAutoSigning = true
		var options = OptionsManager.shared.options
		options.post_installAppAfterSigned = false
		options.post_deleteAppAfterSigned = false
		
		if
			options.ppqProtection,
			let identifier = app.identifier,
			certificate.ppQCheck
		{
			options.appIdentifier = "\(identifier).\(options.ppqString)"
		}
		
		if
			let identifier = app.identifier,
			let mappedIdentifier = options.identifiers[identifier]
		{
			options.appIdentifier = mappedIdentifier
		}
		
		if
			let name = app.name,
			let mappedName = options.displayNames[name]
		{
			options.appName = mappedName
		}
		
		FR.signPackageFileReturningUUID(
			app,
			using: options,
			icon: nil,
			certificate: certificate
		) { signedUUID, error in
			Task { @MainActor in
				var shouldAdvanceStrictPipeline = false

				if let error {
					UIAlertController.showAlertWithOk(
						title: "Auto-sign Failed",
						message: error.localizedDescription
					)
					shouldAdvanceStrictPipeline = true
				} else if let signedUUID, let signed = await _waitForSignedCopy(uuid: signedUUID) {
					if _autoInstall {
						_enqueueInstall(signed, updaterManaged: true)
					} else {
						_applyOlderDownloadPolicy(relativeTo: signed)
						shouldAdvanceStrictPipeline = true
					}
				} else {
					UIAlertController.showAlertWithOk(title: "Update Paused",
						message: "The exact signed replacement could not be located. Installation and cleanup were stopped; all older copies were kept.")
					shouldAdvanceStrictPipeline = true
				}
				
				if !_autoSignQueue.isEmpty {
					_autoSignQueue.removeFirst()
				}
				_isAutoSigning = false
				if shouldAdvanceStrictPipeline, _strictSequentialPipeline {
					_pumpUpdateDownloadQueue()
				}
				_processAutoSignQueue()
			}
		}
	}
	
	private func _waitForSignedCopy(uuid: String) async -> Signed? {
		for _ in 0..<100 {
			if Task.isCancelled { return nil }
			if let match = _signedApps.first(where: { $0.uuid == uuid }) {
				return match
			}
			
			try? await Task.sleep(nanoseconds: 200_000_000)
		}
		
		return nil
	}
}

// MARK: - Install queue
extension LibraryView {
	private func _enqueueInstall(
		_ app: Signed,
		updaterManaged: Bool = false
	) {
		guard let uuid = app.uuid else { return }
		guard !_installSeenUUIDs.contains(uuid) else { return }
		
		_installSeenUUIDs.insert(uuid)
		if updaterManaged {
			_updaterInstallUUIDs.insert(uuid)
		}
		
		if _selectedInstallAppPresenting == nil {
			_activeInstallUUID = uuid
			_selectedInstallAppPresenting = AnyApp(base: app)
			return
		}
		
		_queuedInstallUUIDs.append(uuid)
	}
	
	private func _presentNextQueuedInstall() {
		guard !_queuedInstallUUIDs.isEmpty else { return }
		let uuid = _queuedInstallUUIDs.removeFirst()
		
		if let app = _signedApps.first(where: { $0.uuid == uuid }) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
				_activeInstallUUID = uuid
				_selectedInstallAppPresenting = AnyApp(base: app)
			}
		} else {
			let wasUpdaterManaged = _updaterInstallUUIDs.remove(uuid) != nil
			if wasUpdaterManaged, _strictSequentialPipeline {
				_pumpUpdateDownloadQueue()
			}
			_presentNextQueuedInstall()
		}
	}
}

extension LibraryView {
	enum Scope: CaseIterable {
		case all
		case signed
		case imported
		
		var displayName: String {
			switch self {
			case .all: return .localized("All")
			case .signed: return .localized("Signed")
			case .imported: return .localized("Imported")
			}
		}
	}
}
