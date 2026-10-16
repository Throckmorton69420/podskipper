import Foundation
import SwiftData

#if DEBUG
/// Pass 41 lab (debug builds only): a Downloaded page like his phone's.
///
/// Pass 40 measured Downloaded on the simulator's library — 5,817 episodes
/// but 7 downloads, none with ads found, no transcript, no cuts. His
/// phone's Downloaded holds the episodes he has found ads in: each with a
/// two-hour transcript, its cuts and the reader's. This adds those episodes
/// from one of his Results exports (`-LabDownloadedLibrary <path>`): their
/// real transcripts (stored as the app stores them), cuts, reader cuts,
/// silences from the transcript's own gaps, and a tiny placeholder file so
/// each counts as downloaded. Everything belongs to "Lab ·" shows under
/// lab.invalid and `-LabDownloadedLibrary clear` removes it all, files too.
enum LabDownloadedLibrary {
    static let feedPrefix = "https://lab.invalid/downloaded/"

    static func runIfAsked(container: ModelContainer) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-LabDownloadedLibrary"), args.indices.contains(i + 1) else { return }
        let source = args[i + 1]
        if source == "bench" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                bench(container.mainContext)
            }
            return
        }
        Task.detached(priority: .userInitiated) {
            let context = ModelContext(container)
            context.autosaveEnabled = false
            clear(context)
            guard source != "clear" else { print("LabDownloadedLibrary: cleared"); return }
            let count = seed(from: URL(fileURLWithPath: source), context: context)
            FileIndex.refresh()
            print("LabDownloadedLibrary: \(count) episodes")
        }
    }

    /// Main-context reads as the Downloaded page makes them, timed.
    @MainActor
    private static func bench(_ context: ModelContext) {
        func time(_ label: String, _ body: () -> Int) {
            var ms: [Double] = []
            var n = 0
            for _ in 0..<5 {
                let t = Date()
                n = body()
                ms.append(Date().timeIntervalSince(t) * 1000)
            }
            print(String(format: "LabBench %@: %d rows, median %.1f ms, first %.1f ms", label, n, ms.sorted()[2], ms[0]))
        }
        let downloaded = FetchDescriptor<Episode>(predicate: #Predicate { !$0.isArchived && $0.localFilename != nil },
                                                  sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        var latest = FetchDescriptor<Episode>(predicate: #Predicate { !$0.isArchived && !$0.isPlayed },
                                              sortBy: [SortDescriptor(\.publishedAt, order: .reverse)])
        latest.fetchLimit = 300
        time("downloaded fetch") { ((try? context.fetch(downloaded)) ?? []).filter(\.isDownloaded).count }
        time("latest fetch") { ((try? context.fetch(latest)) ?? []).count }
        time("downloaded rows' time left") {
            let list = ((try? context.fetch(downloaded)) ?? []).filter(\.isDownloaded)
            return Int(list.reduce(0) { $0 + $1.remainingSeconds })
        }
        time("latest rows' time left") {
            Int(((try? context.fetch(latest)) ?? []).reduce(0) { $0 + $1.remainingSeconds })
        }
        var slim = downloaded
        slim.propertiesToFetch = EpisodeRowFetch.properties
        slim.relationshipKeyPathsForPrefetching = [\.adSegments, \.podcast]
        let fresh = ModelContext(context.container)
        time("downloaded slim fetch, fresh context") {
            ((try? fresh.fetch(slim)) ?? []).filter(\.isDownloaded).count
        }
        time("downloaded full fetch, fresh context") {
            ((try? ModelContext(context.container).fetch(downloaded)) ?? []).filter(\.isDownloaded).count
        }
        time("downloaded slim rows' time left, fresh context") {
            Int(((try? ModelContext(context.container).fetch(slim)) ?? []).filter(\.isDownloaded).reduce(0) { $0 + $1.remainingSeconds })
        }
        time("downloaded full rows' time left, fresh context") {
            Int(((try? ModelContext(context.container).fetch(downloaded)) ?? []).filter(\.isDownloaded).reduce(0) { $0 + $1.remainingSeconds })
        }
        let text = ((try? context.fetch(downloaded)) ?? []).reduce(0) { $0 + ($1.transcriptText?.utf8.count ?? 0) }
        print("LabBench downloaded transcriptText in memory: \(text / 1024) KB")
    }

    private static func clear(_ context: ModelContext) {
        let prefix = feedPrefix
        let shows = (try? context.fetch(FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL.starts(with: prefix) }))) ?? []
        for show in shows {
            for episode in show.episodes {
                if let name = episode.localFilename {
                    try? FileManager.default.removeItem(at: FileStore.episodesDirectory.appendingPathComponent(name))
                }
                try? FileManager.default.removeItem(at: TranscriptStore.url(episode.guid))
            }
            context.delete(show)
        }
        try? context.save()
        FileIndex.refresh()
    }

    private struct Export: Decodable {
        struct Item: Decodable {
            var guid: String
            var title: String
            var show: String?
            var duration: Double?
            var audioURL: String?
            var transcript: [TimedLine]?
            var segments: [Cut]?
            var readerSegments: [Cut]?
        }
        struct Cut: Decodable {
            var start: Double
            var end: Double
            var kind: String?
            var sponsor: String?
            var confidence: Int?
            var evidence: String?
            var delivery: String?
        }
        var episodes: [Item]
    }

    private static func seed(from url: URL, context: ModelContext) -> Int {
        guard let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(Export.self, from: data) else {
            print("LabDownloadedLibrary: couldn't read \(url.path)")
            return 0
        }
        var shows: [String: Podcast] = [:]
        try? FileManager.default.createDirectory(at: FileStore.episodesDirectory, withIntermediateDirectories: true)
        for (n, item) in export.episodes.enumerated() {
            let name = item.show ?? "Show"
            let show = shows[name] ?? {
                let slug = name.lowercased().filter { $0.isLetter || $0.isNumber }
                let podcast = Podcast(feedURL: feedPrefix + slug, title: "Lab · " + name)
                context.insert(podcast)
                shows[name] = podcast
                return podcast
            }()
            let guid = "lab-dl-" + item.guid
            let episode = Episode(guid: guid, title: item.title, episodeDescription: "",
                                  audioURL: item.audioURL ?? "https://lab.invalid/\(n).mp3",
                                  publishedAt: Date(timeIntervalSinceNow: -Double(n) * 86_400),
                                  duration: item.duration ?? 3_600)
            episode.podcast = show
            context.insert(episode)
            let lines = item.transcript ?? []
            // As the pipeline stores them: the plain text in the row, the
            // timed lines in TranscriptStore's file.
            episode.transcriptText = lines.map(\.text).joined(separator: " ")
            episode.storeTranscript(lines)
            var silences: [ClosedRange<Double>] = []
            for (a, b) in zip(lines, lines.dropFirst()) where b.start - a.end > 0.3 { silences.append(a.end...b.start) }
            episode.storeSilence(silences)
            for cut in item.segments ?? [] {
                let segment = AdSegment(start: cut.start, end: cut.end, sponsor: cut.sponsor ?? "",
                                        confidence: cut.confidence ?? 0,
                                        kind: SegmentKind(rawValue: cut.kind ?? "") ?? .ad)
                segment.evidenceText = cut.evidence ?? ""
                segment.deliveryRaw = cut.delivery ?? ""
                segment.episode = episode
                context.insert(segment)
            }
            let reader = (item.readerSegments ?? []).map {
                ["start": $0.start, "end": $0.end, "confidence": Double($0.confidence ?? 0)]
            }
            episode.readerSegmentsData = try? JSONSerialization.data(withJSONObject: reader)
            episode.processingState = .ready
            episode.detectorVersion = AdDetector.version
            episode.lastProcessedAt = .now
            let file = guid + ".mp3"
            FileManager.default.createFile(atPath: FileStore.episodesDirectory.appendingPathComponent(file).path,
                                           contents: Data(count: 1024))
            episode.localFilename = file
            episode.audioFileLength = item.duration ?? 3_600
        }
        try? context.save()
        return export.episodes.count
    }
}
#endif
