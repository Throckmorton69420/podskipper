import Foundation
import SoundAnalysis
import AVFoundation

/// Pass 53: Apple's built-in sound classifier over a whole episode —
/// music, singing and speech confidence per 3-s window (1.5-s hop) — to
/// measure whether it finds the themes and closing songs the transcript
/// reader can't see.
///     lab-music in.mp3 out.json
final class Collect: NSObject, SNResultsObserving {
    var rows: [[Double]] = []
    let labels = ["music", "singing", "speech"]
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let start = r.timeRange.start.seconds, end = start + r.timeRange.duration.seconds
        rows.append([start, end] + labels.map { r.classification(forIdentifier: $0)?.confidence ?? 0 })
    }
}

@main struct LabMusic {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: lab-music in.mp3 out.json"); return }
        let started = Date()
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 3, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        let analyzer = try SNAudioFileAnalyzer(url: URL(fileURLWithPath: args[1]))
        let collect = Collect()
        try analyzer.add(request, withObserver: collect)
        analyzer.analyze()
        try JSONSerialization.data(withJSONObject: collect.rows).write(to: URL(fileURLWithPath: args[2]))
        print("windows:", collect.rows.count, "seconds:", Int(Date().timeIntervalSince(started)))
    }
}
