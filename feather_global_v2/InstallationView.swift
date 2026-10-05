//
//  InstallationView.swift
//  Feather
//
//  Created by samara on 3.06.2025.
//

import SwiftUI
import NimbleViews

// MARK: - View
struct InstallationView: View {
	@AppStorage("Feather.installationMethod") private var _installationMethod: Int = 0
	@AppStorage("Feather.GlobalUpdater.AutoDownload") private var _autoDownload = false
	@AppStorage("Feather.GlobalUpdater.AutoSign") private var _autoSign = false
	@AppStorage("Feather.GlobalUpdater.AutoInstall") private var _autoInstall = false
	@AppStorage("Feather.GlobalUpdater.CleanupMode") private var _cleanupMode = 1
	@AppStorage("Feather.GlobalUpdater.CheckIntervalHours") private var _checkIntervalHours = 6
	@State private var _showMethodChangedAlert = false

	private let _installationMethods: [String] = [
		.localized("Server"),
		.localized("idevice")
	]
	
	// MARK: Body
	var body: some View {
		NBList(.localized("Installation")) {
			Section {
				Picker(.localized("Installation Type"), systemImage: "arrow.down.app", selection: $_installationMethod) {
					ForEach(_installationMethods.indices, id: \.description) { index in
						Text(_installationMethods[index]).tag(index)
					}
				}
			} footer: {
				Text(.localized("Server (Recommended):\nUses a locally hosted server and itms-services:// to install applications.\n\nIDevice (advanced):\nUses a VPN and a pairing file. Writes to AFC and manually calls installd, while monitoring install progress by using a callback\nAdvantage: It is very reliable, does not need SSL certificates or a externally hosted server. Rather, works similarly to a computer."))
			}
			
			if _installationMethod == 0 {
				ServerView()
			} else if _installationMethod == 1 {
				TunnelView()
			}
			
			Section("Global Updater") {
				Picker("Automatic Checks", selection: $_checkIntervalHours) {
					Text("Off").tag(0)
					Text("Every hour").tag(1)
					Text("Every 6 hours").tag(6)
					Text("Every 12 hours").tag(12)
					Text("Every 24 hours").tag(24)
				}
				
				Toggle("Automatically Download Matched Updates", isOn: $_autoDownload)
				Toggle("Automatically Sign Downloaded Updates", isOn: $_autoSign)
				Toggle("Automatically Install After Signing", isOn: $_autoInstall)
					.disabled(!_autoSign)
				
				Picker("Older Library Versions", selection: $_cleanupMode) {
					Text("Keep All").tag(0)
					Text("Ask After Download").tag(1)
					Text("Auto-delete Older Imported IPAs").tag(2)
					Text("Auto-delete Older Copies After Signing").tag(3)
				}
			} footer: {
				Text("Global Updater only auto-downloads candidates whose app/mod variant can be matched safely. Apps that merely share a bundle identifier are flagged for review. Auto-install uses Feather's installation method selected above. Server installs may still require the normal iOS install confirmation; iDevice can proceed more directly.")
			}
		}
		.onChange(of: _autoInstall) { enabled in
			if enabled {
				_autoSign = true
			}
		}
		.onChange(of: _installationMethod) { newValue in
			guard newValue == 1 else { return }
			_showMethodChangedAlert = true
		}
		.alert(.localized("Advanced Installation Method"), isPresented: $_showMethodChangedAlert) {
			Button(.localized("Switch Back"), role: .destructive) {
				_installationMethod = 0
			}
			Button(.localized("OK"), role: .cancel) {}
		} message: {
			Text(.localized("idevice warning"))
		}


		.animation(.default, value: _installationMethod)
	}
}

