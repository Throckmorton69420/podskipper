import XCTest
@testable import PodSkipper

/// Pass 50: the transcript laid out as Apple Podcasts 27.2's — timed
/// paragraphs, chapter titles, silences — and its search options.
final class Pass50TranscriptLayoutTests: XCTestCase {
    private func line(_ text: String, _ start: Double, _ end: Double) -> TimedLine {
        TimedLine(text: text, start: start, end: end)
    }

    func testAPauseAfterASentenceStartsAParagraph() {
        let lines = [line("Hello there.", 0, 2), line("How are you?", 2.1, 4),
                     line("Fine.", 6, 7), line("Good", 7.1, 8), line("to hear.", 8.1, 9)]
        let layout = TranscriptLayout.layout(lines: lines, chapters: [])
        XCTAssertEqual(layout.blocks.map(\.lines), [0..<2, 2..<5])
        XCTAssertEqual(layout.blockOfLine, [0, 0, 1, 1, 1])
        XCTAssertEqual(layout.blocks[1].start, 6)
    }

    func testNoBreakInsideASentence() {
        // A long pause after "and" doesn't end the paragraph: the sentence isn't done.
        let lines = [line("We went and", 0, 2), line("then left.", 4, 5)]
        XCTAssertEqual(TranscriptLayout.layout(lines: lines, chapters: []).blocks.count, 1)
    }

    func testLongParagraphsEndAtASentence() {
        let lines = (0..<8).map { line("Line \($0).", Double($0) * 2, Double($0) * 2 + 1.9) }
        let blocks = TranscriptLayout.layout(lines: lines, chapters: []).blocks
        XCTAssertEqual(blocks.map(\.lines), [0..<TranscriptLayout.paragraphLines, TranscriptLayout.paragraphLines..<8])
        // Without sentence ends, a paragraph still stops at the hard limit.
        let run = (0..<25).map { line("word", Double($0), Double($0) + 0.9) }
        XCTAssertTrue(TranscriptLayout.layout(lines: run, chapters: []).blocks.allSatisfy { $0.lines.count <= TranscriptLayout.hardLines })
    }

    func testSilenceAndChapters() {
        let lines = [line("Welcome.", 0, 2), line("Back again.", 15, 17), line("Part two starts.", 60, 62)]
        let layout = TranscriptLayout.layout(lines: lines, chapters: [(60, "Part Two"), (0, "Intro")])
        let kinds = layout.blocks.map(\.kind)
        XCTAssertEqual(kinds, [.chapter("Intro"), .paragraph, .silence, .paragraph, .chapter("Part Two"), .paragraph])
        XCTAssertEqual(layout.blocks[2].start, 2, "silence starts where speech stopped")
        XCTAssertEqual(layout.blockOfLine, [1, 3, 5])
        XCTAssertEqual(Set(layout.blocks.map(\.id)).count, layout.blocks.count, "ids are unique")
    }

    func testEmptyTranscript() {
        let layout = TranscriptLayout.layout(lines: [], chapters: [(0, "Intro")])
        XCTAssertTrue(layout.blockOfLine.isEmpty)
    }

    func testSearchOptions() {
        let text = "Apologies, I apologise. APOLOGISE again."
        XCTAssertEqual(TranscriptLayout.matches(of: "apologise", in: text, matchCase: false, wholeWords: false).count, 2)
        XCTAssertEqual(TranscriptLayout.matches(of: "apologise", in: text, matchCase: true, wholeWords: false).count, 1)
        XCTAssertEqual(TranscriptLayout.matches(of: "apolog", in: text, matchCase: false, wholeWords: false).count, 3)
        XCTAssertEqual(TranscriptLayout.matches(of: "apolog", in: text, matchCase: false, wholeWords: true).count, 0)
        XCTAssertEqual(TranscriptLayout.matches(of: "i", in: text, matchCase: false, wholeWords: true).count, 1)
        XCTAssertTrue(TranscriptLayout.matches(of: "  ", in: text, matchCase: false, wholeWords: false).isEmpty)
    }

    func testWordsSpoken() {
        let timed = TimedLine(text: "one two three", start: 10, end: 13,
                              words: [TranscriptWord(text: "one", start: 10, end: 11),
                                      TranscriptWord(text: "two", start: 11, end: 12),
                                      TranscriptWord(text: "three", start: 12, end: 13)])
        XCTAssertEqual(TranscriptLayout.wordsSpoken(of: timed, at: 9, total: 3), 0)
        XCTAssertEqual(TranscriptLayout.wordsSpoken(of: timed, at: 11.5, total: 3), 2)
        XCTAssertEqual(TranscriptLayout.wordsSpoken(of: timed, at: 13, total: 3), 3)
        // No word times: in proportion to the line's time.
        let plain = TimedLine(text: "a b c d", start: 0, end: 4)
        XCTAssertEqual(TranscriptLayout.wordsSpoken(of: plain, at: 1.5, total: 4), 2)
    }
}
