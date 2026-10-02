import Foundation
import AVFoundation
import Accelerate

/// Audio fingerprints: finding the same recording twice (research §2 H2,
/// stage 2 of the plan in §5).
///
/// Everything produced is played again and again — a show's theme song and
/// closing music every episode, a network's promos, the same produced ad in
/// the pre-roll, mid-roll and post-roll, the same trailer on several shows.
/// Conversation never is. So audio that also appears in the show's previous
/// episode, or matches something already known to be an ad, is produced
/// material, found to a few hundredths of a second with no language model.
///
/// The method is the one Shazam published (Wang 2003): the loudest points of
/// the spectrum (8 kHz mono, 64 ms frames every 32 ms), paired with the next
/// few peaks into hashes of (frequency, frequency, time apart), and two
/// recordings match where many hashes agree on the same time offset. The lab
/// measured it (DETECTION-AUDIT): false matches under ten votes, true ones in
/// the hundreds.
enum AdPrints {

    /// Seconds per fingerprint frame.
    static let hop = 256.0 / 8000.0

    /// One recording's hashes and the frame each starts at, in time order.
    struct Landmarks: Sendable {
        var hashes: [UInt32] = []
        var frames: [Int32] = []
        var seconds: Double = 0

        var count: Int { hashes.count }

        /// The part between two times, with frames made relative to its start.
        func slice(_ range: ClosedRange<Double>) -> Landmarks {
            let a = Int32(range.lowerBound / AdPrints.hop), b = Int32(range.upperBound / AdPrints.hop)
            var out = Landmarks(seconds: range.upperBound - range.lowerBound)
            for i in frames.indices where frames[i] >= a && frames[i] <= b {
                out.hashes.append(hashes[i])
                out.frames.append(frames[i] - a)
            }
            return out
        }

        // Compact file form: count, then hashes, then frames (little-endian).
        func data() -> Data {
            var d = Data()
            var n = UInt32(count), s = Float(seconds)
            d.append(Data(bytes: &n, count: 4))
            d.append(Data(bytes: &s, count: 4))
            hashes.withUnsafeBytes { d.append(contentsOf: $0) }
            frames.withUnsafeBytes { d.append(contentsOf: $0) }
            return d
        }

        init(hashes: [UInt32] = [], frames: [Int32] = [], seconds: Double = 0) {
            self.hashes = hashes; self.frames = frames; self.seconds = seconds
        }

        init?(data: Data) {
            guard data.count >= 8 else { return nil }
            let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
            let s = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Float.self) }
            guard data.count == 8 + n * 8 else { return nil }
            hashes = data.subdata(in: 8..<(8 + n * 4)).withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            frames = data.subdata(in: (8 + n * 4)..<(8 + n * 8)).withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
            seconds = Double(s)
        }
    }

    // MARK: Making them

    enum PrintError: Error { case unreadable }

    /// The landmarks of an audio file, decoded a few seconds at a time so a
    /// two-hour episode never sits in memory. An hour takes a few seconds.
    static func landmarks(fileURL: URL) throws -> Landmarks {
        let file = try AVAudioFile(forReading: fileURL)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else { throw PrintError.unreadable }
        converter.downmix = true
        let chunk = AVAudioFrameCount(inFormat.sampleRate * 4)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8000 * 5) else {
            throw PrintError.unreadable
        }
        let maker = Maker()
        var ended = false
        while !ended {
            outBuffer.frameLength = 0
            var failure: NSError?
            let status = converter.convert(to: outBuffer, error: &failure) { _, state in
                do { try file.read(into: inBuffer, frameCount: chunk) } catch {
                    state.pointee = .endOfStream; return nil
                }
                if inBuffer.frameLength == 0 { state.pointee = .endOfStream; return nil }
                state.pointee = .haveData
                return inBuffer
            }
            if let samples = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                maker.feed(UnsafeBufferPointer(start: samples, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream || status == .error { ended = true }
        }
        return maker.finish()
    }

    /// Streaming spectrogram → peaks → hashes.
    final class Maker {
        private let size = 512, half = 256
        private let log2n: vDSP_Length = 9
        private let setup: FFTSetup
        private var window = [Float](repeating: 0, count: 512)
        private var pending: [Float] = []
        private var frame = 0
        /// The last 15 spectra and their maxima across ±7 bins, for peaks
        /// that are the loudest point within ±7 frames and ±7 bins.
        private var ring: [[Float]] = []
        private var ringMax: [[Float]] = []
        private var meanLevel: Float = 0
        private var framesSeen: Float = 0
        private var anchors: [(t: Int32, f: Int32, fan: Int)] = []
        private(set) var out = Landmarks()

        init() {
            setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
            vDSP_hann_window(&window, 512, Int32(vDSP_HANN_NORM))
        }
        deinit { vDSP_destroy_fftsetup(setup) }

        func feed(_ samples: UnsafeBufferPointer<Float>) {
            pending.append(contentsOf: samples)
            var offset = 0
            while offset + size <= pending.count {
                spectrum(at: offset)
                offset += half
            }
            pending.removeFirst(offset)
        }

        func finish() -> Landmarks {
            out.seconds = Double(frame) * AdPrints.hop
            return out
        }

        private func spectrum(at offset: Int) {
            var windowed = [Float](repeating: 0, count: size)
            pending.withUnsafeBufferPointer { p in
                vDSP_vmul(p.baseAddress! + offset, 1, window, 1, &windowed, 1, vDSP_Length(size))
            }
            var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
            var mags = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    split.imagp[0] = 0                   // the Nyquist bin; DC is dropped below
                    vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                }
            }
            mags[0] = 0
            var n = Int32(half)
            vvlog1pf(&mags, mags, &n)
            add(mags)
            frame += 1
        }

        private func add(_ s: [Float]) {
            var padded = [Float](repeating: -1, count: half + 14)
            padded.replaceSubrange(7..<(7 + half), with: s)
            var fmax = [Float](repeating: 0, count: half)
            vDSP_vswmax(padded, 1, &fmax, 1, vDSP_Length(half), 15)
            ring.append(s); ringMax.append(fmax)
            if ring.count > 15 { ring.removeFirst(); ringMax.removeFirst() }
            var mean: Float = 0
            vDSP_meanv(s, 1, &mean, vDSP_Length(half))
            meanLevel = (meanLevel * framesSeen + mean) / (framesSeen + 1)
            framesSeen += 1
            guard ring.count == 15 else { return }
            var local = ringMax[0]
            for k in 1..<15 { vDSP_vmax(local, 1, ringMax[k], 1, &local, 1, vDSP_Length(half)) }
            let centre = ring[7]
            let t = Int32(frame - 7)
            for f in 1..<half where centre[f] >= local[f] && centre[f] > meanLevel {
                pair(t: t, f: Int32(f))
            }
        }

        private func pair(t: Int32, f: Int32) {
            anchors.removeAll { t - $0.t > 63 }
            for i in anchors.indices where anchors[i].fan < 6 && t > anchors[i].t && abs(f - anchors[i].f) < 64 {
                let dt = UInt32(t - anchors[i].t)
                out.hashes.append(UInt32(anchors[i].f) << 14 | UInt32(f) << 6 | dt)
                out.frames.append(anchors[i].t)
                anchors[i].fan += 1
            }
            anchors.append((t, f, 0))
        }
    }

    // MARK: Finding them

    /// A stretch of one recording that plays again in another (or later in
    /// itself). Times are in the probe; `offset` added to them gives the
    /// other recording's.
    struct Repeat: Sendable, Equatable {
        var start: Double
        var end: Double
        var offset: Double
        var votes: Int
        var seconds: Double { end - start }
    }

    /// One recording's hashes, sorted for lookup.
    struct Index: Sendable {
        let keys: [UInt64]
        let seconds: Double

        init(_ l: Landmarks) {
            keys = zip(l.hashes, l.frames).map { UInt64($0) << 32 | UInt64(UInt32(bitPattern: $1)) }.sorted()
            seconds = l.seconds
        }

        @inline(__always)
        func forEachFrame(of hash: UInt32, _ body: (Int32) -> Void) {
            let low = UInt64(hash) << 32
            var a = 0, b = keys.count
            while a < b { let m = (a + b) >> 1; if keys[m] < low { a = m + 1 } else { b = m } }
            while a < keys.count, keys[a] >> 32 == UInt64(hash) {
                body(Int32(bitPattern: UInt32(truncatingIfNeeded: keys[a])))
                a += 1
            }
        }
    }

    /// Stretches of `probe` that also play in the indexed recording: many
    /// hashes agreeing on one time offset, over at least `minSeconds`, at
    /// least `minDensity` agreeing hashes a second. Random agreement across
    /// an hour is under ten hashes (lab); a real repeat is hundreds.
    /// `skipNear` ignores offsets under that many seconds — a recording
    /// against itself.
    static func repeats(of probe: Landmarks, in index: Index, minSeconds: Double = 8,
                        minDensity: Double = 2.5, skipNear: Double? = nil) -> [Repeat] {
        let bias: Int64 = 1 << 30
        let skip = skipNear.map { Int32($0 / hop) }
        var pairs: [UInt64] = []
        pairs.reserveCapacity(probe.count / 4)
        for i in probe.hashes.indices {
            let t = probe.frames[i]
            index.forEachFrame(of: probe.hashes[i]) { other in
                let offset = other - t
                if let skip, abs(offset) < skip { return }
                // Offsets in bins of two frames; a real repeat jitters by one.
                let bin = UInt64((Int64(offset) + bias) >> 1)
                pairs.append(bin << 32 | UInt64(UInt32(bitPattern: t)))
            }
        }
        pairs.sort()
        var groups: [(bin: UInt64, range: Range<Int>)] = []
        var i = 0
        while i < pairs.count {
            let bin = pairs[i] >> 32
            var j = i + 1
            while j < pairs.count, pairs[j] >> 32 == bin { j += 1 }
            groups.append((bin, i..<j))
            i = j
        }
        let minVotes = Int(minSeconds * minDensity)
        let gap: Int32 = 62                       // two seconds without agreement ends a run
        var found: [Repeat] = []
        for g in groups.indices {
            let neighbour = g + 1 < groups.count && groups[g + 1].bin == groups[g].bin + 1 ? groups[g + 1].range : 0..<0
            guard groups[g].range.count + neighbour.count >= minVotes else { continue }
            var times = (Array(pairs[groups[g].range]) + Array(pairs[neighbour]))
                .map { Int32(bitPattern: UInt32(truncatingIfNeeded: $0)) }
            times.sort()
            let offset = (Double(Int64(groups[g].bin) * 2 - bias) + 0.5) * hop
            var first = 0
            for k in 1...times.count {
                if k == times.count || times[k] - times[k - 1] > gap {
                    let a = Double(times[first]) * hop, b = Double(times[k - 1]) * hop + 0.5
                    let votes = k - first
                    if b - a >= minSeconds, Double(votes) / (b - a) >= minDensity {
                        found.append(Repeat(start: a, end: b, offset: offset, votes: votes))
                    }
                    first = k
                }
            }
        }
        // The same repeat is seen from two neighbouring bins; keep the stronger.
        var kept: [Repeat] = []
        for r in found.sorted(by: { $0.votes > $1.votes }) {
            let duplicate = kept.contains { k in
                abs(k.offset - r.offset) < 0.2 && min(k.end, r.end) - max(k.start, r.start) > 0.5 * r.seconds
            }
            if !duplicate { kept.append(r) }
        }
        return kept.sorted { $0.start < $1.start }
    }

    // MARK: Per show

    /// Produced audio found in one episode: where, and whether it was found
    /// in another episode of the show (a theme, a network promo, an ad run
    /// again) or only twice within this one (the same spot in two breaks).
    struct Produced: Sendable, Equatable, Codable {
        var start: Double
        var end: Double
        var acrossEpisodes: Bool
        /// Found in the library of recordings known from any show (pass 19):
        /// what it was there ("ad", "crossPromo"…), so no question is needed.
        var known: String? = nil
        /// A recording the listener said is not an ad: nothing found by
        /// fingerprint is cut over it.
        var negative: Bool = false
        /// Optional so old cached regions remain readable, without silently
        /// promoting their historical automatic classification to current truth.
        var evidenceProvenance: String? = nil
        var evidencePolicyVersion: Int? = nil

        init(start: Double, end: Double, acrossEpisodes: Bool, known: String? = nil, negative: Bool = false,
             evidenceProvenance: String? = nil, evidencePolicyVersion: Int? = nil) {
            self.start = start; self.end = end; self.acrossEpisodes = acrossEpisodes
            self.known = known; self.negative = negative
            self.evidenceProvenance = evidenceProvenance; self.evidencePolicyVersion = evidencePolicyVersion
        }

        /// Preserve the raw cache/history, but do not turn an unverified
        /// library positive into generic across-episode evidence: that fallback
        /// can itself classify the region as an ad. Contextual repeats that
        /// never asserted a known class are retained.
        var validatedForDetection: Produced? {
            if negative {
                var checked = self
                checked.known = nil
                return checked
            }
            if known != nil && !Library.trustsPositive(provenance: evidenceProvenance, version: evidencePolicyVersion) {
                return nil
            }
            return self
        }

        // Episodes saved before pass 19 have no `known` or `negative`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            start = try c.decode(Double.self, forKey: .start)
            end = try c.decode(Double.self, forKey: .end)
            acrossEpisodes = try c.decode(Bool.self, forKey: .acrossEpisodes)
            known = try c.decodeIfPresent(String.self, forKey: .known)
            negative = try c.decodeIfPresent(Bool.self, forKey: .negative) ?? false
            evidenceProvenance = try c.decodeIfPresent(String.self, forKey: .evidenceProvenance)
            evidencePolicyVersion = try c.decodeIfPresent(Int.self, forKey: .evidencePolicyVersion)
        }
    }

    /// Normalize every detection entry point (fresh, prepared, or cached),
    /// without rewriting the original fingerprint evidence or its history.
    static func detectionEvidence(_ produced: [Produced], duration: Double) -> [Produced] {
        guard duration.isFinite, duration > 0 else { return [] }
        return produced.compactMap { raw in
            guard raw.start.isFinite, raw.end.isFinite, raw.start >= 0,
                  raw.end > raw.start, raw.end <= duration else { return nil }
            return raw.validatedForDetection
        }
    }

    /// Where each show's recent episodes' fingerprints are kept (Caches, so
    /// the system may clear them; the only cost is one episode's comparison).
    static func folder(show: String) -> URL {
        // FNV-1a of the show's feed address: stable, short, never shared.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in show.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fingerprints", isDirectory: true)
            .appendingPathComponent(String(hash, radix: 16), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The show's other recent episodes, newest first. About 1 MB per hour.
    static func previous(show: String, excluding guid: String, limit: Int = 2) -> [Landmarks] {
        let own = fileName(guid)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder(show: show),
                                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent != own }
            .sorted { modified($0) > modified($1) }
            .prefix(limit)
            .compactMap { (try? Data(contentsOf: $0)).flatMap(Landmarks.init(data:)) }
    }

    /// Keep this episode's fingerprints for the show's next one; only the
    /// newest three per show are kept.
    static func remember(_ l: Landmarks, show: String, guid: String) {
        let dir = folder(show: show)
        try? l.data().write(to: dir.appendingPathComponent(fileName(guid)), options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for old in files.sorted(by: { modified($0) > modified($1) }).dropFirst(3) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static func fileName(_ guid: String) -> String {
        String(guid.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.suffix(60)) + ".lm"
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Everything in this episode that plays again — in the show's other
    /// episodes, or twice within this one. Well under a second for an hour.
    static func produced(in episode: Landmarks, previous: [Landmarks]) -> [Produced] {
        var across: [Repeat] = []
        for other in previous { across += repeats(of: episode, in: Index(other)) }
        let within = repeats(of: episode, in: Index(episode), skipNear: 20)
        // A theme with a quiet bar in the middle matches as two pieces a few
        // seconds apart; they are one thing.
        var out = merged(across, within: 5).map { Produced(start: $0.lowerBound, end: $0.upperBound, acrossEpisodes: true) }
        for range in merged(within, within: 5) where !out.contains(where: { $0.start < range.upperBound && $0.end > range.lowerBound }) {
            out.append(Produced(start: range.lowerBound, end: range.upperBound, acrossEpisodes: false))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Stretches, merged, where the recording repeats something else.
    static func merged(_ repeats: [Repeat], within gap: Double = 1.5) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for r in repeats.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, r.start <= last.upperBound + gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.end)
            } else {
                out.append(r.start...r.end)
            }
        }
        return out
    }

    /// The landmarks kept for one episode (see `remember`), if still there.
    static func stored(show: String, guid: String) -> Landmarks? {
        (try? Data(contentsOf: folder(show: show).appendingPathComponent(fileName(guid)))).flatMap(Landmarks.init(data:))
    }

    // MARK: Across shows (pass 19)

    /// Recordings known to be ads or promos, from any of his shows: the
    /// research's cross-show library (stage 2, "next"). The same Liquid IV,
    /// Disney+ and Peacock spots, and the same network promos, run on several
    /// of his shows — measured: every cross-show repeat among the eleven lab
    /// episodes was an ad or a promo but one nine-second piece. A spot
    /// learned where it is certain — stitched in at download (the ad-free
    /// comparison), a repeat the model called an ad, a cut he confirmed — is
    /// then found by its sound on any show, to the frame, with no question.
    /// A cut he marks "not an ad" is kept as a negative: that recording is
    /// never cut by fingerprint again.
    enum Library {
        /// Current automatic learning follows the guarded comparison/explicit
        /// classification policy. Older positives need revalidation; negatives
        /// and known user corrections remain authoritative.
        static let currentEvidencePolicyVersion = 2
        enum Provenance: String, Codable, Sendable {
            case currentAutomatic, userCorrection
        }
        static func trustsPositive(provenance: String?, version: Int?) -> Bool {
            provenance == Provenance.userCorrection.rawValue
                || (provenance == Provenance.currentAutomatic.rawValue && version == currentEvidencePolicyVersion)
        }
        struct Entry: Codable, Sendable {
            var id: String
            var show: String
            /// The episode it came from: never used to find itself.
            var source: String
            var kind: String
            var negative: Bool
            var seconds: Double
            var added: Date
            var lastMatched: Date
            /// Strings preserve unknown future provenance without breaking all
            /// other records. Missing historical positive provenance is unknown.
            var provenance: String? = nil
            var evidencePolicyVersion: Int? = nil
            var verificationSource: String? = nil

            var hasUsableMetadata: Bool {
                UUID(uuidString: id) != nil && seconds.isFinite && seconds >= 8 && seconds <= 150
            }
            var isTrustedForMatching: Bool {
                hasUsableMetadata && (negative || trustsPositive(provenance: provenance, version: evidencePolicyVersion))
            }
            var isQuarantined: Bool { !isTrustedForMatching }
        }

        struct Match: Sendable, Equatable {
            var start: Double
            var end: Double
            var kind: String
            var negative: Bool
            var entry: String
            var provenance: String? = nil
            var evidencePolicyVersion: Int? = nil
        }

        /// Limit the automatic matching set, while retaining all history and
        /// files. Explicit corrections/negatives are never evicted by this cap.
        static let cap = 300

        nonisolated(unsafe) static var folderOverride: URL?
        static var folder: URL {
            let url = folderOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PrintLibrary", isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private static let lock = NSLock()
        nonisolated(unsafe) private static var cache: (folder: URL, entries: [Entry], index: Index, bases: [Int32])?

        /// Includes quarantine/history; consumers must not treat this as the
        /// active detection set. No migration rewrites or deletes legacy files.
        static func entries() -> [Entry] { lock.withLock { load() ?? [] } }

        /// Nil means an existing index is unreadable. Writes fail closed instead
        /// of replacing an unknown learned library with an empty one.
        private static func load() -> [Entry]? {
            let url = folder.appendingPathComponent("index.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            guard let data = try? Data(contentsOf: url) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try? decoder.decode([Entry].self, from: data)
        }

        @discardableResult
        private static func save(_ list: [Entry]) -> Bool {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            guard let data = try? encoder.encode(list),
                  (try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)) != nil else { return false }
            cache = nil
            return true
        }

        private static func matchingEntries(_ all: [Entry]) -> [Entry] {
            let trusted = all.filter { $0.isTrustedForMatching }
            let automatic = trusted.filter { !$0.negative && $0.provenance != Provenance.userCorrection.rawValue }
                .sorted { $0.lastMatched > $1.lastMatched }.prefix(cap)
            let ids = Set(automatic.map(\.id))
            return trusted.filter { $0.negative || $0.provenance == Provenance.userCorrection.rawValue || ids.contains($0.id) }
        }

        private static func usable(_ print: Landmarks) -> Bool {
            guard print.seconds.isFinite, print.seconds >= 8, print.seconds <= 150,
                  print.count >= 40, print.hashes.count == print.frames.count else { return false }
            let maxFrame = Int32((print.seconds / hop).rounded(.up)) + 2
            return print.frames.allSatisfy { $0 >= 0 && $0 <= maxFrame }
        }

        /// Every eligible entry end to end, with a minute between recordings.
        private static func combined(_ list: [Entry]) -> (Index, [Int32]) {
            let directory = folder
            if let cache, cache.folder == directory, cache.entries.map(\.id) == list.map(\.id) {
                return (cache.index, cache.bases)
            }
            // Corrupt/imported indexes must not overflow the 32-bit timeline.
            guard list.count <= Int(Int32.max) / 7000 else { return (Index(Landmarks()), []) }
            var all = Landmarks()
            var bases: [Int32] = []
            var base: Int32 = 0
            for e in list {
                bases.append(base)
                if let l = (try? Data(contentsOf: directory.appendingPathComponent(e.id + ".lm"))).flatMap(Landmarks.init(data:)), usable(l) {
                    all.hashes += l.hashes
                    all.frames += l.frames.map { $0 + base }
                }
                // Library metadata was bounded before reaching this function.
                base += Int32(e.seconds / hop) + 2000
            }
            all.seconds = Double(base) * hop
            let index = Index(all)
            cache = (directory, list, index, bases)
            return (index, bases)
        }

        static func matches(in episode: Landmarks, excludingSource source: String = "") -> [Match] {
            lock.withLock {
                guard episode.seconds.isFinite, episode.seconds > 0,
                      episode.hashes.count == episode.frames.count,
                      episode.frames.allSatisfy({ $0 >= 0 && $0 < 1 << 30 }),
                      let all = load() else { return [] }
                let list = matchingEntries(all)
                guard !list.isEmpty else { return [] }
                let (index, bases) = combined(list)
                var out: [Match] = []
                var touched = Set<String>()
                for r in repeats(of: episode, in: index) {
                    let other = Int32(((r.start + r.offset) / hop).rounded())
                    guard let n = bases.lastIndex(where: { $0 <= other }), list[n].source != source, list[n].verificationSource != source else { continue }
                    let e = list[n]
                    touched.insert(e.id)
                    if let last = out.last, last.entry == e.id, r.start <= last.end + 1.5 {
                        out[out.count - 1].end = max(last.end, r.end)
                    } else {
                        out.append(Match(start: r.start, end: r.end, kind: e.kind, negative: e.negative, entry: e.id,
                                         provenance: e.provenance, evidencePolicyVersion: e.evidencePolicyVersion))
                    }
                }
                if !touched.isEmpty {
                    var updated = all
                    for i in updated.indices where touched.contains(updated[i].id) { updated[i].lastMatched = Date() }
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .secondsSince1970
                    if let data = try? encoder.encode(updated),
                       (try? data.write(to: folder.appendingPathComponent("index.json"), options: .atomic)) != nil {
                        cache = (folder, matchingEntries(updated), index, bases)
                    }
                }
                return out.sorted { $0.start < $1.start }
            }
        }

        /// A matching historical record can be revalidated in place, retaining
        /// its identity/file/date. An automatic positive cannot undo a negative
        /// or relabel an explicit correction.
        @discardableResult
        static func add(_ print: Landmarks, show: String, source: String, kind: String, negative: Bool = false,
                        provenance: Provenance? = nil, evidencePolicyVersion: Int? = nil) -> Bool {
            guard usable(print) else { return false }
            return lock.withLock {
                guard var list = load() else { return false }
                let candidates = list.filter { $0.hasUsableMetadata }
                if !candidates.isEmpty {
                    let (index, bases) = combined(candidates)
                    for r in repeats(of: print, in: index) where r.seconds >= 0.6 * print.seconds {
                        let other = Int32(((r.start + r.offset) / hop).rounded())
                        guard let n = bases.lastIndex(where: { $0 <= other }),
                              let target = list.firstIndex(where: { $0.id == candidates[n].id }) else { continue }
                        // A short confirmed excerpt must not validate the
                        // whole longer legacy recording containing it.
                        let coversStoredRecording = print.seconds >= candidates[n].seconds - hop
                            && r.seconds >= candidates[n].seconds - 1
                        if !negative, !list[target].negative, !coversStoredRecording { continue }
                        list[target].lastMatched = Date()
                        if negative {
                            list[target].negative = true
                            list[target].provenance = Provenance.userCorrection.rawValue
                            list[target].verificationSource = source
                        } else if list[target].negative {
                            return false
                        } else if provenance == .userCorrection {
                            list[target].kind = kind
                            list[target].provenance = provenance?.rawValue
                            list[target].evidencePolicyVersion = evidencePolicyVersion
                            list[target].verificationSource = source
                        } else if trustsPositive(provenance: provenance?.rawValue, version: evidencePolicyVersion),
                                  list[target].provenance != Provenance.userCorrection.rawValue {
                            list[target].kind = kind
                            list[target].provenance = provenance?.rawValue
                            list[target].evidencePolicyVersion = evidencePolicyVersion
                            list[target].verificationSource = source
                        }
                        save(list)
                        return false
                    }
                }
                let id = UUID().uuidString
                guard (try? print.data().write(to: folder.appendingPathComponent(id + ".lm"), options: .atomic)) != nil else { return false }
                list.append(Entry(id: id, show: show, source: source, kind: kind, negative: negative,
                                  seconds: print.seconds, added: Date(), lastMatched: Date(),
                                  provenance: negative ? Provenance.userCorrection.rawValue : provenance?.rawValue,
                                  evidencePolicyVersion: evidencePolicyVersion))
                return save(list)
            }
        }
    }
}
