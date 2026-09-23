import Foundation

// The app's ad-free comparison (Services/AdFreeCopy.swift), run on a lab
// episode, so the Swift port can be checked against dai.py's full diff.
//
//   lab.sh adfree <key> "<show title>"

@main
struct LabAdFree {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: adfree <key> <show title>"); return }
        let key = args[1], show = args[2]
        func read(_ ext: String) -> String {
            (try? String(contentsOfFile: "\(key).\(ext)", encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let started = Date()
        let outcome = await AdFreeCopy.compare(fileURL: URL(fileURLWithPath: "\(key).mp3"),
                                               enclosure: read("url"), feedURL: read("feed"),
                                               showTitle: show, episodeTitle: read("title"))
        print("\(key): source '\(outcome.source)', \(outcome.requests) requests, \(outcome.bytes) bytes, "
              + String(format: "%.1f s", Date().timeIntervalSince(started)) + (outcome.note.isEmpty ? "" : " — \(outcome.note)"))
        for s in outcome.inserted {
            print(String(format: "   %.2f–%.2f  (%.2f s)", s.start, s.end, s.end - s.start))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(outcome) { try? data.write(to: URL(fileURLWithPath: "\(key).adfree.json")) }
    }
}
