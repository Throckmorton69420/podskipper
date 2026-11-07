import Foundation

// Pass 58: a model's saved per-part answers (cpu-lab's `parts`, mlx-lab's
// `answers`) put through the app's own path — JudgePrompt's reading and edge
// anchoring, LocalJudge.merge, ModelFinder.checkedCuts (ModelCutCheck) —
// against the Reader's cuts from AdDetector.detectSentences, so what is scored
// is what the app would save for that read.
//
//   lab-cutcheck <transcript.json> <answers.json>
//   LAB_TAGGER=<w1.bin>:<w2.bin>  the Reader's weights (as lab-segments)
//   LAB_PADDING=0.4               Settings › boundary padding (the default)
//   LAB_EDGES=0 / LAB_BRAND=0     the cut check as before Pass 58's two rules
//   LAB_UNION=0                   the Reader's cuts stand only when sure (before Pass 59)
//   LAB_UNION=all / ads           every kind of Reader cut stands / only its ads
//   answers.json may instead hold {"proposed": [{start, end, kind, sponsor,
//   confidence}]} — a phone read's own cuts — checked as they are.
//
// No audio evidence, silences or corrections: the lab has the transcript
// only, as test_cuts.py's Reader runs do. Prints one JSON object.
//
// Build (from the repository root):
//   xcrun swiftc -O -parse-as-library -o build/lab-cutcheck Tools/DetectionLab/LabCutCheck.swift \
//     Services/{SegmentDetector,SegmentEvidence,TranscriptionService,AdDetector,AdFreeCopy,FeedbackMemory}.swift \
//     Services/{FastReader,SentenceTagger,AdPrints,ModelCutCheck,ModelFinder,CutBlocks}.swift Models/DetectionTypes.swift \
//     Services/LocalModel/{JudgePrompt,ModelAnswerFailure}.swift

struct Line: Codable { let text: String; let start: Double; let end: Double; var words: [TranscriptWord]? }
struct Answer: Decodable { var first: Int; var last: Int; var text: String; var outOfRoom: Bool? }
/// A phone read's own cuts, before the check (`proposed` in an export).
struct Proposed: Decodable { var start: Double; var end: Double; var kind: String; var sponsor: String?; var confidence: Int?; var insertedAtDownload: Bool? }
struct Answers: Decodable {
    var parts: [Answer]?; var answers: [Answer]?; var proposed: [Proposed]?
    enum CodingKeys: String, CodingKey { case parts, answers, proposed }
    /// mlx-lab's records keep a count under "parts" and the replies under "answers".
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parts = try? c.decode([Answer].self, forKey: .parts)
        answers = try? c.decode([Answer].self, forKey: .answers)
        proposed = try? c.decode([Proposed].self, forKey: .proposed)
    }
}

/// Models/Models.swift's TimedLine, without the app.
struct TimedLine: Codable, Hashable, Identifiable {
    var text: String
    var start: Double
    var end: Double
    var words: [TranscriptWord]? = nil
    var id: Double { start }
}

@main struct LabCutCheck {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: lab-cutcheck transcript.json answers.json"); return }
        let env = ProcessInfo.processInfo.environment
        let raw = try! JSONDecoder().decode([Line].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let segments = raw.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end, words: $0.words ?? []) }
        let lines = raw.map { TimedLine(text: $0.text, start: $0.start, end: $0.end, words: $0.words) }
        let file = try! JSONDecoder().decode(Answers.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
        let padding = env["LAB_PADDING"].flatMap(Double.init) ?? 0.4
        let duration = lines.last?.end ?? 0

        let detection = try! await AdDetector().detectSentences(segments: segments, audioDuration: duration, padding: padding)
        let readerCuts = detection.segments

        // CPUJudge.judgeReport's reading of each part's answer (Qwen3.5 4B has
        // no maxCutShare), then LocalJudge.merge.
        var found: [JudgedPart] = []
        var unreadable = 0
        for answer in file.parts ?? file.answers ?? [] {
            let window = answer.first..<(answer.last + 1)
            guard let parts = JudgePrompt.parseComplete(answer.text)
                    ?? ((answer.outOfRoom ?? false) ? nil : JudgePrompt.parse(answer.text)) else { unreadable += 1; continue }
            found += JudgePrompt.shifted(parts, window: window, lines: lines, maxShare: nil)
                .compactMap { JudgePrompt.resolve($0, lines: lines) }
        }
        if env["LAB_EDGES"] == "0" { ModelCutCheck.readerEdges = false }
        if env["LAB_BRAND"] == "0" { ModelCutCheck.brandNeedsCue = false }
        if env["LAB_UNION"] == "0" { ModelCutCheck.readerAlwaysStands = false }
        if env["LAB_UNION"] == "all" { ModelCutCheck.readerStandsAllKinds = true }
        if env["LAB_UNION"] == "ads" { ModelCutCheck.plugStands = 101 }
        let merged = mergeParts(found)
        let checked: ModelCutCheck.Outcome
        if let proposed = file.proposed {
            let cuts = proposed.compactMap { p -> DetectedSegment? in
                guard let kind = SegmentKind(rawValue: p.kind) else { return nil }
                return DetectedSegment(start: p.start, end: p.end, kind: kind, sponsor: p.sponsor ?? "",
                                       confidence: p.confidence ?? 0, evidence: [],
                                       insertedAtDownload: p.insertedAtDownload ?? false)
            }
            checked = ModelCutCheck.verify(cuts, lines: lines, readerCuts: readerCuts, evidence: [], keeps: [], duration: duration)
        } else {
            checked = ModelFinder.checkedCuts(from: merged, lines: lines, readerCuts: readerCuts, inserted: [],
                                              evidence: [], silences: [], padding: padding, duration: duration)
        }
        func rows(_ cuts: [DetectedSegment]) -> [[Any]] { cuts.map { [$0.start, $0.end, $0.kind.rawValue, $0.confidence] } }
        let out: [String: Any] = ["reader": rows(readerCuts), "proposed": rows(checked.proposed), "checked": rows(checked.cuts),
                                  "notes": checked.notes, "dropped": checked.droppedSeconds, "unreadable": unreadable,
                                  "keeps": merged.filter { $0.label == .mockAd || $0.label == .recurringSegment }.count]
        print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
    }

    /// LocalJudge.merge, copied (LocalJudge.swift needs MLX and UIKit).
    static func mergeParts(_ parts: [JudgedPart]) -> [JudgedPart] {
        var merged: [JudgedPart] = []
        for part in parts.sorted(by: { ($0.firstLine, $0.lastLine) < ($1.firstLine, $1.lastLine) }) {
            if let i = merged.lastIndex(where: {
                $0.label == part.label && $0.firstLine <= part.lastLine && part.firstLine <= $0.lastLine
            }) {
                var kept = merged[i]
                let stronger = part.confidence > kept.confidence
                kept.firstLine = Swift.min(kept.firstLine, part.firstLine)
                kept.lastLine = Swift.max(kept.lastLine, part.lastLine)
                kept.funny = kept.funny || part.funny
                if kept.sponsor.isEmpty || (stronger && !part.sponsor.isEmpty) { kept.sponsor = part.sponsor }
                if stronger { kept.why = part.why }
                kept.confidence = Swift.max(kept.confidence, part.confidence)
                merged[i] = kept
            } else {
                merged.append(part)
            }
        }
        return merged
    }
}
