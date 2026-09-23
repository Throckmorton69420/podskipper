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
// Measured in the lab from Shashank's home connection (23 Sep 2026, see
// claude/DETECTION-AUDIT.md §13): 90–125 range requests, 0.55–0.76 MB, 6–8 s,
// and every inserted break on Stavvy's World, Conan and Matt and Shane found
// within 0.05 s of a full comparison.
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
        var insertedSeconds: Double { inserted.reduce(0) { $0 + $1.end - $1.start } }
    }

    // MARK: Frames

    /// Every MPEG-1 Layer III frame of a file: where it starts, how long it
    /// is, and a hash of its audio.
    struct Frames: Sendable {
        var offsets: [Int] = []
        var lengths: [Int] = []
        var hashes: [UInt64] = []
        var frameSeconds = 1152.0 / 44100
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
            let h1 = bytes[i + 1], h2 = bytes[i + 2]
            let bitrate = Int(h2 >> 4) & 15, rate = Int(h2 >> 2) & 3
            if bytes[i] == 0xFF, h1 & 0xE0 == 0xE0, (h1 >> 3) & 3 == 3, (h1 >> 1) & 3 == 1,
               bitrate > 0, bitrate < 15, rate < 3 {
                let sampleRate = sampleRates[rate]
                let length = 144 * bitrates[bitrate] * 1000 / sampleRate + Int((h2 >> 1) & 1)
                guard length > 4, i + length <= n else { break }
                // FNV-1a over the frame's audio (not its header).
                var hash: UInt64 = 0xcbf29ce484222325
                for k in (i + 4)..<(i + length) {
                    hash = (hash ^ UInt64(bytes[k])) &* 0x100000001b3
                }
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
        guard let feed, !feed.isEmpty, let url = URL(string: feed),
              let (data, _) = try? await session.data(from: url) else { return nil }
        let items = Enclosures.parse(data)
        let wanted = plainTitle(episodeTitle)
        return items.first { plainTitle($0.title) == wanted }.flatMap { URL(string: $0.enclosure) }
    }

    /// The reference candidates for one episode, best first.
    static func references(enclosure: String, feedURL: String, showTitle: String, episodeTitle: String,
                           session: URLSession) async -> [(source: String, url: URL)] {
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

    enum ProbeError: Error { case notMP3, noSize, network }

    /// Finds what `local` has that the reference doesn't.
    ///
    /// delta(x) is the local byte offset of the three-frame run found at
    /// reference byte x, minus x. Inserted ads only ever add bytes, so delta
    /// never decreases: every stretch whose two ends differ holds an insert,
    /// and halving it down to a couple of frames places each one.
    static func probe(local: Frames, localBytes: Int, reference: URL, session: URLSession,
                      outcome: inout Outcome) async throws -> [InsertedSpan] {
        guard local.count > 1000 else { throw ProbeError.notMP3 }
        var requests = 0, fetched = 0
        // The address redirects (Simplecast's to its stored file, and it can
        // take a while to answer). Resolved once, then asked directly.
        var target = reference
        func get(_ lower: Int, _ upper: Int) async throws -> (Data, Int?) {
            var request = URLRequest(url: target, timeoutInterval: 60)
            request.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
            var lastError: Error = ProbeError.network
            for _ in 0..<3 {
                do {
                    let (data, response) = try await session.data(for: request)
                    requests += 1; fetched += data.count
                    if let final = response.url { target = final }
                    let total = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?
                        .split(separator: "/").last.flatMap { Int($0) }
                    // A server that ignores Range sends the whole file: use only what was asked for.
                    return (data.prefix(upper - lower + 1), total)
                } catch { lastError = error }
            }
            throw lastError
        }
        defer { outcome.requests = requests; outcome.bytes = fetched }

        let (head, total) = try await get(0, 9)
        guard let size = total, size > 0 else { throw ProbeError.noSize }
        // Nothing smaller than what we have: nothing was inserted, or this
        // isn't an ad-free copy.
        guard size < localBytes - 16_000 else { outcome.note = "the reference is not smaller"; return [] }
        let h = [UInt8](head)
        let refAudio = h.count >= 10 && h[0] == 0x49 && h[1] == 0x44 && h[2] == 0x33
            ? 10 + (Int(h[6]) << 21 | Int(h[7]) << 14 | Int(h[8]) << 7 | Int(h[9])) : 0

        // Unique three-frame runs of the local file. Silence repeats, and a
        // run that occurs twice can't say where it is.
        var runs: [UInt64: Int] = [:]
        var repeated = Set<UInt64>()
        runs.reserveCapacity(local.count)
        for i in 0..<(local.count - 2) {
            let key = local.hashes[i] &* 31 &+ local.hashes[i + 1] &* 17 &+ local.hashes[i + 2]
            if runs[key] != nil { repeated.insert(key) } else { runs[key] = i }
        }
        for key in repeated { runs[key] = nil }

        let window = 6144
        struct Hit { var delta: Int; var localFrame: Int; var refByte: Int }
        var cache: [Int: Hit?] = [:]
        func delta(_ x0: Int) async throws -> Hit? {
            let x = max(refAudio, min(x0, size - window))
            if let known = cache[x] { return known }
            for attempt in 0..<4 {
                let lower = x + attempt * window
                guard lower + window <= size else { break }
                let (chunk, _) = try await get(lower, lower + window - 1)
                let found: Hit? = chunk.withUnsafeBytes { raw in
                    let f = frames(in: raw, skipID3: false)
                    guard f.count >= 3 else { return nil }
                    for k in 0..<(f.count - 2) {
                        let key = f.hashes[k] &* 31 &+ f.hashes[k + 1] &* 17 &+ f.hashes[k + 2]
                        if let i = runs[key] {
                            return Hit(delta: local.offsets[i] - (lower + f.offsets[k]), localFrame: i,
                                       refByte: lower + f.offsets[k])
                        }
                    }
                    return nil
                }
                if let found { cache[x] = found; return found }
            }
            cache[x] = .some(nil)
            return nil
        }

        let meanFrame = Double(local.offsets[local.count - 1] + local.lengths[local.count - 1] - local.offsets[0])
            / Double(local.count)
        var pending: [(Int, Int)] = (0..<64).map { k in
            (refAudio + (size - refAudio) * k / 64, refAudio + (size - refAudio) * (k + 1) / 64)
        }
        var found: [(Hit, Hit)] = []
        while let (a, b) = pending.popLast() {
            guard let da = try await delta(a), let db = try await delta(b), da.delta != db.delta else { continue }
            if Double(db.refByte - da.refByte) <= 2.5 * meanFrame || b - a <= 2 {
                found.append((da, db)); continue
            }
            let m = (a + b) / 2
            pending.append((a, m)); pending.append((m, b))
        }
        // Local frame nearest a byte offset.
        func frame(at byte: Int) -> Int {
            var lo = 0, hi = local.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if local.offsets[mid] < byte { lo = mid + 1 } else { hi = mid }
            }
            // The nearer of the frames either side.
            if lo > 0, byte - local.offsets[lo - 1] < local.offsets[lo] - byte { return lo - 1 }
            return lo
        }
        var spans: [InsertedSpan] = []
        for (da, db) in found {
            // The insert is (db − da) bytes, somewhere in the clean gap of at
            // most a couple of frames between the two matched runs.
            let startByte = local.offsets[da.localFrame] + (db.refByte - da.refByte)
            let s = frame(at: startByte), e = frame(at: startByte + db.delta - da.delta)
            if e > s { spans.append(InsertedSpan(start: Double(s) * local.frameSeconds, end: Double(e) * local.frameSeconds)) }
        }
        // Pre-roll: local frames before the first clean one. Post-roll: the
        // length left over once the clean audio and the mid-rolls are counted.
        var preFrames = 0
        if let d0 = try await delta(refAudio) {
            preFrames = d0.localFrame - Int((Double(d0.refByte - refAudio) / meanFrame).rounded())
        }
        if preFrames > 40 { spans.append(InsertedSpan(start: 0, end: Double(preFrames) * local.frameSeconds)) }
        let middle = spans.filter { $0.start > 0 }.reduce(0) { $0 + ($1.end - $1.start) } / local.frameSeconds
        let post = Double(local.count) - Double(size - refAudio) / meanFrame - Double(max(0, preFrames)) - middle
        if post > 40 {
            spans.append(InsertedSpan(start: (Double(local.count) - post) * local.frameSeconds,
                                      end: Double(local.count) * local.frameSeconds))
        }
        return spans.sorted { $0.start < $1.start }
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
        defer { outcome.seconds = Date().timeIntervalSince(started) }
        guard fileURL.pathExtension.lowercased() == "mp3" || enclosure.lowercased().contains(".mp3") else {
            outcome.note = "not an MP3 file"; return outcome
        }
        let session = URLSession(configuration: .ephemeral)
        let candidates = await references(enclosure: enclosure, feedURL: feedURL, showTitle: showTitle,
                                          episodeTitle: episodeTitle, session: session)
        guard !candidates.isEmpty else { outcome.note = "this host keeps no ad-free copy we know of"; return outcome }
        guard let data = try? Data(contentsOf: fileURL, options: .alwaysMapped) else {
            outcome.note = "couldn't read the download"; return outcome
        }
        // Hashing every frame reads the whole file: never on the main thread.
        let local = await Task.detached(priority: .utility) { data.withUnsafeBytes { frames(in: $0) } }.value
        for candidate in candidates {
            do {
                let spans = try await probe(local: local, localBytes: data.count, reference: candidate.url,
                                            session: session, outcome: &outcome)
                outcome.source = candidate.source
                outcome.inserted = spans
                if !spans.isEmpty { outcome.note = ""; return outcome }
            } catch {
                outcome.note = "\(candidate.source): \(error.localizedDescription)"
            }
        }
        return outcome
    }
}
