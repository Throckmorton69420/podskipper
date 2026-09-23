import Foundation

/// Lab harness for Services/AdPrints.swift. Run in build/lab.
///
///     lab-prints land <key>...          fingerprint and cache <key>.lm.bin
///     lab-prints pair <key> <other>     stretches of <key> also in <other>
///     lab-prints self <key>             stretches of <key> played twice in it
@main
struct LabPrints {
    static func landmarks(_ key: String) throws -> AdPrints.Landmarks {
        let cache = URL(fileURLWithPath: key + ".lm.bin")
        if let data = try? Data(contentsOf: cache), let l = AdPrints.Landmarks(data: data) { return l }
        let started = Date(), cpu = clock()
        let l = try AdPrints.landmarks(fileURL: URL(fileURLWithPath: key + ".mp3"))
        let wall = Date().timeIntervalSince(started), used = Double(clock() - cpu) / Double(CLOCKS_PER_SEC)
        try l.data().write(to: cache)
        print(String(format: "%@: %.2f h, %d hashes (%.0f/s), %.1f s wall, %.1f s cpu = %.1f s per hour",
                     key, l.seconds / 3600, l.count, Double(l.count) / max(1, l.seconds), wall, used,
                     wall / max(0.01, l.seconds / 3600)))
        return l
    }

    static func clockText(_ s: Double) -> String {
        String(format: "%d:%02d:%05.2f", Int(s) / 3600, Int(s) % 3600 / 60, s.truncatingRemainder(dividingBy: 60))
    }

    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { return }
        switch command {
        case "land":
            for key in args.dropFirst() { _ = try landmarks(key) }
        case "pair", "self":
            let key = args[1]
            let probe = try landmarks(key)
            let other = command == "self" ? probe : try landmarks(args[2])
            let started = Date()
            let index = AdPrints.Index(other)
            let found = AdPrints.repeats(of: probe, in: index, skipNear: command == "self" ? 20 : nil)
            print(String(format: "%@ %@: %d repeats in %.2f s", command, key, found.count, Date().timeIntervalSince(started)))
            var json: [[String: Any]] = []
            for r in found {
                print("  \(clockText(r.start))–\(clockText(r.end))  \(String(format: "%5.1f", r.seconds)) s  votes \(r.votes)  other at \(clockText(r.start + r.offset))")
                json.append(["start": r.start, "end": r.end, "offset": r.offset, "votes": r.votes])
            }
            let out = URL(fileURLWithPath: "\(key).\(command == "self" ? "self" : "pair-" + args[2]).json")
            try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted).write(to: out)
        case "produced":
            // produced <key> <other episode of the show>... → <key>.produced.json,
            // exactly what the app hands the detector.
            let key = args[1]
            let probe = try landmarks(key)
            let previous = try args.dropFirst(2).map { try landmarks($0) }
            let started = Date()
            let found = AdPrints.produced(in: probe, previous: previous)
            print(String(format: "produced %@: %d stretches in %.2f s", key, found.count, Date().timeIntervalSince(started)))
            for p in found {
                print("  \(clockText(p.start))–\(clockText(p.end))  \(String(format: "%5.1f", p.end - p.start)) s  \(p.acrossEpisodes ? "across episodes" : "within")")
            }
            let json = found.map { ["start": $0.start, "end": $0.end, "acrossEpisodes": $0.acrossEpisodes] as [String: Any] }
            try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                .write(to: URL(fileURLWithPath: key + ".produced.json"))
        default:
            print("unknown command")
        }
    }
}
