//
//  LibraryAppIconView.swift
//  Feather
//
//  Variant-aware Global Updater v2 UI.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct LibraryCellView: View {
	@Environment(\.horizontalSizeClass) private var horizontalSizeClass
	@Environment(\.editMode) private var editMode
	@ObservedObject private var updateManager = UpdateManager.shared
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
				Button("Download \(update.remoteVersion) from \(update.sourceName)", systemImage: "arrow.down.circle") {
					_startUpdateDownload(update)
				}
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			if let update = _signedUpdateConfirmation {
				Text(verbatim: _updateMessage(update))
			}
		}
		.confirmationDialog(
			"Possible Updates — Verify Variant",
			isPresented: $_isReviewCandidatesPresented,
			titleVisibility: .visible
		) {
			ForEach(_reviewCandidates) { candidate in
				Button(
					"\(candidate.appName) \(candidate.remoteVersion) — \(candidate.sourceName)",
					systemImage: "arrow.down.circle"
				) {
					_startUpdateDownload(candidate)
				}
			}
			Button(.localized("Cancel"), role: .cancel) {}
		} message: {
			Text("These apps share the same bundle identifier, but Feather could not prove they are the same mod/variant. Nothing is downloaded unless you choose one.")
		}
	}
	
	private var _desc: String {
		var lines: [String] = []
		
		if let version = app.version, let id = app.identifier {
			lines.append("\(version) • \(id)")
		} else {
			lines.append(.localized("Unknown"))
		}
		
		if
			let uuid = app.uuid,
			let metadata = Storage.shared.sourceMetadata(for: uuid)
		{
			let sourceName =
				metadata.sourceRepositoryName ??
				metadata.sourceRepositoryURL?.host ??
				"Unknown Source"
			let variantName = metadata.sourceAppName ?? app.name
			
			if let variantName, !variantName.isEmpty {
				lines.append("Variant: \(variantName) • \(sourceName)")
			} else {
				lines.append("Source: \(sourceName)")
			}
		}
		
		if let update = updateManager.update(for: app) {
			lines.append("Update: \(update.remoteVersion) • \(update.sourceName)")
		} else {
			let ambiguous = updateManager.ambiguousCandidates(for: app)
			if !ambiguous.isEmpty {
				lines.append("\(ambiguous.count) possible update\(ambiguous.count == 1 ? "" : "s") need review")
			}
		}
		
		return lines.joined(separator: "\n")
	}
	
	private func _updateMessage(_ update: AppUpdate) -> String {
		var lines = [
			"Installed: \(update.localVersion ?? "Unknown")",
			"New: \(update.appName) \(update.remoteVersion)",
			"Source: \(update.sourceName)",
			"Match: \(update.matchKind.rawValue)"
		]
		
		if update.sourceChanged {
			lines.append("Source changed, but the mod/variant identity matched.")
		}
		
		return lines.joined(separator: "\n")
	}
}


// MARK: - Extension: View
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
		if let update = updateManager.update(for: app) {
			Button("Update to \(update.remoteVersion)", systemImage: "arrow.down.circle") {
				if app.isSigned {
					_signedUpdateConfirmation = update
					_isSignedUpdateConfirmationPresented = true
				} else {
					_startUpdateDownload(update)
				}
			}
		}
		
		let ambiguous = updateManager.ambiguousCandidates(for: app)
		if !ambiguous.isEmpty {
			Button("Review \(ambiguous.count) Possible Update\(ambiguous.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle") {
				_reviewCandidates = ambiguous
				_isReviewCandidatesPresented = true
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
			if let update = updateManager.update(for: app) {
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
}
