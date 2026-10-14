import XCTest
@testable import PodSkipper

/// Pass 38: Core AI engine routing, Gemma 4, per-family prompt plans.
final class Pass38Tests: XCTestCase {

    // MARK: Engine route

    func testHybridAndDecodeOnlyBundlesNeverUseTheRuntimeGrammarDecoder() {
        // The pipelined engine's grammar decoder binds no static inputs or
        // recurrent states and feeds several tokens per step.
        XCTAssertEqual(CoreAIEngineRoute.choose(engineHint: "pipelined",
                                                path: "gpu-pipelined/qwen3_5_0_8b_decode_int8hu_block32_sym", hasStaticInputs: false), .sequential)
        XCTAssertEqual(CoreAIEngineRoute.choose(engineHint: "pipelined", path: "int8", hasStaticInputs: false), .sequential)
        XCTAssertEqual(CoreAIEngineRoute.choose(engineHint: "pipelined",
                                                path: "gpu-pipelined-b2/gemma4_e2b_qat_decode_int4lin_tbl", hasStaticInputs: true), .pipelinedPrimed)
        XCTAssertEqual(CoreAIEngineRoute.choose(engineHint: "static-shape", path: "ios", hasStaticInputs: false), .staticShape)
        // Qwen3's GPU builds stay exactly as his phone runs them (82 % Basic).
        XCTAssertEqual(CoreAIEngineRoute.choose(engineHint: nil, path: "macos", hasStaticInputs: false), .runtimeGrammar)
        XCTAssertEqual(CoreAIEngineRoute.sequential.fallback, .pipelinedPrimed)
        XCTAssertNil(CoreAIEngineRoute.pipelinedPrimed.fallback)
        XCTAssertEqual(CoreAIEngineRoute.sequential.variant, "coreai-sequential")
        XCTAssertEqual(CoreAIEngineRoute.pipelinedPrimed.variant, "coreai-pipelined")
        XCTAssertNil(CoreAIEngineRoute.runtimeGrammar.variant)
    }

    func testSequentialEngineHoldsTwiceThePipelinedCapOnIPhone() {
        XCTAssertEqual(CoreAIBundleLimits.usableContext(bundleContext: 32_768, route: .sequential), 2_047)
        XCTAssertEqual(CoreAIBundleLimits.usableContext(bundleContext: 4_096, route: .pipelinedPrimed), 1_024)
        XCTAssertEqual(CoreAIBundleLimits.usableContext(bundleContext: 4_096, route: .staticShape), 4_096)
        XCTAssertEqual(CoreAIBundleLimits.usableContext(bundleContext: 4_096, route: .runtimeGrammar), 4_096, "Qwen3 4B as before")
        XCTAssertEqual(CoreAIBundleLimits.usableContext(bundleContext: 32_768, route: .sequential, iOS: false), 32_768)
        XCTAssertTrue(CoreAIBundleLimits.isDecodeOnly(path: "lfm2_5_1_2b_instruct_decode_int8hu_block32_sym"))
        XCTAssertFalse(CoreAIBundleLimits.isDecodeOnly(path: "minicpm5_1b_int8"))
    }

    func testHybridFamilies() {
        for name in ["qwen3.5-0.8b Qwen3.5 0.8B", "lfm2.5-1.2b", "granite-4.0-h-1b", "nemotron-3-nano-4b",
                     "qwen3_5_2b_decode_int8hu_block32_sym"] {
            XCTAssertTrue(CoreAIArchitecture.isHybrid(name), name)
        }
        for name in ["qwen3-4b Qwen3 4B", "minicpm5-1b", "gemma-4-e2b", "nanbeige4.2-3b"] {
            XCTAssertFalse(CoreAIArchitecture.isHybrid(name), name)
        }
    }

    // MARK: Gemma 4

    func testGemmaTurnsMatchItsOwnTemplate() {
        // His downloaded E2B revision's template: {{ bos_token }}{% for m %}<|turn>{role}\n{content}<turn|>\n{% endfor %}<|turn>model\n
        XCTAssertEqual(CoreAIPromptFormat.gemma4(system: "Rules", user: "Lines"),
                       "<bos><|turn>system\nRules<turn|>\n<|turn>user\nLines<turn|>\n<|turn>model\n")
    }

    func testGemmaRunsOnAnIPhone16ProOnlyFromACompiledCopy() {
        let portable = "gpu-pipelined-b2/gemma4_e2b_qat_decode_int4lin_tbl"
        let refusal = CoreAIGemmaReadiness.refusal(needsTables: true, decoderPath: portable, machine: "iPhone17,1",
                                                   compiledCopyInstalled: false)
        XCTAssertNotNil(refusal)
        XCTAssertTrue(refusal?.contains("Install Compiled Copy") == true)
        XCTAssertNil(CoreAIGemmaReadiness.refusal(needsTables: true, decoderPath: portable, machine: "iPhone17,1",
                                                  compiledCopyInstalled: true))
        // The publisher's own build for the iPhone 17 Pro's chip.
        XCTAssertNil(CoreAIGemmaReadiness.refusal(needsTables: true, decoderPath: "gpu-pipelined-b2/gemma4_e2b_qat_decode_int4lin_tbl_aotc_h18p",
                                                  machine: "iPhone18,1", compiledCopyInstalled: false))
        // Not Gemma; and the Mac compiles it itself.
        XCTAssertNil(CoreAIGemmaReadiness.refusal(needsTables: false, decoderPath: "int8", machine: "iPhone17,1", compiledCopyInstalled: false))
        XCTAssertNil(CoreAIGemmaReadiness.refusal(needsTables: true, decoderPath: portable, machine: "Mac", compiledCopyInstalled: false, iOS: false))
    }

    // MARK: Graphics chip

    private func compiledBundle(delegates: [String]) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory.appending(path: "p38-\(UUID().uuidString)")
        let compiled = bundle.appending(path: "model.h17p.aimodelc")
        for kind in delegates {
            try FileManager.default.createDirectory(at: compiled.appending(path: "main-h17p-delegates/\(kind)"),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try Data(#"{"assets":{"main":"model.h17p.aimodelc"}}"#.utf8).write(to: bundle.appending(path: "metadata.json"))
        return bundle
    }

    func testOffScreenOnlyWhenTheInstalledGraphHasNoGPUPart() throws {
        // His h17p copies of Qwen3 4B (compiled "for the Neural Engine") and
        // Gemma 4 E2B: MPSGraph only.
        let gpu = try compiledBundle(delegates: ["MPSGraph"])
        XCTAssertEqual(CoreAIComputeUnits.delegates(inBundle: gpu), ["MPSGraph"])
        XCTAssertFalse(CoreAIComputeUnits.runsWithoutGPU(delegates: CoreAIComputeUnits.delegates(inBundle: gpu)))
        let ane = try compiledBundle(delegates: ["ANE"])
        XCTAssertTrue(CoreAIComputeUnits.runsWithoutGPU(delegates: CoreAIComputeUnits.delegates(inBundle: ane)))
        let mixed = try compiledBundle(delegates: ["ANE", "MPSGraph"])
        XCTAssertFalse(CoreAIComputeUnits.runsWithoutGPU(delegates: CoreAIComputeUnits.delegates(inBundle: mixed)))
        // Prepared on the phone: nothing to read, so it counts as the GPU.
        XCTAssertFalse(CoreAIComputeUnits.runsWithoutGPU(delegates: nil))
        XCTAssertFalse(CoreAIComputeUnits.runsWithoutGPU(delegates: []))
    }

    func testBackgroundGPURefusalIsRecognised() {
        struct Fake: Error, CustomStringConvertible { var description: String }
        XCTAssertTrue(CoreAIAnswerText.isBackgroundGPURefusal(Fake(description: "Error Domain=MTLCommandBufferErrorDomain (kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted)")))
        XCTAssertFalse(CoreAIAnswerText.isBackgroundGPURefusal(Fake(description: "Missing state view for convState")))
    }

    // MARK: Answers cut back

    func testSalvageKeepsFinishedPartsOnly() {
        let two = #"{"parts":[{"first_line":3,"last_line":9,"label":"HOST_READ_AD","sponsor":"A"},{"first_line":12,"last_line":20,"label":"PAID_AD","sponsor":"B"},{"first_li"#
        let kept = CoreAIAnswerText.salvage(two)
        XCTAssertEqual(JudgePrompt.parseComplete(kept ?? "")?.count, 2)
        // A closed answer comes back as it was (trailing chatter dropped).
        XCTAssertEqual(CoreAIAnswerText.salvage(#"{"parts":[]} Sure!"#), #"{"parts":[]}"#)
        // Not one part finished: no answer, never an empty list it didn't write.
        XCTAssertNil(CoreAIAnswerText.salvage(#"{"parts":[{"first_line":3,"last_line"#))
        XCTAssertNil(CoreAIAnswerText.salvage("I think the ad is"))
        // Braces inside strings don't count.
        let tricky = #"{"parts":[{"first_line":1,"last_line":2,"label":"PAID_AD","sponsor":"a } b"},{"#
        XCTAssertEqual(JudgePrompt.parseComplete(CoreAIAnswerText.salvage(tricky) ?? "")?.first?.sponsor, "a } b")
    }

    // MARK: Plans

    func testParameterCountsFromNames() {
        XCTAssertEqual(ModelPromptPlan.billions(in: "mlx-community/Qwen3.5-0.8B-MLX"), 0.8)
        XCTAssertEqual(ModelPromptPlan.billions(in: "LiquidAI/LFM2.5-350M-MLX-4bit"), 0.35)
        XCTAssertEqual(ModelPromptPlan.billions(in: "gemma-4-e2b Gemma 4 E2B"), 2)
        XCTAssertEqual(ModelPromptPlan.billions(in: "mlx-community/dolphin3.0-llama3.2-3B-4Bit"), 3)
        XCTAssertEqual(ModelPromptPlan.billions(in: "mlx-community/granite-4.0-h-micro-4bit"), 3)
        XCTAssertEqual(ModelPromptPlan.billions(in: "qwen3-4b Qwen3 4B"), 4)
        XCTAssertNil(ModelPromptPlan.billions(in: "mlx-community/Phi-3-mini-4k-instruct-4bit"))
    }

    func testFamiliesAreAskedTheirOwnWay() {
        let qwenSmall = ModelPromptPlan.plan(id: "qwen3.5-0.8b", modelType: "", template: "enable_thinking", downloadBytes: 0)
        XCTAssertEqual(qwenSmall.family, "Qwen3.5")
        XCTAssertEqual(qwenSmall.maxWindowTokens, 1_800)
        XCTAssertEqual(qwenSmall.thinking, .templateSwitch)
        let qwenBig = ModelPromptPlan.plan(id: "mlx-community/Qwen3.5-4B-MLX-4bit", modelType: "qwen3_5", template: "", downloadBytes: 3_061_129_077)
        XCTAssertEqual(qwenBig.maxWindowTokens, 4_000)

        let gemma = ModelPromptPlan.plan(id: "mlx-community/gemma-4-e2b-it-4bit", modelType: "gemma4", template: "", downloadBytes: 0)
        XCTAssertEqual(gemma.turns, .gemma4)
        XCTAssertEqual(gemma.profile, .leanReasoned)

        let lfm = ModelPromptPlan.plan(id: "LiquidAI/LFM2.5-1.2B-Instruct", modelType: "lfm2", template: "<think>", downloadBytes: 0)
        XCTAssertEqual(lfm.thinking, .closeOpenBlock)
        XCTAssertEqual(lfm.temperature, 0.1)
        XCTAssertEqual(lfm.topK, 50)
        XCTAssertEqual(lfm.repetitionPenalty, 1.05)
        XCTAssertEqual(lfm.maxWindowTokens, 2_000)

        for id in ["mlx-community/Llama-3.2-3B-Instruct-4bit", "prism-ml/Bonsai-8B-mlx-1bit", "prism-ml/Ternary-Bonsai-8B-mlx-2bit"] {
            XCTAssertEqual(ModelPromptPlan.plan(id: id, modelType: "", template: "", downloadBytes: 0).maxCutShare, 0.6, id)
        }
        XCTAssertNil(qwenBig.maxCutShare)
        XCTAssertEqual(ModelPromptPlan.plan(id: "mlx-community/granite-4.0-h-1b-4bit", modelType: "granitemoehybrid", template: "", downloadBytes: 0).repetitionPenalty, 1.1)
        XCTAssertEqual(ModelPromptPlan.plan(id: "mlx-community/Phi-3-mini-4k-instruct-4bit", modelType: "phi3", template: "", downloadBytes: 0).maxWindowTokens, 2_500)
        XCTAssertTrue([qwenSmall, gemma, lfm].allSatisfy(\.primeAnswer))
    }

    func testCoreAIPlansFollowWhatTheModelHoldsHere() {
        let pipelined = ModelPromptPlan.coreAI(id: "gemma-4-e2b", name: "Gemma 4 E2B", template: "", context: 1_024)
        XCTAssertEqual(pipelined.profile, .candidate)
        XCTAssertEqual(pipelined.family, "Gemma 4")
        XCTAssertEqual(pipelined.turns, .gemma4)
        let sequential = ModelPromptPlan.coreAI(id: "lfm2.5-1.2b", name: "LFM2.5 1.2B", template: "", context: 2_047)
        XCTAssertEqual(sequential.profile, .compact)
        XCTAssertEqual(sequential.thinking, .closeOpenBlock)
        let big = ModelPromptPlan.coreAI(id: "qwen3-4b", name: "Qwen3 4B", template: "enable_thinking", context: 4_096)
        XCTAssertEqual(big.profile, .lean)
        XCTAssertNotEqual(pipelined.identity, ModelPromptPlan.coreAI(id: "gemma-4-e2b", name: "Gemma 4 E2B", template: "", context: 4_096).identity)
    }

    // MARK: Prompt

    func testCandidatePromptLeavesRoomForAWholeRead() {
        let profile = JudgePrompt.Profile.candidate
        // ~4 characters a token: about 140 tokens (125 Qwen3, 140 Gemma 4, 147 LFM2.5, counted on the Mac).
        XCTAssertLessThan(profile.system.count, 640)
        XCTAssertFalse(profile.system.contains("\"properties\""), "described in words, not a schema")
        XCTAssertEqual(profile.answerTokens, 110)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(profile.schema.utf8)))
        // 1,024 − ~140 rules − ~60 header − 110 answer − 24: ~690 tokens of transcript.
        XCTAssertGreaterThanOrEqual(1_024 - 140 - 60 - profile.answerTokens - 24, 650)
        // An answer without "funny" reads.
        let parts = JudgePrompt.parseComplete(#"{"parts":[{"first_line":4,"last_line":30,"label":"HOST_READ_AD","sponsor":"Quince"}]}"#)
        XCTAssertEqual(parts?.first?.funny, false)
        XCTAssertEqual(JudgePrompt.Profile.forContext(1_024), .candidate)
        XCTAssertEqual(JudgePrompt.Profile.forContext(2_047), .compact)
        XCTAssertEqual(JudgePrompt.Profile.forContext(4_096), .lean)
    }

    func testStretchesShareTheirHeader() {
        let lines = (0..<40).map { TimedLine(text: "line \($0)", start: Double($0) * 10, end: Double($0) * 10 + 9) }
        let header = JudgePrompt.userHeader(show: "Show", title: "Ep", notes: "Sponsored by Quince. Go to quince.com", corrections: "")
        let user = JudgePrompt.userLocal(show: "Show", title: "Ep", notes: "Sponsored by Quince. Go to quince.com",
                                         lines: lines, window: 10..<20, spans: [])
        XCTAssertTrue(user.hasPrefix(header))
        XCTAssertTrue(user.contains("Lines 0–9:"))
        XCTAssertEqual(JudgePrompt.stretch(lines: lines, window: 0..<0, spans: []), "")
    }

    func testLabelAliases() {
        XCTAssertEqual(JudgePrompt.label(named: "paid_ad"), .paidAd)
        XCTAssertEqual(JudgePrompt.label(named: "Host Read Ad"), .hostReadAd)
        XCTAssertEqual(JudgePrompt.label(named: "advertisement"), .paidAd)
        XCTAssertEqual(JudgePrompt.label(named: "Sponsor"), .paidAd)
        XCTAssertEqual(JudgePrompt.label(named: "self promotion"), .selfPromo)
        XCTAssertEqual(JudgePrompt.label(named: "cross-promo"), .networkPromo)
        XCTAssertEqual(JudgePrompt.label(named: "conversation"), .show)
        XCTAssertNil(JudgePrompt.label(named: "PROMO"), "could be either kind; not guessed")
        // Text in a line-number field is not a line number.
        XCTAssertEqual(JudgePrompt.parse(#"{"parts":[{"first_line":"the ad","last_line":9,"label":"PAID_AD","sponsor":""}]}"#)?.count, 0)
    }

    func testAStretchRestatedAsOneCutIsDropped() {
        // 30 lines, 10 s each: a 5-minute stretch.
        let lines = (0..<30).map { TimedLine(text: "line \($0)", start: Double($0) * 10, end: Double($0) * 10 + 10) }
        func part(_ a: Int, _ b: Int, _ label: JudgeLabel = .hostReadAd) -> JudgePrompt.RawPart {
            JudgePrompt.RawPart(firstLine: a, lastLine: b, firstWords: "", lastWords: "", label: label,
                                sponsor: "", funny: false, confidence: 80, why: "")
        }
        let window = 0..<30
        XCTAssertTrue(JudgePrompt.shifted([part(3, 25)], window: window, lines: lines, maxShare: 0.6).isEmpty, "73 % of five minutes")
        XCTAssertEqual(JudgePrompt.shifted([part(5, 14)], window: window, lines: lines, maxShare: 0.6).count, 1, "a 100-s read stays")
        XCTAssertEqual(JudgePrompt.shifted([part(3, 25)], window: window, lines: lines, maxShare: nil).count, 1, "other families keep it")
        XCTAssertEqual(JudgePrompt.shifted([part(3, 25, .show)], window: window, lines: lines, maxShare: 0.6).count, 1, "SHOW is no cut")
        // A short stretch (2 min): a long read can fill it.
        let short = Array(lines.prefix(12))
        XCTAssertEqual(JudgePrompt.shifted([part(1, 10)], window: 0..<12, lines: short, maxShare: 0.6).count, 1)
    }
}
