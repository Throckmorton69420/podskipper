import Foundation
import FoundationModels
import CoreAILanguageModels

/// Runtime adapter for an external Apple Core AI Qwen3 language-model bundle.
///
/// The model is deliberately not stored in git. A Core AI LLM is a resource
/// directory containing the model asset, tokenizer, and metadata. The adapter
/// accepts either:
///   1. a bundled `Qwen3-4B-CoreAI` resource, or
///   2. a downloaded bundle at Application Support/CoreAI/Qwen3-4B-CoreAI.
///
/// Apple's Core AI Models registry currently includes an iOS Qwen3-4B preset
/// with a fixed context and an iOS-specific compression recipe. The runtime
/// here stays model-asset agnostic so the app can swap the exported bundle
/// without changing the ad-detection code.
@available(iOS 27.0, *)
actor CoreAIQwen3 {
    static let shared = CoreAIQwen3()

    static let benchmarkID = "coreai.qwen3"
    static let modelResourceName = "Qwen3-4B-CoreAI"
    static let modelDirectoryName = "Qwen3-4B-CoreAI"

    enum Availability: Equatable, Sendable {
        case available(URL)
        case unavailable(String)
    }

    private var model: CoreAILanguageModel?

    /// Locate the complete Core AI resource directory.
    ///
    /// The Application Support location is checked first so a future model
    /// downloader can update the asset without rebuilding the IPA. A bundled
    /// resource is the fallback for development/release builds that package
    /// the model directly.
    nonisolated static func resourceURL() -> URL? {
        let fm = FileManager.default

        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let external = appSupport
                .appendingPathComponent("CoreAI", isDirectory: true)
                .appendingPathComponent(modelDirectoryName, isDirectory: true)
            if isModelBundle(external) {
                return external
            }
        }

        if let bundled = Bundle.main.url(forResource: modelResourceName, withExtension: nil),
           isModelBundle(bundled) {
            return bundled
        }

        return nil
    }

    nonisolated static func availability() -> Availability {
        guard let url = resourceURL() else {
            return .unavailable(
                "Core AI is installed, but the Qwen3-4B model bundle is not present. " +
                "Supply (modelDirectoryName) under Application Support/CoreAI or bundle it with the app."
            )
        }
        return .available(url)
    }

    /// Load the model once and keep its specialized runtime resident for the
    /// duration of a group of windows. Individual sessions remain independent,
    /// so one transcript window cannot leak conversational context into the
    /// next window.
    func load() async throws -> CoreAILanguageModel {
        if let model {
            return model
        }

        guard let url = Self.resourceURL() else {
            throw CoreAIError.modelMissing
        }

        let loaded = try await CoreAILanguageModel(
            resourcesAt: url,
            mode: .lazy
        )
        model = loaded
        return loaded
    }

    /// Release Core AI's model resources after a detection job.
    func unload() {
        model?.unload()
        model = nil
    }

    /// One independent Foundation Models session over the shared Core AI
    /// engine. This preserves model residency without retaining transcript
    /// history between ad-detection windows.
    func respond(to prompt: String) async throws -> String {
        let model = try await load()
        let session = LanguageModelSession(model: model)
        let response = try await session.respond(to: prompt)
        return response.content
    }

    enum CoreAIError: LocalizedError, Sendable {
        case modelMissing

        var errorDescription: String? {
            switch self {
            case .modelMissing:
                return "The Core AI Qwen3-4B model bundle is not installed."
            }
        }
    }

    private nonisolated static func isModelBundle(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        // An exported LLM bundle contains metadata.json and either a main
        // .aimodel/.aimodelc asset referenced by that metadata.
        guard FileManager.default.fileExists(
            atPath: url.appendingPathComponent("metadata.json").path
        ) else {
            return false
        }

        return true
    }
}
