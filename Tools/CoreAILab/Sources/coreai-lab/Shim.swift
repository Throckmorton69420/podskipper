import Foundation

/// The app types JudgePrompt.swift needs, without the app.
struct TimedLine: Codable, Hashable {
    var text: String
    var start: Double
    var end: Double
}

enum SegmentKind: String, Codable, CaseIterable, Sendable {
    case ad, selfPromo, crossPromo, intro, outro
}

/// LocalJudge.windows, copied: parts planned in the model's own tokens.
func windows(tokenCounts: [Int], segments: [Range<Int>], budget: Int, overlap: Int) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for segment in segments {
        var start = segment.lowerBound
        while start < segment.upperBound {
            var end = start
            var sum = 0
            while end < segment.upperBound, end == start || sum + tokenCounts[end] <= budget {
                sum += tokenCounts[end]
                end += 1
            }
            result.append(start..<end)
            guard end < segment.upperBound else { break }
            var back = end
            var repeated = 0
            while back > start + 1, repeated < overlap {
                back -= 1
                repeated += tokenCounts[back]
            }
            start = Swift.max(back, start + 1)
        }
    }
    return result
}
