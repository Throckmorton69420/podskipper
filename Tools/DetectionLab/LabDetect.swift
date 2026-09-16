import Foundation

struct Line: Codable { let text: String; let start: Double; let end: Double }

func clock(_ s: Double) -> String { String(format: "%d:%02d:%02d", Int(s) / 3600, Int(s) / 60 % 60, Int(s) % 60) }

@main struct LabDetect {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else { print("usage: detect transcript.json [notes.txt] [title]"); return }
        let lines = try! JSONDecoder().decode([Line].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let segments = lines.map { TranscriptSegment(text: $0.text, start: $0.start, end: $0.end) }
        let notes = args.count >= 3 ? ((try? String(contentsOfFile: args[2], encoding: .utf8)) ?? "") : ""
        let title = args.count >= 4 ? args[3] : ""
        setvbuf(stdout, nil, _IONBF, 0)
        // Simulated thumbs, to exercise the feedback memory:
        //   LAB_REJECT="365-425,1200-1260"  LAB_CONFIRM="2539-2600"
        // Each range (seconds) becomes a correction built from the transcript
        // text in it, exactly as a thumb in the app builds one.
        func corrections(_ variable: String, kind: SegmentKind?) -> [DetectionCorrection] {
            guard let raw = ProcessInfo.processInfo.environment[variable] else { return [] }
            return raw.split(separator: ",").compactMap { part in
                let bounds = part.split(separator: "-").compactMap { Double($0) }
                guard bounds.count == 2 else { return nil }
                let text = segments.filter { $0.start < bounds[1] && $0.end > bounds[0] }
                    .map(\.text).joined(separator: " ")
                return DetectionCorrection(excerpt: text, kind: kind)
            }
        }
        // LAB_STYLE_ONLY="1-27,974-1303" asks only the delivery question for
        // those ranges, skipping detection — for iterating on that prompt.
        if let raw = ProcessInfo.processInfo.environment["LAB_STYLE_ONLY"] {
            for part in raw.split(separator: ",") {
                let b = part.split(separator: "-").compactMap { Double($0) }
                guard b.count == 2 else { continue }
                let text = segments.filter { $0.start < b[1] && $0.end > b[0] }.map(\.text).joined(separator: " ")
                let seg = DetectedSegment(start: b[0], end: b[1], kind: .ad, sponsor: "", confidence: 100)
                let style = await AdDetector().classifyStyle(of: seg, text: text)
                print("\(clock(b[0]))–\(clock(b[1])):", style.map { "\($0.hostRead ? "host-read" : "produced")\($0.comedyBit ? ", played for laughs" : "")" } ?? "no answer",
                      "|", String(text.prefix(120)))
            }
            return
        }
        let feedback = corrections("LAB_REJECT", kind: nil) + corrections("LAB_CONFIRM", kind: .ad)
        let started = Date()
        do {
            let result = try await AdDetector().detect(
                windows: segments.windows(), segments: segments, silences: [],
                knownSponsors: [], corrections: feedback,
                showTitle: args.count >= 5 ? args[4] : "", episodeTitle: title, showNotes: notes,
                minimumConfidence: 60, padding: 0.4) { p in FileHandle.standardError.write("progress \(Int(p * 100)) at \(Int(Date().timeIntervalSince(started)))s\n".data(using: .utf8)!) }
            print("detection seconds:", Int(Date().timeIntervalSince(started)), "segments:", result.segments.count)
            for s in result.segments {
                let text = segments.filter { $0.start < s.end && $0.end > s.start }.map(\.text).joined(separator: " ")
                print("\n[\(s.kind.rawValue)] \(clock(s.start))–\(clock(s.end)) (\(Int(s.end - s.start))s) conf \(s.confidence) sponsor '\(s.sponsor)'")
                print("   " + String(text.prefix(700)))
                // LAB_STYLE=1 also asks how each ad was delivered — the
                // question behind "keep host-read ads" and "keep ads played
                // for laughs".
                if ProcessInfo.processInfo.environment["LAB_STYLE"] == "1", s.kind == .ad {
                    if let style = await AdDetector().classifyStyle(of: s, text: text) {
                        print("   style: \(style.hostRead ? "host-read" : "produced")\(style.comedyBit ? ", played for laughs" : "")")
                    } else {
                        print("   style: no answer")
                    }
                }
            }
            if !result.log.isEmpty {
                print("\n---- log ----")
                result.log.forEach { print($0) }
            }
        } catch { print("error:", error) }
    }
}
