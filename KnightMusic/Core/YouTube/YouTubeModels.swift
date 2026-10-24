import Foundation

// Plain values parsed out of Innertube responses. Foundation-only so the parser is testable without the
// app; `YouTubeMapping` turns them into the domain models stored in GRDB.

struct YTTrack: Hashable, Codable, Sendable {
    var videoId: String
    var title: String
    var artist: String?
    var artistId: String?
    var album: String?
    var albumId: String?
    var durationSeconds: Int?
    var thumbnailURL: String?
    var trackNumber: Int?
    var year: Int?
    var isExplicit = false
    var isVideo = false
}

enum YTBrowseKind: String, Hashable, Codable, Sendable {
    case album, artist, playlist, other
}

struct YTBrowseItem: Hashable, Codable, Sendable {
    var browseId: String
    var title: String
    var subtitle: String
    var thumbnailURL: String?
    var kind: YTBrowseKind
    var artist: String?
    var artistId: String?
    var year: Int?
}

struct YTSearchResults: Sendable {
    var tracks: [YTTrack] = []
    var albums: [YTBrowseItem] = []
    var artists: [YTBrowseItem] = []
    var playlists: [YTBrowseItem] = []

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty }
}

struct YTAlbumPage: Sendable {
    var browseId: String
    var title: String
    var artist: String?
    var artistId: String?
    var year: Int?
    var thumbnailURL: String?
    var tracks: [YTTrack]
}

struct YTArtistPage: Sendable {
    var browseId: String
    var name: String
    var thumbnailURL: String?
    var about: String?
    var topTracks: [YTTrack]
    var albums: [YTBrowseItem]
    var singles: [YTBrowseItem]
}

struct YTPlaylistPage: Sendable {
    var browseId: String
    var title: String
    var author: String?
    var thumbnailURL: String?
    var tracks: [YTTrack]
    var continuation: String?
}

enum YTShelfItem: Hashable, Codable, Sendable {
    case track(YTTrack)
    case browse(YTBrowseItem)
}

struct YTHomeShelf: Hashable, Codable, Sendable {
    var title: String
    var items: [YTShelfItem]
}
