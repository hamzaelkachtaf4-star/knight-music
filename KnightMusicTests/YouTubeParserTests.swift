import XCTest
#if canImport(KnightMusic)
@testable import KnightMusic
#endif

final class YouTubeParserTests: XCTestCase {
    func testDurationText() {
        XCTAssertEqual(YouTubeParser.duration("5:38"), 338)
        XCTAssertEqual(YouTubeParser.duration("1:02:03"), 3723)
        XCTAssertEqual(YouTubeParser.duration("0:07"), 7)
        XCTAssertNil(YouTubeParser.duration(""))
        XCTAssertNil(YouTubeParser.duration("Daft Punk"))
        XCTAssertNil(YouTubeParser.duration("12"))
    }

    func testSearchAllSplitsKindsAndCreditsCardRows() throws {
        let results = YouTubeParser.search(try Fixture.json("yt_search_all.json"))

        let crush = try XCTUnwrap(results.tracks.first { $0.videoId == "khnokW3Mw24" })
        XCTAssertEqual(crush.title, "Instant Crush (feat. Julian Casablancas)")
        // The row itself says only "Song • 5:38"; the artist comes from the promoted artist card.
        XCTAssertEqual(crush.artist, "Daft Punk")
        XCTAssertEqual(crush.artistId, "UCRr1xG_2WIDs18a6cIiCxeA")
        XCTAssertEqual(crush.durationSeconds, 338)
        XCTAssertFalse(crush.isVideo)

        let artist = try XCTUnwrap(results.artists.first { $0.browseId == "UClYV6hHlupm_S_ObS1W-DYw" })
        XCTAssertEqual(artist.title, "The Weeknd")
        XCTAssertEqual(artist.kind, .artist)
        XCTAssertTrue(results.artists.contains { $0.browseId == "UCRr1xG_2WIDs18a6cIiCxeA" && $0.title == "Daft Punk" })

        let album = try XCTUnwrap(results.albums.first { $0.browseId == "MPREb_HzuPxNo8aRW" })
        XCTAssertEqual(album.title, "Daft Punk Is Playing at My House")
        XCTAssertEqual(album.artist, "LCD Soundsystem")
        XCTAssertEqual(album.year, 2005)

        XCTAssertTrue(results.playlists.contains { $0.browseId == "VLPLZ0oqv-_vPEM" })
        XCTAssertFalse(results.tracks.contains { $0.isVideo })
        // Every row lands once.
        XCTAssertEqual(Set(results.tracks.map(\.videoId)).count, results.tracks.count)
    }

    func testSongsSearchReadsCreditsAlbumAndDuration() throws {
        let results = YouTubeParser.search(try Fixture.json("yt_search_songs.json"))
        let first = try XCTUnwrap(results.tracks.first)
        XCTAssertEqual(first.videoId, "J7p4bzqLvCw")
        XCTAssertEqual(first.title, "Blinding Lights")
        XCTAssertEqual(first.artist, "The Weeknd")
        XCTAssertEqual(first.artistId, "UClYV6hHlupm_S_ObS1W-DYw")
        XCTAssertEqual(first.album, "Blinding Lights")
        XCTAssertEqual(first.albumId, "MPREb_4U7yfKKFZLv")
        XCTAssertEqual(first.durationSeconds, 202)
        XCTAssertNotNil(first.thumbnailURL)
        XCTAssertGreaterThan(results.tracks.count, 5)
    }

    func testAlbumsSearch() throws {
        let results = YouTubeParser.search(try Fixture.json("yt_search_albums.json"))
        let first = try XCTUnwrap(results.albums.first)
        XCTAssertEqual(first.browseId, "MPREb_UeLZeVoLffq")
        XCTAssertEqual(first.title, "Daft Punk Is Not Dead Yet")
        XCTAssertEqual(first.artist, "Skathi")
        XCTAssertEqual(first.year, 2021)
    }

    func testAlbumPageTracksInheritHeaderCredit() throws {
        let page = try XCTUnwrap(YouTubeParser.album(try Fixture.json("yt_album_multi.json"), browseId: "MPREb_K8qWMWVqXGi"))
        XCTAssertEqual(page.title, "Random Access Memories")
        XCTAssertEqual(page.artist, "Daft Punk")
        XCTAssertEqual(page.year, 2013)
        XCTAssertNotNil(page.thumbnailURL)
        XCTAssertEqual(page.tracks.count, 13)

        let first = page.tracks[0]
        XCTAssertEqual(first.videoId, "IluRBvnYMoY")
        XCTAssertEqual(first.title, "Give Life Back to Music")
        XCTAssertEqual(first.trackNumber, 1)
        XCTAssertEqual(first.artist, "Daft Punk")
        XCTAssertEqual(first.album, "Random Access Memories")
        XCTAssertEqual(first.albumId, "MPREb_K8qWMWVqXGi")
        XCTAssertNotNil(first.durationSeconds)
        XCTAssertEqual(page.tracks.map(\.trackNumber), Array(1...13))
    }

    func testSingleAlbumPage() throws {
        let page = try XCTUnwrap(YouTubeParser.album(try Fixture.json("yt_album.json"), browseId: "MPREb_HzuPxNo8aRW"))
        XCTAssertEqual(page.title, "Daft Punk Is Playing at My House")
        XCTAssertEqual(page.artist, "LCD Soundsystem")
        XCTAssertEqual(page.year, 2005)
        XCTAssertEqual(page.tracks.count, 1)
        XCTAssertEqual(page.tracks.first?.durationSeconds, 202)
        XCTAssertEqual(page.tracks.first?.artist, "LCD Soundsystem")
    }

    func testArtistPage() throws {
        let page = try XCTUnwrap(YouTubeParser.artist(try Fixture.json("yt_artist.json"), browseId: "UClYV6hHlupm_S_ObS1W-DYw"))
        XCTAssertEqual(page.name, "The Weeknd")
        XCTAssertEqual(page.topTracks.count, 5)
        XCTAssertTrue(page.topTracks.allSatisfy { !$0.videoId.isEmpty && !$0.title.isEmpty })
        XCTAssertFalse(page.albums.isEmpty)
        XCTAssertTrue(page.albums.allSatisfy { $0.browseId.hasPrefix("MPRE") })
        XCTAssertFalse(page.singles.isEmpty)
        XCTAssertNotNil(page.thumbnailURL)
    }

    func testWatchQueueParsesRadio() throws {
        let tracks = YouTubeParser.watchQueue(try Fixture.json("yt_next.json"))
        XCTAssertEqual(tracks.count, 50)
        XCTAssertEqual(tracks[0].videoId, "khnokW3Mw24")
        XCTAssertEqual(tracks[0].artist, "Daft Punk & Julian Casablancas")
        XCTAssertEqual(tracks[0].album, "Random Access Memories")
        XCTAssertEqual(tracks[0].year, 2013)
        XCTAssertEqual(tracks[0].durationSeconds, 338)
        XCTAssertEqual(tracks[1].title, "Get Lucky (feat. Pharrell Williams and Nile Rodgers)")
    }

    func testPlaylistPage() throws {
        let page = try XCTUnwrap(YouTubeParser.playlist(try Fixture.json("yt_playlist.json"), browseId: "VLPLZ0oqv-_vPEM"))
        XCTAssertEqual(page.title, "Daft Punk")
        XCTAssertEqual(page.tracks.map(\.title).prefix(3), ["Get Lucky (feat. Pharrell Williams and Nile Rodgers)", "Voyager", "Around the World"])
        XCTAssertTrue(page.tracks.allSatisfy { $0.artist?.isEmpty == false })
    }

    func testHomeShelves() throws {
        let shelves = YouTubeParser.home(try Fixture.json("yt_home.json"))
        let quick = try XCTUnwrap(shelves.first { $0.title == "Quick picks" })
        XCTAssertEqual(quick.items.count, 20)
        guard case .track(let track) = quick.items[0] else { return XCTFail("quick picks should be tracks") }
        XCTAssertFalse(track.videoId.isEmpty)
        let hits = try XCTUnwrap(shelves.first { $0.title == "Today's hits" })
        guard case .browse(let item) = hits.items[0] else { return XCTFail("Today's hits should be browse cards") }
        XCTAssertEqual(item.title, "Hits of 2026 (So Far)")
    }

    func testSuggestions() throws {
        let list = YouTubeParser.suggestions(try Fixture.json("yt_suggestions.json"))
        XCTAssertEqual(Array(list.prefix(3)), ["daft punk", "daft punk instant crush", "daft punk veridis quo"])
    }

    func testMalformedInputsYieldNothing() {
        XCTAssertTrue(YouTubeParser.search([:]).isEmpty)
        XCTAssertNil(YouTubeParser.album([:], browseId: "x"))
        XCTAssertNil(YouTubeParser.artist(["header": "nope"], browseId: "x"))
        XCTAssertTrue(YouTubeParser.watchQueue(["contents": [1, 2, 3]]).isEmpty)
        XCTAssertTrue(YouTubeParser.home([:]).isEmpty)
    }

    func testYouTubeIDs() {
        XCTAssertEqual(YouTubeID.make("abc"), "yt:abc")
        XCTAssertEqual(YouTubeID.make("yt:abc"), "yt:abc")
        XCTAssertEqual(YouTubeID.raw("yt:abc"), "abc")
        XCTAssertNil(YouTubeID.raw("yt:"))
        XCTAssertNil(YouTubeID.raw("navidrome-id"))
        XCTAssertNil(YouTubeID.raw(nil))
        XCTAssertTrue(YouTubeID.isYouTube("yt:MPREb_1"))
        XCTAssertFalse(YouTubeID.isYouTube("4f2c"))
    }
}
