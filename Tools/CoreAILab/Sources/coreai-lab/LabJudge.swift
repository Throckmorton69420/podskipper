import Foundation

/// Pass 45 lab: one of his exported episodes read the way the app's Core AI
/// path reads it (CoreAIAdJudge): the stretches it is told to read (LAB_ONLY,
/// seconds — the app's focus ranges, computed by phone_judge.py), widened by
/// 15 lines, planned into parts in the model's own tokens at its context
/// (LAB_CONTEXT, default what the engine holds), the shared header kept
/// between parts, each answer held to the schema at the profile's room.
/// Writes the cuts the parts name (before the app's cut check) to LAB_OUT as
/// [[start, end, kind, label, sponsor]] — the format MLXLab's judge writes,
/// so phone_judge.py and model_lab_score.py read both.
///
///   coreai-lab <bundle dir> <results.json> <episode index> judge
///
/// LAB_PROFILE picks a shipped profile (compact, compactListener, …);
/// LAB_SYSTEM=<file> replaces its instructions with a draft (the schema and
/// answer room stay the profile's), LAB_REMINDER=<file> adds a draft
/// reminder after the stretch.
enum LabJudge {
    static let contextLines = 15

    static func run(bundle: URL, results: URL, index: Int, hint: String?, env: [String: String]) async throws {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: results)) as? [String: Any]
        guard let episode = (root?["episodes"] as? [[String: Any]])?[index] else { print("no episode \(index)"); return }
        let lines = try JSONDecoder().decode([TimedLine].self,
                                             from: JSONSerialization.data(withJSONObject: episode["transcript"] ?? []))
        let show = episode["show"] as? String ?? "", title = episode["title"] as? String ?? ""
        let family = env["LAB_FAMILY"] ?? bundle.lastPathComponent

        let session = try await CoreAIClassifierSession(bundleAt: bundle, engineHint: hint, tablesURL: nil, family: family)
        let context = env["LAB_CONTEXT"].flatMap(Int.init) ?? session.contextLimit
        let plan = ModelPromptPlan.coreAI(id: family, name: "", template: session.chatTemplate, context: context)
        // phone_judge.py's variant: `p-<profile>` a shipped profile; any other
        // name a draft in Tools/CoreAILab/variants (<name>.txt rules,
        // optional <name>.reminder.txt), on the plan's own profile.
        var env = env
        if let variant = env["LAB_VARIANT"], !variant.isEmpty, variant != "app" {
            if variant.hasPrefix("p-") {
                env["LAB_PROFILE"] = String(variant.dropFirst(2))
            } else {
                let drafts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent().appending(path: "variants")
                env["LAB_SYSTEM"] = drafts.appending(path: variant + ".txt").path
                let reminderFile = drafts.appending(path: variant + ".reminder.txt").path
                if FileManager.default.fileExists(atPath: reminderFile) { env["LAB_REMINDER"] = reminderFile }
            }
        }
        let profile = env["LAB_PROFILE"].flatMap(JudgePrompt.Profile.init(rawValue:)) ?? plan.profile
        let system = try env["LAB_SYSTEM"].map { try String(contentsOfFile: $0, encoding: .utf8) + JudgePrompt.answerFormat }
            ?? profile.system
        let reminder = try env["LAB_REMINDER"].map { try String(contentsOfFile: $0, encoding: .utf8) } ?? profile.reminder
        let answerRoom = env["LAB_CAP"].flatMap(Int.init) ?? profile.answerTokens
        print("model \(family) · holds \(session.contextLimit), planned at \(context) · \(session.engineName) · \(profile.rawValue)\(env["LAB_SYSTEM"] == nil ? "" : " + draft rules")")

        var ranges: [Range<Int>] = []
        for part in (env["LAB_ONLY"] ?? "").split(separator: ",") {
            let b = part.split(separator: "-").compactMap { Double($0) }
            guard b.count == 2, let first = lines.firstIndex(where: { $0.end >= b[0] }),
                  let last = lines.lastIndex(where: { $0.start <= b[1] }), first <= last else { continue }
            ranges.append(first..<(last + 1))
        }
        if ranges.isEmpty { ranges = [0..<lines.count] }
        var segments: [Range<Int>] = []
        for r in ranges.map({ max(0, $0.lowerBound - contextLines)..<min(lines.count, $0.upperBound + contextLines) })
            .sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = segments.last, r.lowerBound <= last.upperBound {
                segments[segments.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                segments.append(r)
            }
        }

        let header = JudgePrompt.userHeader(show: show, title: title, notes: "")
        let overhead = try await session.promptTokenCount(system: system, user: header
            + JudgePrompt.stretch(lines: lines, window: 0..<1, spans: []) + (reminder.map { "\n\n" + $0 } ?? ""))
        var counts: [Int] = []
        for i in lines.indices { counts.append(await session.tokenCount(JudgePrompt.line(i, lines[i], spans: []) + "\n")) }
        let room = env["LAB_NOCEILING"] != nil ? min(context - overhead - answerRoom - 24, plan.maxWindowTokens)
            : plan.windowRoom(context: context, overhead: overhead, answer: answerRoom)
        guard room >= 120 else { print("instructions alone take \(overhead) of \(context) tokens"); return }
        let parts = windows(tokenCounts: counts, segments: segments, budget: room, overlap: room / 8)

        var found: [JudgedPart] = []
        var written = 0, unreadable = 0
        let started = Date()
        // Pass 54: LAB_ORDER=longest reads as the phone does since Pass 53
        // (the longest part first); LAB_MEMLOG=<file> samples the process's
        // footprint and Metal allocation every 10 ms with the part and step.
        var order = Array(parts.indices)
        if env["LAB_ORDER"] == "longest" {
            var promptTokens: [Int] = []
            for window in parts {
                let user = JudgePrompt.userLocal(show: show, title: title, notes: "", lines: lines, window: window,
                                                 spans: [], reminder: reminder)
                promptTokens.append(try await session.promptTokenCount(system: system, user: user))
            }
            // Pass 53's order (the longest part first), kept to replay its reads.
            let longest = promptTokens.indices.max { promptTokens[$0] < promptTokens[$1] } ?? 0
            order = [longest] + parts.indices.filter { $0 != longest }
            print("order \(order.map { $0 + 1 }) · prompt tokens \(promptTokens)")
        }
        let sampler = env["LAB_MEMLOG"].map { MemorySampler(path: $0) }
        sampler?.start()
        defer { sampler?.stop() }
        for i in order {
            let window = parts[i]
            let user = JudgePrompt.userLocal(show: show, title: title, notes: "", lines: lines, window: window,
                                             spans: [], reminder: reminder)
            sampler?.mark("p\(i + 1) start")
            let answer = try await session.respond(system: system, user: user, schema: profile.schema, sharedUser: header,
                                                   maxAnswer: answerRoom, minimumAnswer: answerRoom / 2) { message in
                sampler?.mark("p\(i + 1) \(message)")
            }
            sampler?.mark("p\(i + 1) done \(answer.generatedTokens) written, kept \(answer.reusedTokens) of \(answer.promptTokens)")
            print("part \(i + 1) peak footprint \(answer.peakFootprintMB) MB · fresh engines \(await session.freshEngines)")
            written += answer.generatedTokens
            let parsed = JudgePrompt.parse(answer.text).map {
                JudgePrompt.shifted($0, window: window, lines: lines, maxShare: plan.maxCutShare)
            }
            if parsed == nil { unreadable += 1 }
            found += (parsed ?? []).compactMap { JudgePrompt.resolve($0, lines: lines) }
            print("part \(i + 1)/\(parts.count) lines \(window.lowerBound)–\(window.upperBound - 1) · " + answer.text.prefix(240))
        }
        var cuts: [[String]] = []
        for p in found where p.isCut {
            guard let kind = p.label.kindName, p.firstLine >= 0, p.lastLine < lines.count, p.firstLine <= p.lastLine else { continue }
            cuts.append([String(lines[p.firstLine].start), String(lines[p.lastLine].end), kind, p.label.rawValue, p.sponsor])
        }
        print(String(format: "%d parts · wrote %d tokens · %.0f s · %d unreadable · %d cuts", parts.count, written,
                     Date().timeIntervalSince(started), unreadable, cuts.count))
        if let out = env["LAB_OUT"] {
            try JSONSerialization.data(withJSONObject: cuts).write(to: URL(fileURLWithPath: out))
        }
    }
}
