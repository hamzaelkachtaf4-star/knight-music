import Foundation

/// Parsed YouTube values → the domain models stored in GRDB. Every id gets the `yt:` prefix; cover art is the
/// absolute thumbnail URL (ArtworkLoader resizes googleusercontent URLs to the bucket it needs).
enum YouTubeMapping {
    static func song(_ track: YTTrack) -> Song {
        Song(
            id: YouTubeID.make(track.videoId),
            title: track.title,
            album: track.album,
            albumId: track.albumId.map(YouTubeID.make),
            artist: track.artist,
            artistId: track.artistId.map(YouTubeID.make),
            track: track.trackNumber,
            discNumber: track.trackNumber == nil ? nil : 1,
            year: track.year,
            coverArt: track.thumbnailURL,
            contentType: "audio/mp4",
            suffix: "m4a",
            duration: track.durationSeconds,
            bitRate: 128)
    }

    static func album(_ item: YTBrowseItem) -> Album {
        Album(id: YouTubeID.make(item.browseId), name: item.title, artist: item.artist,
              artistId: item.artistId.map(YouTubeID.make), coverArt: item.thumbnailURL, year: item.year)
    }

    static func album(_ page: YTAlbumPage) -> Album {
        Album(id: YouTubeID.make(page.browseId), name: page.title, artist: page.artist,
              artistId: page.artistId.map(YouTubeID.make), coverArt: page.thumbnailURL,
              songCount: page.tracks.count,
              duration: page.tracks.compactMap(\.durationSeconds).reduce(0, +),
              year: page.year)
    }

    static func artist(_ item: YTBrowseItem) -> Artist {
        Artist(id: YouTubeID.make(item.browseId), name: item.title, coverArt: item.thumbnailURL)
    }

    static func artist(_ page: YTArtistPage) -> Artist {
        Artist(id: YouTubeID.make(page.browseId), name: page.name, coverArt: page.thumbnailURL,
               albumCount: page.albums.count + page.singles.count)
    }

    static func playlist(_ item: YTBrowseItem) -> Playlist {
        Playlist(id: YouTubeID.make(item.browseId), name: item.title, comment: item.subtitle, coverArt: item.thumbnailURL)
    }

    static func playlist(_ page: YTPlaylistPage) -> Playlist {
        Playlist(id: YouTubeID.make(page.browseId), name: page.title, owner: page.author,
                 songCount: page.tracks.count,
                 duration: page.tracks.compactMap(\.durationSeconds).reduce(0, +),
                 coverArt: page.thumbnailURL ?? page.tracks.first?.thumbnailURL)
    }

    // MARK: Merging with local state

    /// Catalogue fields come from YouTube; listening state (stars, plays, ratings) stays what the user made it,
    /// and a field YouTube didn't state keeps its stored value.
    static func merge(_ fresh: Song, over stored: Song?) -> Song {
        guard let stored else { return fresh }
        var song = fresh
        song.album = fresh.album ?? stored.album
        song.albumId = fresh.albumId ?? stored.albumId
        song.artist = fresh.artist ?? stored.artist
        song.artistId = fresh.artistId ?? stored.artistId
        song.track = fresh.track ?? stored.track
        song.discNumber = fresh.discNumber ?? stored.discNumber
        song.year = fresh.year ?? stored.year
        song.coverArt = fresh.coverArt ?? stored.coverArt
        song.duration = fresh.duration ?? stored.duration
        song.playCount = stored.playCount
        song.played = stored.played
        song.created = stored.created
        song.starred = stored.starred
        song.userRating = stored.userRating
        return song
    }

    static func merge(_ fresh: Album, over stored: Album?) -> Album {
        guard let stored else { return fresh }
        var album = fresh
        album.artist = fresh.artist ?? stored.artist
        album.artistId = fresh.artistId ?? stored.artistId
        album.coverArt = fresh.coverArt ?? stored.coverArt
        album.year = fresh.year ?? stored.year
        album.songCount = fresh.songCount ?? stored.songCount
        album.duration = fresh.duration ?? stored.duration
        album.playCount = stored.playCount
        album.played = stored.played
        album.created = stored.created
        album.starred = stored.starred
        album.userRating = stored.userRating
        return album
    }

    static func merge(_ fresh: Artist, over stored: Artist?) -> Artist {
        guard let stored else { return fresh }
        var artist = fresh
        artist.coverArt = fresh.coverArt ?? stored.coverArt
        artist.albumCount = fresh.albumCount ?? stored.albumCount
        artist.starred = stored.starred
        return artist
    }
}
