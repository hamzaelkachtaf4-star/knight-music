import Foundation

/// Lyrics as parsed from any source, before they become `StructuredLyrics` for storage and display.
struct LyricsDocument: Equatable, Sendable {
    enum Timing: Int, Comparable, Sendable {
        case none = 0, line = 1, word = 2
        static func < (a: Timing, b: Timing) -> Bool { a.rawValue < b.rawValue }
    }

    struct Line: Equatable, Sendable {
        var startMs: Int?
        var endMs: Int?
        var text: String
        /// Separately timed pieces of the line, in order. A syllable of a longer word has no trailing space;
        /// a piece that ends a word carries the space that follows it, so joining them gives `text`.
        var words: [Word]
    }

    struct Word: Equatable, Sendable {
        var startMs: Int
        var endMs: Int
        var text: String
    }

    var timing: Timing
    var lines: [Line]
}

/// Writes word timing in the enhanced LRC form `LyricsView` reads: `<mm:ss.mmm>word <mm:ss.mmm>word<end>`.
/// The closing stamp names no word; it says when the last one stops being sung.
enum EnhancedLrc {
    static func encode(_ line: LyricsDocument.Line) -> String {
        guard let last = line.words.last else { return line.text }
        return line.words.map { stamp($0.startMs) + $0.text }.joined() + stamp(last.endMs)
    }

    static func stamp(_ ms: Int) -> String {
        let clamped = max(ms, 0)
        return String(format: "<%02d:%02d.%03d>", clamped / 60_000, (clamped / 1000) % 60, clamped % 1000)
    }
}

/// Word-synced beats line-synced beats plain; among equals, the earlier (more trusted) source wins.
enum LyricsRanker {
    static func best(_ candidates: [LyricsDocument?]) -> LyricsDocument? {
        var winner: LyricsDocument?
        for case let candidate? in candidates where !candidate.lines.isEmpty {
            if winner == nil || candidate.timing > winner!.timing { winner = candidate }
        }
        return winner
    }
}
