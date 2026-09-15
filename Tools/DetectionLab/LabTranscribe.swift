import Foundation

struct Line: Codable { let text: String; let start: Double; let end: Double }

@main struct LabTranscribe {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: transcribe in.mp3 out.json"); return }
        let started = Date()
        do {
            let segs = try await TranscriptionService().transcribe(fileURL: URL(fileURLWithPath: args[1])) { p in
                FileHandle.standardError.write("\r\(Int(p * 100))%".data(using: .utf8)!)
            }
            let lines = segs.map { Line(text: $0.text, start: $0.start, end: $0.end) }
            try JSONEncoder().encode(lines).write(to: URL(fileURLWithPath: args[2]))
            print("\nsegments:", lines.count, "seconds:", Int(Date().timeIntervalSince(started)))
        } catch {
            print("error:", error)
        }
    }
}
