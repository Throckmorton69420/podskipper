import Foundation
import UIKit
import ImageIO

/// Where podcast artwork lives once it has been fetched.
///
/// The bug this exists to fix: covers vanishing, and vanishing *especially*
/// after pressing Find Ads. Both symptoms come from the same place. Artwork was
/// held only in an `NSCache`, and `NSCache` evicts under memory pressure — which
/// is exactly what transcribing an episode and running a language model
/// produces. So the moment the app did the thing it exists to do, every cover on
/// screen was purged, and each one had to go back to the network.
///
/// The second half of the bug is that going back to the network had no second
/// chance. A single failed fetch — a moment offline, a timeout, a request the
/// system cancelled while scrolling — left the image nil, and the view's
/// `.task(id: url)` never fired again because the URL had not changed. A blank
/// square, permanently, until something else forced the view to be rebuilt.
///
/// So: bytes go to disk as well as to memory, memory is a convenience rather
/// than the source of truth, and a failure is remembered as a failure with a
/// time on it rather than as an answer.
actor ArtworkStore {

    static let shared = ArtworkStore()

    /// Where the bytes live between launches.
    ///
    /// Caches rather than Documents: the system may reclaim it under storage
    /// pressure, which is correct for something re-fetchable, and it keeps
    /// artwork out of the user's iCloud backup.
    private let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// URLs whose last fetch failed, and when. Retried after a cool-off rather
    /// than hammered on every scroll, and never treated as permanent.
    private var failures: [String: Date] = [:]
    private static let retryAfter: TimeInterval = 20

    private var inFlight: [String: Task<Data?, Never>] = [:]

    private func path(for url: String) -> URL {
        // A stable filename that cannot collide and cannot contain a slash.
        var hash: UInt64 = 5381
        for byte in url.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return directory.appendingPathComponent(String(hash, radix: 36))
    }

    /// The bytes for this artwork, from disk if they are there and from the
    /// network if they are not.
    func data(for url: String) async -> Data? {
        let file = path(for: url)
        if let onDisk = try? Data(contentsOf: file), !onDisk.isEmpty {
            return onDisk
        }

        if let failedAt = failures[url], Date().timeIntervalSince(failedAt) < Self.retryAfter {
            return nil
        }

        if let existing = inFlight[url] { return await existing.value }

        let task = Task<Data?, Never> {
            guard let parsed = URL(string: url) else { return nil }
            var request = URLRequest(url: parsed)
            request.timeoutInterval = 20
            guard let (bytes, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  !bytes.isEmpty
            else { return nil }
            return bytes
        }
        inFlight[url] = task
        let bytes = await task.value
        inFlight[url] = nil

        if let bytes {
            failures[url] = nil
            try? bytes.write(to: file, options: .atomic)
        } else {
            failures[url] = Date()
        }
        return bytes
    }

    /// Drop everything. Only used by the "clear cache" control in Settings.
    func empty() {
        failures.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Bytes on disk, for the storage figure in Settings.
    func diskBytes() -> Int64 {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { total, item in
            total + Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Decode at the size it will be drawn, not at the size it was published.
    ///
    /// Podcast covers are routinely 3000×3000, which is about 36 MB decoded.
    /// A screen of those is what made scrolling stutter and what filled the
    /// memory cache fast enough to start evicting itself.
    nonisolated static func downsample(_ data: Data, to pixels: Int) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: thumb, scale: 1, orientation: .up)
    }
}
