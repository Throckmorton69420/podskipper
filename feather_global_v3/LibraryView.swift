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
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var updateManager = UpdateManager.shared
	
	@AppStorage("Feather.GlobalUpdater.AutoDownload") private var _autoDownload = false
	@AppStorage("Feather.GlobalUpdater.AutoSign") private var _autoSign = false
	@AppStorage("Feather.GlobalUpdater.AutoInstall") private var _autoInstall = false
	@AppStorage("Feather.GlobalUpdater.CleanupMode") private var _cleanupMode = 1
	@AppStorage("Feather.GlobalUpdater.CheckIntervalHours") private var _checkIntervalHours = 6
	
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
	@State private var _queuedInstallUUIDs: [String] = []
	@State private var _startedUpdateIDs: Set<String> = []
	@State private var _pendingBatchUpdates: [AppUpdate] = []
	@State private var _activeBatchDownloads = 0
	private let _maxConcurrentUpdateDownloads = 3
	
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
		updateManager.ambiguousUpdates.count
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
							
							if !updateManager.updates.isEmpty {
								Button(
									"Download \(updateManager.updates.count) Matched Update\(updateManager.updates.count == 1 ? "" : "s")",
									systemImage: "arrow.down.circle"
								) {
									_downloadAllUpdates()
								}
							}
							
							if _ambiguousAppCount > 0 {
								Button(
									"\(_ambiguousAppCount) App\(_ambiguousAppCount == 1 ? "" : "s") Need Variant Review",
									systemImage: "exclamationmark.triangle"
								) {}
								.disabled(true)
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
							ZStack(alignment: .topTrailing) {
								Image(
									systemName:
										updateManager.isChecking
										? "arrow.triangle.2.circlepath"
										: (!updateManager.updates.isEmpty ? "arrow.down.circle.fill" :
											(_ambiguousAppCount > 0 ? "exclamationmark.triangle.fill" :
												(_isUpdateCheckCompleteVisible ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")))
								)
								.rotationEffect(.degrees(_updateCheckRotation))
								.animation(
									updateManager.isChecking
										? .linear(duration: 0.8).repeatForever(autoreverses: false)
										: .default,
									value: _updateCheckRotation
								)
								
								if !updateManager.updates.isEmpty {
									Text(updateManager.updates.count.description)
										.font(.system(size: 8, weight: .bold, design: .rounded))
										.foregroundStyle(.white)
										.padding(.horizontal, 4)
										.padding(.vertical, 2)
										.background(Capsule().fill(Color.red))
										.offset(x: 8, y: -7)
								}
							}
						}
						.accessibilityLabel("Global Updates")
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
					_presentNextQueuedInstall()
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
						"\(prompt.newName) \(prompt.newVersion) finished downloading. " +
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
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in
				Task { @MainActor in
					try? await Task.sleep(nanoseconds: 500_000_000)
					if let latest = _signedApps.first {
						_enqueueInstall(latest)
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.GlobalUpdater.Imported"))) { notification in
				guard let uuid = notification.object as? String else { return }
				Task { @MainActor in
					try? await Task.sleep(nanoseconds: 450_000_000)
					_handleGlobalUpdateImported(uuid)
				}
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
				await _automaticallyCheckForUpdatesIfNeeded()
			}
		}
	}
}

extension LibraryView {
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
		guard !updateManager.isChecking, _checkIntervalHours > 0 else { return }
		
		let interval = TimeInterval(_checkIntervalHours) * 60 * 60
		if
			let lastCheck = UserDefaults.standard.object(forKey: _automaticCheckKey) as? Date,
			Date().timeIntervalSince(lastCheck) < interval
		{
			return
		}
		
		await _checkForUpdates()
		UserDefaults.standard.set(Date(), forKey: _automaticCheckKey)
	}
	
	private func _downloadAllUpdates() {
		let newUpdates = updateManager.updates.values
			.sorted(by: {
				$0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
			})
			.filter { !_startedUpdateIDs.contains($0.id) }
		
		for update in newUpdates {
			_startedUpdateIDs.insert(update.id)
			_pendingBatchUpdates.append(update)
		}
		
		_pumpUpdateDownloadQueue()
	}
	
	private func _pumpUpdateDownloadQueue() {
		while
			_activeBatchDownloads < _maxConcurrentUpdateDownloads,
			!_pendingBatchUpdates.isEmpty
		{
			let update = _pendingBatchUpdates.removeFirst()
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
			
			if _autoDownload, !updateManager.updates.isEmpty {
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
	private func _handleGlobalUpdateImported(_ uuid: String) {
		// Limit simultaneous IPA download+unpack work. v1 could launch every
		// matched update at once, which is unnecessarily memory-heavy.
		if _activeBatchDownloads > 0 {
			_activeBatchDownloads -= 1
			_pumpUpdateDownloadQueue()
		}
		
		guard let newApp = _importedApps.first(where: { $0.uuid == uuid }) else {
			return
		}
		
		// Persist the exact metadata-derived variant fingerprint that led to this
		// download. This lets later cleanup/sign/install operations distinguish
		// generic "YouTube" / "TikTok" source titles that actually represent
		// YTKACE, YouMod, BHTikTok, VibeTok, etc.
		if
			let metadata = Storage.shared.sourceMetadata(for: uuid),
			let sourceVersionID = metadata.sourceVersionID,
			let candidate = updateManager.updateCandidate(for: sourceVersionID)
		{
			updateManager.rememberVariant(for: uuid, from: candidate)
		}
		
		switch _cleanupMode {
		case 1:
			let oldUUIDs = _olderCopyUUIDs(relativeTo: newApp, includeSigned: false)
			if !oldUUIDs.isEmpty {
				let prompt = GlobalUpdateCleanupPrompt(
					newAppUUID: uuid,
					newName: newApp.name ?? "App",
					newVersion: newApp.version ?? "Unknown",
					oldUUIDs: oldUUIDs
				)
				_enqueueCleanupPrompt(prompt)
			}
		case 2:
			_deleteUUIDs(_olderCopyUUIDs(relativeTo: newApp, includeSigned: false))
		default:
			break
		}
		
		if _autoSign {
			_enqueueAutoSign(uuid)
		}
	}
	
	private func _olderCopyUUIDs(
		relativeTo newApp: AppInfoPresentable,
		includeSigned: Bool
	) -> [String] {
		guard let newVersion = newApp.version else { return [] }
		
		let imported: [AppInfoPresentable] = _importedApps.map { $0 as AppInfoPresentable }
		let signed: [AppInfoPresentable] = includeSigned
			? _signedApps.map { $0 as AppInfoPresentable }
			: []
		
		return (imported + signed).compactMap { candidate in
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
		guard !uuids.isEmpty else { return }
		let set = Set(uuids)
		
		let apps: [AppInfoPresentable] =
			_importedApps.map { $0 as AppInfoPresentable } +
			_signedApps.map { $0 as AppInfoPresentable }
		
		for app in apps {
			if let uuid = app.uuid, set.contains(uuid) {
				Storage.shared.deleteApp(for: app)
			}
		}
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
		guard !_isAutoSigning, let uuid = _autoSignQueue.first else { return }
		
		guard let app = _importedApps.first(where: { $0.uuid == uuid }) else {
			_autoSignQueue.removeFirst()
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
			_processAutoSignQueue()
			return
		}
		
		_isAutoSigning = true
		var options = OptionsManager.shared.options
		options.post_installAppAfterSigned = false
		options.post_deleteAppAfterSigned = false
		
		// Mirror SigningView's per-app identifier/name behavior so automatic
		// signing uses the same selected-certificate and customization rules
		// the user would get by signing manually.
		if
			options.ppqProtection,
			let identifier = app.identifier,
			certificate.ppQCheck
		{
			options.appIdentifier = "\\(identifier).\\(options.ppqString)"
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
		
		FR.signPackageFile(
			app,
			using: options,
			icon: nil,
			certificate: certificate
		) { error in
			Task { @MainActor in
				if let error {
					UIAlertController.showAlertWithOk(
						title: "Auto-sign Failed",
						message: error.localizedDescription
					)
				} else {
					if _cleanupMode == 3 {
						_deleteUUIDs(_olderCopyUUIDs(relativeTo: app, includeSigned: true))
					}
					
					if _autoInstall {
						try? await Task.sleep(nanoseconds: 600_000_000)
						NotificationCenter.default.post(
							name: Notification.Name("Feather.installApp"),
							object: nil
						)
					}
				}
				
				if !_autoSignQueue.isEmpty {
					_autoSignQueue.removeFirst()
				}
				_isAutoSigning = false
				_processAutoSignQueue()
			}
		}
	}
}

// MARK: - Install queue
extension LibraryView {
	private func _enqueueInstall(_ app: Signed) {
		guard let uuid = app.uuid else { return }
		
		if _selectedInstallAppPresenting == nil {
			_selectedInstallAppPresenting = AnyApp(base: app)
			return
		}
		
		guard !_queuedInstallUUIDs.contains(uuid) else { return }
		_queuedInstallUUIDs.append(uuid)
	}
	
	private func _presentNextQueuedInstall() {
		guard !_queuedInstallUUIDs.isEmpty else { return }
		let uuid = _queuedInstallUUIDs.removeFirst()
		
		if let app = _signedApps.first(where: { $0.uuid == uuid }) {
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
				_selectedInstallAppPresenting = AnyApp(base: app)
			}
		} else {
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
