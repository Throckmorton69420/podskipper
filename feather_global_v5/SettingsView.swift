//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import NimbleViews
import UIKit
import Darwin
import IDeviceSwift

// MARK: - View
struct SettingsView: View {
	@AppStorage("feather.selectedCert") private var _storedSelectedCert: Int = 0
	@State private var _currentIcon: String? = UIApplication.shared.alternateIconName
	
	// MARK: Fetch
	@FetchRequest(
		entity: CertificatePair.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \CertificatePair.date, ascending: false)],
		animation: .snappy
	) private var _certificates: FetchedResults<CertificatePair>
	
	private var selectedCertificate: CertificatePair? {
		guard
			_storedSelectedCert >= 0,
			_storedSelectedCert < _certificates.count
		else {
			return nil
		}
		return _certificates[_storedSelectedCert]
	}

    
	private let _donationsUrl = "https://github.com/sponsors/claration"
	private let _githubUrl = "https://github.com/claration/Feather"
    
	// MARK: Body
	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				#if !NIGHTLY && !DEBUG
					SettingsDonationCellView(site: _donationsUrl)
				#endif
                
				_feedback()
                
				Section {
					NavigationLink(destination: AppearanceView()) {
						Label(.localized("Appearance"), systemImage: "paintbrush")
					}
					NavigationLink(destination: AppIconView(currentIcon: $_currentIcon)) {
						Label(.localized("App Icon"), systemImage: "app.badge")
					}
				}
                
				NBSection(.localized("Certificates")) {
                    
					if let cert = selectedCertificate {
						CertificatesCellView(cert: cert)
					} else {
						Text(.localized("No Certificate"))
							.font(.footnote)
							.foregroundColor(.disabled())
					}
					NavigationLink(destination: CertificatesView()) {
						Label(.localized("Certificates"), systemImage: "checkmark.seal")
					}
                 
				} footer: {
					Text(.localized("Add and manage certificates used for signing applications."))
				}
                
				NBSection(.localized("Features")) {
					NavigationLink(destination: ConfigurationView()) {
						Label(.localized("Signing Options"), systemImage: "signature")
					}
					NavigationLink(destination: ArchiveView()) {
						Label(.localized("Archive & Compression"), systemImage: "archivebox")
					}
					NavigationLink(destination: InstallationView()) {
						Label(.localized("Installation"), systemImage: "arrow.down.circle")
					}
					NavigationLink(destination: GlobalUpdaterSettingsView()) {
						Label("Global Updater", systemImage: "arrow.triangle.2.circlepath.circle")
					}
				} footer: {
					Text(.localized("Configure the apps way of installing, its zip compression levels, and custom modifications to apps."))
				}
                
				_directories()
                
				Section {
					NavigationLink(destination: ResetView()) {
						Label(.localized("Reset"), systemImage: "trash")
					}
				} footer: {
					Text(.localized("Reset the applications sources, certificates, apps, and general contents."))
				}
			}
		}
	}
}

// MARK: - View extension
extension SettingsView {
	@ViewBuilder
	private func _feedback() -> some View {
		Section {
			NavigationLink(destination: AboutView()) {
				Label {
					Text(verbatim: .localized("About %@", arguments: Bundle.main.name))
				} icon: {
					FRAppIconView(size: 23)
				}
			}
            
			Button(.localized("Submit Feedback"), systemImage: "safari") {
				UIApplication.open(URL(string: "\(_githubUrl)/issues/new/choose")!)
			}
			Button(.localized("GitHub Repository"), systemImage: "safari") {
				UIApplication.open(_githubUrl)
			}
		} footer: {
			Text(.localized("If any issues occur within the app please report it via the GitHub repository. When submitting an issue, make sure to submit detailed information."))
		}
	}
    
	@ViewBuilder
	private func _directories() -> some View {
		NBSection(.localized("Misc")) {
			Button(.localized("Open Documents"), systemImage: "folder") {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Archives"), systemImage: "folder") {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			}
			Button(.localized("Open Certificates"), systemImage: "folder") {
				UIApplication.open(FileManager.default.certificates.toSharedDocumentsURL()!)
			}
		} footer: {
			Text(.localized("All of the apps files are contained in the documents directory, here are some quick links to these."))
		}
	}
}


// MARK: - Global Updater
private struct GlobalUpdaterSettingsView: View {
	@StateObject private var updateManager = UpdateManager.shared
	
	@AppStorage("Feather.GlobalUpdater.CheckIntervalHours") private var checkIntervalHours = 6
	@AppStorage("Feather.GlobalUpdater.AutoDownload") private var autoDownload = false
	@AppStorage("Feather.GlobalUpdater.AutoSign") private var autoSign = false
	@AppStorage("Feather.GlobalUpdater.AutoInstall") private var autoInstall = false
	@AppStorage("Feather.GlobalUpdater.CleanupMode") private var cleanupMode = 1
	
	@AppStorage("Feather.GlobalUpdater.FingerprintingEnabled") private var fingerprintingEnabled = true
	@AppStorage("Feather.GlobalUpdater.AutoFingerprint") private var autoFingerprint = false
	@AppStorage("Feather.GlobalUpdater.FingerprintBatchSize") private var fingerprintBatchSize = 2
	
	var body: some View {
		NBList("Global Updater") {
			Section("Update Checks") {
				Picker("Automatic Source Checks", selection: $checkIntervalHours) {
					Text("Off").tag(0)
					Text("Every hour").tag(1)
					Text("Every 6 hours").tag(6)
					Text("Every 12 hours").tag(12)
					Text("Every 24 hours").tag(24)
				}
				
				Toggle("Automatically Download Matched Updates", isOn: $autoDownload)
				Toggle("Automatically Sign Downloaded Updates", isOn: $autoSign)
				Toggle("Automatically Install After Signing", isOn: $autoInstall)
					.disabled(!autoSign)
			} footer: {
				Text("Only updates that pass Feather's source/variant matching are eligible for automatic download.")
			}
			
			Section("Binary Fingerprinting") {
				Toggle("Use Binary Fingerprinting", isOn: $fingerprintingEnabled)
				
				Toggle("Automatically Fingerprint Library", isOn: $autoFingerprint)
					.disabled(!fingerprintingEnabled)
				
				Picker("Batch Size", selection: $fingerprintBatchSize) {
					Text("1 app").tag(1)
					Text("2 apps").tag(2)
					Text("3 apps").tag(3)
				}
				.disabled(!fingerprintingEnabled)
				
				if updateManager.isFingerprinting {
					LabeledContent(
						"Progress",
						value: "\(updateManager.fingerprintCompleted)/\(updateManager.fingerprintTotal)"
					)
					
					if let current = updateManager.fingerprintCurrentApp {
						Text(current)
							.font(.footnote)
							.foregroundStyle(.secondary)
					}
					
					Button("Cancel Fingerprinting", systemImage: "xmark.circle", role: .destructive) {
						updateManager.cancelFingerprinting()
					}
				}
				
				Button("Clear Fingerprint Cache", systemImage: "trash", role: .destructive) {
					updateManager.clearFingerprintCache()
				}
			} footer: {
				Text("Fingerprinting analyzes injected dylibs/frameworks, Mach-O load commands, embedded bundle IDs/plists, targeted binary markers, exact component hashes, and code-signature-normalized Mach-O hashes. Work runs at utility priority in small batches. Low Power Mode or serious thermal pressure automatically reduces the batch size; critical thermal pressure pauses the scan.")
			}
			
			Section("Old Versions") {
				Picker("Older Library Versions", selection: $cleanupMode) {
					Text("Keep All").tag(0)
					Text("Ask After Download").tag(1)
					Text("Auto-delete Older Imported IPAs").tag(2)
					Text("Auto-delete Older Copies After Signing").tag(3)
				}
			}
		}
		.onChange(of: autoInstall) { enabled in
			if enabled {
				autoSign = true
			}
		}
		.onChange(of: fingerprintingEnabled) { enabled in
			if !enabled {
				autoFingerprint = false
				updateManager.cancelFingerprinting()
			}
		}
	}
}
