import Foundation
import SwiftData

#if DEBUG
/// Pass 40 lab (debug builds only): writes to the library the way a back
/// catalogue being indexed does — 50 new episodes a save, a few saves a
/// second — so a page's responsiveness while the store is busy can be
/// measured in the simulator (`ResponsivenessLabUITests`). Everything it
/// adds belongs to one "PodSkipper Lab Writes" show and is deleted at the
/// end, and at the start of the next run.
enum LabStoreWrites {
    static let feed = "https://lab.invalid/podskipper-lab-writes.xml"

    static func startIfAsked(container: ModelContainer) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-LabStoreWrites") else { return }
        let seconds = args.indices.contains(i + 1) ? Double(args[i + 1]) ?? 40 : 40
        Task.detached(priority: .utility) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            let feed = Self.feed
            func clear() {
                if let old = try? context.fetch(FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feed })) {
                    for podcast in old {
                        let id = podcast.persistentModelID
                        try? context.delete(model: Episode.self, where: #Predicate { $0.podcast?.persistentModelID == id })
                        context.delete(podcast)
                    }
                    try? context.save()
                }
            }
            clear()
            let podcast = Podcast(feedURL: feed, title: "PodSkipper Lab Writes")
            context.insert(podcast)
            try? context.save()
            let started = Date()
            var n = 0
            while Date().timeIntervalSince(started) < seconds {
                for _ in 0..<50 {
                    n += 1
                    let episode = Episode(guid: "lab-\(n)", title: "Lab episode \(n)", episodeDescription: "",
                                          audioURL: "https://lab.invalid/\(n).mp3", publishedAt: .distantPast, duration: 60)
                    episode.podcast = podcast
                    episode.isArchived = true
                    context.insert(episode)
                }
                try? context.save()
                try? await Task.sleep(for: .milliseconds(350))
            }
            clear()
            print("LabStoreWrites: \(n) episodes in \(Int(Date().timeIntervalSince(started))) s")
        }
    }
}
#endif
