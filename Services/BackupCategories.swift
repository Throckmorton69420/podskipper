import Foundation

/// Pass 35 (his request): what a backup holds, in parts he can choose
/// when making one and when restoring one.
///
/// The parts follow how the data is stored. Shows, episodes, listening
/// history and positions, stars, bookmarks, stations, the ads found and his
/// corrections are one database (`library`) — SwiftData keeps them together
/// with their relationships, so they are backed up and restored together;
/// taking pieces out of that database would break the links between them.
/// Everything else is a folder of its own and can be left out or kept.
enum BackupCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case library, settings, transcripts, processing, adPrints, readerLearning, audio, diagnostics, artwork, other

    var id: Self { self }

    var title: String {
        switch self {
        case .library: "Library"
        case .settings: "Settings"
        case .transcripts: "Transcripts"
        case .processing: "Unfinished ad finding"
        case .adPrints: "Ad fingerprints"
        case .readerLearning: "What the reader learned"
        case .audio: "Downloaded audio"
        case .diagnostics: "Diagnostics"
        case .artwork: "Artwork"
        case .other: "Other app files"
        }
    }

    var detail: String {
        switch self {
        case .library: "Shows, episodes, listening history and positions, stars, bookmarks, stations, every ad found and your corrections, locks and edits. One database, so these go together."
        case .settings: "App, playback and Speed & Audio settings, per-show settings stored in settings, chosen models and ad-finding preferences."
        case .transcripts: "Transcripts and partly finished transcriptions. Without them, finding ads again needs a new transcription."
        case .processing: "Where unfinished ad finding and publishing jobs got to, and saved model answers, so they continue instead of starting over."
        case .adPrints: "Audio fingerprints of ads already heard, used to recognise the same ad in other episodes."
        case .readerLearning: "What PodSkipper's reader has learned on this iPhone from your corrections and checked model reads."
        case .audio: "Downloaded episode audio. Large; it can be downloaded again."
        case .diagnostics: "Logs, timings, iOS reports and model test history kept for working out problems."
        case .artwork: "Saved show and episode artwork. It is fetched again when missing."
        case .other: "Anything else PodSkipper keeps that isn't in the parts above."
        }
    }

    /// Chosen when he picks "Back Up Everything" (audio has its own switch).
    static let everything: Set<BackupCategory> = Set(allCases).subtracting([.audio])

    /// The part a top-level entry of Application Support belongs to.
    static func of(appSupportEntry name: String) -> BackupCategory {
        if name.hasSuffix(".store") || name.hasSuffix(".sqlite") || name.hasSuffix(".store-wal")
            || name.hasSuffix(".store-shm") { return .library }
        switch name {
        case "Transcripts", "TranscriptCheckpoints": return .transcripts
        case "Processing", "Publishing": return .processing
        case "PrintLibrary": return .adPrints
        case "Detection": return .readerLearning
        case "Episodes": return .audio
        case "Diagnostics": return .diagnostics
        case "Artwork": return .artwork
        default: return .other
        }
    }

    /// The part a path inside the archive belongs to (nil: bookkeeping).
    static func of(archivePath path: String) -> BackupCategory? {
        if path == "manifest.json" { return nil }
        if path == "defaults.plist" { return .settings }
        if path.hasPrefix("Checkpoints/") { return .processing }
        if path.hasPrefix("AppSupport/") {
            let first = path.dropFirst("AppSupport/".count).split(separator: "/").first.map(String.init) ?? ""
            return of(appSupportEntry: first)
        }
        return .other
    }

    struct Summary: Sendable, Equatable {
        var files = 0
        var bytes: Int64 = 0
    }

    /// Files and bytes per part, from a backup's inventory.
    static func summarize(_ files: [String: Int64]) -> [BackupCategory: Summary] {
        var out: [BackupCategory: Summary] = [:]
        for (path, size) in files {
            guard let category = of(archivePath: path) else { continue }
            out[category, default: Summary()].files += 1
            out[category, default: Summary()].bytes += size
        }
        return out
    }
}

/// Which parts of a staged backup to put in place. Written beside the
/// staged backup when he chooses; absent = every part the backup holds.
struct RestorePlan: Codable, Sendable, Equatable {
    var categories: Set<BackupCategory>

    static func url(in staged: URL) -> URL { staged.appending(path: "restore-plan.json") }

    static func load(from staged: URL) -> RestorePlan? {
        (try? Data(contentsOf: url(in: staged))).flatMap { try? JSONDecoder().decode(RestorePlan.self, from: $0) }
    }

    func save(to staged: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(in: staged), options: .atomic)
    }
}

extension BackupService {
    /// What each part takes on the phone now, for choosing what to back up.
    /// Off the main thread; reads sizes only.
    nonisolated static func categorySizes(locations: Locations = .live) -> [BackupCategory: Int64] {
        let fm = FileManager.default
        var sizes: [BackupCategory: Int64] = [:]
        let separate = locations.transaction.separateStoreDirectory
        for item in (try? fm.contentsOfDirectory(at: locations.appSupport, includingPropertiesForKeys: nil)) ?? [] {
            let name = item.lastPathComponent
            if name == ModelStore.folderName || name == "CoreAIKit" { continue }
            let category = BackupCategory.of(appSupportEntry: name)
            if category == .library, separate != nil { continue }
            if name.hasSuffix("-wal") || name.hasSuffix("-shm") { continue }
            sizes[category, default: 0] += ModelStorage.size(of: item)
        }
        if let separate {
            for item in (try? fm.contentsOfDirectory(at: separate, includingPropertiesForKeys: nil)) ?? []
                where item.pathExtension == "store" || item.pathExtension == "sqlite" {
                sizes[.library, default: 0] += ModelStorage.size(of: item)
            }
        }
        sizes[.processing, default: 0] += ModelStorage.size(of: locations.checkpoints)
        let settings = locations.defaults.persistentDomain(forName: locations.domain) ?? [:]
        sizes[.settings] = Int64((try? PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0))?.count ?? 0)
        return sizes
    }
}
