import Foundation

/// A playable YouTube audio source, already proven to serve bytes.
struct YouTubeStream: Sendable, Equatable {
    enum Delivery: String, Sendable {
        /// One AAC/MP4 file: streams, seeks, and can be saved for crossfades, EQ and downloads.
        case progressive
        /// An HLS audio rendition: plays (and seeks) in AVPlayer, but cannot be saved as a file.
        case hls
    }

    let videoId: String
    let url: URL
    let delivery: Delivery
    /// Bits per second (0 when unknown).
    let bitrate: Int
    let contentLength: Int?
    let expiresAt: Date
    let loudnessDb: Double?
    /// Which tier produced it ("ANDROID_VR", "IOS", "Piped", …), for diagnostics.
    let source: String

    var kbps: Int { bitrate / 1000 }

    /// Fresh enough to hand to a player that may still seek in it for a while.
    var isFresh: Bool { expiresAt.timeIntervalSinceNow > 120 }

    /// googlevideo `videoplayback` URLs refuse ranges over 1 MiB (and throttle Range-less GETs to real time),
    /// so they are fetched chunk by chunk. HLS manifests on the same domain are exempt.
    static let chunkSize = 1_048_576

    static func needsChunking(_ url: URL) -> Bool {
        url.host?.hasSuffix("googlevideo.com") == true && url.path.contains("videoplayback")
    }

    /// The file size googlevideo states in the URL (`clen`), when it does.
    static func contentLength(of url: URL) -> Int? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clen" })?.value {
            return Int(value)
        }
        return url.path.firstMatch(of: #/\/clen\/(\d+)/#).flatMap { Int($0.output.1) }
    }
}
