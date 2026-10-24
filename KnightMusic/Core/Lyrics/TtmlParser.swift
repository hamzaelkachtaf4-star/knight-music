import Foundation

/// Apple Music style TTML (`<p begin end><span begin end>syl</span>…</p>`), as served by lrc.red and
/// BetterLyrics. Word-timed documents become per-syllable pieces; line-timed ones keep only line times.
/// Translations and romanisations are skipped; background vocals (`x-bg`) are dropped because they overlap
/// the lead line in time and would steal the active-line highlight.
enum TtmlParser {
    private static let skippedRoles: Set<String> = ["x-translation", "x-roman", "x-bg"]

    static func parse(_ ttml: String) -> LyricsDocument? {
        guard let data = ttml.data(using: .utf8), let root = XMLTree.parse(data) else { return nil }
        let lines = root.descendants(named: "p").compactMap(line(from:)).sorted { ($0.startMs ?? 0) < ($1.startMs ?? 0) }
        guard !lines.isEmpty else { return nil }
        return LyricsDocument(timing: lines.contains { !$0.words.isEmpty } ? .word : .line, lines: lines)
    }

    /// TTML clock values: `12.5`, `1:02.500`, `01:00:01.25`, `750ms`, `3s`.
    static func milliseconds(_ value: String?) -> Int? {
        guard var raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.hasSuffix("ms") { return Double(raw.dropLast(2)).map { Int($0.rounded()) } }
        if raw.hasSuffix("s") { raw.removeLast() }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map { Double($0) }
        guard !parts.isEmpty, parts.count <= 3, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let seconds = parts.reduce(0.0) { $0 * 60 + $1! }
        return Int((seconds * 1000).rounded())
    }

    // MARK: Lines

    private enum Piece {
        case text(String)
        case timed(String, start: Int, end: Int)
    }

    private static func line(from paragraph: XMLTree.Node) -> LyricsDocument.Line? {
        var pieces: [Piece] = []
        collect(paragraph, into: &pieces)
        let words = merge(pieces)
        let begin = milliseconds(paragraph.attributes["begin"])
        let end = milliseconds(paragraph.attributes["end"])
        if words.isEmpty {
            let text = visibleText(paragraph).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let begin, !text.isEmpty else { return nil }
            return .init(startMs: begin, endMs: end.flatMap { $0 > begin ? $0 : nil }, text: text, words: [])
        }
        let text = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(startMs: min(begin ?? words[0].startMs, words[0].startMs),
                     endMs: max(end ?? 0, words.last!.endMs), text: text, words: words)
    }

    private static func role(_ node: XMLTree.Node) -> String {
        node.attributes["ttm:role"] ?? node.attributes["role"] ?? ""
    }

    private static func collect(_ node: XMLTree.Node, into pieces: inout [Piece]) {
        for child in node.children {
            switch child {
            case .text(let text):
                pieces.append(.text(text))
            case .element(let element):
                if skippedRoles.contains(role(element)) { continue }
                if let start = milliseconds(element.attributes["begin"]), let end = milliseconds(element.attributes["end"]),
                   !element.hasTimedDescendant {
                    pieces.append(.timed(visibleText(element), start: start, end: max(end, start)))
                } else {
                    collect(element, into: &pieces)
                }
            }
        }
    }

    /// Joins timed pieces into display pieces: whitespace between spans ends a word, adjacent spans are
    /// syllables of one word, and untimed punctuation sticks to the piece before it.
    private static func merge(_ pieces: [Piece]) -> [LyricsDocument.Word] {
        var words: [LyricsDocument.Word] = []
        func endWord() {
            guard let last = words.last, !last.text.hasSuffix(" ") else { return }
            words[words.count - 1].text += " "
        }
        for piece in pieces {
            switch piece {
            case .text(let text):
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    endWord()
                } else if !words.isEmpty {
                    words[words.count - 1].text += text.replacingOccurrences(of: "\n", with: " ")
                }
            case .timed(let text, let start, let end):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if text.first?.isWhitespace == true { endWord() }
                words.append(.init(startMs: start, endMs: end, text: trimmed))
                if text.last?.isWhitespace == true { endWord() }
            }
        }
        if let last = words.last {
            words[words.count - 1].text = String(last.text.reversed().drop { $0.isWhitespace }.reversed())
        }
        return words
    }

    private static func visibleText(_ node: XMLTree.Node) -> String {
        node.children.map { child in
            switch child {
            case .text(let text): return text
            case .element(let element): return skippedRoles.contains(role(element)) ? "" : visibleText(element)
            }
        }.joined()
    }
}

/// A minimal in-memory XML tree built with Foundation's `XMLParser` (external entities stay unresolved).
enum XMLTree {
    final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Child] = []
        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        func descendants(named name: String) -> [Node] {
            var out: [Node] = []
            for case .element(let element) in children {
                if element.name == name { out.append(element) } else { out += element.descendants(named: name) }
            }
            return out
        }

        var hasTimedDescendant: Bool {
            children.contains {
                guard case .element(let element) = $0 else { return false }
                return element.attributes["begin"] != nil || element.hasTimedDescendant
            }
        }
    }

    enum Child {
        case element(Node)
        case text(String)
    }

    static func parse(_ data: Data) -> Node? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { return nil }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let node = Node(name: elementName, attributes: attributeDict)
            if let parent = stack.last { parent.children.append(.element(node)) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let parent = stack.last else { return }
            if case .text(let previous)? = parent.children.last {
                parent.children[parent.children.count - 1] = .text(previous + string)
            } else {
                parent.children.append(.text(string))
            }
        }
    }
}
