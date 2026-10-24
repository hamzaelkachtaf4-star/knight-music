import Foundation

/// Turns a videoId into audio AVPlayer can play, without any server of ours. Best effort: anonymous clients
/// get no PO token, so YouTube may refuse some songs some of the time.
///
/// 1. **ANDROID_VR** mints direct, unciphered AAC (itag 140) URLs. 1.43.32 has served whole files token-free;
///    1.65.10 URLs can stop at 1 MiB. googlevideo also refuses ranges over 1 MiB and throttles Range-less GETs,
///    so these URLs are only ever fetched in chunks (`ChunkedStreamLoader`, `ChunkedFileDownloader`).
/// 2. **IOS** returns no direct URLs (SABR-only). For video uploads it still offers an `hlsManifestUrl` whose
///    audio-only AAC rendition AVPlayer plays natively; catalogue songs usually get none. Play-only.
/// 3. **Piped / Invidious** public instances, last: slow, and they come and go.
///
/// A URL is only returned after a full chunk past the 1 MiB boundary was served. One resolution per video is in
/// flight at a time and results are cached briefly; `cachedStream(for:)` is the player's synchronous read.
final class YouTubeStreamResolver: @unchecked Sendable {
    static let shared = YouTubeStreamResolver()

    private let client: YouTubeClient
    private let fallback: PipedFallback
    private let probeSession: URLSession
    private let lock = NSLock()
    private var cache: [String: YouTubeStream] = [:]
    private var inFlight: [String: Task<YouTubeStream, Error>] = [:]
    private var verdicts: [String: (reason: String, until: Date)] = [:]
    /// "ANDROID_VR/1.65.10" style keys refused mid-playback, per video, until a date.
    private var excluded: [String: [String: Date]] = [:]

    /// Resolved URLs are bound to the session that minted them; keep them well inside their validity.
    private static let cacheTTL: TimeInterval = 45 * 60
    private static let verdictTTL: TimeInterval = 10 * 60
    private static let exclusionTTL: TimeInterval = 10 * 60
    private static let cacheLimit = 64

    private static let tiers: [YouTubeClient.PlayerIdentity] = [.androidVRLegacy, .androidVR]

    init(client: YouTubeClient = .shared, fallback: PipedFallback = PipedFallback()) {
        self.client = client
        self.fallback = fallback
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        probeSession = URLSession(configuration: config)
    }

    // MARK: Public

    /// A fresh stream resolved earlier, or nil. Never touches the network.
    func cachedStream(for videoId: String) -> YouTubeStream? {
        lock.withLock {
            guard let stream = cache[videoId], stream.isFresh else { return nil }
            return stream
        }
    }

    /// Resolves (or joins the in-flight resolution of) `videoId`. Throws `YouTubeError` with a reason worth showing.
    func resolve(_ videoId: String) async throws -> YouTubeStream {
        try await coalesced(videoId) { try await self.resolveUncached(videoId, progressiveOnly: false) }
    }

    /// A stream that can be saved as a file (downloads, crossfade cache): progressive only.
    func resolveDownloadable(_ videoId: String) async throws -> YouTubeStream {
        if let cached = cachedStream(for: videoId), cached.delivery == .progressive { return cached }
        return try await coalesced(videoId) { try await self.resolveUncached(videoId, progressiveOnly: true) }
    }

    /// googlevideo refused `url` mid-playback: forget it and keep its client away from this video for a while,
    /// so the retry moves on to the next tier instead of minting the same kind of URL again.
    func refused(_ url: URL, videoId: String) {
        let key = Self.clientKey(of: url)
        lock.withLock {
            cache[videoId] = nil
            if let key { excluded[videoId, default: [:]][key] = Date().addingTimeInterval(Self.exclusionTTL) }
        }
    }

    func invalidate(_ videoId: String) {
        lock.withLock { cache[videoId] = nil }
    }

    // MARK: Coalescing

    private func coalesced(_ videoId: String, _ work: @escaping @Sendable () async throws -> YouTubeStream) async throws -> YouTubeStream {
        if let cached = cachedStream(for: videoId) { return cached }
        enum Next { case refused(String), join(Task<YouTubeStream, Error>), start(Task<YouTubeStream, Error>) }
        let next: Next = lock.withLock {
            if let verdict = verdicts[videoId], verdict.until > Date() { return .refused(verdict.reason) }
            if let running = inFlight[videoId] { return .join(running) }
            let task = Task { try await work() }
            inFlight[videoId] = task
            return .start(task)
        }
        switch next {
        case .refused(let reason):
            throw YouTubeError.unplayable(reason)
        case .join(let running):
            return try await running.value
        case .start(let task):
            defer { lock.withLock { inFlight[videoId] = nil } }
            let stream = try await task.value
            remember(stream)
            return stream
        }
    }

    // MARK: Tiers

    private func resolveUncached(_ videoId: String, progressiveOnly: Bool) async throws -> YouTubeStream {
        var reason: String?
        let skip = excludedClients(for: videoId)
        for identity in Self.tiers where !skip.contains("\(identity.name)/\(identity.version)") {
            do {
                let response = try await client.player(videoId: videoId, as: identity)
                guard response.isPlayable else {
                    reason = reason ?? Self.permanentReason(response)
                    continue
                }
                guard let format = YouTubeStreamPicker.bestAudio(response.formats, maxBitrate: nil),
                      let url = format.url, await probe(url, length: format.contentLength) else { continue }
                return YouTubeStream(videoId: videoId, url: url, delivery: .progressive, bitrate: format.bitrate,
                                     contentLength: format.contentLength,
                                     expiresAt: Self.expiry(of: url, seconds: response.expiresInSeconds),
                                     loudnessDb: format.loudnessDb ?? response.loudnessDb, source: identity.name)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.playback.warning("YouTube \(identity.name) \(identity.version) failed for \(videoId): \(error.localizedDescription)")
            }
        }

        if !progressiveOnly {
            do {
                let identity = YouTubeClient.PlayerIdentity.iOS
                let response = try await client.player(videoId: videoId, as: identity)
                if !response.isPlayable { reason = reason ?? Self.permanentReason(response) }
                if response.isPlayable, let master = response.hlsManifestURL {
                    let text = try await client.text(at: master, userAgent: identity.userAgent)
                    if let audio = YouTubeStreamPicker.hlsAudioPlaylist(fromMaster: text),
                       try await client.text(at: audio, userAgent: identity.userAgent).hasPrefix("#EXTM3U") {
                        return YouTubeStream(videoId: videoId, url: audio, delivery: .hls, bitrate: 128_000, contentLength: nil,
                                             expiresAt: Self.expiry(of: master, seconds: response.expiresInSeconds),
                                             loudnessDb: response.loudnessDb, source: identity.name)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.playback.warning("YouTube IOS HLS failed for \(videoId): \(error.localizedDescription)")
            }
        }

        if let found = await fallback.audio(videoId: videoId), await probe(found.url, length: found.contentLength) {
            return YouTubeStream(videoId: videoId, url: found.url, delivery: .progressive, bitrate: found.bitrate,
                                 contentLength: found.contentLength, expiresAt: Date().addingTimeInterval(Self.cacheTTL),
                                 loudnessDb: nil, source: found.source)
        }

        if let reason {
            lock.withLock { verdicts[videoId] = (reason, Date().addingTimeInterval(Self.verdictTTL)) }
            throw YouTubeError.unplayable(reason)
        }
        throw YouTubeError.noStream
    }

    // MARK: Helpers

    /// Fetches a whole chunk at the 1 MiB boundary when the file is that long: some URLs serve the opening
    /// megabyte (and small reads past it) yet refuse real-sized reads after it, so the probe must be as large
    /// as the fetches playback will make.
    private func probe(_ url: URL, length: Int?) async -> Bool {
        let chunk = YouTubeStream.chunkSize
        let total = length ?? YouTubeStream.contentLength(of: url) ?? 0
        let range = total > chunk ? chunk...(min(total, 2 * chunk) - 1) : 0...(max(min(total, chunk), 16_384) - 1)
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else { return false }
            let type = http.mimeType?.lowercased() ?? ""
            let typeOK = type.hasPrefix("audio/") || type.hasPrefix("video/") || type == "application/octet-stream"
            return typeOK && (total == 0 ? !data.isEmpty : data.count >= min(range.count, total - range.lowerBound))
        } catch {
            return false
        }
    }

    private func remember(_ stream: YouTubeStream) {
        lock.withLock {
            if cache.count >= Self.cacheLimit {
                cache = cache.filter { $0.value.isFresh }
                if cache.count >= Self.cacheLimit { cache.removeAll() }
            }
            cache[stream.videoId] = stream
        }
    }

    private func excludedClients(for videoId: String) -> Set<String> {
        lock.withLock {
            let now = Date()
            let live = (excluded[videoId] ?? [:]).filter { $0.value > now }
            excluded[videoId] = live.isEmpty ? nil : live
            return Set(live.keys)
        }
    }

    /// "ANDROID_VR/1.65.10" for the client that minted `url`; without a version, the first tier of that client.
    static func clientKey(of url: URL) -> String? {
        guard let minted = YouTubeStreamPicker.mintingClient(of: url) else { return nil }
        if let version = minted.version { return "\(minted.name)/\(version)" }
        return tiers.first { $0.name == minted.name }.map { "\($0.name)/\($0.version)" }
    }

    /// The earlier of the URL's own `expire` and our TTL.
    private static func expiry(of url: URL, seconds: Int?) -> Date {
        var limit = Date().addingTimeInterval(cacheTTL)
        let fromQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "expire" }?.value
        let fromPath = url.absoluteString.firstMatch(of: #/\/expire\/(\d+)/#).map { String($0.output.1) }
        if let raw = fromQuery ?? fromPath, let epoch = TimeInterval(raw) {
            limit = min(limit, Date(timeIntervalSince1970: epoch).addingTimeInterval(-300))
        } else if let seconds {
            limit = min(limit, Date().addingTimeInterval(TimeInterval(seconds) - 300))
        }
        return limit
    }

    private static func permanentReason(_ response: YTPlayerResponse) -> String? {
        YouTubeStreamPicker.permanentReason(response)
    }
}
