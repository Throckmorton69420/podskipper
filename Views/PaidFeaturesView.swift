import SwiftUI

/// iCloud sync, CarPlay and widgets: built in, and each switched on by an
/// entitlement that only a paid Apple developer account can grant. This page
/// says which of them this build has, and shows the widgets either way.
struct PaidFeaturesView: View {
    @AppStorage("iCloudSync") private var iCloudSync = true
    @State private var syncing = false
    @State private var lastSynced: Date?

    private var cloud: Bool { CloudSync.shared.isAvailable }
    private var widgets: Bool { WidgetPublisher.shared.isAvailable }

    var body: some View {
        List {
            SectionHeader("iCloud Sync")
            status(cloud, on: "Connected to iCloud",
                   off: "Not in this build — needs the iCloud entitlement")
            // Shown off, not greyed-on, when this build can't sync at all.
            Toggle(isOn: Binding(get: { cloud && iCloudSync }, set: { iCloudSync = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sync shows and progress").font(.body)
                    Text("The shows you follow, where you are in each episode, what you've finished and what you've starred, across your devices. Episodes, transcripts and found ads are rebuilt from the feeds on each device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(Theme.accentHot)
            .disabled(!cloud)
            .contentRow()
            if cloud {
                Button {
                    syncing = true
                    Task {
                        CloudSync.shared.push()
                        await CloudSync.shared.pull()
                        lastSynced = CloudSync.shared.lastSynced
                        syncing = false
                    }
                } label: {
                    HStack {
                        Text(syncing ? "Syncing…" : "Sync Now")
                        Spacer()
                        if let lastSynced {
                            Text(lastSynced, style: .relative).foregroundStyle(.secondary).font(.footnote)
                        }
                    }
                }
                .disabled(syncing)
                .contentRow()
            }

            SectionHeader("CarPlay")
            Text("Up Next, your shows and Recently Played on the car's screen, with ads skipped as on the phone. It appears in CarPlay once the app is signed with Apple's CarPlay audio entitlement; there is nothing to switch on here.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()

            SectionHeader("Widgets")
            status(widgets, on: "Sharing with widgets",
                   off: "Not in this build — needs an App Group")
            Text(widgets
                 ? "Add them from the Home Screen: press and hold, tap Edit, then Add Widget, and search for PodSkipper."
                 : "The widgets can be added today but only say \"Open PodSkipper\" until the app can share its data with them. This is what they will show:")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()
            WidgetGalleryView(snapshot: WidgetSnapshot.read() ?? .sample)
                .plainRow(top: 8, bottom: 16)

            SectionHeader("Turning Them On")
            Text("All three come from a paid Apple Developer account (99 US dollars a year). The steps are in the Plain-English Guide under \"Paid features\". In short: enrol, register the app and its widget with the capabilities named in Support/PodSkipper-Paid.entitlements, request the CarPlay audio entitlement from Apple, and sign with the profile that includes them.")
                .font(.footnote).foregroundStyle(.secondary)
                .contentRow()

            BottomClearance()
        }
        .listStyle(.plain)
        .navigationTitle("iCloud, CarPlay & Widgets")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .onAppear { lastSynced = CloudSync.shared.lastSynced }
    }

    private func status(_ on: Bool, on onText: String, off offText: String) -> some View {
        Label(on ? onText : offText, systemImage: on ? "checkmark.circle.fill" : "lock.circle")
            .foregroundStyle(on ? .green : .secondary)
            .font(.subheadline)
            .contentRow()
    }
}

/// The widgets drawn at their real Home Screen sizes, from the same views the
/// widget extension uses.
struct WidgetGalleryView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                tile(width: 158, height: 158) { UpNextWidgetView(snapshot: snapshot, size: .small) }
                tile(width: 158, height: 158) { NowPlayingWidgetView(snapshot: snapshot) }
            }
            tile(width: 330, height: 158) { UpNextWidgetView(snapshot: snapshot, size: .medium) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("WidgetGallery")
    }

    private func tile<Content: View>(width: CGFloat, height: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: width, height: height)
            .background(WidgetStyle.background)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, .dark)
    }
}
