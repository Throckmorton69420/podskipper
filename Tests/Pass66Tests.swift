import XCTest
import UIKit
@testable import PodSkipper

/// Pass 66 (16 Nov): four Readers read together, and the cut check reads a
/// long opener or sign-off at the edge line by line.
final class Pass66Tests: XCTestCase {

    /// The build carries Pass 58's pair and the SponsorBlock-pretrained pair,
    /// each its own file, and the learner's anchor set was made for exactly
    /// these four (it is ignored when the identities differ).
    func testFourReadersAreBundledWithTheirAnchorSet() throws {
        let identities = SentenceTagger.identities()
        try XCTSkipIf(identities.isEmpty, "this build has no reader")
        XCTAssertEqual(identities.count, 4, "TaggerWeights.bin and -2, -3, -4")
        XCTAssertEqual(Set(identities).count, 4, "no reader is bundled twice")
        let readers = SentenceTagger.ensemble
        XCTAssertEqual(readers.map(\.identity), identities)
        let anchor = ReaderAnchor.load(readers: readers)
        XCTAssertGreaterThan(anchor.count, 1_000, "the anchor set matches the four bundled readers")
        XCTAssertTrue(anchor.allSatisfy { $0.features.count == 4 })
    }

    /// The four answers are averaged: every sentence's probabilities sum to
    /// one; a plain offer is an ad, and talk well away from it is the show
    /// (the lines straight after a read keep its label for a few sentences —
    /// Pass 63 — so the talk checked here is a minute on).
    func testFourReadersAverageToOneAnswer() throws {
        try XCTSkipIf(SentenceTagger.identities().isEmpty, "this build has no reader")
        var sentences = [Sentence(text: "This episode is brought to you by Odeon Coffee.", start: 0, end: 3),
                         Sentence(text: "Go to odeoncoffee dot com slash show and use code SHOW for twenty percent off.", start: 3.2, end: 8)]
        let story = ["Anyway, so my brother calls me from the airport.", "And he says he left the dog in the car.",
                     "I said, what do you mean you left the dog in the car?", "He goes, I thought you had him.",
                     "So now we're both driving back, and it's snowing.", "My mom is calling every five minutes.",
                     "We get there and the dog is just asleep on the back seat.", "Didn't even notice we were gone.",
                     "That dog has never worried about anything in his life.", "I wish I could be like that.",
                     "You would be a terrible dog.", "I would be a great dog, I love naps.",
                     "Okay, so what happened when you got home?", "Nothing, we ordered a pizza and watched the game.",
                     "Who was playing?", "I don't even remember, I fell asleep in the second quarter."]
        for (i, text) in story.enumerated() {
            sentences.append(Sentence(text: text, start: 8.4 + Double(i) * 4, end: 8.4 + Double(i) * 4 + 3.6))
        }
        let p = try XCTUnwrap(SentenceTagger.probabilities(sentences))
        XCTAssertEqual(p.count, sentences.count)
        for row in p { XCTAssertEqual(row.reduce(0, +), 1, accuracy: 1e-6) }
        XCTAssertGreaterThan(p[1][1], 0.5, "the offer line is an ad")
        XCTAssertGreaterThan(p[sentences.count - 1][0], 0.5, "the story a minute later is the show")
    }

    private func talk(_ count: Int, from: Int = 0) -> [TimedLine] {
        (from..<from + count).map { TimedLine(text: "So we get to the hotel and nobody has the key, part \($0).",
                                              start: Double($0) * 5, end: Double($0) * 5 + 4.5) }
    }

    /// The 27B teacher called two to four minutes of the hosts' first banter
    /// INTRO, and the veto never looked at an opener in the first tenth of the
    /// episode. A long one is read line by line now: the lines the Reader is
    /// sure are the show go, the lines that say they are the opener stay.
    func testALongOpenerAtTheStartIsReadLineByLine() {
        var lines = [TimedLine(text: "From Copperline Audio, this is Kitchen Table.", start: 0, end: 4.5),
                     TimedLine(text: "You're listening to Kitchen Table with Maya and Jordan.", start: 5, end: 9.5)]
        lines += talk(38, from: 2)
        let show = [Double](repeating: 1.0, count: lines.count)
        var notes: [String] = []
        let long = DetectedSegment(start: 0, end: 124.5, kind: .intro, sponsor: "", confidence: 80)
        let kept = ModelCutCheck.vetoConversation([long], lines: lines, show: show, evidence: [], duration: 1_800, notes: &notes)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.start ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(kept.first?.end ?? 0, 9.5, accuracy: 0.01, "only the two ident lines stand")
        XCTAssertTrue(notes.contains { $0.contains("kept 2 of 25 lines") }, "\(notes)")
    }

    /// A short opener at the edge is still proved by where it is, whatever
    /// the Reader makes of its words.
    func testAShortOpenerAtTheStartStandsWhole() {
        let lines = talk(40)
        let show = [Double](repeating: 1.0, count: lines.count)
        var notes: [String] = []
        let short = DetectedSegment(start: 0, end: 24.5, kind: .intro, sponsor: "", confidence: 80)
        let kept = ModelCutCheck.vetoConversation([short], lines: lines, show: show, evidence: [], duration: 1_800, notes: &notes)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.start ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(kept.first?.end ?? 0, 24.5, accuracy: 0.01)
        XCTAssertLessThanOrEqual(short.end - short.start, ModelCutCheck.edgeProved)
    }

    /// A long opener of nothing but the hosts' talk goes altogether.
    func testALongOpenerOfBanterGoes() {
        let lines = talk(60)
        let show = [Double](repeating: 1.0, count: lines.count)
        var notes: [String] = []
        let banter = DetectedSegment(start: 0, end: 174.5, kind: .intro, sponsor: "", confidence: 80)
        XCTAssertTrue(ModelCutCheck.vetoConversation([banter], lines: lines, show: show, evidence: [], duration: 1_800, notes: &notes).isEmpty)
        // Pass 64's behaviour, for the lab's comparison.
        ModelCutCheck.vetoesInsideEdges = false
        defer { ModelCutCheck.vetoesInsideEdges = true }
        let asBefore = ModelCutCheck.vetoConversation([banter], lines: lines, show: show, evidence: [], duration: 1_800, notes: &notes)
        XCTAssertEqual(asBefore.map(\.end), [174.5])
    }

    /// A long sign-off at the end keeps its credits and loses the talk the
    /// model put in front of them.
    func testALongSignOffKeepsItsCredits() {
        var lines = talk(350)
        let end = lines.last!.end
        lines.append(TimedLine(text: "Kitchen Table is produced by Priya Shah and edited by Tom Becker.", start: end + 0.5, end: end + 5))
        lines.append(TimedLine(text: "Thanks for listening, we'll see you next week.", start: end + 5.5, end: end + 9))
        let show = [Double](repeating: 1.0, count: lines.count)
        var notes: [String] = []
        let duration = lines.last!.end
        let outro = DetectedSegment(start: duration - 70, end: duration, kind: .outro, sponsor: "", confidence: 80)
        let kept = ModelCutCheck.vetoConversation([outro], lines: lines, show: show, evidence: [], duration: duration, notes: &notes)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.start ?? 0, end + 0.5, accuracy: 0.01, "the credits, not the talk before them")
        XCTAssertEqual(kept.first?.end ?? 0, duration, accuracy: 0.01)
    }

    /// Where the Reader isn't sure a line is the show, the opener keeps it:
    /// the veto only ever takes the Reader's sure-show lines.
    func testALongOpenerKeepsWhatTheReaderDoubts() {
        let lines = talk(40)
        var show = [Double](repeating: 1.0, count: lines.count)
        for i in 0..<4 { show[i] = 0.4 }
        var notes: [String] = []
        let long = DetectedSegment(start: 0, end: 99.5, kind: .intro, sponsor: "", confidence: 80)
        let kept = ModelCutCheck.vetoConversation([long], lines: lines, show: show, evidence: [], duration: 1_800, notes: &notes)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.end ?? 0, lines[3].end, accuracy: 0.01)
    }

    func testWhatAnOpenerAndASignOffSayAboutThemselves() {
        XCTAssertTrue(ModelCutCheck.saysItsAnEdge("From WBEZ Chicago, this is This American Life.", kind: .intro))
        XCTAssertTrue(ModelCutCheck.saysItsAnEdge("Welcome to Bad Friends.", kind: .intro))
        XCTAssertFalse(ModelCutCheck.saysItsAnEdge("I was exhausted, it was an early flight.", kind: .intro))
        XCTAssertFalse(ModelCutCheck.saysItsAnEdge("This episode was produced by Zoe Azulay.", kind: .intro), "credits are a sign-off's words")
        XCTAssertTrue(ModelCutCheck.saysItsAnEdge("This episode was produced by Zoe Azulay.", kind: .outro))
        XCTAssertTrue(ModelCutCheck.saysItsAnEdge("Thanks for listening.", kind: .outro))
        XCTAssertFalse(ModelCutCheck.saysItsAnEdge("And then he dropped me off at a catering company.", kind: .outro))
    }

    // MARK: Stage 1 of the 16 Nov continuation: the Hard sample's ad after a promo

    /// His 13 Nov targets on the phone's samples, with the Readers the app
    /// bundles: Basic ≥ 93, Hard ≥ 98, every Hard break named right.
    func testTheReaderMeetsTheThirteenNovemberTargetsOnBothSamples() async throws {
        try XCTSkipIf(SentenceTagger.identities().isEmpty, "this build has no reader")
        let basic = BenchSample.basic.report(cuts: ModelBench.podCuts(try await ModelBench.readerCuts(.basic)))
        let hard = BenchSample.hard.report(cuts: ModelBench.podCuts(try await ModelBench.readerCuts(.hard)))
        XCTAssertGreaterThanOrEqual(basic.quality.score, 0.925, basic.line)
        XCTAssertGreaterThanOrEqual(hard.quality.score, 0.975, hard.line)
        XCTAssertEqual(hard.checks.kindsRight, hard.checks.kindsChecked, hard.line)
    }

    /// A shoe ad, another show's promo and a tax ad read back to back, as one
    /// cut. The tax ad's first lines say nothing by their words, and the four
    /// Readers together give them 0.73–0.77 ad (the pair 0.96): at the old
    /// bar (0.95) they went with the promo and the ad was named a promo; at
    /// 0.75 the cut is three breaks, each its own kind.
    func testAnAdAfterAPromoIsItsOwnBreakWhenTheReaderLeansAd() {
        let texts: [(String, Double, [Double])] = [
            ("Your feet called.", 2, [0.1, 0.85, 0.02, 0.02, 0, 0.01]),
            ("Kestrel running shoes are built on a foam that gives back with every step.", 4, [0.05, 0.9, 0.02, 0.02, 0, 0.01]),
            ("Try them for thirty days.", 2, [0.05, 0.9, 0.02, 0.02, 0, 0.01]),
            ("Kestrel. Find your pair at kestrel run dot com.", 3, [0.01, 0.67, 0.05, 0.27, 0, 0]),
            ("If you like this show, check out Morning Static, another Wavelength Media podcast.", 4, [0.01, 0.37, 0.14, 0.47, 0, 0.01]),
            ("Every Tuesday, Dana and Rob break down the week's weirdest news.", 3, [0.01, 0.6, 0.05, 0.33, 0, 0.01]),
            ("Search Morning Static wherever you listen.", 2, [0.01, 0.71, 0.03, 0.24, 0, 0.01]),
            ("Taxes done in an afternoon?", 2, [0.02, 0.73, 0.03, 0.21, 0, 0.01]),
            ("With Ledgerly, yes.", 1.5, [0.02, 0.77, 0.03, 0.18, 0, 0]),
            ("Snap your forms, answer a few questions, and file from your couch.", 3, [0.01, 0.73, 0.03, 0.21, 0, 0.02]),
            ("Start free at ledgerly dot com.", 2, [0.01, 0.83, 0.02, 0.14, 0, 0]),
            ("Ledgerly. State filing extra.", 2, [0.03, 0.84, 0.02, 0.1, 0, 0.01]),
            ("See site for details.", 1.5, [0.05, 0.8, 0.03, 0.12, 0, 0])]
        var sentences: [Sentence] = []
        var clock = 600.0
        for (text, length, _) in texts {
            sentences.append(Sentence(text: text, start: clock, end: clock + length))
            clock += length + 0.2
        }
        let tag = texts.map(\.2)
        let cut = SegmentFinding(kind: .ad, start: sentences[0].start, end: sentences[12].end, sponsor: "Kestrel",
                                 confidence: 90, startConfidence: 80, endConfidence: 80,
                                 firstSentence: 0, lastSentence: 12, evidence: [])
        let saved = SegmentDetector.tuning
        defer { SegmentDetector.tuning = saved }
        var log: [String] = []
        XCTAssertEqual(SegmentDetector.tuning.wordlessAdSure, 0.75)
        let now = SegmentDetector.kindsApart(cut, sentences: sentences, tag: tag, log: &log)
        XCTAssertEqual(now.map(\.kind), [.ad, .crossPromo, .ad], log.joined(separator: "\n"))
        XCTAssertEqual(now.last?.firstSentence, 8, "the tax ad starts at its own first line the Reader leans ad on")
        SegmentDetector.tuning.wordlessAdSure = 0.95
        let before = SegmentDetector.kindsApart(cut, sentences: sentences, tag: tag, log: &log)
        XCTAssertEqual(before.map(\.kind), [.ad, .crossPromo], "Pass 64's bar: the tax ad went with the promo")
    }

    // MARK: Stage 4: a teacher's reason before its label

    /// The why-first prompt asks for "why" before "label"; the app's reading
    /// of an answer takes the fields by name, in either order.
    func testAnAnswerWithItsReasonFirstReadsTheSame() throws {
        let whyFirst = #"{"parts":[{"why":"a code and a web address","first_line":3,"last_line":9,"label":"PAID_AD","sponsor":"Ledgerly","funny":false,"confidence":90}]}"#
        let labelFirst = #"{"parts":[{"first_line":3,"last_line":9,"label":"PAID_AD","sponsor":"Ledgerly","funny":false,"confidence":90,"why":"a code and a web address"}]}"#
        let a = try XCTUnwrap(JudgePrompt.parse(whyFirst))
        let b = try XCTUnwrap(JudgePrompt.parse(labelFirst))
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a.map(\.firstLine), b.map(\.firstLine))
        XCTAssertEqual(a.map(\.lastLine), b.map(\.lastLine))
        XCTAssertEqual(a.map(\.label), b.map(\.label))
        XCTAssertEqual(a.first?.why, "a code and a web address")
        XCTAssertNotNil(JudgePrompt.parseComplete(whyFirst))
    }


    // MARK: Stage 3: every model can be downloaded and imported

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "pass66-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A bundle as the drive script leaves it after compiling for h17p: the
    /// download's graph, the compiled graph, metadata.json naming the
    /// compiled one and the download's metadata kept as metadata.portable.json.
    private func compiledBundle(at bundle: URL) throws {
        try write(#"{"assets":{"main":"qwen3_4b.aimodel"},"name":"q"}"#, to: bundle.appending(path: "metadata.portable.json"))
        try write(#"{"assets":{"main":"qwen3_4b.h17p.aimodelc"},"name":"q"}"#, to: bundle.appending(path: "metadata.json"))
        try write(String(repeating: "w", count: 4_000), to: bundle.appending(path: "qwen3_4b.aimodel/main.mlirb"))
        try write(#"{"sourceHash":"AB"}"#, to: bundle.appending(path: "qwen3_4b.h17p.aimodelc/metadata.json"))
        try write(String(repeating: "c", count: 3_000), to: bundle.appending(path: "qwen3_4b.h17p.aimodelc/main.mlirb"))
    }

    /// Download, Import, Delete and choosing, for each runtime: a CPU model,
    /// an MLX model and Core AI models (compiled or portable) on the drive
    /// offer Import and Download; a heavy Core AI model too (it asks before
    /// it runs); a model with no build this iPhone could hold offers neither.
    func testEveryRuntimeOffersImportAndDownload() {
        func state(compatible: Bool = true, heavy: Bool = false, downloaded: Bool = false, local: Bool? = nil,
                   onDrive: Bool = true) -> ModelRowState {
            ModelRowState.make(downloaded: downloaded, local: local ?? downloaded, compatible: compatible, heavy: heavy,
                               enabled: true, downloading: false, removing: false, importing: false, inUse: false,
                               onDrive: onDrive, anotherDownload: false, unsupported: "Not published for iPhone")
        }
        for (runtime, s) in [("CPU GGUF", state()), ("MLX", state()), ("Core AI compiled GPU", state()),
                             ("Core AI portable GPU", state()), ("heavy Core AI", state(compatible: false, heavy: true))] {
            XCTAssertTrue(s.offersImport, runtime)
            XCTAssertFalse(s.actionDisabled, runtime)
            XCTAssertEqual(s.actionTitle, "Download", runtime)
        }
        XCTAssertEqual(state(compatible: false, heavy: true).availability, "Heavy for this iPhone · Not downloaded · on your drive")
        // Downloaded, a heavy model can be chosen and tested (each asks first) and deleted.
        let heavyHere = state(compatible: false, heavy: true, downloaded: true)
        XCTAssertTrue(heavyHere.usable)
        XCTAssertEqual(heavyHere.actionTitle, "Delete")
        XCTAssertEqual(heavyHere.availability, "Ready · heavy for this iPhone")
        // A CPU or MLX model read from the drive: Import and Download still offered for a copy of its own.
        let readsFromDrive = state(downloaded: true, local: false)
        XCTAssertTrue(readsFromDrive.offersImport)
        XCTAssertEqual(readsFromDrive.actionTitle, "Download")
        XCTAssertEqual(readsFromDrive.availability, "Ready · on your drive")
        // No build this iPhone could hold at all.
        let none = state(compatible: false, heavy: false)
        XCTAssertFalse(none.offersImport)
        XCTAssertTrue(none.actionDisabled)
        XCTAssertEqual(none.availability, "Not published for iPhone")
    }

    /// A model heavier than iOS lets PodSkipper hold names its build (so it
    /// can be downloaded or imported) and is marked heavy, not runnable unasked.
    func testAHeavyCoreAIModelNamesItsBuild() {
        let budget = CoreAICompatibility.weightBudgetMB(physicalMB: 7_470, increasedLimit: true)
        let gptOSS = CoreAICompatibility.resolve(ios: nil, mac: .init(path: "macos", sizeMB: 13_789), machine: "iPhone17,1",
                                                 weightBudgetMB: budget)
        XCTAssertFalse(gptOSS.compatible)
        XCTAssertTrue(gptOSS.heavy)
        XCTAssertEqual(gptOSS.path, "macos")
        XCTAssertTrue(gptOSS.usesMacBuild)
        XCTAssertEqual(gptOSS.note?.contains("will likely close PodSkipper"), true)
        let fits = CoreAICompatibility.resolve(ios: .init(path: "ios", sizeMB: 2_000), mac: nil, machine: "iPhone17,1", weightBudgetMB: budget)
        XCTAssertFalse(fits.heavy)
        let descriptor = CoreAIModelDescriptor(id: "gpt-oss-20b", name: "GPT-OSS 20B", repo: "r", sizeMB: 13_789,
                                               isCompatible: false, isHeavy: true)
        XCTAssertTrue(descriptor.canRun)
        XCTAssertFalse(CoreAIModelDescriptor(id: "x", name: "X", repo: "r", sizeMB: 1, isCompatible: false).canRun)
    }

    /// The drive's compiled bundle is offered twice: the compiled copy (the
    /// default) and the portable build without it; what is on the phone
    /// decides which one counts as imported.
    func testADriveBundleWithACompiledCopyOffersBothGraphs() throws {
        let drive = try temporaryFolder()
        let relative = "mlboydaisuke/qwen3-4b/e40878f/ios"
        try compiledBundle(at: drive.appending(path: relative, directoryHint: .isDirectory))
        let store = try temporaryFolder()
        var items = ExternalModelInventory.coreAIItems(under: drive, store: store)
        XCTAssertEqual(items.map(\.id), ["coreai:" + relative, "coreai-portable:" + relative])
        XCTAssertEqual(items.map(\.graph), [.compiled(chip: "h17p"), .portable])
        XCTAssertGreaterThan(items[0].bytes, items[1].bytes, "the portable import leaves the compiled copy out")
        // Sizes are what the disk allocates (ModelStorage.size), so the difference is the compiled copy's allocation.
        let compiledCopy = drive.appending(path: relative + "/qwen3_4b.h17p.aimodelc", directoryHint: .isDirectory)
        XCTAssertEqual(items[0].bytes - items[1].bytes, ModelStorage.size(of: compiledCopy))
        XCTAssertEqual(items.map(\.imported), [false, false])
        XCTAssertEqual(CoreAIExternal.relativePath(ofItemID: items[1].id), relative)
        // The compiled copy on the phone: that one is imported, the portable build is the other choice.
        try compiledBundle(at: store.appending(path: relative, directoryHint: .isDirectory))
        items = ExternalModelInventory.coreAIItems(under: drive, store: store)
        XCTAssertEqual(items.map(\.imported), [true, false])
        // A bundle with no compiled copy is one portable item.
        let plain = try temporaryFolder()
        try write(#"{"assets":{"main":"m.aimodel"}}"#, to: plain.appending(path: "o/r/rev/gpu/metadata.json"))
        try write("w", to: plain.appending(path: "o/r/rev/gpu/m.aimodel/main.mlirb"))
        XCTAssertEqual(ExternalModelInventory.coreAIItems(under: plain, store: nil).map(\.graph), [.portable])
    }

    /// Importing the portable build: no compiled copy comes across and the
    /// download's own metadata is metadata.json again; importing the compiled
    /// one, then removing its compiled copy, gives the same bundle.
    func testSwitchingBetweenTheCompiledAndPortableBuildsRestoresTheMetadata() throws {
        let drive = try temporaryFolder()
        let source = drive.appending(path: "o/r/rev/ios", directoryHint: .isDirectory)
        try compiledBundle(at: source)
        let phone = try temporaryFolder()
        let portable = phone.appending(path: "portable", directoryHint: .isDirectory)
        try ModelCopier.copy(source, to: portable, total: 0, report: { _, _ in },
                             skip: CoreAIBundleScan.isCompiledCopy, finish: CoreAIBundleScan.restorePortable)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: portable.appending(path: "qwen3_4b.h17p.aimodelc").path))
        XCTAssertFalse(fm.fileExists(atPath: portable.appending(path: CoreAICompiledCopy.portableMetadata).path))
        XCTAssertEqual(CoreAICompiledCopy.mainAsset(in: portable), "qwen3_4b.aimodel")
        XCTAssertNil(CoreAICompiledCopy.installed(in: portable))
        XCTAssertTrue(fm.fileExists(atPath: portable.appending(path: "qwen3_4b.aimodel/main.mlirb").path))
        XCTAssertFalse(fm.fileExists(atPath: phone.appending(path: ".import-portable").path), "no staging left")
        // The compiled build, then back to portable from the row (Remove Compiled Copy).
        let compiled = phone.appending(path: "compiled", directoryHint: .isDirectory)
        try ModelCopier.copy(source, to: compiled, total: 0, report: { _, _ in })
        XCTAssertEqual(CoreAICompiledCopy.installed(in: compiled), "qwen3_4b.h17p.aimodelc")
        try CoreAICompiledCopy.remove(from: compiled)
        XCTAssertNil(CoreAICompiledCopy.installed(in: compiled))
        XCTAssertEqual(try Data(contentsOf: compiled.appending(path: "metadata.json")),
                       try Data(contentsOf: portable.appending(path: "metadata.json")))
        XCTAssertFalse(fm.fileExists(atPath: compiled.appending(path: CoreAICompiledCopy.portableMetadata).path))
        XCTAssertFalse(fm.fileExists(atPath: compiled.appending(path: "qwen3_4b.h17p.aimodelc").path))
    }

    /// "Choose Model File or Folder…": each kind of file is matched to its model.
    func testAChosenFileOrFolderIsMatchedToItsModel() throws {
        let root = try temporaryFolder()
        // A CPU model's file, complete (a sparse file of its exact size).
        let cpu = try XCTUnwrap(CPUReading.catalog.first)
        let gguf = root.appending(path: cpu.file)
        XCTAssertTrue(FileManager.default.createFile(atPath: gguf.path, contents: nil))
        let handle = try FileHandle(forWritingTo: gguf)
        try handle.truncate(atOffset: UInt64(cpu.bytes))
        try handle.close()
        guard case .item(let cpuItem) = ChosenModel.classify(gguf) else { return XCTFail("the CPU file") }
        XCTAssertEqual(cpuItem.id, "gguf:" + cpu.id)
        XCTAssertTrue(cpuItem.scoped)
        // Not one of the catalog's files, or incomplete.
        let other = root.appending(path: "other-model.gguf")
        try write("x", to: other)
        guard case .refused = ChosenModel.classify(other) else { return XCTFail("an unknown GGUF") }
        guard case .refused = ChosenModel.classify(root.appending(path: "nothing.txt")) else { return XCTFail("missing") }
        // A Core AI bundle in the drive's layout, with its compiled copy.
        let bundle = root.appending(path: "coreai/mlboydaisuke/qwen3-4b/e40878f/ios", directoryHint: .isDirectory)
        try compiledBundle(at: bundle)
        let catalog = [(name: "Qwen3 4B", path: "mlboydaisuke/qwen3-4b/e40878f/ios")]
        guard case .item(let coreItem) = ChosenModel.classify(bundle, coreAIBundles: catalog) else { return XCTFail("the bundle") }
        XCTAssertEqual(coreItem.id, "coreai:mlboydaisuke/qwen3-4b/e40878f/ios")
        XCTAssertEqual(coreItem.graph, .compiled(chip: "h17p"))
        guard case .refused = ChosenModel.classify(bundle, coreAIBundles: []) else { return XCTFail("not in the catalog") }
        // The compiled graph alone, and the download's graph alone.
        XCTAssertEqual(ChosenModel.classify(bundle.appending(path: "qwen3_4b.h17p.aimodelc")),
                       .compiledCopy(bundle.appending(path: "qwen3_4b.h17p.aimodelc")))
        guard case .refused(let why) = ChosenModel.classify(bundle.appending(path: "qwen3_4b.aimodel")) else { return XCTFail("graph") }
        XCTAssertTrue(why.contains("metadata.json"))
        // An MLX model's folder.
        let spec = try XCTUnwrap(LocalModelSpec.all.first)
        let mlx = root.appending(path: String(spec.id.split(separator: "/").last!), directoryHint: .isDirectory)
        try write("{}", to: mlx.appending(path: "config.json"))
        guard case .item(let mlxItem) = ChosenModel.classify(mlx) else { return XCTFail("the MLX folder") }
        XCTAssertEqual(mlxItem.id, "mlx:" + spec.id)
    }

    /// The load gate's refusal of a model whose on-phone preparation closed
    /// PodSkipper becomes a choice: after "Try Preparing on iPhone" it lets
    /// the model through, unless the phone lacks room for the preparation.
    func testTheLoadGateLetsHimTryPreparingOnThePhone() throws {
        let suite = "Pass66Tests.gate." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let roomy = CoreAILoadGate.Facts(compiledCopy: false, prepared: false, plainFree: 40_000_000_000, modelBytes: 3_000_000_000)
        let refused = CoreAILoadGate.refusal(id: "qwen3.5-2b", name: "Qwen3.5 2B", facts: roomy, closures: nil, defaults: defaults)
        XCTAssertEqual(refused?.contains("Try Preparing on iPhone"), true)
        CoreAILoadGate.allowOnPhonePreparation("qwen3.5-2b", defaults: defaults)
        XCTAssertNil(CoreAILoadGate.refusal(id: "qwen3.5-2b", name: "Qwen3.5 2B", facts: roomy, closures: nil, defaults: defaults))
        let tight = CoreAILoadGate.Facts(compiledCopy: false, prepared: false, plainFree: 2_000_000_000, modelBytes: 3_000_000_000)
        XCTAssertEqual(CoreAILoadGate.refusal(id: "qwen3.5-2b", name: "Qwen3.5 2B", facts: tight, closures: nil, defaults: defaults)?
            .hasPrefix("Not enough space"), true, "the space check stands")
        XCTAssertNotNil(CoreAILoadGate.refusal(id: "gemma-3-4b-it", name: "Gemma 3 4B", facts: roomy, closures: nil, defaults: defaults),
                        "only the model he chose")
    }


    // MARK: Stage 6 audit

    /// Stop during an import stops the copy itself (it used to run in a
    /// detached task that Stop never reached, and then say it had worked).
    @MainActor
    func testStoppingAnImportStopsTheCopy() async throws {
        let model = try XCTUnwrap(CPUReading.catalog.last)
        try XCTSkipIf(FileManager.default.fileExists(atPath: model.location.path), "a real copy is in place")
        let folder = try temporaryFolder()
        let source = folder.appending(path: model.file)
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 6_000_000_000)   // sparse: reads as zeros, takes seconds to copy
        try handle.close()
        let importer = ExternalModelImport.shared
        let item = ExternalModelInventory.Item(id: "gguf:" + model.id, name: model.name, kind: .gguf, source: source,
                                               bytes: 6_000_000_000, imported: false, readsInPlace: false)
        importer.importItem(item)
        XCTAssertTrue(importer.isImporting)
        try await Task.sleep(for: .milliseconds(300))
        let asked = Date()
        importer.stop()
        let deadline = Date().addingTimeInterval(10)
        while importer.isImporting, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(importer.isImporting)
        XCTAssertLessThan(Date().timeIntervalSince(asked), 3, "the copy stops when asked, not at its end")
        XCTAssertEqual(importer.message, "Import stopped; nothing was kept.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.location.path))
        let staging = model.location.deletingLastPathComponent().appending(path: ".import-" + model.location.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "no half-copied file left")
    }

    /// A late callback of a CPU download that was stopped (or replaced)
    /// changes nothing: it used to clear the next download's state.
    @MainActor
    func testALateCallbackOfAStoppedCPUDownloadLeavesTheNextOneAlone() throws {
        let copy = CPUModelCopy.shared
        let model = try XCTUnwrap(CPUReading.catalog.first)
        try XCTSkipIf(copy.downloadingID != nil, "a download is under way")
        let before = copy.state(of: model)
        copy.failed(model, URLError(.timedOut), run: UUID())
        XCTAssertEqual(copy.state(of: model), before, "a stale run's failure is ignored")
        XCTAssertNil(copy.downloadingID)
    }

    /// The Readers' weights can be let go at once (before a model loads, or
    /// on a memory warning); the next reading loads them again.
    func testTheReadersCanBeLetGoAtOnce() {
        let cache = ReaderCache()
        _ = cache.readers { [] }
        XCTAssertTrue(cache.isHolding)
        cache.releaseNow()
        XCTAssertFalse(cache.isHolding)
        _ = cache.readers { [] }
        XCTAssertEqual(cache.loads, 2)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertFalse(cache.isHolding, "a memory warning lets them go")
    }

    // MARK: Stage 6.2: Apple Podcasts 27.3 parity

    /// 27.3's Video Streaming Options › Use Cellular Data: on by default
    /// (video kept streaming as before), saved like every other setting.
    @MainActor
    func testVideoStreamingOverCellularIsASavedSetting() throws {
        let key = "videoStreamingCellular"
        let before = UserDefaults.standard.object(forKey: key)
        addTeardownBlock { UserDefaults.standard.set(before, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(AppSettings().videoStreamingOverCellular, "on by default: video streams as it did")
        let settings = AppSettings()
        settings.videoStreamingOverCellular = false
        XCTAssertFalse(AppSettings().videoStreamingOverCellular)
        XCTAssertTrue(PlayerEngine.cellularVideoMessage.contains("Video Streaming Options"))
    }
}
