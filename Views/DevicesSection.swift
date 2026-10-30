import SwiftUI
import UIKit

/// Settings → iCloud, Widgets & CarPlay.
///
/// Pass 35 (his request): each capability says what this installed copy can
/// actually do, read from its own signature and from what has happened — not
/// what the project file asks for, and not a paragraph about enrolling in the
/// developer program. His install is re-signed by Feather, which renames the
/// bundle id and App Group; Apple grants CarPlay audio separately, on request.
struct DevicesSection: View {
    @AppStorage("iCloudSync") private var iCloudSync = true
    @State private var syncing = false
    @State private var tick = 0

    private var cloud: CloudSync { CloudSync.shared }

    var body: some View {
        let _ = tick // redraws after Sync Now
        Group {
            SectionHeader("iCloud Sync")
            CapabilityRow(title: "iCloud key-value storage", state: cloudState)
            Toggle("Sync with your other devices", isOn: $iCloudSync)
                .tint(Theme.accentHot)
                .disabled(!cloud.isAvailable)
                .contentRow()
            Group {
                LabeledContent("Last sent from this device", value: when(cloud.lastSent))
                LabeledContent("Last received from iCloud",
                               value: when(cloud.lastReceived) + (cloud.lastReceivedReason.map { " · " + $0 } ?? ""))
            }
            .font(.subheadline)
            .contentRow()
            if cloud.isAvailable {
                Button {
                    syncing = true
                    Task {
                        cloud.push()
                        await cloud.pull()
                        syncing = false
                        tick += 1
                    }
                } label: {
                    HStack { Text(syncing ? "Syncing…" : "Sync Now"); if syncing { Spacer(); ProgressView() } }
                }
                .disabled(syncing || !iCloudSync)
                .contentRow()
            }
            if let records = cloud.lastRecords {
                let applied = records.applied.values.reduce(0, +), sent = records.sent.values.reduce(0, +)
                Text("Last sync: \(applied) received, \(sent) sent"
                     + (records.conflictsKeptHere > 0 ? ", \(records.conflictsKeptHere) of your corrections here kept over another device's" : "")
                     + (records.waiting > 0 ? ", \(records.waiting) waiting for episodes this device hasn't loaded yet" : "")
                     + (records.skippedForSize > 0 ? ", \(records.skippedForSize) oldest left out (iCloud's 1 MB limit)" : "") + ".")
                    .font(.footnote).foregroundStyle(.secondary).contentRow()
            }
            // Pass 47: both devices must name the same store; Feather can
            // sign each install differently.
            if let store = SignedEntitlements.describe("com.apple.developer.ubiquity-kvstore-identifier") {
                LabeledContent("iCloud store", value: store)
                    .font(.subheadline).textSelection(.enabled).contentRow()
                // Pass 53: seen directly — each device writes its own entry.
                let others = cloud.otherDevices
                LabeledContent("Other devices here",
                               value: others.isEmpty ? "None yet"
                                : others.map { "\($0.kind) · \(when($0.at))" }.joined(separator: ", "))
                    .font(.subheadline).contentRow()
                if others.isEmpty, cloud.isAvailable, !cloud.usesRelay {
                    Text("No other device has written to this iCloud store. Open PodSkipper on your other device and tap Sync Now there: if it still isn't listed here, that device's copy is signed with a different iCloud store (compare the store above on both). Copies signed by different developers can never share one; sync them through your Cloudflare storage below instead.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentRow()
                }
            }
            if !cloud.keptUnfollowed.isEmpty {
                Text("Unfollowed on another device but kept here, because they hold your corrections, downloads or listening: "
                     + cloud.keptUnfollowed.sorted().joined(separator: ", ") + ".")
                    .font(.footnote).foregroundStyle(.secondary).contentRow()
            }
            Text("Syncs: the shows you follow, and shows you unfollow; where you are (a pause reaches your other device straight away), played and starred for about 1,500 recent episodes; your listening and sound settings; each show's own settings and what it has learned; bookmarks; stations; your ad corrections on up to 200 episodes; and the ads found on up to 150 recent episodes, which your other device uses until it finds its own (only when its copy is the same length). The newest change wins — a rewind too — and corrections made on this device are never replaced by another device's. Through iCloud, both devices must show the same iCloud store above and use the same Apple Account; otherwise sync through your Cloudflare storage below. Not synced: device settings (models, downloads, storage, notifications, text size), listening statistics, media, transcripts and models. Not yet confirmed between two of your devices: “Last received” shows when something arrives.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentRow()
            RelaySyncRows(tick: $tick)

            SectionHeader("Widgets")
            CapabilityRow(title: "Home Screen widgets", state: widgetState)
            if case .available = widgetState.kind {
                Text("Add them from the Home Screen: press and hold, tap Edit, then Add Widget, and search for PodSkipper.")
                    .font(.footnote).foregroundStyle(.secondary).contentRow()
            }
            WidgetGalleryView(snapshot: WidgetSnapshot.read() ?? .sample)
                .plainRow(top: 8, bottom: 16)

            SectionHeader("CarPlay")
            CapabilityRow(title: "CarPlay audio", state: carPlayState)
            Text("On the car's screen: Up Next, your shows and Recently Played, with ads skipped as on the phone.")
                .font(.footnote).foregroundStyle(.secondary).contentRow()
        }
    }

    private func when(_ date: Date?) -> String {
        date.map { $0.formatted(.relative(presentation: .named)) } ?? "Never"
    }

    // MARK: Status

    private var cloudState: CapabilityRow.State {
        if !CloudSync.entitled && !cloud.isAvailable {
            return .init(.missing, "This copy isn't signed with the iCloud key-value entitlement.")
        }
        if !CloudSync.signedIn { return .init(.limited, "Not signed in to iCloud on this device.") }
        if !cloud.isAvailable { return .init(.limited, "Signed for iCloud, but iCloud didn't answer. Try again later.") }
        if !iCloudSync { return .init(.limited, "Available, switched off.") }
        return .init(.available, cloud.lastReceived == nil
                     ? "Available. Nothing received from another device yet."
                     : "Available and receiving.")
    }

    private var widgetState: CapabilityRow.State {
        let status = WidgetCapability.current
        switch status {
        case .noExtension: return .init(.missing, "The widget extension isn't in this copy of the app.")
        case .noGroup: return .init(.missing, "The app isn't signed with an App Group, so it can't share data with the widgets.")
        case .extensionNotInGroup(let app, let ext):
            return .init(.limited, "The app and the widget were signed with different App Groups (app: \(app); widget: \(ext.isEmpty ? "none" : ext)). Re-sign both with the same group.")
        case .ready(let group, let updated):
            return .init(.available, "Sharing through \(group)" + (updated.map { ", updated " + $0.formatted(.relative(presentation: .named)) } ?? ", nothing written yet") + ".")
        }
    }

    private var carPlayState: CapabilityRow.State {
        let key = "com.apple.developer.carplay-audio"
        if SignedEntitlements.granted.contains(key) {
            return .init(.available, "Signed with Apple's CarPlay audio entitlement. Connect to CarPlay to use it.")
        }
        return .init(.missing, "This copy isn't signed with Apple's CarPlay audio entitlement. Apple grants it on request for each developer team; ordinary membership doesn't include it. The CarPlay screens are built in and appear once the app is signed with it.")
    }
}

/// One capability: a symbol, a word for the state, and why.
struct CapabilityRow: View {
    struct State {
        enum Kind { case available, limited, missing }
        var kind: Kind
        var detail: String
        init(_ kind: Kind, _ detail: String) { self.kind = kind; self.detail = detail }
    }
    let title: String
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(state.detail).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .contentRow()
    }

    private var symbol: String {
        switch state.kind {
        case .available: "checkmark.circle.fill"
        case .limited: "exclamationmark.circle.fill"
        case .missing: "xmark.circle.fill"
        }
    }
    private var color: Color {
        switch state.kind {
        case .available: .green
        case .limited: .orange
        case .missing: .secondary
        }
    }
}

/// Whether the widgets can show real data in this installed copy: the
/// extension is in the app, the app has a group iOS gives a folder for, and
/// the extension was signed with that same group.
enum WidgetCapability: Equatable {
    case noExtension, noGroup
    case extensionNotInGroup(app: String, widget: String)
    case ready(group: String, updated: Date?)

    static var current: WidgetCapability {
        guard let plugins = Bundle.main.builtInPlugInsURL,
              let appex = ((try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [])
                .first(where: { $0.pathExtension == "appex" }) else { return .noExtension }
        guard let group = WidgetSnapshot.resolvedGroup else { return .noGroup }
        // The extension's own signature, read from its executable.
        let executable = Bundle(url: appex)?.executableURL
        let widgetGroups = executable.flatMap { SignedEntitlements.entitlements(ofExecutable: $0) }
            .map { SignedEntitlements.groups(in: $0) } ?? []
        // An unsigned build (simulator, CI) has no signature to compare.
        if executable != nil, SignedEntitlements.present.isEmpty == false, !widgetGroups.contains(group) {
            return .extensionNotInGroup(app: group, widget: widgetGroups.joined(separator: ", "))
        }
        let file = WidgetSnapshot.folder?.appendingPathComponent(WidgetSnapshot.fileName)
        let updated = file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        return .ready(group: group, updated: updated)
    }
}

/// Pass 54: syncing through his Cloudflare storage, for devices whose copies
/// name different iCloud stores.
private struct RelaySyncRows: View {
    @Binding var tick: Int
    @State private var copied = false
    @State private var problem: String?
    @State private var confirmStop = false
    private var cloud: CloudSync { CloudSync.shared }

    var body: some View {
        let _ = tick
        SectionHeader("Sync Through Your Cloudflare Storage")
        if cloud.usesRelay {
            CapabilityRow(title: "Cloudflare storage", state: cloud.relayProblem.map { .init(.limited, $0) }
                          ?? .init(.available, cloud.relayDevices.isEmpty
                                   ? "On. Nothing from another device yet: turn it on there with this device's setup."
                                   : "On and receiving."))
            LabeledContent("Other devices here",
                           value: cloud.relayDevices.isEmpty ? "None yet"
                            : cloud.relayDevices.map { "\($0.kind) · \($0.at.formatted(.relative(presentation: .named)))" }.joined(separator: ", "))
                .font(.subheadline).contentRow()
            Button(copied ? "Copied — paste it on your other device" : "Copy Setup for Your Other Device") {
                guard let setup = SyncRelaySetup.load() else { return }
                var full = setup
                if full.credentials == nil { full.credentials = R2Credentials.load() }
                UIPasteboard.general.setItems([["public.utf8-plain-text": full.text]],
                                              options: [.expirationDate: Date.now.addingTimeInterval(600)])
                copied = true
            }
            .accessibilityIdentifier("relay.copy")
            .contentRow()
            Text("The setup holds your Cloudflare storage key and this sync's secret. Paste it only on your own devices; it leaves the clipboard after ten minutes.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
            Button("Stop Syncing Through Cloudflare", role: .destructive) { confirmStop = true }
                .confirmationDialog("Stop syncing through your Cloudflare storage?", isPresented: $confirmStop, titleVisibility: .visible) {
                    Button("Stop Syncing", role: .destructive) { cloud.stopRelay(); tick += 1 }
                } message: {
                    Text("Everything already synced stays on this device. Your other device keeps its copy too.")
                }
                .contentRow()
        } else {
            Text("Use this when your devices' copies of PodSkipper are signed by different developers, so the iCloud stores above differ. The same things sync, sealed so only your devices can read them, in the storage PodSkipper publishes feeds to.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).contentRow()
            Button("Turn On on This Device") {
                do {
                    try cloud.useRelay(.new(credentials: nil))
                    problem = nil
                } catch { problem = error.localizedDescription }
                tick += 1
            }
            .disabled(!R2Credentials.isConfigured)
            .accessibilityIdentifier("relay.start")
            .contentRow()
            if !R2Credentials.isConfigured {
                Text("Needs your Cloudflare storage, set up under Publishing — or paste the setup from a device that has it.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).contentRow()
            }
            PasteButton(payloadType: String.self) { strings in
                Task { @MainActor in
                    guard let text = strings.first, let setup = SyncRelaySetup(text: text) else {
                        problem = "That isn't a PodSkipper sync setup. On your other device, tap Copy Setup for Your Other Device, then paste here."
                        return
                    }
                    do {
                        try cloud.useRelay(setup)
                        problem = nil
                    } catch { problem = error.localizedDescription }
                    tick += 1
                }
            }
            .accessibilityIdentifier("relay.paste")
            .contentRow()
        }
        if let problem {
            Text(problem).font(.footnote).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).contentRow()
        }
    }
}
