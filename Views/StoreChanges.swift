import Combine
import Foundation
import SwiftData
import SwiftUI

/// Pass 40: what a library save changed, so a page refetches only for saves
/// that can change what it shows.
///
/// His 15 Oct report: the Downloaded page was slow to answer touches. In the
/// simulator, on a library of 5,817 episodes, with the store busy the way a
/// back catalogue being indexed keeps it (50 episodes a save), the main
/// thread spent ~75 ms of every second refetching, with nothing touched:
/// the Library page underneath (its `@Query` re-read every show on every
/// save) and Downloaded itself (re-read on every save since Pass 39). With
/// the store quiet: ~0. `StationStoreChanges` already did this for stations.
struct StoreChanges {
    var inserted: Set<PersistentIdentifier> = []
    var updated: Set<PersistentIdentifier> = []
    var deleted: Set<PersistentIdentifier> = []
    /// The save didn't say what it changed (or invalidated everything):
    /// treat it as touching everything.
    var unknown = false

    /// nil for a save to another container. Must run where the save is
    /// posted, while the saving context and its container are certainly
    /// alive: read later on the main thread, a short-lived context's
    /// container can already be gone (a trap, seen in the unit tests).
    init?(_ notification: Notification, container: ModelContainer) {
        if let source = notification.object as? ModelContext, source.container !== container { return nil }
        let info = notification.userInfo ?? [:]
        if info[ModelContext.NotificationKey.invalidatedAllIdentifiers] as? Bool == true
            || info[ModelContext.NotificationKey.invalidatedAllIdentifiers.rawValue] as? Bool == true {
            unknown = true
            return
        }
        var saw = false
        func ids(_ key: ModelContext.NotificationKey) -> Set<PersistentIdentifier> {
            let value = info[key] ?? info[key.rawValue]
            if let array = value as? [PersistentIdentifier] { saw = true; return Set(array) }
            if let set = value as? Set<PersistentIdentifier> { saw = true; return set }
            return []
        }
        inserted = ids(.insertedIdentifiers)
        updated = ids(.updatedIdentifiers)
        deleted = ids(.deletedIdentifiers)
        unknown = !saw
    }

    /// Every library save as what it changed, on the main run loop.
    static func saves(in container: ModelContainer) -> AnyPublisher<StoreChanges, Never> {
        NotificationCenter.default.publisher(for: ModelContext.didSave)
            .compactMap { StoreChanges($0, container: container) }
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    /// For tests.
    init(inserted: Set<PersistentIdentifier> = [], updated: Set<PersistentIdentifier> = [],
         deleted: Set<PersistentIdentifier> = [], unknown: Bool = false) {
        self.inserted = inserted; self.updated = updated; self.deleted = deleted; self.unknown = unknown
    }

    func of<T: PersistentModel>(_ type: T.Type, _ set: Set<PersistentIdentifier>) -> Set<PersistentIdentifier> {
        let name = Schema.entityName(for: type)
        return set.filter { $0.entityName == name }
    }

    /// Shows added or removed (a show's own fields reach the page through
    /// observation without a refetch).
    var changesShowList: Bool {
        unknown || !of(Podcast.self, inserted).isEmpty || !of(Podcast.self, deleted).isEmpty
    }
}

/// Pass 40: a live query kept in a view of its own. SwiftData's `@Query`
/// redraws the view holding it on every library save, whether or not its
/// results changed (in the simulator, a hidden New page redrew 178 times and
/// Up Next 89 in 40 s of back-catalogue-style saves). Here only this empty
/// view redraws; the page gets the results — through `update` — only when
/// which items, or their order, changed. Each item's own fields still reach
/// the page through observation. Put it in a page's background only while
/// the page is showing.
struct LiveQuery<Model: PersistentModel>: View {
    @Query private var items: [Model]
    private let update: ([Model]) -> Void

    init(_ descriptor: FetchDescriptor<Model>, update: @escaping ([Model]) -> Void) {
        _items = Query(descriptor)
        self.update = update
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: items.map(\.persistentModelID), initial: true) { update(items) }
    }
}

extension PersistentModel {
    /// Pass 40: still in the library — not deleted since a page last read
    /// its list (a kept list can outlive a deletion until it is read again).
    var isLive: Bool { !isDeleted && modelContext != nil }
}
