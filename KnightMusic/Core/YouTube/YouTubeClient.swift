import Foundation

enum YouTubeError: LocalizedError {
    case http(Int)
    case badResponse
    case notFound
    case unplayable(String)
    case noStream

    var errorDescription: String? {
        switch self {
        case .http(let code): return "YouTube Music answered with HTTP \(code)."
        case .badResponse: return "YouTube Music sent a response Knight Music couldn’t read."
        case .notFound: return "YouTube Music doesn’t have this item."
        case .unplayable(let reason): return reason
        case .noStream: return "YouTube Music offered no playable audio for this song."
        }
    }
}

/// Anonymous YouTube Music (Innertube) client: search, browse and radio through the WEB_REMIX web client,
/// and `player` requests through the device clients the stream resolver picks. No account, no API key.
actor YouTubeClient {
    static let shared = YouTubeClient()

    /// A device identity for `player` requests. googlevideo bakes the minting client into its URLs.
    struct PlayerIdentity: @unchecked Sendable {
        let name: String
        let clientId: String
        let version: String
        let userAgent: String
        let extra: [String: Any]

        static let androidVR = PlayerIdentity(
            name: "ANDROID_VR", clientId: "28", version: "1.65.10",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
            extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32, "osName": "Android", "osVersion": "12L"])
        static let androidVRLegacy = PlayerIdentity(
            name: "ANDROID_VR", clientId: "28", version: "1.43.32",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.43.32 (Linux; U; Android 12; en_US; Quest 3; Build/SQ3A.220605.009.A1; Cronet/107.0.5284.2)",
            extra: ["deviceMake": "Oculus", "deviceModel": "Quest 3", "androidSdkVersion": 32, "osName": "Android", "osVersion": "12"])
        static let iOS = PlayerIdentity(
            name: "IOS", clientId: "5", version: "21.29.1",
            userAgent: "com.google.ios.youtube/21.29.1 (iPhone16,2; U; CPU iOS 18_5 like Mac OS X;)",
            extra: ["deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.5.0.22F76"])
    }

    enum SearchFilter: String, Sendable {
        case songs = "EgWKAQIIAWoKEAkQBRAKEAMQBA=="
        case albums = "EgWKAQIYAWoKEAkQBRAKEAMQBA=="
        case artists = "EgWKAQIgAWoKEAkQBRAKEAMQBA=="
        case playlists = "EgeKAQQoADgBagwQAxAJEAQQDhAKEAU="
    }

    private static let musicBase = URL(string: "https://music.youtube.com/youtubei/v1/")!
    private static let webRemixVersion = "1.20250101.01.00"
    private static let webUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"

    private let session: URLSession
    private var visitorData: String?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    private var language: String { Locale.current.language.languageCode?.identifier ?? "en" }
    private var region: String { Locale.current.region?.identifier ?? "US" }

    // MARK: Catalogue

    func search(_ query: String, filter: SearchFilter? = nil) async throws -> YTSearchResults {
        var body: JSONObject = ["query": query]
        if let filter { body["params"] = filter.rawValue }
        return YouTubeParser.search(try await music("search", body))
    }

    func suggestions(_ input: String) async throws -> [String] {
        YouTubeParser.suggestions(try await music("music/get_search_suggestions", ["input": input]))
    }

    func album(_ browseId: String) async throws -> YTAlbumPage {
        guard let page = YouTubeParser.album(try await music("browse", ["browseId": browseId]), browseId: browseId) else {
            throw YouTubeError.notFound
        }
        return page
    }

    func artist(_ browseId: String) async throws -> YTArtistPage {
        guard let page = YouTubeParser.artist(try await music("browse", ["browseId": browseId]), browseId: browseId) else {
            throw YouTubeError.notFound
        }
        return page
    }

    /// A playlist with up to `maxPages` continuation pages (~100 rows each).
    func playlist(_ browseId: String, maxPages: Int = 5) async throws -> YTPlaylistPage {
        guard var page = YouTubeParser.playlist(try await music("browse", ["browseId": browseId]), browseId: browseId) else {
            throw YouTubeError.notFound
        }
        var seen = Set(page.tracks.map(\.videoId))
        var pages = 1
        while let token = page.continuation, pages < maxPages {
            let next = try await music("browse", ["continuation": token],
                                       query: ["ctoken": token, "continuation": token, "type": "next"])
            guard let more = YouTubeParser.playlist(next, browseId: browseId) else { break }
            page.tracks += more.tracks.filter { seen.insert($0.videoId).inserted }
            page.continuation = more.continuation
            pages += 1
        }
        return page
    }

    func home() async throws -> [YTHomeShelf] {
        YouTubeParser.home(try await music("browse", ["browseId": "FEmusic_home"]))
    }

    /// YouTube Music's radio after `videoId` (the RDAMVM mix), the seed first.
    func radio(after videoId: String) async throws -> [YTTrack] {
        YouTubeParser.watchQueue(try await music("next", [
            "videoId": videoId, "playlistId": "RDAMVM\(videoId)", "isAudioOnly": true,
        ]))
    }

    // MARK: Player

    func player(videoId: String, as identity: PlayerIdentity) async throws -> YTPlayerResponse {
        var client: JSONObject = ["clientName": identity.name, "clientVersion": identity.version, "hl": language, "gl": region]
        for (key, value) in identity.extra { client[key] = value }
        if let visitorData { client["visitorData"] = visitorData }
        let body: JSONObject = [
            "context": ["client": client, "user": ["lockedSafetyMode": false]],
            "videoId": videoId, "contentCheckOk": true, "racyCheckOk": true,
        ]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(identity.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(identity.version, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return YouTubeStreamPicker.playerResponse(try await send(request))
    }

    /// Downloads a small text resource (an HLS manifest) the way the minting client would.
    func text(at url: URL, userAgent: String) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw YouTubeError.http(http.statusCode) }
        guard let text = String(data: data, encoding: .utf8) else { throw YouTubeError.badResponse }
        return text
    }

    // MARK: Plumbing

    private func music(_ endpoint: String, _ extras: JSONObject, query: [String: String] = [:]) async throws -> JSONObject {
        if visitorData == nil { await mintVisitorData() }
        var components = URLComponents(url: Self.musicBase.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")] + query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var client: JSONObject = ["clientName": "WEB_REMIX", "clientVersion": Self.webRemixVersion, "hl": language, "gl": region]
        if let visitorData { client["visitorData"] = visitorData }
        var body: JSONObject = ["context": ["client": client, "user": ["lockedSafetyMode": false]]]
        for (key, value) in extras { body[key] = value }

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("67", forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(Self.webRemixVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await sendWithRetry(request)
        if visitorData == nil, let minted = YouTubeParser.visitorData(json) { visitorData = minted }
        return json
    }

    /// A visitor id makes `player` requests look like a real session; without one Google may hand out URLs
    /// that serve a few bytes and then 403. The service-worker bootstrap mints one without loading a page.
    private func mintVisitorData() async {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/sw.js_data")!)
        request.setValue(Self.webUserAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await session.data(for: request)
            guard let text = String(data: data, encoding: .utf8),
                  let match = text.firstMatch(of: #/Cg[A-Za-z0-9_%\-]{40,}/#) else { return }
            visitorData = String(match.output)
        } catch {
            Log.app.warning("YouTube visitor id unavailable: \(error.localizedDescription)")
        }
    }

    private func sendWithRetry(_ request: URLRequest) async throws -> JSONObject {
        var delay: UInt64 = 400_000_000
        for attempt in 0..<3 {
            do {
                return try await send(request)
            } catch let error as URLError where error.code != .cancelled && error.code != .timedOut && attempt < 2 {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            } catch YouTubeError.http(let code) where code >= 500 && attempt < 2 {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
        }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> JSONObject {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw YouTubeError.http(http.statusCode) }
        guard let json = InnertubeJSON.parse(data) else { throw YouTubeError.badResponse }
        return json
    }
}
