import Foundation

/// Pass 30: every cut an open model proposes is checked against the
/// episode's own words and audio before it is saved.
///
/// His 5 Oct phone: Core AI Qwen3 4B marked about 47 of Bad Friends' 66
/// minutes ("Bobby Is Tone Tone Galore") as ads and MLX Qwen3.5 4B about 18,
/// while the reader and Apple Intelligence found the two real breaks
/// (≈ 8.5 min: Liquid IV / Rocket Money / TalkSpace, BlueChew / Shopify /
/// QUO). A single answer like that removes most of a show, so a model's cut
/// now stands only where something backs it:
///
/// - the reader cut the same stretch, or the audio proves it (stitched in by
///   the ad server «I», or a recording that plays elsewhere «R»); or
/// - the lines themselves sell: an offer, a code, a web address, a hand-off
///   ("brought to you by"), the sponsor's name, tickets and merch for a plug.
///
/// Unbacked stretches are cut down to the lines that sell, with room for a
/// lead-in and a sign-off; whatever is left with nothing selling is dropped.
/// Intros and outros have to sit at the edges of the episode. If even after
/// that the model's own cuts would take an implausible share of the
/// episode, its unbacked cuts are dropped altogether.
///
/// Model silence is not a veto: an ad the reader was sure of (or one the ad
/// server stitched in) stays cut unless the model explicitly called that
/// stretch the show (MOCK_AD or RECURRING_SEGMENT). Pass 45 widened "sure"
/// (`readerStands`) and reads a break as one (`breakTouch`).
enum ModelCutCheck {
    /// Before the first selling line: a hand-off and the product's pitch.
    static let leadIn: Double = 50
    /// After the last selling line: the repeated address, "that's…", the
    /// small print read fast (Progressive's 30 s of "savings vary").
    static let tail: Double = 35
    /// Selling stretches this close together are one read.
    static let joinGap: Double = 90
    /// Longest stretch kept on the model's word alone, by kind.
    static func cap(_ kind: SegmentKind) -> Double {
        switch kind {
        case .ad: return 330
        case .selfPromo, .crossPromo: return 200
        case .intro, .outro: return 150
        }
    }
    /// The model's unbacked cuts may not take more than this of an episode.
    static func ceiling(duration: Double) -> Double { max(600, duration * 0.3) }

    struct Outcome {
        /// What the model asked for, before the check.
        var proposed: [DetectedSegment] = []
        var cuts: [DetectedSegment]
        /// One plain line per change, for the background log and Diagnostics.
        var notes: [String]
        /// Seconds the model asked for that were not kept.
        var droppedSeconds: Double
    }

    static func verify(_ proposed: [DetectedSegment], lines: [TimedLine], readerCuts: [DetectedSegment],
                       evidence: [EvidenceSpan], keeps: [ClosedRange<Double>], duration: Double) -> Outcome {
        let end = max(duration, lines.last?.end ?? 0)
        var notes: [String] = []
        var dropped = 0.0
        var backed: [DetectedSegment] = []
        var unbacked: [DetectedSegment] = []

        for cut in joinSplitReads(proposed) {
            if cut.insertedAtDownload { backed.append(cut); continue }
            let support = backing(for: cut, readerCuts: readerCuts, evidence: evidence)
            let pieces = kept(cut, lines: lines, support: support, duration: end)
            let keptSeconds = pieces.reduce(0.0) { $0 + ($1.cut.end - $1.cut.start) }
            let asked = cut.end - cut.start
            if keptSeconds + 1 < asked {
                dropped += asked - keptSeconds
                notes.append(pieces.isEmpty
                    ? "dropped \(clock(cut.start))–\(clock(cut.end)) \(cut.kind.rawValue): nothing in it sells and nothing else found it"
                    : "trimmed \(clock(cut.start))–\(clock(cut.end)) \(cut.kind.rawValue) to the \(Int(keptSeconds)) s that sell")
            }
            for piece in pieces {
                if piece.backed { backed.append(piece.cut) } else { unbacked.append(piece.cut) }
            }
        }

        let modelOnly = unbacked.reduce(0) { $0 + ($1.end - $1.start) }
        if modelOnly > ceiling(duration: end) {
            notes.append("the model's own cuts came to \(Int(modelOnly / 60)) min of a \(Int(end / 60))-min episode; only the ones something else backs were kept")
            dropped += modelOnly
            unbacked = []
        }

        var cuts = merge(backed + unbacked)
        // The reader's sure ads stay unless the model said they are the show.
        // Pass 32 (his 7 Oct LoS #954 and Bad Friends runs): so do produced
        // openers and closers the audio itself proves — the same recording
        // plays in other episodes — which the focused MLX reads left out
        // (both Qwen3.5 4B runs lost Bad Friends' intro and outro, the 6-bit
        // one LoS's network intro, while the reader and Apple Intelligence
        // had them). A repeat is exact evidence; a merely confident plug is
        // not (Apple's 12-s "plug" in Bad Friends was the show).
        //
        // Pass 39 (his 15 Oct We Might Be Drunk, Theo Von #690, Stavvy's
        // #202): the reader adds only what the model's cuts leave out. It
        // used to ask whether any *one* model cut covered half of the
        // reader's stretch; three sponsors read back to back (Rocket Money,
        // Hims, Underdog) each covered under half of the reader's 235-s
        // block, so the whole block went back in and swallowed two of them,
        // with the third left overlapping it. Now the model's cuts keep their
        // edges and sponsors; the reader fills the holes between them (the
        // next read's lead-in), the lead-in before the first (where models
        // start late, at the sponsor's name), and the end only where the
        // words there still sell. Where the model is mostly silent the
        // reader's stretch stands, around whatever the model did cut.
        for reader in readerCuts {
            let sure = Self.readerStands(reader, lines: lines)
            let vetoed = keeps.contains { overlap(reader, $0.lowerBound, $0.upperBound) >= 0.5 }
            guard !vetoed else { continue }
            let covering = cuts.indices.filter { cuts[$0].end > reader.start + 0.5 && cuts[$0].start < reader.end - 0.5 }
                .sorted { cuts[$0].start < cuts[$1].start }
            let share = coveredShare(reader, by: covering.map { cuts[$0].start...cuts[$0].end })
            // A stretch only the reader had a middling score for still counts
            // when the model independently cut a good part of it (Stavvy's
            // post-roll: reader 70, the model the last 37 s of it).
            // Pass 53 (his 28 Oct LoS #954): so does a plug stretch longer
            // than a plug the model alone may cut — the hosts' 7½ minutes of
            // tour dates, specials and contest at 0:57, reader 95 — where
            // the model cut pieces of it: every model kept only its pieces
            // and left 2½–5 minutes of plugs to hear.
            let corroborated = (reader.kind == .ad && reader.confidence >= 60 && share >= 0.25)
                || (Self.plugPolicy >= 1 && (reader.kind == .selfPromo || reader.kind == .crossPromo)
                    && reader.confidence >= 85 && share >= 0.25 && sellsInside(reader, lines: lines))
            guard sure || corroborated else { continue }
            if covering.isEmpty {
                var kept = reader
                kept.evidence.append("kept from PodSkipper's reader: the model didn't mention this stretch")
                cuts.append(kept)
                notes.append("kept the reader's \(reader.kind.rawValue) at \(clock(reader.start)) (\(Int(reader.end - reader.start)) s) the model left out")
                continue
            }
            let added = fill(reader, around: covering, in: &cuts, lines: lines, keeps: keeps,
                             modelMostlySilent: share < 0.5 && sure)
            if added >= 1 {
                notes.append("added \(Int(added)) s of the reader's \(reader.kind.rawValue) at \(clock(reader.start)) around the model's \(covering.count) cut\(covering.count == 1 ? "" : "s")")
            }
        }
        // Pass 45 (his 22 Oct #691 Johnny Hamcheck): a break is read as one.
        // The reader's middling stretch right against something already cut
        // (Theo's "my new special is out now on Netflix", 52, straight after
        // the Paramount+ spot) is the same break, when its own lines sell.
        var joined = Set<Int>()
        var added = true
        while added {
            added = false
            for (i, reader) in readerCuts.enumerated() where !joined.contains(i)
                && reader.kind != .intro && reader.kind != .outro && reader.confidence >= 50
                && reader.end - reader.start <= cap(reader.kind) {
                guard !keeps.contains(where: { overlap(reader, $0.lowerBound, $0.upperBound) >= 0.5 }),
                      coveredShare(reader, by: cuts.map { $0.start...$0.end }) < 0.5,
                      cuts.contains(where: { $0.start - reader.end <= breakTouch && reader.start - $0.end <= breakTouch }),
                      sellsInside(reader, lines: lines) else { continue }
                var kept = reader
                kept.evidence.append("kept from PodSkipper's reader: it runs on from the break next to it")
                cuts.append(kept)
                joined.insert(i)
                notes.append("kept the reader's \(reader.kind.rawValue) at \(clock(reader.start)) (\(Int(reader.end - reader.start)) s) next to a break")
                added = true
            }
        }
        cuts = relabelNamedSponsors(cuts, readerCuts: readerCuts, notes: &notes)
        if reconcilesKinds { cuts = reconcileKinds(cuts, readerCuts: readerCuts, lines: lines, notes: &notes) }
        return Outcome(proposed: proposed, cuts: separate(merge(cuts)), notes: notes, droppedSeconds: dropped)
    }

    /// Pass 46 (the 23 Oct #691 runs): what a stretch *is*, where the model's
    /// kind and the episode disagree. He skips ads, plugs, promos, intros and
    /// outros separately, so the kind decides what is heard.
    /// - A model's intro, outro or network promo that the reader heard as an
    ///   ad and whose own lines sell something that is not a podcast is the
    ///   ad: MLX Qwen3.5 4B called Paramount+'s Tulsa King spot ("New season
    ///   now streaming only on Paramount+") the intro at 0:00 and a network
    ///   promo when it played again at 1:00:03.
    /// - A model's ad whose lines promote a podcast, where the reader heard a
    ///   network promo, is the promo.
    /// - A host's own plug at the edge of an ad ("my new special, I'm Doing
    ///   Fine, is out now on Netflix" straight after the spot) is the host's plug,
    ///   not part of the ad: Core AI MiniCPM5 2B's save folded it in.
    static func reconcileKinds(_ cuts: [DetectedSegment], readerCuts: [DetectedSegment], lines: [TimedLine],
                               notes: inout [String]) -> [DetectedSegment] {
        var out: [DetectedSegment] = []
        for cut in cuts {
            guard !cut.insertedAtDownload else { out.append(cut); continue }
            let inside = lines.filter { ($0.start + $0.end) / 2 >= cut.start && ($0.start + $0.end) / 2 <= cut.end }
            let text = inside.map(\.text).joined(separator: " ")
            func reader(_ kind: SegmentKind) -> Bool {
                readerCuts.contains { $0.kind == kind && $0.confidence >= 50 && overlap(cut, $0.start, $0.end) >= 0.5 }
            }
            var cut = cut
            if [.intro, .outro, .crossPromo].contains(cut.kind), reader(.ad), !promotesAPodcast(text),
               inside.contains(where: { commercial($0.text, brand: brandTokens(cut.sponsor)) }) {
                notes.append("called \(clock(cut.start)) an ad, not the \(cut.kind == .crossPromo ? "network promo" : cut.kind.rawValue): its lines sell, the reader heard a paid spot")
                cut.evidence.append("an ad: its lines sell something and the reader heard a paid spot")
                cut.kind = .ad
            } else if cut.kind == .ad, reader(.crossPromo), promotesAPodcast(text) {
                notes.append("called \(clock(cut.start)) a network promo, not an ad: it promotes a podcast")
                cut.evidence.append("a promo for another podcast, not a paid ad")
                cut.kind = .crossPromo
            }
            out += carveOwnPlug(cut, lines: inside, notes: &notes)
        }
        return out
    }

    /// Pass 46: lines that sell a product as a commercial does — an offer, a
    /// hand-off, the sponsor's name, or a release ("now streaming", "in
    /// theaters") — but never a host's own plug.
    static func commercial(_ text: String, brand: [String]) -> Bool {
        let lower = text.lowercased()
        let flat = AdDetector.normalise(text).replacingOccurrences(of: " ", with: "")
        if brand.contains(where: { flat.contains($0) }) { return true }
        guard !ownPlug(text) else { return false }
        if sells(text, kind: .ad, brand: brand) { return true }
        return ["now streaming", "streaming now", "streaming on", "stream it on", "only on", "in theaters",
                "in theatres", "now available", "available now", "new season", "watch it on", "rated r", "rated pg"]
            .contains { lower.contains($0) }
    }

    /// Pass 46: a promo for a podcast, by its words.
    static func promotesAPodcast(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["podcast", "wherever you get your", "wherever you listen", "new episodes", "listen to", "listen now",
                "subscribe to"].contains { lower.contains($0) }
    }

    /// Pass 46: the host (or guest) plugging their own work in the first person.
    static func ownPlug(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.firstMatch(of: try! Regex(#"\b(my|our)\s+(?:\w+\s+){0,2}(special|tour|album|book|podcast|patreon|merch|youtube|channel|newsletter|residency|substack|movie|film)\b"#)) != nil
            || ["come see me", "come see us", "i'm on tour", "we're on tour", "i'm going on tour"].contains { lower.contains($0) }
    }

    /// Pass 46: an ad cut whose last lines (or first) are the host's own plug
    /// becomes the ad and the plug beside it. Only lines after the ad's last
    /// selling line (or before its first) move; at least four seconds of plug.
    static func carveOwnPlug(_ cut: DetectedSegment, lines inside: [TimedLine],
                             notes: inout [String]) -> [DetectedSegment] {
        guard cut.kind == .ad, inside.count >= 2 else { return [cut] }
        let brand = brandTokens(cut.sponsor)
        let selling = inside.indices.filter { commercial(inside[$0].text, brand: brand) }
        guard let firstSelling = selling.first, let lastSelling = selling.last else { return [cut] }
        func piece(_ range: ClosedRange<Int>, kind: SegmentKind) -> DetectedSegment {
            var p = cut
            p.start = range.lowerBound == 0 ? cut.start : inside[range.lowerBound].start
            p.end = range.upperBound == inside.count - 1 ? cut.end : inside[range.upperBound].end
            if kind != cut.kind {
                p.kind = kind
                p.sponsor = ""
                p.style = nil
                p.evidence.append("the host's own plug, next to the ad")
            }
            return p
        }
        var out: [DetectedSegment] = []
        var adFirst = 0, adLast = inside.count - 1
        func plugLine(_ i: Int) -> Bool { ownPlug(inside[i].text) && !commercial(inside[i].text, brand: brand) }
        if let plug = inside.indices.first(where: { $0 > lastSelling && plugLine($0) }),
           cut.end - inside[plug].start >= 4 {
            adLast = plug - 1
        }
        if let plug = inside.indices.last(where: { $0 < firstSelling && plugLine($0) }),
           inside[plug].end - cut.start >= 4 {
            adFirst = plug + 1
        }
        guard adFirst > 0 || adLast < inside.count - 1, adFirst <= adLast else { return [cut] }
        if adFirst > 0 { out.append(piece(0...(adFirst - 1), kind: .selfPromo)) }
        out.append(piece(adFirst...adLast, kind: .ad))
        if adLast < inside.count - 1 { out.append(piece((adLast + 1)...(inside.count - 1), kind: .selfPromo)) }
        // Edges meet: the ad ends where the plug starts.
        for i in out.indices.dropLast() { out[i].end = min(out[i].end, out[i + 1].start) }
        notes.append("split the host's own plug from the ad at \(clock(cut.start))")
        return out
    }

    /// Pass 46: off only in the lab's replay, to measure `reconcileKinds`.
    nonisolated(unsafe) static var reconcilesKinds = true

    /// Pass 53: how the reader's long plug stretches are taken (the replay's
    /// switch): 0 as before, 1 where the model cut part of one, 2 also a
    /// sure one (≥ 90) up to `longPlug` the model left out. Measured on 96
    /// model reads of 35 labelled episodes (Pass 53 evidence): 2 hears least
    /// for every model, at ≤ 1.8 s/h more show cut.
    nonisolated(unsafe) static var plugPolicy = 2
    static let longPlug: Double = 600

    /// Two stretches this close are one break.
    static let breakTouch: Double = 3
    /// Longest produced spot kept on its repeated recording alone.
    static let repeatedSpot: Double = 90

    /// Pass 45: a reader stretch that stands even where the model said
    /// nothing. Before, only an ad the reader was 90 sure of (or audio
    /// evidence for an intro/outro) did; his retrained Reader's middling ads
    /// and sure plugs were dropped whenever a model left them out — #691's
    /// Paramount+ spot (53, and 88 when it played again an hour in), dozens
    /// of 85–99 plugs across his labelled episodes. Measured on them
    /// (Pass 45 evidence): these keep ads and plugs without cutting the show.
    static func readerStands(_ reader: DetectedSegment, lines: [TimedLine]) -> Bool {
        if reader.insertedAtDownload || provenOpenerOrCloser(reader) { return true }
        let length = reader.end - reader.start
        switch reader.kind {
        case .ad:
            if reader.confidence >= 90 { return true }
            // A spot whose recording plays elsewhere — exact audio evidence —
            // and is spot-length (a rerun of a whole segment is longer).
            if repeated(reader), length <= repeatedSpot, reader.confidence >= 50 { return true }
            return reader.confidence >= 70 && length <= cap(.ad) && sellsInside(reader, lines: lines)
        case .crossPromo:
            if repeated(reader), length <= repeatedSpot, reader.confidence >= 50 { return true }
            return reader.confidence >= 80 && length <= cap(.crossPromo) && sellsInside(reader, lines: lines)
        case .selfPromo:
            if plugPolicy >= 2, reader.confidence >= 90, length <= longPlug, sellsInside(reader, lines: lines) { return true }
            return reader.confidence >= 80 && length <= cap(.selfPromo) && sellsInside(reader, lines: lines)
        case .intro, .outro:
            return false
        }
    }

    static func repeated(_ cut: DetectedSegment) -> Bool {
        cut.evidence.contains { $0.contains(SegmentEvidence.repeatedAudio.rawValue) }
    }

    /// Whether any line inside the stretch does what its kind does.
    static func sellsInside(_ cut: DetectedSegment, lines: [TimedLine]) -> Bool {
        let brand = brandTokens(cut.sponsor)
        return lines.contains {
            let mid = ($0.start + $0.end) / 2
            return mid >= cut.start && mid <= cut.end && sells($0.text, kind: cut.kind, brand: brand)
        }
    }

    /// Pass 45: a model's "own plug" that names a sponsor inside a stretch
    /// the reader is sure is a paid read is that ad (#691: Shopify, read
    /// after BlueChew, called the show's merch because it mentions the store).
    static func relabelNamedSponsors(_ cuts: [DetectedSegment], readerCuts: [DetectedSegment],
                                     notes: inout [String]) -> [DetectedSegment] {
        cuts.map { cut in
            guard cut.kind == .selfPromo, !cut.sponsor.isEmpty,
                  readerCuts.contains(where: { $0.kind == .ad && $0.confidence >= 90
                      && overlap(cut, $0.start, $0.end) >= 0.5 }) else { return cut }
            var ad = cut
            ad.kind = .ad
            ad.evidence.append("an ad, not the show's own plug: the reader heard a paid read there")
            notes.append("called \(clock(cut.start)) an ad (\(cut.sponsor)), not an own plug")
            return ad
        }
    }

    /// One read the model answered as several parts (Stavvy's Cosentix as
    /// 2:08:20–25 and 2:08:27–31) is checked as one: same kind and sponsor,
    /// a breath apart. Each piece alone was under the 6-s floor and dropped.
    static func joinSplitReads(_ cuts: [DetectedSegment], gap: Double = 3) -> [DetectedSegment] {
        var out: [DetectedSegment] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if let i = out.indices.last, out[i].kind == cut.kind, !cut.sponsor.isEmpty,
               !out[i].insertedAtDownload, !cut.insertedAtDownload,
               AdDetector.normalise(out[i].sponsor) == AdDetector.normalise(cut.sponsor),
               cut.start <= out[i].end + gap {
                out[i].end = max(out[i].end, cut.end)
                out[i].confidence = max(out[i].confidence, cut.confidence)
            } else {
                out.append(cut)
            }
        }
        return out
    }

    /// Longest lead-in the reader may add in front of the model's first cut.
    static let readerLeadIn: Double = 60
    /// A hole between two model cuts longer than this is its own cut rather
    /// than the next read's lead-in.
    static let longHole: Double = 90

    /// Share of `reader` the ranges cover together (their union).
    static func coveredShare(_ reader: DetectedSegment, by ranges: [ClosedRange<Double>]) -> Double {
        let length = reader.end - reader.start
        guard length > 0 else { return 0 }
        let clipped = ranges.compactMap { r -> ClosedRange<Double>? in
            let a = max(r.lowerBound, reader.start), b = min(r.upperBound, reader.end)
            return b > a ? a...b : nil
        }
        return SkipJoin.joined(clipped, maxGap: 0).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } / length
    }

    /// The reader's time that `covering` (indices into `cuts`, by start)
    /// leaves out, added to the model's cuts. Holes between two model cuts
    /// extend the later one back (a hand-off is the next read's lead-in);
    /// the lead-in before the first extends it back; time after the last is
    /// added only when its lines sell, or when the model was mostly silent.
    /// Never into a stretch the model called a joke ad or a regular bit.
    /// Returns the seconds added.
    private static func fill(_ reader: DetectedSegment, around covering: [Int], in cuts: inout [DetectedSegment],
                             lines: [TimedLine], keeps: [ClosedRange<Double>], modelMostlySilent: Bool) -> Double {
        var added = 0.0
        var extra: [DetectedSegment] = []
        func free(_ a: Double, _ b: Double) -> [ClosedRange<Double>] {
            // a…b minus the keeps.
            var out: [ClosedRange<Double>] = b > a ? [a...b] : []
            for k in keeps {
                out = out.flatMap { r -> [ClosedRange<Double>] in
                    guard k.upperBound > r.lowerBound, k.lowerBound < r.upperBound else { return [r] }
                    var pieces: [ClosedRange<Double>] = []
                    if k.lowerBound > r.lowerBound { pieces.append(r.lowerBound...k.lowerBound) }
                    if k.upperBound < r.upperBound { pieces.append(k.upperBound...r.upperBound) }
                    return pieces
                }
            }
            return out.filter { $0.upperBound - $0.lowerBound >= 1 }
        }
        func readerPiece(_ r: ClosedRange<Double>) {
            var piece = reader
            piece.start = r.lowerBound
            piece.end = r.upperBound
            // The reader's sponsor belongs to one read of the break; on a
            // piece next to the model's named reads it would mislabel it.
            if covering.contains(where: { !cuts[$0].sponsor.isEmpty }) { piece.sponsor = "" }
            piece.evidence.append("kept from PodSkipper's reader: the model didn't mention this stretch")
            extra.append(piece)
            added += r.upperBound - r.lowerBound
        }
        let note = "edge moved to where PodSkipper's reader heard the ad"

        // Before the first model cut.
        let first = covering[0]
        if reader.start < cuts[first].start - 1 {
            let room = free(reader.start, cuts[first].start)
            if modelMostlySilent {
                room.forEach(readerPiece)
            } else if let last = room.last, last.upperBound >= cuts[first].start - 0.01,
                      cuts[first].start - last.lowerBound <= readerLeadIn {
                added += cuts[first].start - last.lowerBound
                cuts[first].start = last.lowerBound
                cuts[first].evidence.append(note)
            }
        }
        // Between model cuts.
        for (i, j) in zip(covering, covering.dropFirst()) {
            let a = max(cuts[i].end, reader.start), b = min(cuts[j].start, reader.end)
            guard b - a >= 1 else { continue }
            let room = free(a, b)
            if b - a <= longHole, room.count == 1, let r = room.first, r.upperBound >= b - 0.01 {
                added += cuts[j].start - r.lowerBound
                cuts[j].start = r.lowerBound
                cuts[j].evidence.append(note)
            } else {
                room.forEach(readerPiece)
            }
        }
        // After the last model cut.
        let last = covering[covering.count - 1]
        if reader.end > cuts[last].end + 1 {
            let room = free(cuts[last].end, reader.end)
            if modelMostlySilent {
                room.forEach(readerPiece)
            } else if let r = room.first, r.lowerBound <= cuts[last].end + 0.01 {
                let brand = brandTokens(cuts[last].sponsor) + brandTokens(reader.sponsor)
                let tail = lines.filter { ($0.start + $0.end) / 2 > r.lowerBound && ($0.start + $0.end) / 2 < r.upperBound }
                if let lastSelling = tail.last(where: { sells($0.text, kind: cuts[last].kind, brand: brand) }) {
                    let stop = min(r.upperBound, lastSelling.end)
                    if stop > cuts[last].end {
                        added += stop - cuts[last].end
                        cuts[last].end = stop
                        cuts[last].evidence.append(note)
                    }
                }
            }
        }
        cuts += extra
        return added
    }

    /// No two cuts overlap: where a cut runs into a different-kind cut, the
    /// earlier one stops where the later one starts (one nested inside
    /// another splits it). The later, usually narrower, model cut keeps its
    /// name and edges.
    static func separate(_ cuts: [DetectedSegment]) -> [DetectedSegment] {
        var out: [DetectedSegment] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if let i = out.indices.last, cut.start < out[i].end - 0.5 {
                let before = out[i]
                out[i].end = cut.start
                if before.end > cut.end + 1 {
                    var rest = before
                    rest.start = cut.end
                    out.append(cut)
                    out.append(rest)
                    out.sort { $0.start < $1.start }
                    continue
                }
            }
            out.append(cut)
        }
        return out.filter { $0.end > $0.start + 1 }
    }

    /// An intro or outro whose recording also plays elsewhere (exact audio
    /// evidence), at most a few minutes long.
    static func provenOpenerOrCloser(_ cut: DetectedSegment) -> Bool {
        (cut.kind == .intro || cut.kind == .outro)
            && cut.end - cut.start <= cap(cut.kind)
            && cut.evidence.contains { $0.contains(SegmentEvidence.repeatedAudio.rawValue) }
    }

    // MARK: Pieces

    private struct Piece { var cut: DetectedSegment; var backed: Bool }

    /// Time ranges something other than the model vouches for, padded a little.
    private static func backing(for cut: DetectedSegment, readerCuts: [DetectedSegment],
                                evidence: [EvidenceSpan]) -> [ClosedRange<Double>] {
        let pad = 8.0
        var ranges = readerCuts.filter { $0.end > cut.start && $0.start < cut.end }
            .map { ($0.start - pad)...($0.end + pad) }
        ranges += evidence.filter { $0.end > cut.start && $0.start < cut.end }
            .map { ($0.start - pad)...($0.end + pad) }
        return ranges
    }

    /// What of `cut` survives: backed stretches, plus the lines that sell
    /// with a lead-in and a tail, inside the model's own edges.
    private static func kept(_ cut: DetectedSegment, lines: [TimedLine], support: [ClosedRange<Double>],
                             duration: Double) -> [Piece] {
        var ranges = support
        let inside = lines.indices.filter {
            let mid = (lines[$0].start + lines[$0].end) / 2
            return mid >= cut.start && mid <= cut.end
        }
        switch cut.kind {
        case .intro, .outro:
            // Openers and sign-offs live at the edges of an episode.
            let atEdge = cut.kind == .intro ? cut.start <= 240 : cut.end >= duration - 420
            if atEdge, cut.end - cut.start <= cap(cut.kind) { ranges.append(cut.start...cut.end) }
        case .ad, .selfPromo, .crossPromo:
            let brand = brandTokens(cut.sponsor)
            var selling: [Int] = []
            for i in inside where sells(lines[i].text, kind: cut.kind, brand: brand) { selling.append(i) }
            for i in selling {
                ranges.append((lines[i].start - leadIn)...(lines[i].end + tail))
            }
        }
        // Join and clip to the model's own edges.
        var joined: [ClosedRange<Double>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let a = max(r.lowerBound, cut.start), b = min(r.upperBound, cut.end)
            guard b > a else { continue }
            // Inside one stretch the model called a single part, selling
            // lines a short gap apart are one read, not two with a hole.
            if let last = joined.last, a <= last.upperBound + joinGap {
                joined[joined.count - 1] = last.lowerBound...max(last.upperBound, b)
            } else {
                joined.append(a...b)
            }
        }
        var pieces: [Piece] = []
        for r in joined {
            // On line edges, so a cut never starts or ends mid-sentence.
            let members = inside.filter { lines[$0].end > r.lowerBound && lines[$0].start < r.upperBound }
            // The model's own edge stays where it is (music before the first
            // word of a jingle is part of it); only edges the check made snap.
            let start = r.lowerBound <= cut.start + 0.5 ? cut.start
                : members.first.map { max(cut.start, lines[$0].start) } ?? r.lowerBound
            let stop = r.upperBound >= cut.end - 0.5 ? cut.end
                : members.last.map { min(cut.end, lines[$0].end) } ?? r.upperBound
            guard stop - start >= 6 else { continue }
            let span = stop - start
            let vouched = support.reduce(0) { $0 + max(0, min($1.upperBound, stop) - max($1.lowerBound, start)) }
            let isBacked = vouched >= 0.5 * span
            if !isBacked, span > cap(cut.kind) {
                let brand = brandTokens(cut.sponsor)
                let sellingCount = members.filter { sells(lines[$0].text, kind: cut.kind, brand: brand) }.count
                // A long stretch on the model's word alone needs selling all through it.
                guard Double(sellingCount) >= span / 45 else { continue }
            }
            var piece = cut
            piece.start = start
            piece.end = stop
            if start > cut.start + 1 || stop < cut.end - 1 {
                piece.evidence.append("trimmed to the lines that sell")
            }
            pieces.append(Piece(cut: piece, backed: isBacked))
        }
        return pieces
    }

    /// Whether one line does what this kind of cut does.
    static func sells(_ text: String, kind: SegmentKind, brand: [String]) -> Bool {
        let lower = text.lowercased()
        if SegmentDetector.offersSomething(lower) || SegmentDetector.opensAnAd(text) { return true }
        if !brand.isEmpty {
            let flat = AdDetector.normalise(text).replacingOccurrences(of: " ", with: "")
            if brand.contains(where: { flat.contains($0) }) { return true }
        }
        switch kind {
        case .ad:
            return false
        case .selfPromo:
            let plugs = ["tickets", "on tour", "tour dates", "merch", "patreon", "subscribe", "rate and review",
                         "five star", "5 star", "youtube channel", "instagram", "follow me", "follow us",
                         "link in the", "in the description", "come see", "special is out", "my special", "new special",
                         "bonus episode", "premium feed", "live show", "go see", "pre-order", "preorder", "out now",
                         "go get it", "new episodes", "on spotify", "on youtube", "theater", "theatre", "dates",
                         "become a member", "support the show", "newsletter", "available for"]
            return plugs.contains { lower.contains($0) } || SegmentDetector.strongCues.contains { lower.contains($0) }
        case .crossPromo:
            let promo = ["check out", "new show", "listen to", "wherever you get your podcasts", "new episodes",
                         "subscribe", "podcast called", "series"]
            return promo.contains { lower.contains($0) } || SegmentDetector.promoCues.contains { lower.contains($0) }
        case .intro, .outro:
            return false
        }
    }

    /// The sponsor as squashed lowercase pieces worth matching ("liquidiv").
    static func brandTokens(_ sponsor: String) -> [String] {
        let words = AdDetector.normalise(sponsor).split(separator: " ").map(String.init)
        let squashed = words.joined()
        var tokens = words.filter { $0.count >= 4 && !["with", "from", "your", "show", "this"].contains($0) }
        if squashed.count >= 4 { tokens.append(squashed) }
        return Array(Set(tokens))
    }

    // MARK: Helpers

    /// Overlapping cuts of the same kind become one (back-to-back reads that
    /// only touch stay apart, each with its sponsor); sorted by start.
    static func merge(_ cuts: [DetectedSegment]) -> [DetectedSegment] {
        var out: [DetectedSegment] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if let i = out.indices.last, out[i].kind == cut.kind, cut.start < out[i].end - 0.5 {
                out[i].end = max(out[i].end, cut.end)
                out[i].confidence = max(out[i].confidence, cut.confidence)
                out[i].insertedAtDownload = out[i].insertedAtDownload || cut.insertedAtDownload
                if out[i].sponsor.isEmpty { out[i].sponsor = cut.sponsor }
            } else {
                out.append(cut)
            }
        }
        return out.filter { $0.end > $0.start + 1 }
    }

    static func overlap(_ cut: DetectedSegment, _ start: Double, _ end: Double) -> Double {
        let length = cut.end - cut.start
        guard length > 0 else { return 0 }
        return max(0, min(cut.end, end) - max(cut.start, start)) / length
    }

    static func clock(_ s: Double) -> String {
        let t = Int(max(0, s))
        return String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }
}
