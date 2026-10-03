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
