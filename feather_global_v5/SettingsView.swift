//
//  SettingsView.swift
//  Feather
//
//  Created by samara on 10.04.2025.
//

import SwiftUI
import AltSourceKit
import CoreData
import NimbleJSON
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
	@AppStorage("Feather.GlobalUpdater.MaxConcurrentDownloads") private var maxConcurrentDownloads = 2
	@AppStorage("Feather.GlobalUpdater.StrictSequentialPipeline") private var strictSequentialPipeline = true
	@AppStorage("Feather.GlobalUpdater.AdaptiveSourceRanking") private var adaptiveSourceRanking = true
	
	@State private var isAddingMoeSource = false
	@State private var moeSourceStatus: String?
	
	var body: some View {
		NBList(.localized("Global Updater")) {
			Section {
				Picker("Check When Library Opens", selection: $checkIntervalHours) {
					Text("Off").tag(0)
					Text("Every hour").tag(1)
					Text("Every 6 hours").tag(6)
					Text("Every 12 hours").tag(12)
					Text("Every 24 hours").tag(24)
				}
				
				Toggle("Automatically Download Matched Updates", isOn: $autoDownload)
				Toggle("Automatically Sign Downloaded Updates", isOn: $autoSign)
					.disabled(!fingerprintingEnabled)
				Toggle("Automatically Install After Signing", isOn: $autoInstall)
					.disabled(!autoSign || !fingerprintingEnabled)
				
				Toggle("Adaptive Source Ranking", isOn: $adaptiveSourceRanking)
				
				Toggle("Strict Sequential Update Pipeline", isOn: $strictSequentialPipeline)
				
				Picker("Concurrent Downloads", selection: $maxConcurrentDownloads) {
					Text("1").tag(1)
					Text("2").tag(2)
					Text("3").tag(3)
				}
				.disabled(strictSequentialPipeline)
			} header: {
				Text("Update Checks")
			} footer: {
				Text("The interval is a foreground freshness rule: Feather checks when the Library is opened and the selected interval has elapsed. It does not promise an exact background wake-up. Automatic cleanup, signing, and installation require binary fingerprinting. Adaptive Source Ranking checks original sources first, then learns from source fetch reliability and prior binary-verification results. Strict Sequential runs download → verify → sign → install one update at a time; disabling it allows up to the selected number of simultaneous downloads while signing and installation remain serialized.")
			}
			
			Section {
				Toggle("Use Binary Fingerprinting", isOn: $fingerprintingEnabled)
				
				Toggle("Fingerprint Missing/Changed Apps After Checks", isOn: $autoFingerprint)
					.disabled(!fingerprintingEnabled)
				
				Picker("Batch Size", selection: $fingerprintBatchSize) {
					Text("1 app").tag(1)
					Text("2 apps").tag(2)
					Text("3 apps").tag(3)
				}
				.disabled(!fingerprintingEnabled)
				
				if let lastRun = updateManager.fingerprintLastRunDate {
					LabeledContent(
						"Last Completed Pass",
						value: lastRun.formatted(date: .abbreviated, time: .shortened)
					)
				}
				
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
			} header: {
				Text("Binary Fingerprinting")
			} footer: {
				Text("A full fingerprint is created once per Library app/version and content stamp, then cached. Interrupted scans resume by skipping cached apps. New or changed Library entries are fingerprinted again. Candidate IPAs are fingerprinted after download and compared with the cached installed-app fingerprint before automatic cleanup, signing, or installation. A match confirms variant continuity; it is not a malware scan or a guarantee that a source is trustworthy. Work runs at utility priority in small batches; Low Power Mode or thermal pressure reduces or pauses work.")
			}
			
			Section {
				Button {
					_addMoeSource()
				} label: {
					Label(
						isAddingMoeSource ? "Adding Moe App Hub…" : "Add Moe App Hub Source",
						systemImage: "plus.circle"
					)
				}
				.disabled(isAddingMoeSource)
				
				if let moeSourceStatus {
					Text(moeSourceStatus)
						.font(.footnote)
						.foregroundStyle(.secondary)
				}
			} header: {
				Text("Recommended Source")
			} footer: {
				Text("Moe App Hub has a community-maintained AltStore/SideStore source mirror that regenerates metadata from the actual IPA files and re-hosts downloadable IPA assets on GitHub Releases.")
			}
			
			Section {
				Picker("Older Library Versions", selection: $cleanupMode) {
					Text("Keep Everything").tag(0)
					Text("Ask After Verified Download").tag(1)
					Text("Delete Older Unsigned IPAs After Verified Download").tag(2)
					Text("Delete Older Unsigned IPAs After Successful Signing").tag(3)
					Text("Delete Older Matching Copies After Confirmed Install").tag(4)
				}
			} header: {
				Text("Old Versions")
			} footer: {
				Text("Imported means an unsigned/decrypted IPA stored in Feather's Imported section, whether it came from Files, a URL, a source, or the updater. The download/signing modes preserve older Signed copies as rollback points. The confirmed-install mode removes an older Signed copy only after the direct device installer reports success for the exact replacement. Server-install progress is heuristic, so those installs preserve Signed rollback copies.")
			}
		}
		.onChange(of: autoInstall) { enabled in
			if enabled {
				autoSign = true
			}
		}
		.onChange(of: autoSign) { enabled in
			if !enabled {
				autoInstall = false
			}
		}
		.onChange(of: fingerprintingEnabled) { enabled in
			if !enabled {
				autoFingerprint = false
				autoSign = false
				autoInstall = false
				updateManager.cancelFingerprinting()
			}
		}
	}
	
	private func _addMoeSource() {
		guard !isAddingMoeSource else { return }
		guard let url = URL(
			string: "https://raw.githubusercontent.com/MountainofPenguin/moe-altstore/main/apps.json"
		) else {
			moeSourceStatus = "The Moe source URL is invalid."
			return
		}
		
		isAddingMoeSource = true
		moeSourceStatus = nil
		
		Task { @MainActor in
			do {
				var request = URLRequest(url: url)
				request.timeoutInterval = 20
				request.cachePolicy = .reloadIgnoringLocalCacheData
				let (data, response) = try await URLSession.shared.data(for: request)
				if
					let http = response as? HTTPURLResponse,
					!(200...299).contains(http.statusCode)
				{
					throw URLError(.badServerResponse)
				}
				let repository = try JSONDecoder().decode(ASRepository.self, from: data)
				Storage.shared.addSource(url, repository: repository) { error in
					DispatchQueue.main.async {
						isAddingMoeSource = false
						if let error {
							moeSourceStatus = "Could not add source: \(error.localizedDescription)"
						} else {
							moeSourceStatus = "Moe App Hub source is available in Sources."
						}
					}
				}
			} catch {
				isAddingMoeSource = false
				moeSourceStatus = "Could not load source: \(error.localizedDescription)"
			}
		}
	}
}
