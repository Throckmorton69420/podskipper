import Foundation
import AVFoundation

/// A stretch of an episode as a small audio file to send someone (task 07).
///
/// The clip is the episode's own audio between two moments, with PodSkipper's
/// cuts taken out — the same ads that are skipped when listening — the
/// episode's artwork as its cover, and "Show — Episode (12:30–13:30)" as its
/// title. It is copied, not re-recorded from what is heard, so the equaliser
/// and repairs are not in it.
enum ClipExporter {

    /// The longest clip, as Apple Podcasts allows.
    static let maxLength: Double = 180

    struct Request: Sendable {
        /// The episode's audio: the download when there is one, else the
        /// feed's address (the export then fetches just what it needs).
        var source: URL
        var range: ClosedRange<Double>
        /// What PlayerEngine skips, so the clip matches what is heard.
        var cuts: [ClosedRange<Double>]
        var showTitle: String
        var episodeTitle: String
        var artwork: Data?
    }

    enum ExportError: LocalizedError {
        case noAudio
        case nothingLeft
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noAudio:     return "This episode's audio couldn't be read."
            case .nothingLeft: return "That stretch is all ads, so there's nothing left to share."
            case .failed(let reason): return "The clip couldn't be made: \(reason)"
            }
        }
    }

    /// "Stavvy's World — #199 Are You Garbage? (12:30–13:30)"
    static func title(show: String, episode: String, range: ClosedRange<Double>) -> String {
        let span = "\(stamp(range.lowerBound))–\(stamp(range.upperBound))"
        return show.isEmpty ? "\(episode) (\(span))" : "\(show) — \(episode) (\(span))"
    }

    /// The parts of `range` left once `cuts` are taken out, in order.
    /// Pieces under a tenth of a second are dropped: a sliver between two
    /// cuts is a click, not audio.
    static func pieces(of range: ClosedRange<Double>, removing cuts: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var pieces: [ClosedRange<Double>] = []
        var cursor = range.lowerBound
        for cut in cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) where cut.upperBound > cursor {
            guard cut.lowerBound < range.upperBound else { break }
            if cut.lowerBound > cursor { pieces.append(cursor...cut.lowerBound) }
            cursor = max(cursor, cut.upperBound)
        }
        if cursor < range.upperBound { pieces.append(cursor...range.upperBound) }
        return pieces.filter { $0.upperBound - $0.lowerBound >= 0.1 }
    }

    /// Writes the clip to a temporary file and returns it. `progress` is
    /// called with 0…1 as the export runs.
    static func export(_ request: Request, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: request.source)
        guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExportError.noAudio
        }
        let parts = pieces(of: request.range, removing: request.cuts)
        guard !parts.isEmpty else { throw ExportError.nothingLeft }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.noAudio
        }
        var at = CMTime.zero
        for part in parts {
            let span = CMTimeRange(start: CMTime(seconds: part.lowerBound, preferredTimescale: 44_100),
                                   end: CMTime(seconds: part.upperBound, preferredTimescale: 44_100))
            try track.insertTimeRange(span, of: sourceTrack, at: at)
            at = at + span.duration
        }

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ExportError.failed("no exporter for this audio")
        }
        let name = title(show: request.showTitle, episode: request.episodeTitle, range: request.range)
        session.metadata = metadata(title: name, request: request)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(fileName(name) + ".m4a")
        try? FileManager.default.removeItem(at: destination)

        let watcher = Task {
            for await state in session.states(updateInterval: 0.1) {
                if case .exporting(let running) = state { progress(running.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        do {
            try await session.export(to: destination, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw ExportError.failed(error.localizedDescription)
        }
        progress(1)
        return destination
    }

    // MARK: Helpers

    private static func metadata(title: String, request: Request) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol,
                  dataType: String? = nil) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            if let dataType { item.dataType = dataType }
            item.extendedLanguageTag = "und"
            return item
        }
        var items = [
            item(.commonIdentifierTitle, title as NSString),
            item(.commonIdentifierArtist, request.showTitle as NSString),
            item(.commonIdentifierAlbumName, request.episodeTitle as NSString),
        ]
        if let artwork = request.artwork {
            items.append(item(.commonIdentifierArtwork, artwork as NSData,
                              dataType: kCMMetadataBaseDataType_JPEG as String))
        }
        return items
    }

    /// "12:30", or "1:02:30" past an hour.
    static func stamp(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Safe as a file name: no slashes or colons, not absurdly long.
    private static func fileName(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = title.components(separatedBy: bad).joined(separator: "-")
        return String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
    }
}
