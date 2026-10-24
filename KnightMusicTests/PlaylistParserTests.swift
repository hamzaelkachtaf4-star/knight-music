import Foundation
import XCTest
#if canImport(KnightMusic)
@testable import KnightMusic
#endif

final class PlaylistParserTests: XCTestCase {
    func testSpotifyURLDetectionAndIdExtraction() {
        let urls = [
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
            "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abcd1234",
            "https://open.spotify.com/intl-fr/playlist/37i9dQZF1DXcBWIGoYBM5M",
            "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"
        ]

        for u in urls {
            XCTAssertTrue(PlaylistParser.isSpotifyURL(u), "Expected true for \(u)")
            XCTAssertEqual(PlaylistParser.extractSpotifyPlaylistId(from: u), "37i9dQZF1DXcBWIGoYBM5M")
        }

        XCTAssertFalse(PlaylistParser.isSpotifyURL("https://youtube.com/watch?v=123"))
        XCTAssertFalse(PlaylistParser.isSpotifyURL("Artist - Title"))
    }

    func testParseTextTracklist() {
        let text = """
        1. Pink Floyd - Comfortably Numb
        2. Hotel California by Eagles
        03 - Bohemian Rhapsody - Queen
        [4] Stairway to Heaven - Led Zeppelin
        Simple Title Only
        """

        let parsed = PlaylistParser.parseTextTracklist(text)
        XCTAssertEqual(parsed.tracks.count, 5)

        XCTAssertEqual(parsed.tracks[0].title, "Comfortably Numb")
        XCTAssertEqual(parsed.tracks[0].artist, "Pink Floyd")

        XCTAssertEqual(parsed.tracks[1].title, "Hotel California")
        XCTAssertEqual(parsed.tracks[1].artist, "Eagles")

        XCTAssertEqual(parsed.tracks[2].title, "Queen")
        XCTAssertEqual(parsed.tracks[2].artist, "Bohemian Rhapsody")

        XCTAssertEqual(parsed.tracks[3].title, "Led Zeppelin")
        XCTAssertEqual(parsed.tracks[3].artist, "Stairway to Heaven")

        XCTAssertEqual(parsed.tracks[4].title, "Simple Title Only")
    }

    func testParseSpotifyEmbedHTML() throws {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><title>Hits 2024 | Spotify</title></head>
        <body>
        <script id="__NEXT_DATA__" type="application/json">
        {
          "props": {
            "pageProps": {
              "state": {
                "data": {
                  "entity": {
                    "title": "Summer Vibes 2024",
                    "trackList": [
                      { "title": "Espresso", "subtitle": "Sabrina Carpenter" },
                      { "title": "Birds of a Feather", "subtitle": "Billie Eilish" }
                    ]
                  }
                }
              }
            }
          }
        }
        </script>
        </body>
        </html>
        """

        let parsed = try PlaylistParser.parseSpotify(html: html)
        XCTAssertEqual(parsed.title, "Summer Vibes 2024")
        XCTAssertEqual(parsed.tracks.count, 2)
        XCTAssertEqual(parsed.tracks[0].title, "Espresso")
        XCTAssertEqual(parsed.tracks[0].artist, "Sabrina Carpenter")
        XCTAssertEqual(parsed.tracks[1].title, "Birds of a Feather")
        XCTAssertEqual(parsed.tracks[1].artist, "Billie Eilish")
    }
}
