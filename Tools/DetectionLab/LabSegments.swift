import Foundation

// Runs the sentence-level detector (Services/SegmentDetector.swift) on a lab
// transcript and prints its findings in the same form as LabDetect, so
// `lab.sh score` reads either.
//
// Every question and answer is kept in <transcript>.replies.json, so a change
// to one stage only asks the questions that changed. LAB_RELABEL=1 starts
// afresh. LAB_TRACE="690-800,1840-2020" prints every sentence in those
// seconds with the span that covers it.

struct Line: Codable { let text: String; let start: Double; let end: Double; var words: [TranscriptWord]? }

final class ReplyStore: @unchecked Sendable {
    private var replies: [String: String]
    private let url: URL
    private let lock = NSLock()
    private(set) var hits = 0, misses = 0
    init(url: URL, fresh: Bool) {
        self.url = url
        replies = fresh ? [:] : ((try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:])
    }
    func get(_ key: String) -> String? {
        lock.withLock {
            if let r = replies[key] { hits += 1; return r }
            misses += 1; return nil
        }
    }
    func set(_ key: String, _ value: String) { lock.withLock { replies[key] = value } }
    func save() { lock.withLock { try? JSONEncoder().encode(replies).write(to: url) } }
}

@main struct LabSegments {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: segments transcript.json [notes.txt] [show] [title]"); return }
        let path = args[1]
        let lines = try! JSONDecoder().decode([Line].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let segments = lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? []) }
        let notes = args.count >= 3 ? ((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "") : ""
        let show = args.count >= 4 ? args[3] : ""
        let title = args.count >= 5 ? args[4] : ""
        setvbuf(stdout, nil, _IONBF, 0)
        let env = ProcessInfo.processInfo.environment
        let store = ReplyStore(url: URL(fileURLWithPath: path.replacingOccurrences(of: ".json", with: ".replies.json")),
                               fresh: env["LAB_RELABEL"] != nil)
        AdDetector.replyCache = (get: { store.get($0) }, set: { store.set($0, $1) })
        // Tuning from the environment, for sweeps.
        var tuning = SegmentDetector.Tuning()
        if let v = env["LAB_SIZE"].flatMap(Int.init) { tuning.labelSize = v }
        if let v = env["LAB_STEP"].flatMap(Int.init) { tuning.labelStep = v }
        if let v = env["LAB_PAD"].flatMap(Double.init) { tuning.hitPad = v }
        if let v = env["LAB_CUEPAD"].flatMap(Double.init) { tuning.cuePad = v }
        if let v = env["LAB_WALK"].flatMap(Int.init) { tuning.walkBelow = v }
        if let v = env["LAB_PAR"].flatMap(Int.init) { tuning.parallel = v }
        SegmentDetector.tuning = tuning
        FileHandle.standardError.write("tuning \(tuning)\n".data(using: .utf8)!)
        // LAB_INSERTED=1: the cheap evidence (dai.py cuts → <key>.cheap.json:
        // the ad-free comparison plus repeated-ad fingerprints) is handed to
        // the detector as the app hands it the comparison's spans.
        var inserted: [ClosedRange<Double>] = []
        if env["LAB_INSERTED"] != nil {
            struct Span: Decodable { var start: Double; var end: Double }
            let url = URL(fileURLWithPath: path.replacingOccurrences(of: "-pub.json", with: ".json")
                .replacingOccurrences(of: ".json", with: ".cheap.json"))
            if let data = try? Data(contentsOf: url), let spans = try? JSONDecoder().decode([Span].self, from: data) {
                inserted = spans.map { $0.start...$0.end }
            }
            FileHandle.standardError.write("inserted spans: \(inserted.count)\n".data(using: .utf8)!)
        }
        // LAB_PRODUCED=1: audio that plays again (lab-prints produced →
        // <key>.produced.json), handed over as the app hands AdPrints' result.
        var produced: [AdPrints.Produced] = []
        if env["LAB_PRODUCED"] != nil {
            struct P: Decodable { var start: Double; var end: Double; var acrossEpisodes: Bool; var known: String?; var negative: Bool? }
            let url = URL(fileURLWithPath: path.replacingOccurrences(of: "-pub.json", with: ".json")
                .replacingOccurrences(of: ".json", with: ".produced.json"))
            if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([P].self, from: data) {
                produced = list.map { AdPrints.Produced(start: $0.start, end: $0.end, acrossEpisodes: $0.acrossEpisodes,
                                                        known: $0.known, negative: $0.negative ?? false) }
            }
            FileHandle.standardError.write("produced spans: \(produced.count)\n".data(using: .utf8)!)
        }
        let started = Date()
        do {
            let (findings, log) = try await SegmentDetector().detect(
                segments: segments, showTitle: show, episodeTitle: title, showNotes: notes,
                inserted: inserted, produced: produced) { p in
                    FileHandle.standardError.write("progress \(Int(p * 100)) at \(Int(Date().timeIntervalSince(started)))s\n".data(using: .utf8)!)
                }
            store.save()
            print("detection seconds:", Int(Date().timeIntervalSince(started)), "segments:", findings.count,
                  "questions asked:", store.misses, "answered from cache:", store.hits)
            let sentences = SegmentDetector.sentences(from: segments)
            for f in findings {
                print("\n[\(f.kind.rawValue)] \(SegmentDetector.clock(f.start))–\(SegmentDetector.clock(f.end)) (\(Int(f.end - f.start))s) conf \(f.confidence) edges \(f.startConfidence)/\(f.endConfidence) sponsor '\(f.sponsor)'\(f.detail.isEmpty ? "" : " class " + f.detail)\(f.insertedAtDownload ? " inserted" : "")")
                let text = sentences[f.firstSentence...f.lastSentence].map(\.text).joined(separator: " ")
                print("   " + String(text.prefix(400)))
            }
            if let trace = env["LAB_TRACE"] {
                for part in trace.split(separator: ",") {
                    let b = part.split(separator: "-").compactMap { Double($0) }
                    guard b.count == 2 else { continue }
                    print("\n---- trace \(SegmentDetector.clock(b[0]))–\(SegmentDetector.clock(b[1])) ----")
                    for (i, s) in sentences.enumerated() where s.end > b[0] && s.start < b[1] {
                        let covering = findings.first { $0.firstSentence <= i && i <= $0.lastSentence }
                        let tag = covering.map { String($0.kind.rawValue.prefix(6)) } ?? "  .   "
                        let votes = i < SegmentDetector.lastVotes.count
                            ? SegmentDetector.lastVotes[i].sorted { $0.value > $1.value }.map { "\($0.key.rawValue)\($0.value)" }.joined()
                            : ""
                        print("\(SegmentDetector.clock(s.start)) \(tag.padding(toLength: 6, withPad: " ", startingAt: 0)) \(votes.padding(toLength: 5, withPad: " ", startingAt: 0)) \(s.text.prefix(90))")
                    }
                }
            }
            print("\n---- log ----")
            log.forEach { print($0) }
        } catch { store.save(); print("error:", error) }
    }
}
