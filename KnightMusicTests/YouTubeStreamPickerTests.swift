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

    func testPermanentVerdictsAreOnlyAboutTheSong() {
        func response(_ status: String, _ reason: String?) -> YTPlayerResponse {
            YTPlayerResponse(status: status, reason: reason, formats: [], hlsManifestURL: nil, expiresInSeconds: nil, durationSeconds: nil, loudnessDb: nil)
        }
        XCTAssertNotNil(YouTubeStreamPicker.permanentReason(response("LOGIN_REQUIRED", "Sign in to confirm your age")))
        XCTAssertNotNil(YouTubeStreamPicker.permanentReason(response("UNPLAYABLE", "The uploader has not made this video available in your country")))
        XCTAssertNotNil(YouTubeStreamPicker.permanentReason(response("ERROR", "This video has been removed by the uploader")))
        XCTAssertNotNil(YouTubeStreamPicker.permanentReason(response("LOGIN_REQUIRED", "This video is private")))
        // About the client or the network, not the song: never remembered.
        XCTAssertNil(YouTubeStreamPicker.permanentReason(response("LOGIN_REQUIRED", "Sign in to confirm you’re not a bot")))
        XCTAssertNil(YouTubeStreamPicker.permanentReason(response("LOGIN_REQUIRED", "Please sign in")))
        XCTAssertNil(YouTubeStreamPicker.permanentReason(response("UNPLAYABLE", nil)))
        XCTAssertNil(YouTubeStreamPicker.permanentReason(response("OK", "anything")))
    }

    func testMintingClientFromQueryAndPath() throws {
        let query = try XCTUnwrap(URL(string: "https://rr1---sn-x.googlevideo.com/videoplayback?itag=140&c=ANDROID_VR&cver=1.65.10&clen=1"))
        XCTAssertEqual(YouTubeStreamPicker.mintingClient(of: query)?.name, "ANDROID_VR")
        XCTAssertEqual(YouTubeStreamPicker.mintingClient(of: query)?.version, "1.65.10")
        let path = try XCTUnwrap(URL(string: "https://rr1---sn-x.googlevideo.com/videoplayback/id/1/itag/234/c/IOS/cver/21.29.1/file/seg.ts"))
        XCTAssertEqual(YouTubeStreamPicker.mintingClient(of: path)?.name, "IOS")
        XCTAssertEqual(YouTubeStreamPicker.mintingClient(of: path)?.version, "21.29.1")
        let bare = try XCTUnwrap(URL(string: "https://pipedproxy.example/videoplayback?itag=140"))
        XCTAssertNil(YouTubeStreamPicker.mintingClient(of: bare))
    }

    func testChunkingAndLengthFromURL() throws {
        let direct = try XCTUnwrap(URL(string: "https://rr1---sn-x.googlevideo.com/videoplayback?itag=140&clen=3449447"))
        XCTAssertTrue(YouTubeStream.needsChunking(direct))
        XCTAssertEqual(YouTubeStream.contentLength(of: direct), 3_449_447)
        let hls = try XCTUnwrap(URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/id/x/itag/234/playlist/index.m3u8"))
        XCTAssertFalse(YouTubeStream.needsChunking(hls))
        XCTAssertNil(YouTubeStream.contentLength(of: hls))
        XCTAssertFalse(YouTubeStream.needsChunking(try XCTUnwrap(URL(string: "https://music.example.com/rest/stream?id=1"))))
    }
}
