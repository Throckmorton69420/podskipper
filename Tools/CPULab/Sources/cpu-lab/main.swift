import Foundation
import LlamaCPU

/// Pass 58: a whole episode (or LAB_ONLY's stretches, widened 15 lines as the
/// app does) read on the CPU the way `CPUJudge` reads it: parts of 3,000
/// transcript tokens, Qwen's chat format with thinking off, greedy, the
/// listener profile's rules and answer cap; paced at LAB_PACE of one core
/// (as off screen), or flat out when unset (as overnight on a charger).
struct Episode: Decodable { var show: String; var title: String; var transcript: [TimedLine] }
struct Results: Decodable { var episodes: [Episode] }

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
let env = ProcessInfo.processInfo.environment
let results = try JSONDecoder().decode(Results.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let episode = results.episodes[Int(args[2])!]
let lines = episode.transcript
let gguf = env["LAB_GGUF"] ?? "/Volumes/Samsung PSSD T9 Media/PodSkipper/models/gguf/Qwen3.5-4B-Q4_0.gguf"
let threads = env["LAB_THREADS"].flatMap(Int.init) ?? 2
let share = env["LAB_PACE"].flatMap(Double.init)
let budget = env["LAB_BUDGET"].flatMap(Int.init) ?? 3_000
let profile = JudgePrompt.Profile(rawValue: env["LAB_PROFILE"] ?? "listener") ?? .listener

if let n = env["LAB_BENCH"].flatMap(Int.init) {
    // Pass 58: prefill speed alone, to compare with llama-bench at the same settings.
    let engine = try LlamaEngine(path: gguf, options: .init(threads: threads, contextTokens: 4_096,
                                                            batchTokens: env["LAB_BATCH"].flatMap(Int.init) ?? 128))
    let text = String(repeating: "so anyway we were talking about the show and then the sponsor came on and it was a whole thing. ", count: 200)
    let tokens = Array(engine.tokenize(text).prefix(n))
    let start = Date()
    let (_, s) = try engine.answer(prompt: tokens, maxTokens: 16) { _ in }
    print(String(format: "bench: %d threads, prefill %d tok at %.1f tok/s, %d answer tok at %.1f tok/s (%.0f s)", threads, s.promptTokens,
                 Double(s.promptTokens) / max(0.001, s.promptSeconds), s.answerTokens, Double(s.answerTokens) / max(0.001, s.answerSeconds),
                 Date().timeIntervalSince(start)))
    exit(0)
}
let loadStart = Date()
let engine = try LlamaEngine(path: gguf, options: .init(threads: threads, contextTokens: 8_192, batchTokens: 128))
print("\(episode.show) · \(episode.title) · \(lines.count) lines · loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s · \(threads) threads · pace \(share.map { String($0) } ?? "full")")

var ranges: [Range<Int>] = []
if let only = env["LAB_ONLY"], !only.isEmpty {
    for part in only.split(separator: ",") {
        let b = part.split(separator: "-").compactMap { Double($0) }
        guard b.count == 2, let first = lines.firstIndex(where: { $0.end >= b[0] }),
              let last = lines.lastIndex(where: { $0.start <= b[1] }), first <= last else { continue }
        ranges.append(max(0, first - 15)..<min(lines.count, last + 16))
    }
} else { ranges = [0..<lines.count] }
ranges.sort { $0.lowerBound < $1.lowerBound }
var segments: [Range<Int>] = []
for r in ranges {
    if let last = segments.last, r.lowerBound <= last.upperBound { segments[segments.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound) }
    else { segments.append(r) }
}
let formatted = lines.indices.map { JudgePrompt.line($0, lines[$0], spans: []) }
let counts = formatted.map { engine.countTokens($0 + "\n") }
let parts = windows(tokenCounts: counts, segments: segments, budget: budget, overlap: budget / 10)

func cpuNow() -> Double { var t = timespec(); clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t); return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }
var lastWall = Date(), lastCPU = cpuNow(), rested = 0.0
let pace: (LlamaEngine.Phase) throws -> Void = { _ in
    if let share {
        let rest = min(90, max(0, (cpuNow() - lastCPU) / share - Date().timeIntervalSince(lastWall)))
        if rest > 0 { Thread.sleep(forTimeInterval: rest); rested += rest }
    }
    lastWall = Date(); lastCPU = cpuNow()
}

var cuts: [[String]] = []
var detail: [[String: Any]] = []
let started = Date(), cpuStart = cpuNow()
var readTokens = 0, readSeconds = 0.0, wrote = 0, writeSeconds = 0.0, unreadable = 0
for (i, w) in parts.enumerated() {
    let user = JudgePrompt.userLocal(show: episode.show, title: episode.title, notes: "", lines: lines, window: w, spans: [], reminder: profile.reminder)
    let prompt = engine.tokenize("<|im_start|>system\n\(profile.system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n", special: true)
    let (text, s) = try engine.answer(prompt: prompt, maxTokens: profile.answerTokens, pace: pace)
    readTokens += s.promptTokens; readSeconds += s.promptSeconds; wrote += s.answerTokens; writeSeconds += s.answerSeconds
    let parsed = JudgePrompt.parseComplete(text) ?? (s.ranOutOfRoom ? nil : JudgePrompt.parse(text))
    if parsed == nil { unreadable += 1 }
    for p in JudgePrompt.shifted(parsed ?? [], window: w) {
        guard p.firstLine >= 0, p.lastLine < lines.count, p.firstLine <= p.lastLine else { continue }
        let kind: String?
        switch p.label {
        case .paidAd, .hostReadAd: kind = "ad"
        case .networkPromo: kind = "crossPromo"
        case .selfPromo, .guestPlug: kind = "selfPromo"
        case .intro: kind = "intro"
        case .outro, .credits: kind = "outro"
        default: kind = nil
        }
        if let kind { cuts.append([String(lines[p.firstLine].start), String(lines[p.lastLine].end), kind, p.label.rawValue, p.sponsor]) }
    }
    detail.append(["first": w.lowerBound, "last": w.upperBound - 1, "text": text, "outOfRoom": s.ranOutOfRoom])
    print(String(format: "part %d/%d lines %d–%d · read %d (%d kept) at %.1f tok/s · wrote %d at %.1f tok/s · rested %.0f s%@ · %@",
                 i + 1, parts.count, w.lowerBound, w.upperBound - 1, s.promptTokens, s.reusedPromptTokens,
                 s.promptSeconds > 0 ? Double(s.promptTokens) / s.promptSeconds : 0, s.answerTokens,
                 s.answerSeconds > 0 ? Double(s.answerTokens) / s.answerSeconds : 0, s.pausedSeconds,
                 parsed == nil ? " · UNREADABLE" : "", String(text.replacingOccurrences(of: "\n", with: " ").prefix(200))))
}
let wall = Date().timeIntervalSince(started), cpu = cpuNow() - cpuStart
print(String(format: "%d parts · %d unreadable · read %d tok at %.1f tok/s · wrote %d at %.1f tok/s · %.0f s wall · CPU %.0f s (%.0f%% of one core) · rested %.0f s · %d cuts",
             parts.count, unreadable, readTokens, readSeconds > 0 ? Double(readTokens) / readSeconds : 0, wrote,
             writeSeconds > 0 ? Double(wrote) / writeSeconds : 0, wall, cpu, 100 * cpu / max(1, wall), rested, cuts.count))
if let out = env["LAB_OUT"] {
    try JSONSerialization.data(withJSONObject: ["cuts": cuts, "parts": detail, "wall": wall, "cpu": cpu]).write(to: URL(fileURLWithPath: out))
}
