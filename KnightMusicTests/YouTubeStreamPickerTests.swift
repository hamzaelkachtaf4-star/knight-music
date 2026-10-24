import XCTest
#if canImport(KnightMusic)
@testable import KnightMusic
#endif

final class YouTubeStreamPickerTests: XCTestCase {
    func testPicksDirectAACOverOpusAndVideo() throws {
        let response = YouTubeStreamPicker.playerResponse(try Fixture.json("player_android_vr.json"))
        XCTAssertTrue(response.isPlayable)
        XCTAssertEqual(response.durationSeconds, 213)
        XCTAssertEqual(response.expiresInSeconds, 21540)
        XCTAssertEqual(response.loudnessDb, -1.5)
        XCTAssertEqual(response.formats.map(\.itag), [139, 140, 251])

        let best = try XCTUnwrap(YouTubeStreamPicker.bestAudio(response.formats, maxBitrate: nil))
        XCTAssertEqual(best.itag, 140)
        XCTAssertEqual(best.contentLength, 3_449_447)
        XCTAssertTrue(best.isAAC)
        XCTAssertNotNil(best.url)
    }

    func testBitrateCeilingPicksLowerAACRung() throws {
        let response = YouTubeStreamPicker.playerResponse(try Fixture.json("player_android_vr.json"))
        XCTAssertEqual(YouTubeStreamPicker.bestAudio(response.formats, maxBitrate: 64_000)?.itag, 139)
        // Everything over budget: the cheapest still beats silence.
        XCTAssertEqual(YouTubeStreamPicker.bestAudio(response.formats, maxBitrate: 10_000)?.itag, 139)
    }

    func testSabrOnlyResponseHasNoDirectStreamButOffersHLS() throws {
        let response = YouTubeStreamPicker.playerResponse(try Fixture.json("player_ios_sabr.json"))
        XCTAssertTrue(response.isPlayable)
        XCTAssertNil(YouTubeStreamPicker.bestAudio(response.formats, maxBitrate: nil))
        XCTAssertEqual(response.hlsManifestURL?.host, "manifest.googlevideo.com")
    }

    func testUnplayableCarriesReason() throws {
        let response = YouTubeStreamPicker.playerResponse(try Fixture.json("player_unplayable.json"))
        XCTAssertFalse(response.isPlayable)
        XCTAssertEqual(response.status, "LOGIN_REQUIRED")
        XCTAssertEqual(response.reason, "Sign in to confirm your age")
        XCTAssertTrue(response.formats.isEmpty)
    }

    func testHLSMasterPrefersAACLCAudioRendition() throws {
        let url = YouTubeStreamPicker.hlsAudioPlaylist(fromMaster: try Fixture.string("hls_master.m3u8"))
        XCTAssertEqual(url?.absoluteString, "https://manifest.googlevideo.com/api/manifest/hls_playlist/id/test/itag/234/playlist/index.m3u8")
    }

    func testHLSMasterWithoutAudioMedia() {
        XCTAssertNil(YouTubeStreamPicker.hlsAudioPlaylist(fromMaster: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nhttps://x/v.m3u8\n"))
        XCTAssertNil(YouTubeStreamPicker.hlsAudioPlaylist(fromMaster: ""))
    }

    func testMalformedPlayerResponse() {
        let response = YouTubeStreamPicker.playerResponse(["streamingData": ["adaptiveFormats": [["itag": "x"]]]])
        XCTAssertFalse(response.isPlayable)
        XCTAssertTrue(response.formats.isEmpty)
    }
}
