import SwiftUI
import SwiftData

/// A local draft keeps Cancel from modifying the station or the global queue.
struct StationOrderView: View {
    let filter: SmartFilter
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var episodes: [Episode] = []
    @State private var failure: String?
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                ForEach(episodes) { episode in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(episode.title).font(.body)
                        Text(episode.podcast?.title ?? "Unknown Show")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("station.order.episode.\(episode.guid)")
                }
                .onMove { source, destination in
                    episodes.move(fromOffsets: source, toOffset: destination)
                }
            } footer: {
                Text(filter.groupByShow
                    ? "Drag to change episode order. Shows are grouped by their first episode in this order."
                    : "Drag to change episode order. New matching episodes are added after your choices.")
            }
            if episodes.isEmpty {
                ContentUnavailableView("No Matching Episodes", systemImage: filter.iconName,
                    description: Text("Change the station's rules to include episodes."))
            }
        }
        .navigationTitle("Episode Order")
        .navigationBarTitleDisplayMode(.inline)
        .amoledScreen()
        .environment(\.editMode, .constant(.active))
        .accessibilityIdentifier("station.order.editor")
        .task {
            guard !loaded else { return }
            episodes = filter.episodes(in: context)
            loaded = true
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .accessibilityIdentifier("station.order.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    do {
                        try StationOrderStore.save(episodes.map(\.guid), for: filter) { try context.save() }
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }
                .disabled(episodes.isEmpty)
                .accessibilityIdentifier("station.order.save")
            }
        }
        .alert("Couldn't Save Episode Order", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }
}

@MainActor
enum StationOrderStore {
    /// Restore only station fields on failure; rolling back the shared context
    /// would discard unrelated listening history and processing checkpoints.
    static func save(_ visibleGUIDs: [String], for filter: SmartFilter,
                     persist: () throws -> Void) throws {
        let previousOrder = filter.manualEpisodeGUIDs
        let previousSort = filter.sortRaw
        filter.manualEpisodeGUIDs = StationEpisodeOrder.replacingVisibleOrder(
            existing: previousOrder, with: visibleGUIDs)
        filter.sort = .manual
        do { try persist() }
        catch {
            filter.manualEpisodeGUIDs = previousOrder
            filter.sortRaw = previousSort
            throw error
        }
    }
}

/// Only store changes concerning station membership/order trigger a refresh.
/// UI subscribers debounce this event instead of refetching on every render.
@MainActor
enum StationStoreChanges {
    static func affectsStations(_ notification: Notification, context: ModelContext) -> Bool {
        if let source = notification.object as? ModelContext, source.container !== context.container { return false }
        if notification.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers] as? Bool == true
            || notification.userInfo?[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] as? Bool == true {
            return true
        }
        let names: Set<String> = [Schema.entityName(for: SmartFilter.self), Schema.entityName(for: Episode.self),
                                  Schema.entityName(for: Podcast.self)]
        var sawIdentifiers = false
        for key in [ModelContext.NotificationKey.insertedIdentifiers, .updatedIdentifiers, .deletedIdentifiers] {
            let value = notification.userInfo?[key] ?? notification.userInfo?[key.rawValue]
            let identifiers: [PersistentIdentifier]?
            if let array = value as? [PersistentIdentifier] { identifiers = array }
            else if let set = value as? Set<PersistentIdentifier> { identifiers = Array(set) }
            else { identifiers = nil }
            if let identifiers {
                sawIdentifiers = true
                if identifiers.contains(where: { names.contains($0.entityName) }) { return true }
            }
        }
        // Some save publishers omit identifier details; keep the UI truthful.
        return !sawIdentifiers
    }
}
