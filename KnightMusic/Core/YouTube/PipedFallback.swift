import Foundation

/// Last-resort audio from public Piped and Invidious instances, used only when every YouTube client failed
/// (captcha, bot check). Instances are volunteer-run and come and go, so each gets a short timeout.
struct PipedFallback: Sendable {
    struct Found: Sendable {
        let url: URL
        let bitrate: Int
        let contentLength: Int?
        let source: String
    }

    var pipedInstances = ["https://pipedapi.kavin.rocks", "https://pipedapi.adminforge.de", "https://api.piped.private.coffee"]
    var invidiousInstances = ["https://inv.nadeko.net", "https://invidious.nerdvpn.de", "https://yewtu.be"]

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    func audio(videoId: String) async -> Found? {
        for base in pipedInstances {
            if let found = await piped(base, videoId) { return found }
        }
        for base in invidiousInstances {
            if let found = await invidious(base, videoId) { return found }
        }
        return nil
    }

    /// `GET /streams/{id}` → `audioStreams[{url, mimeType, bitrate}]`.
    private func piped(_ base: String, _ videoId: String) async -> Found? {
        guard let url = URL(string: "\(base)/streams/\(videoId)"), let json = await fetch(url) else { return nil }
        let streams = (json.a("audioStreams") ?? []).compactMap { $0 as? JSONObject }
        let aac = streams.filter { ($0.s("mimeType") ?? "").hasPrefix("audio/mp4") }
        guard let best = aac.max(by: { ($0["bitrate"] as? NSNumber)?.intValue ?? 0 < ($1["bitrate"] as? NSNumber)?.intValue ?? 0 }),
              let streamURL = best.s("url").flatMap(URL.init(string:)) else { return nil }
        return Found(url: streamURL, bitrate: (best["bitrate"] as? NSNumber)?.intValue ?? 0,
                     contentLength: (best["contentLength"] as? NSNumber)?.intValue, source: "Piped")
    }

    /// `GET /api/v1/videos/{id}?local=true` → `adaptiveFormats[{url, type, bitrate, clen}]` proxied by the instance.
    private func invidious(_ base: String, _ videoId: String) async -> Found? {
        guard let url = URL(string: "\(base)/api/v1/videos/\(videoId)?local=true&fields=adaptiveFormats"),
              let json = await fetch(url) else { return nil }
        let formats = (json.a("adaptiveFormats") ?? []).compactMap { $0 as? JSONObject }
            .filter { ($0.s("type") ?? "").hasPrefix("audio/mp4") }
        func rate(_ f: JSONObject) -> Int { Int(f.s("bitrate") ?? "") ?? 0 }
        guard let best = formats.max(by: { rate($0) < rate($1) }), var raw = best.s("url") else { return nil }
        if raw.hasPrefix("/") { raw = base + raw }
        guard let streamURL = URL(string: raw) else { return nil }
        return Found(url: streamURL, bitrate: rate(best), contentLength: best.s("clen").flatMap { Int($0) }, source: "Invidious")
    }

    private func fetch(_ url: URL) async -> JSONObject? {
        do {
            let (data, response) = try await Self.session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return InnertubeJSON.parse(data)
        } catch {
            return nil
        }
    }
}
