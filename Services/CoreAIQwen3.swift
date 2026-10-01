import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(CoreAI)
import CoreAI
#endif

/// Optional Apple Core AI-backed Qwen3 runtime.
///
/// The production detector remains compatible with the existing Foundation
/// Models path. This wrapper provides a single availability/runtime surface for
/// a Core AI Qwen3 4B resource once an iOS 27 .aimodel bundle is supplied.
///
/// The model asset is intentionally not checked into git: Core AI models are
/// build/runtime assets and may be bundled or downloaded separately.
enum CoreAIQwen3 {
    static let modelResourceKey = "CoreAIQwen3ModelResource"

    enum Availability: Equatable {
        case available
        case unavailable(String)
    }

    static var availability: Availability {
        #if canImport(CoreAI)
        guard let url = Bundle.main.url(forResource: "Qwen3-4B", withExtension: "aimodel") else {
            return .unavailable("Qwen3 4B Core AI model asset is not bundled")
        }
        return .available
        #else
        return .unavailable("Core AI is unavailable in this SDK")
        #endif
    }

    #if canImport(CoreAI)
    static func loadModel() async throws -> AIModel {
        guard let url = Bundle.main.url(forResource: "Qwen3-4B", withExtension: "aimodel") else {
            throw NSError(domain: "PodSkipper.CoreAI", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Qwen3 4B Core AI model asset is missing"])
        }
        return try await AIModel(contentsOf: url)
    }
    #endif

    /// A stable identifier used by diagnostics/benchmarks before the model
    /// asset exists. This keeps Core AI selection separate from MLX model IDs.
    static let benchmarkID = "coreai.qwen3-4b"
}
