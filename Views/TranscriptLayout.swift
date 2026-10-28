import Foundation

/// Pass 50: the transcript laid out as Apple Podcasts 27.2 lays its own out —
/// timed paragraphs rather than one row per sentence, chapter titles between
/// them, and a "Silence" mark where nobody speaks for a while
/// (`PodcastsTranscripts`: `ParagraphViewModel`, `ChapterTitleView`,
/// `SilentContentView`, `TranscriptTimestampView`).
///
/// Pure, so it is worked out once per transcript and tested without a player.
enum TranscriptLayout {
    /// A gap at least this long between lines is shown as silence.
    static let silenceGap: Double = 8
    /// A pause this long after a finished sentence starts a new paragraph.
    static let pauseBreak: Double = 1.2
    /// Paragraphs end at a sentence's end once they run this long…
    static let paragraphSpan: Double = 25
    /// …or hold this many lines; past `hardLines` they end mid-sentence too.
    /// Kept short: the transcript sits in a window about 340 points tall,
    /// and a paragraph taller than that pushes the words being said out of
    /// sight (the first simulator photograph: eleven rows in one).
    static let paragraphLines = 4
    static let hardLines = 8

    struct Block: Identifiable, Hashable {
        enum Kind: Hashable { case chapter(String), silence, paragraph }
        let kind: Kind
        /// The transcript lines it holds; empty for a chapter title or silence.
        let lines: Range<Int>
        let start: Double
        var id: String {
            switch kind {
            case .chapter:   "chapter-\(start)"
            case .silence:   "silence-\(start)"
            case .paragraph: "paragraph-\(lines.lowerBound)"
            }
        }
    }

    struct Layout {
        var blocks: [Block] = []
        /// For each transcript line, the block holding it.
        var blockOfLine: [Int] = []
    }

    static func layout(lines: [TimedLine], chapters: [(start: Double, title: String)]) -> Layout {
        var out = Layout()
        out.blockOfLine = Array(repeating: 0, count: lines.count)
        let chapters = chapters.sorted { $0.start < $1.start }
        var nextChapter = 0
        var open: Int?            // first line of the paragraph being built

        func close(upTo end: Int) {
            guard let first = open, first < end else { open = nil; return }
            for index in first..<end { out.blockOfLine[index] = out.blocks.count }
            out.blocks.append(Block(kind: .paragraph, lines: first..<end, start: lines[first].start))
            open = nil
        }

        for (index, line) in lines.enumerated() {
            // Chapters that begin at or before this line go above it.
            var titled = false
            while nextChapter < chapters.count, chapters[nextChapter].start <= line.start + 0.5 {
                if !titled { close(upTo: index); titled = true }
                let chapter = chapters[nextChapter]
                out.blocks.append(Block(kind: .chapter(chapter.title), lines: index..<index, start: chapter.start))
                nextChapter += 1
            }
            if let first = open, index > 0 {
                let previous = lines[index - 1]
                let gap = line.start - previous.end
                let count = index - first
                let sentenceDone = endsSentence(previous.text)
                if gap >= silenceGap {
                    close(upTo: index)
                    out.blocks.append(Block(kind: .silence, lines: index..<index, start: previous.end))
                } else if count >= hardLines
                            || (sentenceDone && (gap >= pauseBreak || count >= paragraphLines
                                                 || line.start - lines[first].start >= paragraphSpan)) {
                    close(upTo: index)
                }
            }
            if open == nil { open = index }
        }
        close(upTo: lines.count)
        return out
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!…\"”'’)".contains(last)
    }

    /// Where the words searched for appear in `text`. Apple's search options:
    /// match case, and whole words only.
    static func matches(of needle: String, in text: String, matchCase: Bool, wholeWords: Bool) -> [Range<String.Index>] {
        let needle = needle.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return [] }
        var options: String.CompareOptions = matchCase ? [] : [.caseInsensitive, .diacriticInsensitive]
        options.insert(.literal)
        var found: [Range<String.Index>] = []
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: needle, options: options, range: from..<text.endIndex) {
            if !wholeWords || isWordBoundary(text, before: range.lowerBound) && isWordBoundary(text, after: range.upperBound) {
                found.append(range)
            }
            from = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
        }
        return found
    }

    private static func isWordBoundary(_ text: String, before index: String.Index) -> Bool {
        index == text.startIndex || !isWordCharacter(text[text.index(before: index)])
    }

    private static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }

    private static func isWordBoundary(_ text: String, after index: String.Index) -> Bool {
        index == text.endIndex || !isWordCharacter(text[index])
    }

    /// How many of a line's words have been said at `time`: from each word's
    /// own time when the transcript kept them, else in proportion to the
    /// line's time.
    static func wordsSpoken(of line: TimedLine, at time: Double, total: Int) -> Int {
        guard total > 0 else { return 0 }
        if time >= line.end { return total }
        if time < line.start { return 0 }
        if let words = line.words, words.count == total {
            return words.filter { $0.start <= time }.count
        }
        let fraction = (time - line.start) / max(0.01, line.end - line.start)
        return min(total, Int((Double(total) * fraction).rounded(.up)))
    }
}
