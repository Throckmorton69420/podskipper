import Foundation

enum ModelAnswerFailure {
    static func describe(answer: String, generatedTokens: Int, limit: Int) -> String {
        if generatedTokens >= limit {
            return "The model reached its \(limit)-token answer limit before returning a complete classification."
        }
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "The model returned no classification text (\(generatedTokens) generated tokens)."
        }
        return "The model returned an incomplete or invalid classification. Its response is saved in the test details."
    }
}

/// Pass 33 (his 9 Oct phone): small MLX models writing freely fell into a
/// short loop — SmolLM3 "/&/&/&…", Phi-3 "commercial, commercial, …" — and
/// wrote to the 320-token cap before failing. The end of the text made of
/// one short piece six or more times over is a loop; no answer in the
/// expected format looks like that.
enum AnswerLoop {
    static func isLooping(_ text: String, longestUnit: Int = 16, repeats: Int = 6) -> Bool {
        let tail = Array(text.utf8.suffix(longestUnit * repeats))
        guard tail.count >= 12 else { return false }
        for unit in 1...longestUnit {
            let span = unit * repeats
            guard span <= tail.count else { break }
            let window = tail[(tail.count - span)...]
            let start = window.startIndex
            var periodic = true
            for i in (start + unit)..<window.endIndex where window[i] != window[i - unit] {
                periodic = false
                break
            }
            // Indentation repeats too; only a loop with something in it counts.
            let piece = window[(window.endIndex - unit)...]
            if periodic, piece.contains(where: { $0 != 32 && $0 != 10 && $0 != 13 && $0 != 9 }) { return true }
        }
        return false
    }
}
