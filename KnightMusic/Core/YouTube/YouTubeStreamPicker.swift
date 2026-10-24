import Foundation

/// One audio rendition offered by a `player` response.
struct YTAudioFormat: Hashable, Sendable {
    var itag: Int
    var mimeType: String
    var bitrate: Int
    /// Present only when the client was handed a direct URL (not SABR-only, not ciphered).
    var url: URL?
    var contentLength: Int?
    var loudnessDb: Double?

    /// AAC in MP4: the only YouTube audio AVPlayer decodes (Opus/Vorbis arrive in WebM).
    var isAAC: Bool { mimeType.hasPrefix("audio/mp4") && mimeType.contains("mp4a") }
}

struct YTPlayerResponse: Sendable {
    var status: String
    var reason: String?
    var formats: [YTAudioFormat]
    var hlsManifestURL: URL?
    var expiresInSeconds: Int?
    var durationSeconds: Int?
    var loudnessDb: Double?

    var isPlayable: Bool { status == "OK" && (!formats.isEmpty || hlsManifestURL != nil) }
}

/// Pure selection logic for the stream resolver, kept free of networking so it is unit-tested.
enum YouTubeStreamPicker {
    static func playerResponse(_ root: JSONObject) -> YTPlayerResponse {
        let playability = root.o("playabilityStatus")
        let streaming = root.o("streamingData")
        let formats: [YTAudioFormat] = (streaming?.a("adaptiveFormats") ?? []).compactMap { raw in
            guard let format = raw as? JSONObject,
                  let itag = (format["itag"] as? NSNumber)?.intValue,
                  let mime = format.s("mimeType"), mime.hasPrefix("audio/") else { return nil }
            return YTAudioFormat(
                itag: itag, mimeType: mime,
                bitrate: (format["bitrate"] as? NSNumber)?.intValue ?? 0,
                url: format.s("url").flatMap(URL.init(string:)),
                contentLength: format.s("contentLength").flatMap { Int($0) },
                loudnessDb: (format["loudnessDb"] as? NSNumber)?.doubleValue)
        }
        return YTPlayerResponse(
            status: playability?.s("status") ?? "ERROR",
            reason: playability?.s("reason") ?? playability?.o("errorScreen").flatMap { InnertubeJSON.findString("text", in: $0) },
            formats: formats,
            hlsManifestURL: streaming?.s("hlsManifestUrl").flatMap(URL.init(string:)),
            expiresInSeconds: streaming?.s("expiresInSeconds").flatMap { Int($0) },
            durationSeconds: root.o("videoDetails")?.s("lengthSeconds").flatMap { Int($0) },
            loudnessDb: (root.o("playerConfig")?.o("audioConfig")?["loudnessDb"] as? NSNumber)?.doubleValue)
    }

    /// The best directly playable AAC rendition at or under `maxBitrate` (bits/s); when every rung is over
    /// budget, the cheapest one — a rung over budget still beats silence.
    static func bestAudio(_ formats: [YTAudioFormat], maxBitrate: Int?) -> YTAudioFormat? {
        let usable = formats.filter { $0.isAAC && $0.url != nil }
        guard !usable.isEmpty else { return nil }
        let ceiling = maxBitrate ?? .max
        return usable.filter { $0.bitrate <= ceiling }.max { $0.bitrate < $1.bitrate }
            ?? usable.min { $0.bitrate < $1.bitrate }
    }

    /// The audio-only media playlist of an HLS master: AAC-LC (itag 234, from 140) first, then HE-AAC (233).
    static func hlsAudioPlaylist(fromMaster text: String) -> URL? {
        var renditions: [(group: String, url: URL)] = []
        for line in text.components(separatedBy: .newlines) where line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            guard let uri = attribute("URI", in: line), let url = URL(string: uri) else { continue }
            renditions.append((attribute("GROUP-ID", in: line) ?? "", url))
        }
        for preferred in ["234", "233"] {
            if let match = renditions.first(where: { $0.group == preferred }) { return match.url }
        }
        return renditions.first?.url
    }

    private static func attribute(_ name: String, in line: String) -> String? {
        guard let range = line.range(of: "\(name)=\"") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
