import Foundation

public struct ImportedTrack: Sendable, Hashable {
    public let title: String
    public let artist: String

    public init(title: String, artist: String = "") {
        self.title = title
        self.artist = artist
    }
}

public struct ParsedImport: Sendable {
    public let title: String
    public let tracks: [ImportedTrack]

    public init(title: String, tracks: [ImportedTrack]) {
        self.title = title
        self.tracks = tracks
    }
}

public enum PlaylistImporterError: LocalizedError {
    case invalidSource
    case emptyPlaylist
    case noMatchesFound
    case fetchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "Could not recognize a valid Spotify URL or tracklist."
        case .emptyPlaylist:
            return "No songs found in the playlist."
        case .noMatchesFound:
            return "None of the tracks could be found on YouTube Music."
        case .fetchFailed(let reason):
            return "Failed to import: \(reason)"
        }
    }
}

public enum PlaylistParser {
    /// Determines if the input looks like a Spotify URL or URI
    public static func isSpotifyURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("spotify.com") || trimmed.hasPrefix("spotify:playlist:")
    }

    /// Extracts the Spotify playlist ID from URL or URI
    public static func extractSpotifyPlaylistId(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("spotify:playlist:") {
            return String(trimmed.dropFirst("spotify:playlist:".count))
        }
        if let match = trimmed.firstMatch(of: #/playlist\/([a-zA-Z0-9]+)/#) {
            return String(match.output.1)
        }
        return nil
    }

    /// Parses either a Spotify URL or raw tracklist text into a playlist name and list of tracks
    public static func parse(input: String, session: URLSession = .shared) async throws -> ParsedImport {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PlaylistImporterError.emptyPlaylist }

        if isSpotifyURL(trimmed), let playlistId = extractSpotifyPlaylistId(from: trimmed) {
            return try await fetchAndParseSpotify(playlistId: playlistId, session: session)
        } else {
            return parseTextTracklist(trimmed)
        }
    }

    /// Fetches and parses Spotify playlist via public embed endpoint without requiring credentials
    public static func fetchAndParseSpotify(playlistId: String, session: URLSession = .shared) async throws -> ParsedImport {
        guard let url = URL(string: "https://open.spotify.com/embed/playlist/\(playlistId)") else {
            throw PlaylistImporterError.invalidSource
        }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            throw PlaylistImporterError.fetchFailed("Could not load Spotify playlist page.")
        }

        return try parseSpotify(html: html)
    }

    /// Parses Spotify embed HTML into a ParsedImport
    public static func parseSpotify(html: String) throws -> ParsedImport {
        var playlistTitle = "Spotify Playlist"
        var tracks: [ImportedTrack] = []

        // 1. Primary: Parse __NEXT_DATA__ JSON
        if let nextDataMatch = html.firstMatch(of: #/(?s)<script id="__NEXT_DATA__"[^>]*>(.*?)<\/script>/#) {
            let jsonString = String(nextDataMatch.output.1)
            if let jsonData = jsonString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let props = json["props"] as? [String: Any],
               let pageProps = props["pageProps"] as? [String: Any],
               let state = pageProps["state"] as? [String: Any],
               let dataObj = state["data"] as? [String: Any],
               let entity = dataObj["entity"] as? [String: Any] {
                if let t = entity["title"] as? String, !t.isEmpty {
                    playlistTitle = t
                }
                if let trackList = entity["trackList"] as? [[String: Any]] {
                    for item in trackList {
                        let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let subtitle = (item["subtitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !title.isEmpty {
                            tracks.append(ImportedTrack(title: title, artist: subtitle))
                        }
                    }
                }
            }
        }

        // 2. Secondary: Fallback to HTML meta and regex scanning
        if tracks.isEmpty {
            if let titleMatch = html.firstMatch(of: #/<meta property="og:title" content="([^"]+)"/#) {
                playlistTitle = String(titleMatch.output.1)
            } else if let titleMatch = html.firstMatch(of: #/<title>([^<]+)<\/title>/#) {
                playlistTitle = String(titleMatch.output.1).replacingOccurrences(of: " | Spotify", with: "")
            }

            let pattern = #/"title":"([^"]+)","subtitle":"([^"]+)"/#
            for match in html.matches(of: pattern) {
                let t = String(match.output.1)
                let s = String(match.output.2)
                if t != playlistTitle && !tracks.contains(where: { $0.title == t && $0.artist == s }) {
                    tracks.append(ImportedTrack(title: t, artist: s))
                }
            }
        }

        guard !tracks.isEmpty else {
            throw PlaylistImporterError.emptyPlaylist
        }

        return ParsedImport(title: playlistTitle, tracks: tracks)
    }

    /// Parses raw text lines (e.g. pasted tracklist)
    public static func parseTextTracklist(_ text: String) -> ParsedImport {
        let lines = text.components(separatedBy: .newlines)
        var tracks: [ImportedTrack] = []

        for rawLine in lines {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // Strip common list bullet formats: "1. ", "01 - ", "[1] ", etc.
            if let stripped = line.firstMatch(of: #/^\s*\[?\d+\]?[\.\:\)\s\-]+\s*(.*)$/#) {
                line = String(stripped.output.1).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !line.isEmpty else { continue }

            // Check " - " separator (Artist - Title or Title - Artist)
            if line.contains(" - ") {
                let parts = line.components(separatedBy: " - ")
                if parts.count >= 2 {
                    let part1 = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let part2 = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    tracks.append(ImportedTrack(title: part2, artist: part1))
                    continue
                }
            }

            // Check " by " separator (Title by Artist)
            if line.contains(" by ") {
                let parts = line.components(separatedBy: " by ")
                if parts.count >= 2 {
                    let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    tracks.append(ImportedTrack(title: title, artist: artist))
                    continue
                }
            }

            // Fallback: whole line is title
            tracks.append(ImportedTrack(title: line, artist: ""))
        }

        return ParsedImport(title: "Imported Playlist", tracks: tracks)
    }
}
