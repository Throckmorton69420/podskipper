import Foundation

// Pass 63: Compare Models' Basic and Hard samples on the Mac, through the
// app's own code — the Reader (`AdDetector.detectSentences`), a model's saved
// answers through `JudgePrompt` + `ModelFinder.checkedCuts`, and the score
// (`BenchSample.report`).
//
//   lab-bench <basic|hard>                    the Reader's cuts, line by line
//   lab-bench <basic|hard> dump <out.json>    the sample as a lab transcript
//                                             ([{text,start,end,words}]) plus
//                                             <out>.meta.json (silences, focus
//                                             ranges, show, title, notes)
//   lab-bench <basic|hard> score <answers.json>
//                                             a model's answers (cpu-lab's
//                                             `parts` / mlx-lab's `answers`):
//                                             raw score and the score after
//                                             the app's cut check
//   LAB_TAGGER=<w1.bin>:<w2.bin>   the Reader's weights
//   LAB_TRACE=1                    every line with the Reader's probabilities
//   LAB_LOG=1                      the detector's log
//
// Build (from the repository root):
//   xcrun swiftc -O -parse-as-library -o build/p63/lab-bench Tools/DetectionLab/LabBench.swift \
//     Services/{SegmentDetector,SegmentEvidence,TranscriptionService,AdDetector,AdFreeCopy,FeedbackMemory}.swift \
//     Services/{FastReader,SentenceTagger,AdPrints,ModelCutCheck,ModelFinder,CutBlocks}.swift Models/DetectionTypes.swift \
//     Services/LocalModel/{JudgePrompt,ModelAnswerFailure,BenchScripts,BenchSample}.swift Services/PodTest/PodTestScore.swift

struct Answer: Decodable { var first: Int; var last: Int; var text: String; var outOfRoom: Bool? }
struct Answers: Decodable {
    var parts: [Answer]?; var answers: [Answer]?
    enum CodingKeys: String, CodingKey { case parts, answers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parts = try? c.decode([Answer].self, forKey: .parts)
        answers = try? c.decode([Answer].self, forKey: .answers)
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

@main struct LabBench {
    static func main() async {
        let args = CommandLine.arguments
        // lab-bench export <out.json>: both samples as a results file the
        // model labs read ({"episodes":[{show,title,notes,transcript}]};
        // 0 = Basic, 1 = Hard) and <out>.focus.txt with Hard's LAB_ONLY.
        if args.count >= 3, args[1] == "export" {
            var episodes: [[String: Any]] = []
            for sample in BenchSample.allCases {
                episodes.append(["show": sample.show, "title": sample.episode, "notes": sample.notes,
                                 "transcript": sample.script.lines.map { ["text": $0.text, "start": $0.start, "end": $0.end] }])
            }
            try! JSONSerialization.data(withJSONObject: ["episodes": episodes]).write(to: URL(fileURLWithPath: args[2]))
            let hard = BenchSample.hard
            let cuts = try! await AdDetector().detectSentences(
                segments: hard.transcript, silences: hard.silences, showTitle: hard.show, episodeTitle: hard.episode,
                showNotes: hard.notes, audioDuration: hard.duration).segments
            let lines = hard.lines
            let focus = ModelFinder.focusRanges(lines: lines, readerCuts: cuts, duration: hard.duration, evidence: [], hints: [])
            let only = focus.map { "\(Int(lines[$0.lowerBound].start))-\(Int(lines[$0.upperBound - 1].end))" }.joined(separator: ",")
            try! only.write(toFile: args[2].replacingOccurrences(of: ".json", with: ".focus.txt"), atomically: true, encoding: .utf8)
            print("wrote \(args[2]); Hard focus \(focus) = \(Int(ModelFinder.share(focus, of: lines) * 100))% of its lines")
            return
        }
        guard args.count >= 2, let sample = BenchSample(rawValue: args[1]) else {
            print("usage: lab-bench <basic|hard> [dump out.json | score answers.json]"); return
        }
        let env = ProcessInfo.processInfo.environment
        // The detector's lab switches, as lab-segments reads them.
        var tuning = SegmentDetector.Tuning()
        if let v = env["LAB_SHOWFLOOR"] { tuning.showFloor = v == "off" ? nil : Double(v) }
        if let v = env["LAB_SHOWRUN"].flatMap(Double.init) { tuning.showRunSeconds = v }
        if let v = env["LAB_PLUGGAP"] { tuning.plugGapShow = v == "off" ? nil : Double(v) }
        if env["LAB_ENDS"] == "0" { tuning.endsWhereItSells = false }
        if let v = env["LAB_TAILWAVERS"].flatMap(Double.init) { tuning.tailWavers = v }
        if let v = env["LAB_TAILMEAN"].flatMap(Double.init) { tuning.tailMean = v }
        if let v = env["LAB_TAIL"].flatMap(Double.init) { tuning.longestTail = v }
        if env["LAB_JOKES"] == "0" { tuning.keepsJokeAds = false }
        if env["LAB_CREDITS"] == "0" { tuning.splitsAfterCredits = false }
        if env["LAB_KINDS"] == "0" { tuning.splitsKinds = false }
        SegmentDetector.tuning = tuning
        let lines = sample.lines
        let segments = sample.transcript
        let silences = sample.silences
        let duration = sample.duration

        if args.count >= 4, args[2] == "dump" {
            struct Out: Encodable { var text: String; var start: Double; var end: Double; var words: [TranscriptWord] }
            let rows = segments.map { Out(text: $0.text, start: $0.start, end: $0.end, words: $0.words) }
            try! JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: args[3]))
            let detection = try! await AdDetector().detectSentences(
                segments: segments, silences: silences, showTitle: sample.show, episodeTitle: sample.episode,
                showNotes: sample.notes, audioDuration: duration)
            let focus = ModelFinder.focusRanges(lines: lines, readerCuts: detection.segments, duration: duration,
                                                evidence: [], hints: [])
            let meta: [String: Any] = ["show": sample.show, "title": sample.episode, "notes": sample.notes,
                                       "silences": silences.map { [$0.lowerBound, $0.upperBound] },
                                       "focus": focus.map { [$0.lowerBound, $0.upperBound - 1] },
                                       "lines": lines.count, "duration": duration]
            try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
                .write(to: URL(fileURLWithPath: args[3].replacingOccurrences(of: ".json", with: ".meta.json")))
            print("wrote \(rows.count) lines, \(Int(duration)) s, focus \(focus)")
            return
        }

        let started = Date()
        let detection = try! await AdDetector().detectSentences(
            segments: segments, silences: silences, showTitle: sample.show, episodeTitle: sample.episode,
            showNotes: sample.notes, audioDuration: duration)
        let readerCuts = detection.segments
        let seconds = Date().timeIntervalSince(started)

        func show(_ title: String, _ cuts: [DetectedSegment]) {
            let report = sample.report(cuts: cuts.map { PodTestCut(start: $0.start, end: $0.end, kind: $0.kind.rawValue) })
            print("\(title): \(report.line)")
            for cut in cuts {
                let inside = lines.indices.filter { (lines[$0].start + lines[$0].end) / 2 >= cut.start
                    && (lines[$0].start + lines[$0].end) / 2 <= cut.end }
                print("   \(cut.kind.rawValue) lines \(inside.first ?? -1)–\(inside.last ?? -1) conf \(cut.confidence) \(String(format: "%.1f–%.1f", cut.start, cut.end))")
            }
            if !report.checks.trapsCut.isEmpty { print("   traps cut: \(report.checks.trapsCut)") }
        }

        if args.count >= 4, args[2] == "score" {
            let file = try! JSONDecoder().decode(Answers.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
            let share = env["LAB_SHARE"].flatMap(Double.init)
            var found: [JudgedPart] = []
            var unreadable = 0
            for answer in file.parts ?? file.answers ?? [] {
                let window = answer.first..<(answer.last + 1)
                guard let parts = JudgePrompt.parseComplete(answer.text)
                        ?? ((answer.outOfRoom ?? false) ? nil : JudgePrompt.parse(answer.text)) else { unreadable += 1; continue }
                found += JudgePrompt.shifted(parts, window: window, lines: lines, maxShare: share)
                    .compactMap { JudgePrompt.resolve($0, lines: lines) }
            }
            let merged = mergeParts(found)
            let raw = ModelFinder.cuts(from: merged, lines: lines, readerCuts: [], inserted: [], silences: silences,
                                       padding: 0.4, duration: duration)
            // Pass 64: LAB_VETO=0 is the check without the Reader's show veto.
            if env["LAB_VETO"] == "0" { ModelCutCheck.continuityVeto = false }
            if let sure = env["LAB_SHOWSURE"].flatMap(Double.init) { ModelCutCheck.showSure = sure }
            let checked = ModelFinder.checkedCuts(from: merged, lines: lines, readerCuts: readerCuts, inserted: [],
                                                  evidence: [], silences: silences, padding: 0.4, duration: duration,
                                                  readerShow: detection.readerShow)
            print("parts read: \(merged.map { "\($0.label.rawValue) \($0.firstLine)–\($0.lastLine)" }.joined(separator: ", ")) · unreadable \(unreadable)")
            show("Reader", readerCuts)
            show("Model alone", raw)
            show("With PodSkipper's check", checked.cuts)
            for note in checked.notes { print("   note: \(note)") }
            return
        }

        show("Reader (\(String(format: "%.1f", seconds)) s)", readerCuts)
        if env["LAB_TRACE"] != nil {
            let sentences = SegmentDetector.sentences(from: segments)
            let probabilities = SentenceTagger.probabilities(sentences) ?? []
            let expected = sample.expectedCut
            for (i, s) in sentences.enumerated() {
                let line = lines.firstIndex { ($0.start + $0.end) / 2 >= s.start && ($0.start + $0.end) / 2 <= s.end } ?? -1
                let p = i < probabilities.count ? probabilities[i] : []
                let cut = readerCuts.first { s.start < $0.end && s.end > $0.start }
                let mark = (expected.contains(line) ? "B" : sample.either.contains(line) ? "e" : " ")
                    + (cut.map { String($0.kind.rawValue.prefix(4)).padding(toLength: 5, withPad: " ", startingAt: 0) } ?? "  .  ")
                let ps = p.map { String(format: "%2d", Int(($0 * 100).rounded())) }.joined(separator: " ")
                print("\(String(format: "%3d", line)) \(mark) [\(ps)] \(s.text.prefix(80))")
            }
        }
        if env["LAB_LOG"] != nil { print("---- log ----"); detection.log.forEach { print($0) } }
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
