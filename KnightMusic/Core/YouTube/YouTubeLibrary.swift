import Foundation
import GRDB
import Observation

/// YouTube Music as a library source. Search results are shown straight from the network; anything the user
/// opens, plays or likes is written into the local GRDB mirror, so the existing album / artist / playlist
/// screens, favourites, lyrics and offline playback work on it unchanged (CLAUDE.md: the network feeds the
/// mirror, the UI reads the mirror).
@MainActor @Observable
final class YouTubeLibrary {
    /// The Home feed, cached in the mirror so it shows instantly (and offline) on the next launch.
    private(set) var homeShelves: [YTHomeShelf] = []
    private(set) var isLoadingHome = false

    @ObservationIgnored private let client: YouTubeClient
    @ObservationIgnored private weak var library: LibraryRepository?
    @ObservationIgnored private var refreshing = Set<String>()
    @ObservationIgnored private var loadedHomeFor: ObjectIdentifier?

    private static let pageTTL: TimeInterval = 3 * 86400
    private static let homeTTL: TimeInterval = 3 * 3600

    init(client: YouTubeClient = .shared) {
        self.client = client
    }

    func configure(library: LibraryRepository) {
        self.library = library
    }

    private var database: LibraryDatabase? { library?.database }

    // MARK: Search

    func search(_ query: String, scope: YouTubeSearchScope) async throws -> YTSearchResults {
        switch scope {
        case .top: return try await client.search(query)
        case .songs: return try await client.search(query, filter: .songs)
        case .albums: return try await client.search(query, filter: .albums)
        case .artists: return try await client.search(query, filter: .artists)
        case .playlists: return try await client.search(query, filter: .playlists)
        }
    }

    func suggestions(_ input: String) async -> [String] {
        (try? await client.suggestions(input)) ?? []
    }

    // MARK: Playback

    /// Writes the tracks into the mirror (keeping stars and play counts) and returns them as playable songs.
    @discardableResult
    func songsForPlayback(_ tracks: [YTTrack]) async -> [Song] {
        let fresh = tracks.filter { !$0.isVideo }.map(YouTubeMapping.song)
        return await store(songs: fresh)
    }

    /// YouTube Music's radio after `song`, stored so the queue survives a relaunch.
    func radio(after song: Song, count: Int) async throws -> [Song] {
        guard let videoId = YouTubeID.raw(song.id) else { return [] }
        let tracks = try await client.radio(after: videoId).filter { $0.videoId != videoId && !$0.isVideo }
        return await store(songs: Array(tracks.prefix(count)).map(YouTubeMapping.song))
    }

    // MARK: Opening items (seed instantly from what the card showed, then fill from the network)

    func seed(_ item: YTBrowseItem) async {
        guard let database else { return }
        do {
            try await database.pool.write { db in
                switch item.kind {
                case .album:
                    let fresh = YouTubeMapping.album(item)
                    try YouTubeMapping.merge(fresh, over: try Album.fetchOne(db, key: fresh.id)).save(db)
                case .artist:
                    let fresh = YouTubeMapping.artist(item)
                    try YouTubeMapping.merge(fresh, over: try Artist.fetchOne(db, key: fresh.id)).save(db)
                case .playlist:
                    let fresh = YouTubeMapping.playlist(item)
                    if try Playlist.fetchOne(db, key: fresh.id) == nil { try fresh.insert(db) }
                case .other:
                    break
                }
            }
        } catch {
            Log.database.warning("Seeding YouTube \(item.kind.rawValue) \(item.browseId) failed: \(error)")
        }
    }

    /// Fetches album `id` (`yt:MPRE…`) into the mirror unless it was fetched recently.
    func ensureAlbum(_ id: String, force: Bool = false) async {
        guard let browseId = YouTubeID.raw(id), let database, begin(id, force: force, database: database) else { return }
        defer { refreshing.remove(id) }
        do {
            let page = try await client.album(browseId)
            let songs = page.tracks.map(YouTubeMapping.song)
            try await database.pool.write { db in
                let album = YouTubeMapping.album(page)
                try YouTubeMapping.merge(album, over: try Album.fetchOne(db, key: album.id)).save(db)
                if let artistId = album.artistId, let name = album.artist, try Artist.fetchOne(db, key: artistId) == nil {
                    try Artist(id: artistId, name: name).insert(db)
                }
                for song in songs { try YouTubeMapping.merge(song, over: try Song.fetchOne(db, key: song.id)).save(db) }
            }
            await database.setStateValue(String(Date().timeIntervalSince1970), for: Self.stateKey(id))
        } catch {
            report(error, "Couldn’t load this album from YouTube Music")
        }
    }

    /// Fetches artist `id` (`yt:UC…`): the artist row, top songs and their albums and singles.
    func ensureArtist(_ id: String, force: Bool = false) async {
        guard let browseId = YouTubeID.raw(id), let database, begin(id, force: force, database: database) else { return }
        defer { refreshing.remove(id) }
        do {
            let page = try await client.artist(browseId)
            let top = page.topTracks.map(YouTubeMapping.song)
            let albums = (page.albums + page.singles).map(YouTubeMapping.album)
            try await database.pool.write { db in
                let artist = YouTubeMapping.artist(page)
                try YouTubeMapping.merge(artist, over: try Artist.fetchOne(db, key: artist.id)).save(db)
                for album in albums { try YouTubeMapping.merge(album, over: try Album.fetchOne(db, key: album.id)).save(db) }
                for song in top { try YouTubeMapping.merge(song, over: try Song.fetchOne(db, key: song.id)).save(db) }
                try db.execute(sql: "DELETE FROM topSong WHERE artistId = ?", arguments: [artist.id])
                for (index, song) in top.enumerated() {
                    try db.execute(sql: "INSERT INTO topSong(artistId, position, songId) VALUES (?, ?, ?)",
                                   arguments: [artist.id, index, song.id])
                }
                if let about = page.about,
                   let data = try? JSONEncoder().encode(ArtistInfo(biography: about, largeImageUrl: page.thumbnailURL)),
                   let json = String(data: data, encoding: .utf8) {
                    try db.execute(sql: """
                        INSERT INTO artistInfo(artistId, json, fetchedAt) VALUES (?, ?, ?)
                        ON CONFLICT(artistId) DO UPDATE SET json = excluded.json, fetchedAt = excluded.fetchedAt
                        """, arguments: [artist.id, json, Date()])
                }
            }
            await database.setStateValue(String(Date().timeIntervalSince1970), for: Self.stateKey(id))
        } catch {
            report(error, "Couldn’t load this artist from YouTube Music")
        }
    }

    /// Fetches playlist `id` (`yt:VL…`) and its tracks. YouTube playlists are read-only here.
    func ensurePlaylist(_ id: String, force: Bool = false) async {
        guard !YouTubeID.isLocalPlaylist(id), let browseId = YouTubeID.raw(id), let database,
              begin(id, force: force, database: database) else { return }
        defer { refreshing.remove(id) }
        do {
            let page = try await client.playlist(browseId)
            let songs = await store(songs: page.tracks.filter { !$0.isVideo }.map(YouTubeMapping.song))
            try await database.storePlaylist(YouTubeMapping.playlist(page), songs: songs)
            await database.setStateValue(String(Date().timeIntervalSince1970), for: Self.stateKey(id))
        } catch {
            report(error, "Couldn’t load this playlist from YouTube Music")
        }
    }

    // MARK: Home

    /// Shows the cached feed immediately, then refreshes it when stale (or when `force`).
    func loadHome(force: Bool = false) async {
        guard let database else { return }
        let databaseId = ObjectIdentifier(database)
        if loadedHomeFor != databaseId {
            loadedHomeFor = databaseId
            homeShelves = []
            if let raw = await database.stateValue(Self.homeKey), let data = raw.data(using: .utf8),
               let cached = try? JSONDecoder().decode(CachedHome.self, from: data) {
                homeShelves = cached.shelves
                if !force, Date().timeIntervalSince(cached.fetchedAt) < Self.homeTTL { return }
            }
        } else if !force, !homeShelves.isEmpty {
            return
        }
        guard !isLoadingHome else { return }
        isLoadingHome = true
        defer { isLoadingHome = false }
        do {
            let shelves = try await client.home()
            guard ObjectIdentifier(database) == loadedHomeFor else { return }
            homeShelves = shelves
            if let data = try? JSONEncoder().encode(CachedHome(fetchedAt: Date(), shelves: shelves)),
               let json = String(data: data, encoding: .utf8) {
                await database.setStateValue(json, for: Self.homeKey)
            }
        } catch {
            if homeShelves.isEmpty { report(error, "Couldn’t load YouTube Music") }
            Log.network.warning("YouTube home failed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    private struct CachedHome: Codable {
        var fetchedAt: Date
        var shelves: [YTHomeShelf]
    }

    private static let homeKey = "yt.home"
    private static func stateKey(_ id: String) -> String { "yt.fetched.\(id)" }

    /// Claims a refresh of `id`: false when one is running or the stored copy is fresh enough.
    private func begin(_ id: String, force: Bool, database: LibraryDatabase) -> Bool {
        guard !refreshing.contains(id) else { return false }
        refreshing.insert(id)
        guard !force else { return true }
        // Freshness is checked synchronously from a cached read to keep the claim atomic on the main actor.
        if let fetched = try? database.pool.read({ db in
            try String.fetchOne(db, sql: "SELECT value FROM syncState WHERE key = ?", arguments: [Self.stateKey(id)])
        }), let at = TimeInterval(fetched), Date().timeIntervalSince1970 - at < Self.pageTTL {
            refreshing.remove(id)
            return false
        }
        return true
    }

    private func store(songs fresh: [Song]) async -> [Song] {
        guard let database, !fresh.isEmpty else { return fresh }
        do {
            return try await database.pool.write { db in
                try fresh.map { song in
                    let merged = YouTubeMapping.merge(song, over: try Song.fetchOne(db, key: song.id))
                    try merged.save(db)
                    return merged
                }
            }
        } catch {
            Log.database.warning("Storing \(fresh.count) YouTube songs failed: \(error)")
            return fresh
        }
    }

    private func report(_ error: Error, _ prefix: String) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        library?.report(error, prefix)
    }
}

/// What the YouTube Music half of Search asks for.
enum YouTubeSearchScope: Sendable {
    case top, songs, albums, artists, playlists
}
