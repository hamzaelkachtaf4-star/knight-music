import XCTest
#if canImport(KnightMusic)
@testable import KnightMusic
#endif

final class YouTubeAuthTests: XCTestCase {
    private func session(_ cookies: [String: String], authUser: String = "0") -> YouTubeSessionData {
        YouTubeSessionData(cookies: cookies, authUser: authUser, visitorData: nil, account: nil)
    }

    // MARK: SAPISIDHASH and headers

    func testSapisidHashIsSha1OfTimestampSapisidOrigin() {
        // printf '1700000000 abc/123 https://music.youtube.com' | sha1sum
        XCTAssertEqual(YouTubeAuth.sapisidHash(sapisid: "abc/123", origin: "https://music.youtube.com", timestamp: 1_700_000_000),
                       "149e3c5c81746e107a88a2e0103de8a4b63040a3")
    }

    func testAuthorizationHeaderShape() {
        let value = YouTubeAuth.authorization(sapisid: "s", origin: YouTubeAuth.musicOrigin, now: Date(timeIntervalSince1970: 42))
        XCTAssertTrue(value.hasPrefix("SAPISIDHASH 42_"))
        XCTAssertEqual(value.count, "SAPISIDHASH 42_".count + 40)
    }

    func testSapisidFallsBackToSecure3PAPISID() {
        XCTAssertEqual(YouTubeAuth.sapisid(in: ["__Secure-3PAPISID": "x"]), "x")
        XCTAssertEqual(YouTubeAuth.sapisid(in: ["SAPISID": "a", "__Secure-3PAPISID": "x"]), "a")
        XCTAssertNil(YouTubeAuth.sapisid(in: ["SID": "z"]))
    }

    func testOnlyYouTubeCookieDomainsAreKept() {
        XCTAssertTrue(YouTubeAuth.isYouTubeCookie(domain: ".youtube.com"))
        XCTAssertTrue(YouTubeAuth.isYouTubeCookie(domain: "music.youtube.com"))
        XCTAssertFalse(YouTubeAuth.isYouTubeCookie(domain: "accounts.google.com"))
        XCTAssertFalse(YouTubeAuth.isYouTubeCookie(domain: "notyoutube.com"))
    }

    func testSignAddsCookieAuthorizationAndAuthUser() {
        var request = URLRequest(url: URL(string: "https://music.youtube.com/youtubei/v1/browse")!)
        YouTubeAuth.sign(&request, with: session(["SAPISID": "a", "SID": "z"], authUser: "1"), origin: YouTubeAuth.musicOrigin)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "SAPISID=a; SID=z")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SAPISIDHASH ") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-AuthUser"), "1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), YouTubeAuth.musicOrigin)
    }

    func testSignLeavesAnonymousRequestsAlone() {
        var request = URLRequest(url: URL(string: "https://music.youtube.com")!)
        YouTubeAuth.sign(&request, with: nil, origin: YouTubeAuth.musicOrigin)
        YouTubeAuth.sign(&request, with: session(["SID": "z"]), origin: YouTubeAuth.musicOrigin)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    // MARK: probeScript

    func testProbeParsesLoggedInPage() throws {
        let probe = try XCTUnwrap(YouTubeAuth.Probe.parse(#"{"loggedIn":true,"visitorData":"Cgt","sessionIndex":2}"#))
        XCTAssertEqual(probe, YouTubeAuth.Probe(loggedIn: true, visitorData: "Cgt", authUser: "2"))
    }

    func testProbeDefaultsToAccountZeroAndLoggedOut() throws {
        let probe = try XCTUnwrap(YouTubeAuth.Probe.parse(#"{"loggedIn":false,"visitorData":null,"sessionIndex":null}"#))
        XCTAssertFalse(probe.loggedIn)
        XCTAssertNil(probe.visitorData)
        XCTAssertEqual(probe.authUser, "0")
        XCTAssertNil(YouTubeAuth.Probe.parse(nil))
        XCTAssertNil(YouTubeAuth.Probe.parse("not json"))
    }

    // MARK: account(from:) / libraryPlaylists(from:)

    func testAccountReadsNameHandleEmailAndLargestAvatar() throws {
        let account = try XCTUnwrap(YouTubeParser.account(from: try Fixture.json("yt_account_menu.json")))
        XCTAssertEqual(account.name, "Hamza K")
        XCTAssertEqual(account.handle, "@hamzak")
        XCTAssertEqual(account.email, "hamza@example.com")
        XCTAssertEqual(account.avatarURL, "https://yt3.ggpht.com/photo=s88")
    }

    func testAccountIsNilForAnonymousResponse() {
        XCTAssertNil(YouTubeParser.account(from: ["responseContext": ["visitorData": "x"]]))
    }

    func testLibraryPlaylistsKeepPlaylistsOnceInPageOrder() throws {
        let playlists = YouTubeParser.libraryPlaylists(from: try Fixture.json("yt_library_playlists.json"))
        XCTAssertEqual(playlists.map(\.browseId), ["VLLM", "VLPLroadtrip123"])
        XCTAssertEqual(playlists.map(\.title), ["Your likes", "Road trip"])
        XCTAssertTrue(playlists.allSatisfy { $0.kind == .playlist })
        XCTAssertEqual(playlists[1].thumbnailURL, "https://example.com/trip.jpg")
    }

    func testLibraryPlaylistsEmptyWhenPageHasNone() {
        XCTAssertTrue(YouTubeParser.libraryPlaylists(from: [:]).isEmpty)
    }
}
