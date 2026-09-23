import Foundation
import NaturalLanguage

/// Lab only: every transcript line of each fixture as Apple's on-device
/// sentence embedding, written to <key>.emb.bin (Float32, 512 per line) for
/// the Python experiments in adlike.py.
///
///     lab-embed <key>...     (run in build/lab)
@main
struct LabEmbed {
    struct Line: Decodable { var start: Double; var end: Double; var text: String }

    static func main() throws {
        guard let model = NLEmbedding.sentenceEmbedding(for: .english) else {
            print("no sentence embedding on this Mac"); exit(1)
        }
        for key in CommandLine.arguments.dropFirst() {
            let started = Date()
            let lines = try JSONDecoder().decode([Line].self, from: Data(contentsOf: URL(fileURLWithPath: key + ".json")))
            var out = Data()
            for line in lines {
                var v = model.vector(for: line.text.lowercased()) ?? [Double](repeating: 0, count: model.dimension)
                if v.count != model.dimension { v = [Double](repeating: 0, count: model.dimension) }
                var f = v.map { Float($0) }
                out.append(Data(bytes: &f, count: f.count * 4))
            }
            try out.write(to: URL(fileURLWithPath: key + ".emb.bin"))
            print(key, lines.count, "lines", model.dimension, "dims",
                  String(format: "%.1f s", Date().timeIntervalSince(started)))
        }
    }
}
