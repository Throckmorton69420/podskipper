import Foundation

// MARK: - The ad-free copy (pass 17, decision 2)
//
// Many hosts stitch ads into the file at download time and also keep the
// episode as uploaded, without them. Simplecast serves its stored file when the
// stitcher's own address is asked for without the analytics prefixes and the
// query; Megaphone shows are mirrored on Spreaker as uploaded. Stitching never
// re-encodes: outside the ads the two files hold the same MP3 frames, byte for
// byte. So comparing a few small pieces of the ad-free copy with the file on
// the phone finds every inserted ad to the frame (26 ms), host reads included,
// with no language model at all.
//
// The original probe was measured from Shashank's home connection (23 Sep 2026, see
// claude/DETECTION-AUDIT.md §13): 90–125 range requests, 0.55–0.76 MB, 6–8 s,
// and every inserted break on Stavvy's World, Conan and Matt and Shane found
// within 0.05 s of a full comparison. These are historical measurements;
// the stricter current policy needs separate real-episode measurements.
//
// Only the comparison is new here. What the ads are is not decided by it:
// the cuts it finds are handed to the detector, which leaves them alone and
// reads only the rest of the episode.

/// One stretch of the downloaded file that the ad-free copy doesn't have.
struct InsertedSpan: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
}

enum AdFreeCopy {

    /// Version 2 confirms bracketed interior differences only. Legacy terminal
    /// length estimates must not be restored as certain advertisements.
    static let comparisonPolicyVersion = 2

    /// What a comparison found, and what it cost. Logged for Diagnostics.
    struct Outcome: Codable, Sendable {
        var date = Date()
        var show = ""
        var episode = ""
        var host = ""
        var source = ""          // "simplecast", "spreaker", or "" when none
        var requests = 0
        var bytes = 0
        var seconds = 0.0
        var inserted: [InsertedSpan] = []
        var note = ""            // plain English: why nothing, or what went wrong
        var policyVersion: Int? = comparisonPolicyVersion
        var terminalCandidates: [InsertedSpan]? = nil // differences, not classified advertisements
        var insertedSeconds: Double { inserted.reduce(0) { $0 + $1.end - $1.start } }
        /// Interior inserts and pre/post-roll differences together. For keeping
        /// a clean video in step only; a shorter program edit can also differ
        /// at the ends, so these are never cut from the audio.
        var alignmentSpans: [InsertedSpan] {
            (inserted + (terminalCandidates ?? [])).sorted { $0.start < $1.start }
        }
        /// Worth keeping for the video: something was found, the reference was
        /// the same length, or there is no ad-free copy to ask. A network or
        /// range failure is not kept, so the next play measures again.
        var isDefinitiveForVideo: Bool {
            !alignmentSpans.isEmpty || source.isEmpty || note.hasPrefix("the reference is not shorter")
        }
    }

    // MARK: Frames

    /// Every MPEG-1 Layer III frame of a file: where it starts, how long it
    /// is, and a hash of its audio.
    struct Frames: Sendable {
        var offsets: [Int] = []
        var lengths: [Int] = []
        var hashes: [UInt64] = []
        var frameSeconds = 1152.0 / 44100
        var leadingMetadataFrames = 0
        var consistentSampleRate = true
        var count: Int { offsets.count }
    }

    private static let bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
    private static let sampleRates = [44100, 48000, 32000]

    /// Frames from `start`, skipping an ID3 tag at the very beginning.
    static func frames(in bytes: UnsafeRawBufferPointer, skipID3: Bool = true) -> Frames {
        var out = Frames()
        let n = bytes.count
        var i = 0
        if skipID3, n > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            i = 10 + (Int(bytes[6]) << 21 | Int(bytes[7]) << 14 | Int(bytes[8]) << 7 | Int(bytes[9]))
        }
        out.offsets.reserveCapacity(n / 400)
        out.lengths.reserveCapacity(n / 400)
        out.hashes.reserveCapacity(n / 400)
        while i + 4 <= n {
            if out.count & 1023 == 0, Task.isCancelled { return Frames() }
            let h1 = bytes[i + 1], h2 = bytes[i + 2]
            let bitrate = Int(h2 >> 4) & 15, rate = Int(h2 >> 2) & 3
            if bytes[i] == 0xFF, h1 & 0xE0 == 0xE0, (h1 >> 3) & 3 == 3, (h1 >> 1) & 3 == 1,
               bitrate > 0, bitrate < 15, rate < 3 {
                let sampleRate = sampleRates[rate]
                let length = 144 * bitrates[bitrate] * 1000 / sampleRate + Int((h2 >> 1) & 1)
                guard length > 4, i + length <= n else { break }
                if out.count == 0 {
                    let sideInfo = (bytes[i + 3] >> 6 == 3 ? 17 : 32) + (h1 & 1 == 0 ? 2 : 0)
                    let marker = i + 4 + sideInfo
                    let xing = marker + 4 <= i + length
                        && (Array(bytes[marker..<(marker + 4)]) == [0x58, 0x69, 0x6E, 0x67]
                            || Array(bytes[marker..<(marker + 4)]) == [0x49, 0x6E, 0x66, 0x6F])
                    let vbri = length > 40 && Array(bytes[(i + 36)..<(i + 40)]) == [0x56, 0x42, 0x52, 0x49]
                    if xing || vbri { out.leadingMetadataFrames = 1 }
                }
                // FNV-1a over the frame's audio (not its header).
                var hash: UInt64 = 0xcbf29ce484222325
                for k in (i + 4)..<(i + length) {
                    hash = (hash ^ UInt64(bytes[k])) &* 0x100000001b3
                }
                if !out.offsets.isEmpty, out.frameSeconds != 1152.0 / Double(sampleRate) { out.consistentSampleRate = false }
                out.offsets.append(i)
                out.lengths.append(length)
                out.hashes.append(hash)
                out.frameSeconds = 1152.0 / Double(sampleRate)
                i += length
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: Where the ad-free copy is

    /// Simplecast: the stitcher's own path, analytics prefixes and query
    /// removed. Following the full enclosure asks the ad server for a stitch.
    static func simplecastReference(enclosure: String) -> URL? {
        guard let range = enclosure.range(of: #"stitcher\.simplecastaudio\.com/[^?]+"#, options: .regularExpression)
        else { return nil }
        return URL(string: "https://" + enclosure[range])
    }

    static func plainTitle(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Megaphone and Simplecast shows that also publish on Spreaker: the
    /// mirror's copy of the same episode (found by title). The mirror's feed
    /// address is looked up once per show through Apple's podcast search and
    /// remembered.
    static func spreakerReference(showTitle: String, episodeTitle: String, session: URLSession) async -> URL? {
        // "2": pass 18 widened the name match, so earlier "no mirror"
        // answers are asked again once.
        guard !Task.isCancelled else { return nil }
        let key = "spreakerMirror2." + plainTitle(showTitle)
        var feed = UserDefaults.standard.string(forKey: key)
        if feed == nil {
            var parts = URLComponents(string: "https://itunes.apple.com/search")!
            parts.queryItems = [.init(name: "media", value: "podcast"), .init(name: "term", value: showTitle),
                                .init(name: "limit", value: "10")]
            guard let url = parts.url, let (data, _) = try? await session.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { return nil }
            // Same name, or one name containing the other ("Your Mom's House"
            // vs "Your Mom's House with Christina P. and Tom Segura").
            let wanted = plainTitle(showTitle)
            let found = results.first {
                let name = plainTitle($0["collectionName"] as? String ?? "")
                return ($0["feedUrl"] as? String)?.contains("spreaker.com") == true
                    && !name.isEmpty && (name == wanted || name.hasPrefix(wanted) || wanted.hasPrefix(name))
            }?["feedUrl"] as? String
            // Remembered either way ("" = this show has no mirror), so the
            // search runs once per show, not once per episode.
            UserDefaults.standard.set(found ?? "", forKey: key)
            feed = found ?? ""
        }
        guard !Task.isCancelled, let feed, !feed.isEmpty, let url = URL(string: feed),
              let (data, _) = try? await session.data(from: url) else { return nil }
        let items = Enclosures.parse(data)
        let wanted = plainTitle(episodeTitle)
        return items.first { plainTitle($0.title) == wanted }.flatMap { URL(string: $0.enclosure) }
    }

    /// The reference candidates for one episode, best first.
    static func references(enclosure: String, feedURL: String, showTitle: String, episodeTitle: String,
                           session: URLSession) async -> [(source: String, url: URL)] {
        guard !Task.isCancelled else { return [] }
        var out: [(String, URL)] = []
        if let url = simplecastReference(enclosure: enclosure) { out.append(("simplecast", url)) }
        // Spreaker mirrors exist for shows hosted anywhere (his library: MSSP
        // on Audioboom, Bad Friends on Anchor, Theo Von on Omny — all served
        // by Megaphone). The search is remembered per show, so asking costs
        // one directory lookup per show, ever.
        if !enclosure.contains("spreaker.com") {
            if let url = await spreakerReference(showTitle: showTitle, episodeTitle: episodeTitle, session: session) {
                out.append(("spreaker", url))
            }
        }
        return out
    }

    /// Titles and enclosure addresses of a feed's items; nothing else.
    final class Enclosures: NSObject, XMLParserDelegate {
        var items: [(title: String, enclosure: String)] = []
        private var inItem = false, text = "", title = "", enclosure = ""
        static func parse(_ data: Data) -> [(title: String, enclosure: String)] {
            let d = Enclosures()
            let p = XMLParser(data: data)
            p.delegate = d
            if p.parse() || !d.items.isEmpty { return d.items }
            return loose(String(decoding: data, as: UTF8.self))
        }

        /// Some Spreaker feeds are not well-formed XML; read their items by
        /// pattern instead (the lab found this on a mirror of Your Mom's House).
        static func loose(_ text: String) -> [(title: String, enclosure: String)] {
            let item = try! Regex(#"<item>(.*?)</item>"#).dotMatchesNewlines()
            let title = try! Regex(#"<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>"#).dotMatchesNewlines()
            let url = try! Regex(#"<enclosure[^>]*url="([^"]+)""#)
            return text.matches(of: item).compactMap { m in
                let body = String(text[m.range])
                guard let t = body.firstMatch(of: title), let e = body.firstMatch(of: url),
                      let tr = t.output[1].range, let er = e.output[1].range else { return nil }
                let decode = { (s: Substring) in
                    String(s).replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
                        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
                }
                return (decode(body[tr]), decode(body[er]))
            }
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" { inItem = true; title = ""; enclosure = "" }
            if name == "enclosure", inItem { enclosure = attributes["url"] ?? "" }
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "title", inItem, title.isEmpty { title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if name == "item" { inItem = false; if !enclosure.isEmpty { items.append((title, enclosure)) } }
        }
    }

    // MARK: The comparison, by small range requests

    enum ProbeError: Error, LocalizedError, Equatable {
        case notMP3, noSize, network
        case invalidRange, changedReference, insufficientMatch, differentEdit
        var errorDescription: String? {
            switch self {
            case .notMP3: "The comparison needs a complete MPEG-1 Layer III file."
            case .noSize: "The comparison copy did not report a valid file size."
            case .network: "The comparison copy could not be downloaded."
            case .invalidRange: "The host returned an invalid or incomplete byte range; no cuts were confirmed."
            case .changedReference: "The comparison copy changed during the check; no cuts were confirmed."
            case .insufficientMatch: "The comparison copy could not be matched throughout the episode; no cuts were confirmed."
            case .differentEdit: "The comparison copy has reordered or removed audio; no cuts were confirmed."
            }
        }
    }

    /// Validate cached evidence as well as newly computed evidence. Old
    /// results cannot establish which terminal differences were only estimates.
    static func trustedInserted(_ spans: [InsertedSpan], policyVersion: Int?, duration: Double) -> [InsertedSpan] {
        guard policyVersion == comparisonPolicyVersion, duration.isFinite, duration > 0 else { return [] }
        let ordered = spans.sorted { $0.start < $1.start }
        var end = 0.0
        for span in ordered {
            guard span.start.isFinite, span.end.isFinite, span.start > 0,
                  span.end < duration, span.end > span.start, span.start >= end else { return [] }
            end = span.end
        }
        guard implausible(ordered, duration: duration) == nil else { return [] }
        return ordered
    }

    /// Match every sampled part in order before deriving any cuts. Increasing
    /// offsets establish an interior insertion only when clean audio brackets
    /// both ends. The beginning/end of a shorter program edit is indistinguishable
    /// from a pre/post-roll by frames alone, so terminal differences stay unclassified.
    static func probe(local: Frames, localBytes: Int, reference: URL, session: URLSession,
                      outcome: inout Outcome) async throws -> [InsertedSpan] {
        try Task.checkCancellation()
        outcome.policyVersion = comparisonPolicyVersion
        outcome.terminalCandidates = nil
        outcome.note = ""
        guard localBytes >= 0, local.count > 1000, local.consistentSampleRate,
              (0...1).contains(local.leadingMetadataFrames), local.offsets.count == local.hashes.count,
              local.lengths.count == local.count, local.frameSeconds.isFinite, local.frameSeconds > 0,
              zip(local.offsets, local.lengths).allSatisfy({ $0 >= 0 && $1 > 4 && $0 <= localBytes - $1 }),
              zip(zip(local.offsets, local.lengths), local.offsets.dropFirst()).allSatisfy({ $0.0 + $0.1 == $1 })
        else { throw ProbeError.notMP3 }
        var requests = 0, fetched = 0
        var target = reference
        var expectedSize: Int?
        var validators: [String: String] = [:]
        func get(_ lower: Int, _ upper: Int) async throws -> (Data, Int) {
            var request = URLRequest(url: target, timeoutInterval: 60)
            request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            var lastError: Error = ProbeError.network
            for attempt in 0..<3 {
                try Task.checkCancellation()
                requests += 1
                do {
                    let (data, response) = try await session.data(for: request)
                    fetched += data.count
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                          http.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
                          let range = http.value(forHTTPHeaderField: "Content-Range"),
                          let match = range.firstMatch(of: try Regex(#"^bytes (\d+)-(\d+)/(\d+)$"#)),
                          let start = match.output[1].substring.flatMap({ Int($0) }), let end = match.output[2].substring.flatMap({ Int($0) }), let size = match.output[3].substring.flatMap({ Int($0) }),
                          start == lower, end == upper, size > end,
                          data.count == upper - lower + 1 else { throw ProbeError.invalidRange }
                    if let expectedSize, expectedSize != size { throw ProbeError.changedReference }
                    expectedSize = size
                    for name in ["ETag", "Last-Modified"] {
                        if let value = http.value(forHTTPHeaderField: name) {
                            if let previous = validators[name], previous != value { throw ProbeError.changedReference }
                            validators[name] = value
                        }
                    }
                    if let final = response.url { target = final }
                    return (data, size)
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        throw CancellationError()
                    }
                    // Protocol errors are deterministic. Retry only a transient transport failure.
                    guard let transport = error as? URLError,
                          [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(transport.code),
                          attempt < 2 else { throw error }
                    lastError = error
                }
            }
            throw lastError
        }
        defer { outcome.requests += requests; outcome.bytes += fetched }

        let (head, size) = try await get(0, 9)
        guard size > 0 else { throw ProbeError.noSize }
        guard size < localBytes - 16_000 else {
            outcome.note = "the reference is not shorter; no inserted cuts were confirmed"
            return []
        }
        let h = [UInt8](head)
        var refAudio = 0
        if h[0] == 0x49 && h[1] == 0x44 && h[2] == 0x33 {
            guard h[6...9].allSatisfy({ $0 < 128 }) else { throw ProbeError.notMP3 }
            refAudio = 10 + (Int(h[6]) << 21 | Int(h[7]) << 14 | Int(h[8]) << 7 | Int(h[9]))
            if h[3] == 4, h[5] & 0x10 != 0 { refAudio += 10 } // ID3v2.4 footer
        }
        let window = 6144
        guard refAudio >= 0, size - refAudio >= window * 2 else { throw ProbeError.insufficientMatch }

        // Three payload hashes and the frame lengths are verified after lookup;
        // a hash-combination collision cannot become alignment evidence.
        var runs: [UInt64: Int] = [:]
        var repeated = Set<UInt64>()
        runs.reserveCapacity(local.count)
        for i in 0..<(local.count - 2) {
            if i & 1023 == 0 { try Task.checkCancellation() }
            let key = local.hashes[i] &* 31 &+ local.hashes[i + 1] &* 17 &+ local.hashes[i + 2]
            if runs[key] != nil { repeated.insert(key) } else { runs[key] = i }
        }
        for key in repeated { runs[key] = nil }

        // Hosts may rewrite the Xing/Info/VBRI counts for a stitched file.
        // That single metadata frame is not program audio or an advertisement.
        let (initialAudio, _) = try await get(refAudio, refAudio + window - 1)
        let initialFrames = initialAudio.withUnsafeBytes { frames(in: $0, skipID3: false) }
        if initialFrames.leadingMetadataFrames == 1, let length = initialFrames.lengths.first { refAudio += length }
        guard size - refAudio >= window * 2 else { throw ProbeError.insufficientMatch }

        struct Hit { var delta: Int; var localFrame: Int; var refByte: Int }
        var cache: [Int: [Hit]] = [:]
        var observed: [Int: Hit] = [:]
        func matches(_ lower: Int) async throws -> [Hit] {
            if let cached = cache[lower] { return cached }
            let (chunk, _) = try await get(lower, lower + window - 1)
            let found: [Hit] = try chunk.withUnsafeBytes { raw in
                let f = frames(in: raw, skipID3: false)
                try Task.checkCancellation()
                guard f.count >= 3, f.consistentSampleRate, f.frameSeconds == local.frameSeconds else { return [] }
                var hits: [Hit] = []
                for k in 0..<(f.count - 2) {
                    let key = f.hashes[k] &* 31 &+ f.hashes[k + 1] &* 17 &+ f.hashes[k + 2]
                    if let i = runs[key], (0..<3).allSatisfy({ local.hashes[i + $0] == f.hashes[k + $0]
                        && local.lengths[i + $0] == f.lengths[k + $0] }) {
                        hits.append(Hit(delta: local.offsets[i] - (lower + f.offsets[k]), localFrame: i,
                                        refByte: lower + f.offsets[k]))
                    }
                }
                return hits
            }
            cache[lower] = found
            for hit in found { observed[hit.refByte] = hit }
            return found
        }
        func delta(_ x0: Int) async throws -> Hit {
            let x = max(refAudio, min(x0, size - window))
            for attempt in 0..<4 {
                let lower = x + attempt * window
                guard lower + window <= size else { break }
                if let hit = try await matches(lower).first { return hit }
            }
            throw ProbeError.insufficientMatch
        }
        func verifyOrder() throws {
            let ordered = observed.values.sorted { $0.refByte < $1.refByte }
            let baseline = local.offsets[local.leadingMetadataFrames] - refAudio
            var previous: Hit?
            for hit in ordered {
                guard hit.delta >= baseline else { throw ProbeError.differentEdit }
                if let previous {
                    guard hit.localFrame > previous.localFrame, hit.delta >= previous.delta else { throw ProbeError.differentEdit }
                }
                previous = hit
            }
        }

        // Endpoint matches must cover the actual first/last audio, rather than
        // guessing their positions from average bitrate or total file length.
        let firstHits = try await matches(refAudio)
        let lastLower = size - window
        let lastHits = try await matches(lastLower)
        let (firstChunk, _) = try await get(refAudio, refAudio + window - 1)
        let (lastChunk, _) = try await get(lastLower, size - 1)
        let firstFrames = firstChunk.withUnsafeBytes { frames(in: $0, skipID3: false) }
        let lastFrames = lastChunk.withUnsafeBytes { frames(in: $0, skipID3: false) }
        guard let first = firstHits.first, first.refByte == refAudio,
              let last = lastHits.last, lastFrames.count >= 3,
              last.refByte == lastLower + lastFrames.offsets[lastFrames.count - 3],
              firstFrames.count >= 3 else { throw ProbeError.insufficientMatch }
        try verifyOrder()

        let samplePositions = (0...64).map { refAudio + (size - window - refAudio) * $0 / 64 }
        for position in samplePositions { _ = try await delta(position) }
        try verifyOrder()
        var pending: [(Int, Int)] = zip(samplePositions, samplePositions.dropFirst()).map { ($0, $1) }
        var found: [(Hit, Hit)] = []
        while let (a, b) = pending.popLast() {
            try Task.checkCancellation()
            let da = try await delta(a), db = try await delta(b)
            guard da.delta != db.delta else { continue }
            guard db.refByte > da.refByte, db.delta > da.delta else { throw ProbeError.differentEdit }
            let bracketBytes = local.lengths[da.localFrame..<(da.localFrame + 3)].reduce(0, +)
            if db.refByte - da.refByte <= bracketBytes {
                found.append((da, db)); continue
            }
            guard b - a > 2 else { throw ProbeError.insufficientMatch }
            let m = (a + b) / 2
            pending.append((a, m)); pending.append((m, b))
        }
        try verifyOrder()
        func frame(at byte: Int) -> Int {
            var lo = 0, hi = local.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if local.offsets[mid] < byte { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0, byte - local.offsets[lo - 1] < local.offsets[lo] - byte { return lo - 1 }
            return lo
        }
        var spans: [InsertedSpan] = []
        for (da, db) in found {
            let startByte = local.offsets[da.localFrame] + (db.refByte - da.refByte)
            let s = frame(at: startByte), e = frame(at: startByte + db.delta - da.delta)
            if e > s { spans.append(InsertedSpan(start: Double(s) * local.frameSeconds, end: Double(e) * local.frameSeconds)) }
        }
        // Overlapping bisection leaves can refer to the same insertion.
        spans = Array(Set(spans)).sorted { $0.start < $1.start }
        let duration = Double(local.count) * local.frameSeconds
        let trusted = trustedInserted(spans, policyVersion: comparisonPolicyVersion, duration: duration)
        guard trusted.count == spans.count else { throw ProbeError.differentEdit }
        let preFrames = max(0, first.localFrame - local.leadingMetadataFrames)
        let postStart = last.localFrame + 3
        var terminal: [InsertedSpan] = []
        if preFrames > 40 { terminal.append(InsertedSpan(start: 0, end: Double(preFrames) * local.frameSeconds)) }
        if local.count - postStart > 40 {
            terminal.append(InsertedSpan(start: Double(postStart) * local.frameSeconds, end: duration))
        }
        outcome.terminalCandidates = terminal.isEmpty ? nil : terminal
        if !terminal.isEmpty { outcome.note = "terminal audio differs; kept for classification because a shorter edit can match the same frames" }
        else if trusted.isEmpty { outcome.note = "no inserted cuts were confirmed" }
        try Task.checkCancellation()
        return trusted
    }

    /// Why these "inserted" stretches can't be ad breaks, or nil if they can.
    ///
    /// His 28 Sep results (a12b647): on Bad Friends "We Are Garbage" the
    /// Spreaker copy was about 27 minutes shorter than the download, and the
    /// leftover length was taken as a post-roll — 47:39 to the end, 27 min
    /// of the show, cut at confidence 100 with edges nothing may move. A
    /// shorter edit (a preview, a clip, a different cut) matches frame for
    /// frame up to where it stops, so the frames can't tell; the length can.
    /// Stitched-in breaks are seconds to a few minutes: any one over six
    /// minutes, or all of them over a quarter of the episode, means the
    /// reference is a different edit, and none of it is used.
    static func implausible(_ spans: [InsertedSpan], duration: Double) -> String? {
        guard duration.isFinite, duration > 0,
              spans.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                  && $0.end > $0.start && $0.end <= duration }) else {
            return "the comparison has invalid audio bounds"
        }
        let longest = spans.map { $0.end - $0.start }.max() ?? 0
        let total = spans.reduce(0) { $0 + ($1.end - $1.start) }
        if longest > 360 {
            return "it's a different edit (one stretch of \(Int(min(9_999, longest / 60))) min isn't in it — too long for an ad break)"
        }
        if duration > 0, total > max(600, duration * 0.25) {
            return "it's a different edit (\(Int(min(9_999, total / 60))) of \(Int(min(9_999, duration / 60))) min aren't in it)"
        }
        return nil
    }

    /// The whole job for one downloaded episode. Never throws: a failure is an
    /// outcome with a note, and the episode is simply processed without it.
    static func compare(fileURL: URL, enclosure: String, feedURL: String, showTitle: String,
                        episodeTitle: String) async -> Outcome {
        var outcome = Outcome()
        outcome.show = showTitle
        outcome.episode = episodeTitle
        outcome.host = URL(string: enclosure)?.host ?? ""
        let started = Date()
        func finished() -> Outcome { outcome.seconds = Date().timeIntervalSince(started); return outcome }
        guard fileURL.pathExtension.lowercased() == "mp3" || enclosure.lowercased().contains(".mp3") else {
            outcome.note = "not an MP3 file"; return finished()
        }
        guard !Task.isCancelled else { outcome.note = "comparison cancelled"; return finished() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let candidates = await references(enclosure: enclosure, feedURL: feedURL, showTitle: showTitle,
                                          episodeTitle: episodeTitle, session: session)
        guard !Task.isCancelled else { outcome.note = "comparison cancelled"; return finished() }
        guard !candidates.isEmpty else { outcome.note = "this host keeps no ad-free copy we know of"; return finished() }
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) else {
            outcome.note = "couldn't read the download"; return finished()
        }
        // Hashing every frame reads the whole file: never on the main thread.
        let hashing = Task.detached(priority: .utility) { data.withUnsafeBytes { frames(in: $0) } }
        let local = await withTaskCancellationHandler { await hashing.value } onCancel: { hashing.cancel() }
        guard !Task.isCancelled else { outcome.note = "comparison cancelled"; return finished() }
        for candidate in candidates {
            do {
                let spans = try await probe(local: local, localBytes: data.count, reference: candidate.url,
                                            session: session, outcome: &outcome)
                outcome.source = candidate.source
                if let why = implausible(spans, duration: Double(local.count) * local.frameSeconds) {
                    // Not an ad-free copy of this episode, whatever its name.
                    outcome.inserted = []
                    outcome.note = "\(candidate.source): not used — \(why)"
                    continue
                }
                outcome.inserted = spans
                if !spans.isEmpty { return finished() }
            } catch {
                outcome.inserted = []
                outcome.terminalCandidates = nil
                if Task.isCancelled || error is CancellationError {
                    outcome.note = "comparison cancelled"; return finished()
                }
                outcome.note = "\(candidate.source): \(error.localizedDescription)"
            }
        }
        return finished()
    }
}
