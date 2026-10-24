import Foundation

/// `[mm:ss.xx] words` (LRCLIB), including enhanced `<mm:ss.xx>` word stamps, and plain unsynced text.
enum LrcParser {
    private static let lineStamp = #/\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/#
    private static let wordStamp = #/<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>/#

    /// Nil when the text carries no line stamps at all.
    static func parse(_ lrc: String) -> LyricsDocument? {
        var lines: [LyricsDocument.Line] = []
        for raw in lrc.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var starts: [Int] = []
            // A line may carry several stamps: `[00:12.00][01:30.00]chorus`.
            while let match = rest.prefixMatch(of: lineStamp) {
                starts.append(ms(match.output.1, match.output.2, match.output.3))
                rest = rest[match.range.upperBound...]
            }
            guard !starts.isEmpty else { continue }
            let body = String(rest)
            let words = enhancedWords(body)
            let text = body.replacing(wordStamp, with: "").trimmingCharacters(in: .whitespaces)
            for start in starts {
                lines.append(.init(startMs: start, endMs: nil, text: text, words: words))
            }
        }
        guard !lines.isEmpty else { return nil }
        lines.sort { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
        return LyricsDocument(timing: lines.contains { !$0.words.isEmpty } ? .word : .line, lines: lines)
    }

    /// Unsynced lyrics, one line each; blank lines inside are kept as stanza breaks.
    static func plain(_ text: String) -> LyricsDocument? {
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        return LyricsDocument(timing: .none, lines: lines.map { .init(startMs: nil, endMs: nil, text: $0, words: []) })
    }

    private static func enhancedWords(_ body: String) -> [LyricsDocument.Word] {
        let marks = body.matches(of: wordStamp)
        guard marks.count > 1 else { return [] }
        var words: [LyricsDocument.Word] = []
        for (index, mark) in marks.enumerated() {
            let until = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
            let text = String(body[mark.range.upperBound..<until])
            let start = ms(mark.output.1, mark.output.2, mark.output.3)
            let end = index + 1 < marks.count ? ms(marks[index + 1].output.1, marks[index + 1].output.2, marks[index + 1].output.3) : start
            if !text.isEmpty { words.append(.init(startMs: start, endMs: max(end, start), text: text)) }
        }
        return words
    }

    private static func ms(_ minutes: Substring, _ seconds: Substring, _ fraction: Substring?) -> Int {
        let padded = (fraction.map(String.init) ?? "").padding(toLength: 3, withPad: "0", startingAt: 0)
        return ((Int(minutes) ?? 0) * 60 + (Int(seconds) ?? 0)) * 1000 + (Int(padded) ?? 0)
    }
}
