import Foundation
import CoreAIKit
import CoreAIKitCore

/// Podskipper's small adapter around CoreAIKit's in-app catalog and Apple's
/// Core AI runtime. The selected catalog model is downloaded on demand and
/// cached by CoreAIKit; inference stays on device.
@available(iOS 27.0, *)
actor CoreAIQwen3 {
    static let shared = CoreAIQwen3()
    static let benchmarkID = "coreai.qwen3"

    struct Response: Sendable {
        let text: String
        let inputTokens: Int
        let outputTokens: Int
        let reasoningTokens: Int
    }

    enum CoreAIError: LocalizedError, Sendable {
        case modelMissing
        case modelUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "The selected Core AI model is not downloaded."
            case .modelUnavailable(let id):
                return "Core AI model \(id) is not available for iOS."
            }
        }
    }

    func respond(to prompt: String) async throws -> Response {
        let id = await MainActor.run { CoreAIModelLibrary.shared.selectedID }
        guard let entry = await MainActor.run { () -> CatalogEntry? in
            CoreAIModelLibrary.shared.entries.first { $0.id == id }
        } else {
            throw CoreAIError.modelMissing
        }
        guard entry.modelID != nil else {
            throw CoreAIError.modelUnavailable(id)
        }
        guard await MainActor.run({ CoreAIModelLibrary.shared.isDownloaded(entry) }) else {
            throw CoreAIError.modelMissing
        }

        var configuration = ChatSession.Configuration()
        configuration.temperature = nil
        configuration.maxResponseTokens = 256
        configuration.systemPrompt = JudgePrompt.system

        let chat = try await ChatSession(catalog: id, configuration: configuration)
        let text = try await chat.respond(to: prompt)
        let stats = await chat.stats
        return Response(
            text: text,
            inputTokens: stats.promptTokens,
            outputTokens: stats.generatedTokens,
            reasoningTokens: 0
        )
    }

    func unload() {
        // ChatSession owns its runtime and releases it when the actor drops it.
    }
}
