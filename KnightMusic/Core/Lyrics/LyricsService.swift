import Foundation

/// Synced lyrics from public sources, no server needed. Three providers are asked in parallel and the best
/// answer wins: syllable-timed TTML (lrc.red by ISRC, then BetterLyrics), then LRCLIB's line-timed LRC, then
/// plain text. Ported from BitChord's LyricsRepository.
actor LyricsService {
    static let shared = LyricsService()

    enum Outcome: Sendable {
        case found(StructuredLyrics)
        /// Every provider answered and none has this song: worth remembering for a while.
        case notFound
        /// At least one provider couldn't be reached: ask again next time.
        case unavailable
    }

    private struct Answer {
        var document: LyricsDocument?
        var failed = false
        static let none = Answer()
        static let failure = Answer(document: nil, failed: true)
    }

    private let session: URLSession
    private static let userAgent = "KnightMusic (https://github.com/KNIGHTABDO/knight-music)"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: config)
    }

    func lyrics(title: String, artist: String, album: String?, durationSeconds: Int?) async -> Outcome {
        let cleanTitle = LyricsMatcher.cleanTitle(title)
        let leadArtist = LyricsMatcher.primaryArtist(artist)
        async let red = lrcRed(title: title, artist: artist, durationSeconds: durationSeconds)
        async let better = betterLyrics(title: cleanTitle, artist: leadArtist, album: album, durationSeconds: durationSeconds)
        async let lrclib = lrcLib(title: cleanTitle, artist: leadArtist, album: album, durationSeconds: durationSeconds)
        let answers = await [red, better, lrclib]
        if let best = LyricsRanker.best(answers.map(\.document)) {
            return .found(Self.structured(best))
        }
        return answers.contains(where: \.failed) ? .unavailable : .notFound
    }

    /// Word timing is stored as enhanced LRC inside each line, which `LyricsView` lights word by word.
    static func structured(_ document: LyricsDocument) -> StructuredLyrics {
        StructuredLyrics(
            lang: nil, synced: document.timing != .none, displayArtist: nil, displayTitle: nil, offset: nil,
            line: document.lines.map { line in
                .init(start: line.startMs, value: document.timing == .word ? EnhancedLrc.encode(line) : line.text)
            })
    }

    // MARK: lrc.red — Apple Music TTML filed by ISRC

    private nonisolated func lrcRed(title: String, artist: String, durationSeconds: Int?) async -> Answer {
        var search = URLComponents(string: "https://lrc.red/search.json")!
        search.queryItems = [URLQueryItem(name: "q", value: "\(LyricsMatcher.cleanTitle(title)) \(LyricsMatcher.primaryArtist(artist))")]
        guard let url = search.url else { return .none }
        switch await fetch(url) {
        case .failure: return .failure
        case .missing: return .none
        case .data(let data):
            guard let hits = try? JSONDecoder().decode(LrcRedSearch.self, from: data).hits,
                  let hit = LyricsMatcher.bestLrcRedHit(hits, title: title, artist: artist, durationSeconds: durationSeconds),
                  let isrc = hit.isrc, let document = URL(string: "https://lrc.red/s/\(isrc).ttml") else { return .none }
            switch await fetch(document) {
            case .failure: return .failure
            case .missing: return .none
            case .data(let ttml): return Answer(document: String(data: ttml, encoding: .utf8).flatMap(TtmlParser.parse))
            }
        }
    }

    // MARK: BetterLyrics — Apple Music TTML by title, artist and duration

    private nonisolated func betterLyrics(title: String, artist: String, album: String?, durationSeconds: Int?) async -> Answer {
        var components = URLComponents(string: "https://lyrics-api.boidu.dev/getLyrics")!
        var items = [URLQueryItem(name: "s", value: title), URLQueryItem(name: "a", value: artist)]
        if let durationSeconds, durationSeconds > 0 { items.append(URLQueryItem(name: "d", value: String(durationSeconds))) }
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "al", value: album)) }
        components.queryItems = items
        guard let url = components.url else { return .none }
        switch await fetch(url) {
        case .failure: return .failure
        case .missing: return .none
        case .data(let data):
            guard let content = LyricsEnvelope.unwrap(data) else { return .none }
            if content.contains("<tt") { return Answer(document: TtmlParser.parse(content)) }
            return Answer(document: LrcParser.parse(content) ?? LrcParser.plain(content))
        }
    }

    // MARK: LRCLIB — line-synced LRC, exact match then search

    private nonisolated func lrcLib(title: String, artist: String, album: String?, durationSeconds: Int?) async -> Answer {
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        if let album, !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if let durationSeconds, durationSeconds > 0 { items.append(URLQueryItem(name: "duration", value: String(durationSeconds))) }
        exact.queryItems = items
        if let url = exact.url {
            switch await fetch(url) {
            case .failure: return .failure
            case .data(let data):
                if let record = try? JSONDecoder().decode(LrcLibRecord.self, from: data), let document = record.document {
                    return Answer(document: document)
                }
            case .missing: break
            }
        }
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: artist)]
        guard let url = search.url else { return .none }
        switch await fetch(url) {
        case .failure: return .failure
        case .missing: return .none
        case .data(let data):
            let records = (try? JSONDecoder().decode([LrcLibRecord].self, from: data)) ?? []
            // Same song, different edit, would drift: only lengths within a few seconds count.
            let close = records.filter { record in
                guard let wanted = durationSeconds, wanted > 0, let theirs = record.duration else { return true }
                return abs(theirs - Double(wanted)) <= 4
            }
            let synced = close.first { $0.syncedLyrics?.isEmpty == false }
            return Answer(document: (synced ?? close.first)?.document)
        }
    }

    private struct LrcLibRecord: Decodable {
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?

        var document: LyricsDocument? {
            if let synced = syncedLyrics, let document = LrcParser.parse(synced) { return document }
            return plainLyrics.flatMap(LrcParser.plain)
        }
    }

    // MARK: HTTP

    private enum Fetched {
        case data(Data)
        case missing
        case failure
    }

    private nonisolated func fetch(_ url: URL) async -> Fetched {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else { return .failure }
            switch http.statusCode {
            case 200..<300: return data.isEmpty ? .missing : .data(data)
            // 404 is "no lyrics"; 400/401 mean the provider won't answer this query (BetterLyrics wants a key for
            // uncached ones) — a miss. 403/429/5xx are a block or an outage, never remembered as "none".
            case 400, 401, 404, 410: return .missing
            default: return .failure
            }
        } catch {
            return .failure
        }
    }
}
