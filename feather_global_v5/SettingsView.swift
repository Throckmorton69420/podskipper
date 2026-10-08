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


private struct GlobalUpdaterAdvancedSettingsView: View {
	@ObservedObject private var manager = UpdateManager.shared
	@AppStorage("Feather.GlobalUpdater.FingerprintingEnabled") private var fingerprintingEnabled = true
	@AppStorage("Feather.GlobalUpdater.AdaptiveSourceRanking") private var adaptiveSourceRanking = true
	@AppStorage("Feather.GlobalUpdater.AutoSign") private var autoSign = false
	@AppStorage("Feather.GlobalUpdater.AutoInstall") private var autoInstall = false
	@State private var showClearConfirmation = false
	var body: some View {
		NBList("Verification & Sources") {
			Section {
				Toggle("Verify Downloaded Updates", isOn: $fingerprintingEnabled)
				if let lastRun = manager.fingerprintLastRunDate {
					LabeledContent("Last Library Scan", value: lastRun.formatted(date: .abbreviated, time: .shortened))
				}
				if manager.isFingerprinting {
					LabeledContent("Scan Progress", value: "\(manager.fingerprintCompleted)/\(manager.fingerprintTotal)")
					Text(manager.fingerprintCurrentApp ?? "Preparing…").font(.footnote)
					Button("Cancel Library Scan", role: .destructive) { manager.cancelFingerprinting() }
				}
				if manager.fingerprintFailed > 0 {
					Text("\(manager.fingerprintFailed) apps could not be scanned. Automatic updates for these apps require review.")
						.font(.footnote).foregroundStyle(.secondary)
				}
				Button(manager.isClearingFingerprintCache ? "Clearing Fingerprints…" : "Clear Saved Fingerprints", role: .destructive) { showClearConfirmation = true }
					.disabled(manager.isClearingFingerprintCache)
			} header: {
				Text("Binary Verification")
			} footer: {
				Text("Only apps involved in an update are scanned automatically. A full Library scan is optional in Library’s update menu. Scans run one at a time and stop when Feather backgrounds or the phone becomes hot. Fingerprints check variant continuity, not malware or source trust. Turning verification off also stops automatic signing and installation.")
			}
			Section {
				Toggle("Learn Source Reliability", isOn: $adaptiveSourceRanking)
			} header: {
				Text("Source Ranking")
			} footer: {
				Text("Uses previous fetch and verification results to prioritize sources. It never makes an untrusted source safe.")
			}
		}
		.confirmationDialog("Clear saved fingerprints?", isPresented: $showClearConfirmation, titleVisibility: .visible) {
			Button("Clear Fingerprints", role: .destructive) { manager.clearFingerprintCache() }
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Apps and certificates are kept. The next update must be fingerprinted again.")
		}
		.onChange(of: fingerprintingEnabled) { enabled in
			if !enabled { autoSign = false; autoInstall = false; manager.cancelFingerprinting() }
		}
	}
}

// MARK: - Global Updater
private struct GlobalUpdaterSettingsView: View {
	@AppStorage("Feather.GlobalUpdater.CheckIntervalHours") private var checkIntervalHours = 6
	@AppStorage("Feather.GlobalUpdater.AutoDownload") private var autoDownload = false
	@AppStorage("Feather.GlobalUpdater.AutoSign") private var autoSign = false
	@AppStorage("Feather.GlobalUpdater.AutoInstall") private var autoInstall = false
	@AppStorage("Feather.GlobalUpdater.OlderDownloadPolicy") private var cleanupPolicy = 0
	@AppStorage("Feather.GlobalUpdater.FingerprintingEnabled") private var fingerprintingEnabled = true
	@State private var isAddingMoeSource = false
	@State private var moeSourceStatus: String?

	var body: some View {
		NBList("Global Updater") {
			Section {
				Picker("Check on Library Open", selection: $checkIntervalHours) {
					Text("Manual only").tag(0)
					Text("Hourly").tag(1)
					Text("Every 6 hours").tag(6)
					Text("Every 12 hours").tag(12)
					Text("Daily").tag(24)
				}
			} header: {
				Text("Check for Updates")
			} footer: {
				Text("Checks all your sources when Library opens and the interval has passed. No scheduled background checks.")
			}

			Section {
				Toggle("Download Matched Updates", isOn: $autoDownload)
				Toggle("Sign Verified Updates", isOn: $autoSign)
					.disabled(!fingerprintingEnabled)
				Toggle("Install After Signing", isOn: $autoInstall)
					.disabled(!autoSign || !fingerprintingEnabled)
			} header: {
				Text("Automatic Updates")
			} footer: {
				Text("Each switch controls one step. Review candidates stay manual. One update runs at a time; signing requires a selected certificate and binary verification.")
			}

			Section {
				Picker("Older Unsigned Downloads", selection: $cleanupPolicy) {
					ForEach(OlderDownloadPolicy.allCases) { policy in
						Text(policy.title).tag(policy.rawValue)
					}
				}
			} header: {
				Text("Storage & Rollback")
			} footer: {
				Text("Applies only to older Imported copies of the same verified variant, after a replacement is signed. If automatic installation is on, cleanup waits for confirmed device installation. Download-only updates and unconfirmed installs keep old copies. Signed copies are always kept for rollback.")
			}

			Section {
				NavigationLink("Verification & Sources") {
					GlobalUpdaterAdvancedSettingsView()
				}
				Button(isAddingMoeSource ? "Adding Moe App Hub…" : "Add Moe App Hub Source") {
					_addMoeSource()
				}
				.disabled(isAddingMoeSource)
				if let moeSourceStatus {
					Text(moeSourceStatus).font(.footnote).foregroundStyle(.secondary)
				}
			}
		}
		.onAppear { UpdaterRuntimePolicy.migrate(UserDefaults.standard) }
		.onChange(of: autoSign) { enabled in
			if !enabled { autoInstall = false }
		}
		.onChange(of: fingerprintingEnabled) { enabled in
			if !enabled { autoSign = false; autoInstall = false }
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
