import Foundation

// Runs the structure detector (Services/StructureDetector.swift) on a lab
// transcript and prints its findings in the same form as LabDetect, so
// `lab.sh score` reads either. Replies are cached in <transcript>.structure.json;
// LAB_RELABEL=1 starts afresh. LAB_TRACE="660-800" prints each sentence with
// what each reading called it.

struct SLine: Codable { let text: String; let start: Double; let end: Double; var words: [TranscriptWord]? }

final class SReplyStore: @unchecked Sendable {
    private var replies: [String: String]
    private let url: URL
    private let lock = NSLock()
    private(set) var hits = 0, misses = 0
    init(url: URL, fresh: Bool) {
        self.url = url
        replies = fresh ? [:] : ((try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:])
    }
    func get(_ key: String) -> String? { lock.withLock { if let r = replies[key] { hits += 1; return r }; misses += 1; return nil } }
    func set(_ key: String, _ value: String) { lock.withLock { replies[key] = value } }
    func save() { lock.withLock { try? JSONEncoder().encode(replies).write(to: url) } }
}

@main struct LabStructure {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: structure transcript.json [notes.txt] [show] [title]"); return }
        let path = args[1]
        let lines = try! JSONDecoder().decode([SLine].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let segments = lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? []) }
        let notes = args.count >= 3 ? ((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "") : ""
        let show = args.count >= 4 ? args[3] : ""
        let title = args.count >= 5 ? args[4] : ""
        setvbuf(stdout, nil, _IONBF, 0)
        let env = ProcessInfo.processInfo.environment
        let store = SReplyStore(url: URL(fileURLWithPath: path.replacingOccurrences(of: ".json", with: ".structure.json")),
                                fresh: env["LAB_RELABEL"] != nil)
        AdDetector.replyCache = (get: { store.get($0) }, set: { store.set($0, $1) })
        let started = Date()
        do {
            let (findings, log) = try await StructureDetector().detect(
                segments: segments, showTitle: show, episodeTitle: title, showNotes: notes) { p in
                    FileHandle.standardError.write("progress \(Int(p * 100)) at \(Int(Date().timeIntervalSince(started)))s\n".data(using: .utf8)!)
                }
            store.save()
            print("detection seconds:", Int(Date().timeIntervalSince(started)), "segments:", findings.count,
                  "questions asked:", store.misses, "answered from cache:", store.hits)
            let sentences = SegmentDetector.sentences(from: segments)
            for f in findings {
                print("\n[\(f.kind.rawValue)] \(SegmentDetector.clock(f.start))–\(SegmentDetector.clock(f.end)) (\(Int(f.end - f.start))s) conf \(f.confidence) edges \(f.startConfidence)/\(f.endConfidence) sponsor '\(f.sponsor)'\(f.needsReview ? " NEEDS REVIEW" : "")")
                print("   why: \(f.evidence.joined(separator: "; "))")
                let text = sentences[f.firstSentence...f.lastSentence].map(\.text).joined(separator: " ")
                print("   " + String(text.prefix(300)))
            }
            if let trace = env["LAB_TRACE"] {
                for part in trace.split(separator: ",") {
                    let b = part.split(separator: "-").compactMap { Double($0) }
                    guard b.count == 2 else { continue }
                    print("\n---- trace \(SegmentDetector.clock(b[0]))–\(SegmentDetector.clock(b[1])) ----")
                    for (i, s) in sentences.enumerated() where s.end > b[0] && s.start < b[1] {
                        let covering = findings.first { $0.firstSentence <= i && i <= $0.lastSentence }
                        let tag = covering.map { String($0.kind.rawValue.prefix(6)) } ?? "  .   "
                        let readings = i < StructureDetector.lastVotes.count
                            ? StructureDetector.lastVotes[i].map { String($0.rawValue) }.joined() : ""
                        print("\(i) \(SegmentDetector.clock(s.start)) \(tag.padding(toLength: 6, withPad: " ", startingAt: 0)) \(readings.padding(toLength: 3, withPad: " ", startingAt: 0)) \(s.text.prefix(95))")
                    }
                }
            }
            print("\n---- log ----")
            log.forEach { print($0) }
        } catch { store.save(); print("error:", error) }
    }
}
