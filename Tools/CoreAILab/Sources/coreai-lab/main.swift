import Foundation

/// Pass 30 Core AI lab: one model, one fixture, the app's own prompt and
/// reader. Run from the repo root. Writes build/coreai-lab/<tag>.detect.txt
/// in the format Tools/DetectionLab/regression/score.py reads.
@main
struct CoreAILab {
    static func clock(_ s: Double) -> String {
        let t = max(0, s)
        return String(format: "%d:%02d:%05.2f", Int(t) / 3600, Int(t) / 60 % 60, t.truncatingRemainder(dividingBy: 60))
    }

    static func main() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: coreai-lab <bundle dir> <fixture> [auto|lean|compact|full] [engine hint]")
            return
        }
        let bundle = URL(fileURLWithPath: args[1])
        let key = args[2]
        let profileArg = args.count > 3 ? args[3] : "auto"
        let hint = args.count > 4 && !args[4].isEmpty ? args[4] : nil
        let env = ProcessInfo.processInfo.environment
        let lab = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "build/lab")
        let lines = try JSONDecoder().decode([TimedLine].self, from: Data(contentsOf: lab.appending(path: key + ".json")))
        let notes = (try? String(contentsOf: lab.appending(path: key + ".notes.txt"), encoding: .utf8)) ?? ""
        let title = ((try? String(contentsOf: lab.appending(path: key + ".title"), encoding: .utf8)) ?? key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let show = env["LAB_SHOW"] ?? ""

        let loadStarted = Date()
        let session = try await CoreAIClassifierSession(bundleAt: bundle, engineHint: hint)
        let loadSeconds = Date().timeIntervalSince(loadStarted)
        // LAB_CONTEXT=4096 plans parts as the phone's bundle would hold them.
        let context = env["LAB_CONTEXT"].flatMap(Int.init) ?? session.contextLimit
        let profile = profileArg == "auto" ? JudgePrompt.Profile.forContext(context)
            : (JudgePrompt.Profile(rawValue: profileArg) ?? .lean)
        print("model \(bundle.lastPathComponent) · loaded in \(Int(loadSeconds)) s · holds \(session.contextLimit) (bundle \(session.bundleContext)) · pipelined \(session.pipelined) · profile \(profile.rawValue)")

        var notesCut = profile == .full ? notes : String(notes.prefix(profile.notesLimit))
        if env["LAB_NOTES"] == "0" { notesCut = "" }
        let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: []) }
        let header = JudgePrompt.user(show: show, title: title, notes: notesCut, lines: lines,
                                      window: 0..<0, formatted: formatted, corrections: "")
        let overhead = try await session.promptTokenCount(system: profile.system, user: header)
        var counts: [Int] = []
        for line in formatted { counts.append(await session.tokenCount(line + "\n")) }
        let answerRoom = profile.answerTokens
        let room = context - overhead - answerRoom - 48
        guard room >= 120 else { print("instructions alone take \(overhead) of \(context) tokens"); return }
        // LAB_ONLY="1200-1700,2400-2800" (seconds): read just those stretches.
        var segments = [0..<lines.count]
        if let only = env["LAB_ONLY"] {
            segments = only.split(separator: ",").compactMap { part in
                let b = part.split(separator: "-").compactMap { Double($0) }
                guard b.count == 2,
                      let first = lines.firstIndex(where: { $0.end >= b[0] }),
                      let last = lines.lastIndex(where: { $0.start <= b[1] }), first <= last else { return nil }
                return first..<(last + 1)
            }
        }
        let parts = windows(tokenCounts: counts, segments: segments, budget: room, overlap: room / 8)
        let limit = env["LAB_PARTS"].flatMap(Int.init) ?? parts.count
        print("\(lines.count) lines · \(counts.reduce(0, +)) transcript tokens · instructions \(overhead) · \(parts.count) parts of ≤\(room) tokens")

        var found: [JudgedPart] = []
        var prompt = 0, reused = 0, written = 0, readSeconds = 0.0, writeSeconds = 0.0, unreadable = 0
        let started = Date()
        for (index, window) in parts.prefix(limit).enumerated() {
            var user = JudgePrompt.user(show: show, title: title, notes: notesCut, lines: lines,
                                        window: window, formatted: formatted)
            if env["LAB_NORANGE"] == "1", let r = user.range(of: #"This is part of it: lines \d+–\d+\. Mark only parts inside these lines\.\n"#, options: .regularExpression) {
                user.removeSubrange(r)
            }
            var system = profile.system, schema = profile.schema
            if env["LAB_VERDICT"] == "1" {
                system += "\nFirst say whether these lines hold any ad, promo, intro or outro at all (\"any\": true or false); most stretches of an episode hold none. Only when it is true, list the parts."
                schema = schema.replacingOccurrences(of: #"{"type": "object", "properties": {"parts""#, with: #"{"type": "object", "properties": {"any": {"type": "boolean"}, "parts""#)
                    .replacingOccurrences(of: #""required": ["parts"]"#, with: #""required": ["any", "parts"]"#)
            }
            let answer = try await session.respond(system: system, user: user, schema: schema,
                                                   maxAnswer: answerRoom, minimumAnswer: answerRoom / 2) { _ in }
            var parsed = JudgePrompt.parse(answer.text)
            if answer.text.replacingOccurrences(of: " ", with: "").contains(#""any":false"#) { parsed = [] }
            if parsed == nil { unreadable += 1 }
            if env["LAB_DEBUG"] != nil { print("   reuse: " + (await session.reuseNote) + " · answer: " + String(answer.text.prefix(200))) }
            let judged = (parsed ?? []).compactMap { JudgePrompt.resolve($0, lines: lines) }
            found += judged
            prompt += answer.promptTokens - answer.reusedTokens
            reused += answer.reusedTokens
            written += answer.generatedTokens
            readSeconds += answer.promptSeconds
            writeSeconds += answer.generateSeconds
            print(String(format: "part %2d/%d lines %4d–%4d · read %4d (kept %4d) in %5.1f s · wrote %3d in %5.1f s · %@",
                         index + 1, parts.count, window.lowerBound, window.upperBound - 1,
                         answer.promptTokens - answer.reusedTokens, answer.reusedTokens, answer.promptSeconds,
                         answer.generatedTokens, answer.generateSeconds,
                         judged.isEmpty ? (parsed == nil ? "UNREADABLE: " + String(answer.text.prefix(80)) : "nothing")
                            : judged.map { "\($0.label.rawValue) \($0.firstLine)–\($0.lastLine) \($0.sponsor)" }.joined(separator: "; ")))
        }
        let total = Date().timeIntervalSince(started)
        let hours = (lines.last?.end ?? 1) / 3600
        print(String(format: "TOTAL %.0f s (%.0f s per audio hour) · read %d new + %d kept tokens at %.0f tok/s · wrote %d tokens at %.1f tok/s · %d unreadable",
                     total, total / max(0.01, hours), prompt, reused, Double(prompt) / max(0.01, readSeconds),
                     written, Double(written) / max(0.01, writeSeconds), unreadable))

        var detect = ""
        for part in found.sorted(by: { $0.firstLine < $1.firstLine }) where part.isCut {
            detect += "[\(part.label.kindName ?? "ad")] \(clock(lines[part.firstLine].start))–\(clock(lines[part.lastLine].end)) \(part.label.rawValue) \(part.sponsor)\n"
        }
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appending(path: "build/coreai-lab")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let tag = env["LAB_TAG"] ?? "\(key)-\(bundle.lastPathComponent)-\(profile.rawValue)"
        try detect.write(to: out.appending(path: tag + ".detect.txt"), atomically: true, encoding: .utf8)
        print("wrote build/coreai-lab/\(tag).detect.txt")
    }
}
