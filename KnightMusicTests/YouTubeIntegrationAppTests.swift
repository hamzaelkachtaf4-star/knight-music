import XCTest
#if canImport(KnightMusic)
@testable import KnightMusic
#endif

/// Tests that need app types (GRDB models, Nuke, the lyrics timeline). CI only; `scripts/core-tests.sh`
/// skips `*AppTests.swift`.
final class YouTubeIntegrationAppTests: XCTestCase {
    // MARK: Lyrics pipeline → LyricsView's timeline

    func testWordTimedLineRoundTripsThroughTheTimeline() throws {
        let document = try XCTUnwrap(TtmlParser.parse(try Fixture.string("lyrics_word.ttml")))
        let structured = LyricsService.structured(document)
        XCTAssertTrue(structured.synced)
        XCTAssertEqual(structured.line.first?.start, 12_000)

        let identified = IdentifiedLyricLine(id: 0, line: try XCTUnwrap(structured.line.first))
        XCTAssertEqual(identified.text, "Morning comes enough,")
        XCTAssertEqual(identified.words.map(\.start), [12_000, 12_400, 12_700, 13_100])
        XCTAssertEqual(identified.words.map(\.text).joined(), "Morning comes enough,")
        XCTAssertEqual(identified.endMs, 13_600)
    }

    func testLineTimedLyricsStayPlainText() throws {
        let document = try XCTUnwrap(TtmlParser.parse(try Fixture.string("lyrics_line.ttml")))
        let structured = LyricsService.structured(document)
        XCTAssertTrue(structured.synced)
        XCTAssertEqual(structured.line.map(\.value), ["First line of the verse", "Second line & more"])
        let identified = IdentifiedLyricLine(id: 0, line: structured.line[0])
        XCTAssertTrue(identified.words.isEmpty)
        XCTAssertNil(identified.endMs)
    }

    func testPlainLyricsAreUnsynced() throws {
        let structured = LyricsService.structured(try XCTUnwrap(LrcParser.plain("One\nTwo")))
        XCTAssertFalse(structured.synced)
        XCTAssertEqual(structured.line.map(\.start), [nil, nil])
    }

    // MARK: Mapping into the mirror

    func testMappingPrefixesEveryId() {
        let track = YTTrack(videoId: "abc", title: "Song", artist: "Artist", artistId: "UC1", album: "Album", albumId: "MPRE1",
                            durationSeconds: 200, thumbnailURL: "https://lh3.googleusercontent.com/x=w60-h60", trackNumber: 3)
        let song = YouTubeMapping.song(track)
        XCTAssertEqual(song.id, "yt:abc")
        XCTAssertEqual(song.artistId, "yt:UC1")
        XCTAssertEqual(song.albumId, "yt:MPRE1")
        XCTAssertEqual(song.track, 3)
        XCTAssertEqual(song.suffix, "m4a")
        XCTAssertEqual(song.duration, 200)
    }

    func testMergeKeepsListeningStateAndFillsGaps() {
        var stored = YouTubeMapping.song(YTTrack(videoId: "abc", title: "Old title", album: "Album", albumId: "MPRE1", durationSeconds: 200))
        let starred = Date(timeIntervalSince1970: 1_700_000_000)
        stored.starred = starred
        stored.playCount = 7
        stored.userRating = 4
        // A radio row knows less (no album) but has a fresher title.
        let fresh = YouTubeMapping.song(YTTrack(videoId: "abc", title: "New title"))
        let merged = YouTubeMapping.merge(fresh, over: stored)
        XCTAssertEqual(merged.title, "New title")
        XCTAssertEqual(merged.album, "Album")
        XCTAssertEqual(merged.albumId, "yt:MPRE1")
        XCTAssertEqual(merged.duration, 200)
        XCTAssertEqual(merged.starred, starred)
        XCTAssertEqual(merged.playCount, 7)
        XCTAssertEqual(merged.userRating, 4)
        XCTAssertEqual(YouTubeMapping.merge(fresh, over: nil).title, "New title")
    }

    func testLocalPlaylistIdsAreProtectedFromSyncAndYouTube() {
        let id = YouTubeID.newLocalPlaylistId()
        XCTAssertTrue(YouTubeID.isYouTube(id))
        XCTAssertTrue(YouTubeID.isLocalPlaylist(id))
        XCTAssertFalse(YouTubeID.isLocalPlaylist("yt:VLPL123"))
        XCTAssertNotEqual(id, YouTubeID.newLocalPlaylistId())
    }

    // MARK: Artwork

    func testDirectArtworkURLs() {
        XCTAssertEqual(ArtworkLoader.directURL("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj", size: 300)?.absoluteString,
                       "https://lh3.googleusercontent.com/abc=w300-h300-l90-rj")
        XCTAssertEqual(ArtworkLoader.directURL("https://yt3.googleusercontent.com/abc", size: 120)?.absoluteString,
                       "https://yt3.googleusercontent.com/abc=w120-h120-l90-rj")
        XCTAssertEqual(ArtworkLoader.directURL("https://i.ytimg.com/vi/x/hqdefault.jpg", size: 300)?.absoluteString,
                       "https://i.ytimg.com/vi/x/hqdefault.jpg")
        XCTAssertNil(ArtworkLoader.directURL("al-4f2c", size: 300))
    }
}
