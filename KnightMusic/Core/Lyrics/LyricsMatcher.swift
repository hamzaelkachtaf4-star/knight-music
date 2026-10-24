import Foundation

/// Query cleaning and recording matching shared by the lyrics providers. A miss only costs a fallback; the
/// wrong song's words scrolling in time is worse, so lrc.red hits must pass every test, not score highest.
enum LyricsMatcher {
    private static let noise = #"\((?:feat\.?|ft\.?|featuring|with|from|official|lyrics?|lyrical|video|audio|visuali[sz]er|explicit|clean|hd|4k)[^)]*\)|\[[^\]]*\]"#

    /// "Song (Official Video) | Topic" → "Song". Returns the input when cleaning would leave nothing.
    static func cleanTitle(_ title: String) -> String {
        var cleaned = title.replacingOccurrences(of: noise, with: " ", options: [.regularExpression, .caseInsensitive])
        if let bar = cleaned.range(of: " | ") { cleaned = String(cleaned[..<bar.lowerBound]) }
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    /// The lead artist of a credit like "A, B & C" or "A feat. B".
    static func primaryArtist(_ artist: String) -> String {
        artistParts(artist).first ?? artist
    }

    static func bestLrcRedHit(_ hits: [LrcRedHit], title: String, artist: String, durationSeconds: Int?) -> LrcRedHit? {
        let wantedCore = core(title)
        let wantedVersion = version(title)
        let wantedArtists = Set(artistParts(artist).map(normalized))
        func distance(_ hit: LrcRedHit) -> Double {
            guard let duration = durationSeconds, duration > 0, let theirs = hit.duration else { return 0 }
            return abs(theirs - Double(duration))
        }
        return hits.filter { hit in
            guard let isrc = hit.isrc, isValidISRC(isrc), let name = hit.title else { return false }
            let theirArtists = Set(artistParts(hit.artist ?? "").map(normalized))
            return core(name) == wantedCore && version(name) == wantedVersion
                && (wantedArtists.isEmpty || !theirArtists.isDisjoint(with: wantedArtists))
                && distance(hit) <= 3
        }.min { distance($0) < distance($1) }
    }

    static func isValidISRC(_ code: String) -> Bool {
        code.range(of: #"^[A-Z]{2}[A-Z0-9]{3}\d{7}$"#, options: .regularExpression) != nil
    }

    // MARK: Matching internals

    /// Bracket words that name a different recording rather than a different label.
    private static let versionWords: Set<String> = [
        "live", "remix", "remixed", "mix", "acoustic", "unplugged", "instrumental", "karaoke", "cappella", "acapella",
        "demo", "edit", "version", "cover", "sped", "slowed", "reverb", "nightcore", "lofi", "orchestral", "extended",
        "drumless", "stripped",
    ]
    private static let bracketed = #"[(\[][^)\]]*[)\]]"#

    private static func core(_ title: String) -> String {
        var base = title.replacingOccurrences(of: bracketed, with: " ", options: .regularExpression)
        if let dash = base.range(of: " - ") { base = String(base[..<dash.lowerBound]) }
        let value = normalized(base)
        return value.isEmpty ? normalized(title) : value
    }

    private static func version(_ title: String) -> Set<String> {
        var extras = ""
        var search = title.startIndex..<title.endIndex
        while let range = title.range(of: bracketed, options: .regularExpression, range: search) {
            extras += " " + title[range]
            search = range.upperBound..<title.endIndex
        }
        if let dash = title.range(of: " - ") { extras += " " + title[dash.upperBound...] }
        return Set(normalized(extras).split(separator: " ").map(String.init).filter(versionWords.contains))
    }

    private static func artistParts(_ artist: String) -> [String] {
        artist.replacingOccurrences(of: #"\s*(?:,|&|;|/|\s+and\s+|\s+x\s+|\s+with\s+|\s+feat\.?\s+|\s+ft\.?\s+)\s*"#,
                                    with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Lower case, accents off, letters and digits only.
    private static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let mapped = String(folded.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        return mapped.split(separator: " ").joined(separator: " ")
    }
}

struct LrcRedHit: Decodable, Hashable, Sendable {
    var isrc: String?
    var title: String?
    var artist: String?
    var album: String?
    /// Seconds, fractional.
    var duration: Double?
}

struct LrcRedSearch: Decodable, Sendable {
    var hits: [LrcRedHit]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hits = try container.decodeIfPresent([LrcRedHit].self, forKey: .hits) ?? []
    }

    private enum CodingKeys: String, CodingKey { case hits }
}

/// Lyrics providers wrap their document in JSON (`{"ttml": "…"}`) or return it bare; errors come back as
/// JSON too. This digs the document out, or returns nil for an error or an empty answer.
enum LyricsPayload {
    private static let contentKeys = ["ttml", "ttmlContent", "lyrics", "syncedLyrics", "lrc", "content", "text", "plainLyrics", "data", "result"]

    static func unwrap(_ data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: [.fragmentsAllowed]) else { return raw }
        return extract(json)
    }

    private static func extract(_ node: Any) -> String? {
        switch node {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let nested = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)), !(nested is String) { return extract(nested) }
            return trimmed.isEmpty ? nil : trimmed
        case let array as [Any]:
            let joined = array.compactMap(extract).joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        case let object as [String: Any]:
            if let error = object["error"], !(error is NSNull), (error as? Bool) != false { return nil }
            if (object["isError"] as? Bool) == true { return nil }
            for key in contentKeys { if let value = object[key], let found = extract(value) { return found } }
            return nil
        default:
            return nil
        }
    }
}
