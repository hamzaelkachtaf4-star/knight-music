import Foundation

actor PlaylistImporter {
    static let shared = PlaylistImporter()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Determines if the input looks like a Spotify URL or URI
    static func isSpotifyURL(_ text: String) -> Bool {
        PlaylistParser.isSpotifyURL(text)
    }

    /// Parses either a Spotify URL or raw tracklist text into a playlist name and list of tracks
    func parse(input: String) async throws -> ParsedImport {
        try await PlaylistParser.parse(input: input, session: session)
    }

    /// Matches parsed tracks on YouTube Music and writes them into the local library database
    func matchAndImport(
        parsed: ParsedImport,
        client: YouTubeClient = .shared,
        database: LibraryDatabase,
        onProgress: (@Sendable (Int, Int, String) -> Void)? = nil
    ) async throws -> (playlist: Playlist, songs: [Song]) {
        var matchedSongs: [Song] = []
        let total = parsed.tracks.count

        for (index, track) in parsed.tracks.enumerated() {
            onProgress?(index + 1, total, track.title)
            let query = track.artist.isEmpty ? track.title : "\(track.title) \(track.artist)"
            do {
                let results = try await client.search(query, filter: .songs)
                if let best = results.tracks.first {
                    matchedSongs.append(YouTubeMapping.song(best))
                } else if !track.artist.isEmpty {
                    // Fallback search with title only
                    let fallbackResults = try await client.search(track.title, filter: .songs)
                    if let best = fallbackResults.tracks.first {
                        matchedSongs.append(YouTubeMapping.song(best))
                    }
                }
            } catch {
                // Ignore individual track search errors to continue importing the rest
            }
        }

        guard !matchedSongs.isEmpty else {
            throw PlaylistImporterError.noMatchesFound
        }

        let now = Date()
        let playlist = Playlist(
            id: YouTubeID.newLocalPlaylistId(),
            name: parsed.title,
            comment: "Imported \(matchedSongs.count) songs",
            songCount: matchedSongs.count,
            duration: matchedSongs.reduce(0) { $0 + ($1.duration ?? 0) },
            created: now,
            changed: now,
            coverArt: matchedSongs.first?.coverArt
        )

        try await database.storePlaylist(playlist, songs: matchedSongs)
        return (playlist, matchedSongs)
    }
}
