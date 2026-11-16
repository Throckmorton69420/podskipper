import XCTest
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
}
