import Foundation
#if canImport(CoreAI)
import CoreAI
#endif

/// Apple Core AI Qwen3 runtime surface.
///
/// The actual .aimodel resource is intentionally external to this source
/// tree. The app can later bundle or download the iOS Qwen3 export produced by
/// Apple's coreai-models toolchain without changing the selection/diagnostics
/// contract here.
enum CoreAIQwen3 {
    static let benchmarkID = "coreai.qwen3"
    static let modelResourceName = "Qwen3"

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    static var availability: Availability {
        #if canImport(CoreAI)
        guard Bundle.main.url(forResource: modelResourceName, withExtension: "aimodel") != nil else {
            return .unavailable("Apple Core AI is available, but the Qwen3 model resource is not bundled")
        }
        return .available
        #else
        return .unavailable("Core AI is unavailable in this SDK")
        #endif
    }

    #if canImport(CoreAI)
    static func loadModel() async throws -> AIModel {
        guard let url = Bundle.main.url(forResource: modelResourceName, withExtension: "aimodel") else {
            throw NSError(
                domain: "PodSkipper.CoreAI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The Qwen3 Core AI model resource is missing"]
            )
        }
        return try await AIModel(contentsOf: url)
    }
    #endif
}
