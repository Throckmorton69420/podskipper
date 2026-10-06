//
//  LibraryAppIconView.swift
//  Feather
//
//  Metadata-aware Global Updater v3 UI.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

struct LibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	@ObservedObject private var updateManager = UpdateManager.shared
	@ObservedObject private var downloadManager = DownloadManager.shared
	@State private var _signedUpdateConfirmation: AppUpdate?
	@State private var _isSignedUpdateConfirmationPresented = false
	@State private var _reviewCandidates: [AppUpdate] = []
	@State private var _isReviewCandidatesPresented = false

	var certInfo: Date.ExpirationInfo? {
		Storage.shared.getCertificate(from: app)?.expiration?.expirationInfo()
	}
	
	var certRevoked: Bool {
		Storage.shared.getCertificate(from: app)?.revoked == true
	}
	
	var app: AppInfoPresentable
	@Binding var selectedInfoAppPresenting: AnyApp?
	@Binding var selectedSigningAppPresenting: AnyApp?
	@Binding var selectedInstallAppPresenting: AnyApp?
	@Binding var selectedAppUUIDs: Set<String>
	
	private var _isSelected: Bool {
		guard let uuid = app.uuid else { return false }
		return selectedAppUUIDs.contains(uuid)
	}
	
	private var _currentUpdateDownload: Download? {
		guard let uuid = app.uuid else { return nil }
		let prefix = "FeatherManualDownload_Update_\(uuid)_"
		return downloadManager.downloads.first { $0.id.hasPrefix(prefix) }
	}
	
	private func _toggleSelection() {
		guard let uuid = app.uuid else { return }
		if selectedAppUUIDs.contains(uuid) {
			selectedAppUUIDs.remove(uuid)
		} else {
			selectedAppUUIDs.insert(uuid)
		}
	}
	
	var body: some View {
		let isRegular = horizontalSizeClass != .compact
		let isEditing = editMode?.wrappedValue == .active
		
		HStack(spacing: 18) {
			if isEditing {
				Button {
					_toggleSelection()
				} label: {
					Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
						.foregroundColor(_isSelected ? .accentColor : .secondary)
						.font(.title2)
				}
				.buttonStyle(.borderless)
			}
			
			_appIcon(for: app)
			
			NBTitleWithSubtitleView(
				title: app.name ?? .localized("Unknown"),
				subtitle: _desc,
				linelimit: 0
			)
			
			if !isEditing {
				_buttonActions(for: app)
			}
		}
		.padding(isRegular ? 12 : 0)
		.background(
			isRegular
				? RoundedRectangle(cornerRadius: 18, style: .continuous)
				.fill(_isSelected && isEditing ? Color.accentColor.opacity(0.1) : Color(.quaternarySystemFill))
				: nil
		)
		.contentShape(Rectangle())
		.onTapGesture {
			if isEditing {
				_toggleSelection()
			}
		}
		.swipeActions {
			if !isEditing {
				_actions(for: app)
			}
		}
		.contextMenu {
			if !isEditing {
				_contextActions(for: app)
				Divider()
				_contextActionsExtra(for: app)
				Divider()
				_actions(for: app)
			}
		}
		.confirmationDialog(
			.localized("Update Available"),
			isPresented: $_isSignedUpdateConfirmationPresented,
			titleVisibility: .visible
		) {
			Button(.localized("Install Current Version"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			if let update = _signedUpdateConfirmation {
				Button(_candidateButtonTitle(update), systemImage: "arrow.down.circle") {
					_startUpdateDownload(update)
				}
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			if let update = _signedUpdateConfirmation {
				Text(verbatim: _updateMessage(update))
			}
		}
		.sheet(isPresented: $_isReviewCandidatesPresented) {
			UpdateCandidateReviewView(
				appName: app.name ?? "App",
				candidates: _reviewCandidates,
				onDownload: { candidate in
					_startUpdateDownload(candidate)
					_isReviewCandidatesPresented = false
				},
				onDismissSuggestions: {
					updateManager.dismissReview(for: app)
					_isReviewCandidatesPresented = false
				}
			)
		}
	}
	
	private var _desc: String {
		var lines: [String] = []
		
		if let version = app.version, let id = app.identifier {
			lines.append("\(version) • \(id)")
		} else {
			lines.append(.localized("Unknown"))
		}
		
		if let detected = updateManager.variantDisplay(for: app) {
			if let evidence = updateManager.variantEvidenceSummary(for: app) {
				lines.append("Detected variant: \(detected) • \(evidence)")
			} else {
				lines.append("Detected variant: \(detected)")
			}
		}
		
		if
			let uuid = app.uuid,
			let metadata = Storage.shared.sourceMetadata(for: uuid)
		{
			let repositoryName =
				metadata.sourceRepositoryName ??
				metadata.sourceRepositoryURL?.host ??
				"Unknown Source"
			let entryName = metadata.sourceAppName ?? app.name ?? "Unknown"
			lines.append("Source entry: \(entryName) • \(repositoryName)")
		}
		
		if let validation = updateManager.binaryValidationDisplay(for: app) {
			if let detail = updateManager.binaryValidationDetail(for: app) {
				lines.append("\(validation) • \(detail)")
			} else {
				lines.append(validation)
			}
		}
		
		if let fingerprintDate = updateManager.fingerprintDate(for: app) {
			lines.append(
				"Fingerprint: " +
				fingerprintDate.formatted(date: .abbreviated, time: .shortened)
			)
		} else if updateManager.needsFingerprint(app) {
			lines.append("Fingerprint: not yet scanned")
		}
		
		if let update = updateManager.update(for: app) {
			let variant = update.variantLabel.map { " • \($0)" } ?? ""
			lines.append("Update: \(update.remoteVersion)\(variant) • \(update.sourceName)")
		} else {
			let ambiguous = updateManager.ambiguousCandidates(for: app)
			if !ambiguous.isEmpty {
				lines.append("\(ambiguous.count) possible update\(ambiguous.count == 1 ? "" : "s") need review")
			}
		}
		
		return lines.joined(separator: "\n")
	}
	
	private func _candidateButtonTitle(_ update: AppUpdate) -> String {
		let variant = update.variantLabel ?? update.appName
		return "\(variant) \(update.remoteVersion) — \(update.sourceName)"
	}
	
	private func _updateMessage(_ update: AppUpdate) -> String {
		var lines = [
			"Installed: \(update.localVersion ?? "Unknown")",
			"Remote source entry: \(update.appName)",
			"New version: \(update.remoteVersion)",
			"Repository: \(update.sourceName)",
			"Match: \(update.matchKind.rawValue)"
		]
		
		if let variant = update.variantLabel {
			lines.append("Detected variant: \(variant)")
		}
		
		if let evidence = update.variantEvidence {
			lines.append("Evidence: \(evidence)")
		}
		
		if update.sourceChanged {
			lines.append("Repository changed, but the extracted variant fingerprint matched.")
		}
		
		return lines.joined(separator: "\n")
	}
}

extension LibraryCellView {
	private func _appIcon(for app: AppInfoPresentable) -> some View {
		FRAppIconView(app: app, size: 57)
			.overlay(alignment: .topTrailing) {
				if updateManager.update(for: app) != nil {
					Image(systemName: "arrow.down.circle.fill")
						.font(.system(size: 18, weight: .semibold))
						.symbolRenderingMode(.palette)
						.foregroundStyle(.white, Color.accentColor)
						.background(
							Circle()
								.fill(Color(.systemBackground))
								.frame(width: 20, height: 20)
						)
						.offset(x: 5, y: -5)
						.accessibilityLabel(.localized("Update Available"))
				} else if !updateManager.ambiguousCandidates(for: app).isEmpty {
					Image(systemName: "exclamationmark.triangle.fill")
						.font(.system(size: 16, weight: .semibold))
						.foregroundStyle(Color.orange)
						.background(
							Circle()
								.fill(Color(.systemBackground))
								.frame(width: 20, height: 20)
						)
						.offset(x: 5, y: -5)
						.accessibilityLabel("Possible update needs review")
				}
			}
	}
	
	@ViewBuilder
	private func _actions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
			Storage.shared.deleteApp(for: app)
		}
	}
	
	@ViewBuilder
	private func _contextActions(for app: AppInfoPresentable) -> some View {
		Button(.localized("Get Info"), systemImage: "info.circle") {
			selectedInfoAppPresenting = AnyApp(base: app)
		}
	}
	
	@ViewBuilder
	private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
		if let download = _currentUpdateDownload {
			Button("Cancel Update Download", systemImage: "xmark.circle", role: .destructive) {
				_cancelUpdateDownload(download)
			}
		}
		
		if let update = updateManager.update(for: app) {
			let variant = update.variantLabel.map { " (\($0))" } ?? ""
			Button("Update to \(update.remoteVersion)\(variant)", systemImage: "arrow.down.circle") {
				if app.isSigned {
					_signedUpdateConfirmation = update
					_isSignedUpdateConfirmationPresented = true
				} else {
					_startUpdateDownload(update)
				}
			}
			Button("Dismiss This Update", systemImage: "eye.slash") {
				updateManager.dismissUpdate(for: app)
			}
		}
		
		let ambiguous = updateManager.ambiguousCandidates(for: app)
		if !ambiguous.isEmpty {
			Button("Review \(ambiguous.count) Possible Update\(ambiguous.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle") {
				_reviewCandidates = ambiguous
				_isReviewCandidatesPresented = true
			}
			Button("Dismiss Review Suggestions", systemImage: "eye.slash") {
				updateManager.dismissReview(for: app)
			}
		}
		
		if app.isSigned {
			if let id = app.identifier {
				Button(.localized("Open"), systemImage: "app.badge.checkmark") {
					UIApplication.openApp(with: id)
				}
			}
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Re-sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Export"), systemImage: "square.and.arrow.up") {
				selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			}
		} else {
			Button(.localized("Install"), systemImage: "square.and.arrow.down") {
				selectedInstallAppPresenting = AnyApp(base: app)
			}
			Button(.localized("Sign"), systemImage: "signature") {
				selectedSigningAppPresenting = AnyApp(base: app)
			}
		}
	}
	
	@ViewBuilder
	private func _buttonActions(for app: AppInfoPresentable) -> some View {
		Group {
			if let download = _currentUpdateDownload {
				Button {
					_cancelUpdateDownload(download)
				} label: {
					FRExpirationPillView(
						title: "Cancel",
						revoked: false,
						expiration: nil
					)
				}
			} else if let update = updateManager.update(for: app) {
				Button {
					if app.isSigned {
						_signedUpdateConfirmation = update
						_isSignedUpdateConfirmationPresented = true
					} else {
						_startUpdateDownload(update)
					}
				} label: {
					FRExpirationPillView(
						title: "Update \(update.remoteVersion)",
						revoked: app.isSigned ? certRevoked : false,
						expiration: app.isSigned ? certInfo : nil
					)
				}
			} else {
				let ambiguous = updateManager.ambiguousCandidates(for: app)
				if !ambiguous.isEmpty {
					Button {
						_reviewCandidates = ambiguous
						_isReviewCandidatesPresented = true
					} label: {
						FRExpirationPillView(
							title: "Review",
							revoked: false,
							expiration: nil
						)
					}
				} else if app.isSigned {
					Button {
						selectedInstallAppPresenting = AnyApp(base: app)
					} label: {
						FRExpirationPillView(
							title: .localized("Install"),
							revoked: certRevoked,
							expiration: certInfo
						)
					}
				} else {
					Button {
						selectedSigningAppPresenting = AnyApp(base: app)
					} label: {
						FRExpirationPillView(
							title: .localized("Sign"),
							revoked: false,
							expiration: nil
						)
					}
				}
			}
		}
		.buttonStyle(.borderless)
	}
	
	private func _startUpdateDownload(_ update: AppUpdate) {
		_ = DownloadManager.shared.startDownload(
			from: update.downloadURL,
			id: "FeatherManualDownload_Update_\(update.localUUID)_\(UUID().uuidString)",
			sourceProvenance: update.sourceProvenance
		)
	}
	
	private func _cancelUpdateDownload(_ download: Download) {
		downloadManager.cancelDownload(download)
	}
}


private struct UpdateCandidateReviewView: View {
	@Environment(\.dismiss) private var dismiss
	
	let appName: String
	let candidates: [AppUpdate]
	let onDownload: (AppUpdate) -> Void
	let onDismissSuggestions: () -> Void
	
	var body: some View {
		NavigationStack {
			List {
				Section {
					Text(
						"These candidates could not be proven to be the same variant from source metadata alone. Expand each candidate before choosing. A downloaded candidate is still binary-fingerprinted before automatic signing or installation."
					)
					.font(.subheadline)
					.foregroundStyle(.secondary)
				}
				
				ForEach(candidates) { candidate in
					DisclosureGroup {
						VStack(alignment: .leading, spacing: 10) {
							_detail("Source entry", candidate.appName)
							_detail("Version", candidate.remoteVersion)
							_detail("Repository", candidate.sourceName)
							_detail(
								"Source confidence",
								"\(candidate.sourceQualityScore)/100 • \(candidate.sourceQualitySummary)"
							)
							_detail("Bundle ID", candidate.bundleIdentifier)
							if let variant = candidate.variantLabel {
								_detail("Detected variant", variant)
							}
							if let evidence = candidate.variantEvidence {
								_detail("Variant evidence", evidence)
							}
							if let developer = candidate.developer {
								_detail("Developer", developer)
							}
							if let date = candidate.versionDate {
								_detail("Updated", date.formatted(date: .abbreviated, time: .omitted))
							}
							if let subtitle = candidate.subtitle, !subtitle.isEmpty {
								_detail("Subtitle", subtitle)
							}
							if let description = candidate.summaryDescription, !description.isEmpty {
								_detail("Description", description)
							}
							if let notes = candidate.releaseNotes, !notes.isEmpty {
								_detail("Release notes", notes)
							}
							_detail("Source URL", candidate.sourceURL.absoluteString)
							_detail("IPA URL", candidate.downloadURL.absoluteString)
							
							Button("Download and Verify This Candidate", systemImage: "arrow.down.circle") {
								onDownload(candidate)
							}
							.buttonStyle(.borderedProminent)
							.padding(.top, 4)
						}
						.padding(.vertical, 6)
					} label: {
						VStack(alignment: .leading, spacing: 3) {
							Text(candidate.variantLabel ?? candidate.appName)
								.font(.headline)
							Text(
								"\(candidate.remoteVersion) • \(candidate.sourceName) • " +
								"source \(candidate.sourceQualityScore)/100"
							)
								.font(.subheadline)
								.foregroundStyle(.secondary)
						}
					}
				}
				
				Section {
					Button("Dismiss These Suggestions", systemImage: "eye.slash") {
						onDismissSuggestions()
					}
					.foregroundStyle(.secondary)
				}
			}
			.navigationTitle("Review \(appName) Updates")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Close") { dismiss() }
				}
			}
		}
	}
	
	@ViewBuilder
	private func _detail(_ title: String, _ value: String) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(title)
				.font(.caption)
				.foregroundStyle(.secondary)
			Text(value)
				.font(.subheadline)
				.textSelection(.enabled)
		}
	}
}
