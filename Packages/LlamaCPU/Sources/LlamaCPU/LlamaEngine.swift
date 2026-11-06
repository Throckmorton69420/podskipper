import Foundation
import llama

/// Pass 58: a GGUF model read on the CPU only.
///
/// Why the CPU: iOS refuses GPU work from an app that isn't on screen unless
/// it is signed with Background GPU Access (PodSkipper's sideloaded builds
/// aren't), and the Neural Engine copies of the models carry GPU delegates
/// (catalog X38-05). The CPU is always allowed — the Reader runs there — but
/// iOS ends a background app that keeps the CPU busy for a minute, so the
/// caller paces the work between batches (`pace`), and runs flat out only in
/// the overnight task, where iOS lifts that limit while the phone charges.
///
/// The weights are memory-mapped from the file, read-only: the pages are
/// the file's, so iOS can drop and re-read them under memory pressure
/// instead of counting them as the app's own memory.
public final class LlamaEngine: @unchecked Sendable {
    public struct Options: Sendable {
        public var threads: Int
        public var contextTokens: Int
        public var batchTokens: Int
        public init(threads: Int, contextTokens: Int = 8_192, batchTokens: Int = 256) {
            self.threads = threads; self.contextTokens = contextTokens; self.batchTokens = batchTokens
        }
    }

    public enum Phase: Sendable { case reading, writing }

    public struct Stats: Sendable {
        public var promptTokens = 0
        public var reusedPromptTokens = 0
        public var promptSeconds = 0.0
        public var answerTokens = 0
        public var answerSeconds = 0.0
        public var pausedSeconds = 0.0
        public var ranOutOfRoom = false
    }

    public enum EngineError: LocalizedError {
        case loadFailed(String), contextFailed, tooLong(Int, Int), decodeFailed(Int32)
        public var errorDescription: String? {
            switch self {
            case .loadFailed(let path): return "The CPU copy of the model couldn't be opened (\((path as NSString).lastPathComponent))."
            case .contextFailed: return "The CPU copy of the model couldn't make room to read."
            case .tooLong(let n, let room): return "A part was \(n) tokens, more than the \(room) the CPU reader holds."
            case .decodeFailed(let code): return "The CPU reader stopped (code \(code))."
            }
        }
    }

    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    public let options: Options
    /// What the context holds now, so a part that starts with the same rules
    /// as the last one reads only what differs (when the model allows it).
    private var held: [llama_token] = []

    private static let backendOnce: Void = { llama_backend_init() }()

    public init(path: String, options: Options) throws {
        _ = Self.backendOnce
        self.options = options
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 0
        mparams.load_mode = LLAMA_LOAD_MODE_MMAP
        // CPU only: the CPU and Apple's Accelerate (the CPU's matrix unit),
        // never the GPU, which iOS refuses to an app that isn't on screen.
        var devices: [ggml_backend_dev_t?] = (0..<ggml_backend_dev_count()).compactMap { i -> ggml_backend_dev_t? in
            guard let dev = ggml_backend_dev_get(i) else { return nil }
            let type = ggml_backend_dev_type(dev)
            return type == GGML_BACKEND_DEVICE_TYPE_CPU || type == GGML_BACKEND_DEVICE_TYPE_ACCEL ? dev : nil
        } + [nil]
        guard let loaded = devices.withUnsafeMutableBufferPointer({ buffer -> OpaquePointer? in
            mparams.devices = buffer.baseAddress
            return llama_model_load_from_file(path, mparams)
        }) else { throw EngineError.loadFailed(path) }
        model = loaded
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(options.contextTokens)
        cparams.n_batch = UInt32(options.batchTokens)
        cparams.n_ubatch = UInt32(options.batchTokens)
        cparams.n_threads = Int32(options.threads)
        cparams.n_threads_batch = Int32(options.threads)
        cparams.offload_kqv = false
        cparams.op_offload = false
        cparams.no_perf = true
        guard let ctx = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw EngineError.contextFailed
        }
        context = ctx
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    public func tokenize(_ text: String, special: Bool = true) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        var n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &tokens, Int32(tokens.count), false, special)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, Int32(utf8.count - 1), &tokens, Int32(tokens.count), false, special)
        }
        return Array(tokens.prefix(Int(max(0, n))))
    }

    public func countTokens(_ text: String) -> Int { tokenize(text, special: false).count }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }

    /// Reads `prompt` and writes at most `maxTokens` greedily, stopping at the
    /// model's end of turn. `pace` runs before every batch read and every
    /// token written; it may sleep (to keep the CPU under iOS's limit) or
    /// throw (to stop the read).
    public func answer(prompt: [llama_token], maxTokens: Int,
                       pace: (Phase) throws -> Void) throws -> (text: String, stats: Stats) {
        var stats = Stats()
        let room = options.contextTokens - maxTokens - 8
        guard prompt.count <= room else { throw EngineError.tooLong(prompt.count, room) }
        let memory = llama_get_memory(context)

        // Keep what the context already holds of this prompt, if the model's
        // state can be cut back there (models with recurrent layers can't).
        var common = 0
        while common < min(held.count, prompt.count - 1), held[common] == prompt[common] { common += 1 }
        if common > 0, !llama_memory_seq_rm(memory, 0, llama_pos(common), -1) { common = 0 }
        if common == 0 { llama_memory_clear(memory, true) }
        held = Array(prompt.prefix(common))
        stats.reusedPromptTokens = common

        var position = common
        let readStart = Date()
        var paused = 0.0
        while position < prompt.count {
            let pauseStart = Date()
            try pace(.reading)
            paused += Date().timeIntervalSince(pauseStart)
            let end = min(prompt.count, position + options.batchTokens)
            var chunk = Array(prompt[position..<end])
            let code = chunk.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
            }
            guard code == 0 else { held = []; throw EngineError.decodeFailed(code) }
            held += chunk
            position = end
        }
        stats.promptTokens = prompt.count - common
        stats.promptSeconds = Date().timeIntervalSince(readStart) - paused
        stats.pausedSeconds = paused

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        defer { llama_sampler_free(sampler) }
        var bytes: [UInt8] = []
        let writeStart = Date()
        paused = 0
        var written = 0
        while written < maxTokens {
            let pauseStart = Date()
            try pace(.writing)
            paused += Date().timeIntervalSince(pauseStart)
            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            written += 1
            var one = [token]
            let code = one.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress, 1))
            }
            guard code == 0 else { held = []; throw EngineError.decodeFailed(code) }
            held.append(token)
        }
        stats.ranOutOfRoom = written >= maxTokens
        stats.answerTokens = written
        stats.answerSeconds = Date().timeIntervalSince(writeStart) - paused
        stats.pausedSeconds += paused
        return (String(decoding: bytes, as: UTF8.self), stats)
    }
}
