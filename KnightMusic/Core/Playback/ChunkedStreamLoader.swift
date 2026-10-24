import AVFoundation
import Foundation

/// Streams a googlevideo AAC file to AVPlayer through `AVAssetResourceLoader`, answering each of AVPlayer's
/// byte-range reads with ≤1 MiB requests (googlevideo refuses larger ranges on ANDROID_VR URLs, and AVPlayer
/// asks for whole-file ranges). Playback starts after the first chunk and seeking works anywhere.
/// The asset holds only a weak reference to its delegate: whoever owns the player item must keep this alive.
final class ChunkedStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "kmchunk"

    let remote: URL
    private let queue = DispatchQueue(label: "com.knightabdo.knightmusic.chunked-stream")
    private let lock = NSLock()
    private var length: Int?
    /// Only touched on `queue`.
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(remote: URL) {
        self.remote = remote
        length = YouTubeStream.contentLength(of: remote)
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }

    /// Stops every read in flight. The owning player item calls this when it is dropped: AVFoundation doesn't
    /// always send `didCancel` for an item that is simply removed.
    func cancelAll() {
        queue.async {
            for task in self.tasks.values { task.cancel() }
            self.tasks.removeAll()
        }
    }

    func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        components?.scheme = Self.scheme
        let asset = AVURLAsset(url: components?.url ?? remote)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    // MARK: AVAssetResourceLoaderDelegate (called on `queue`)

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        tasks[key] = Task { [weak self] in
            await self?.serve(loadingRequest)
            self?.queue.async { self?.tasks[key] = nil }
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    // MARK: Serving

    private func serve(_ loadingRequest: AVAssetResourceLoadingRequest) async {
        do {
            let total = try await totalLength()
            if let info = loadingRequest.contentInformationRequest {
                queue.sync {
                    info.contentType = AVFileType.m4a.rawValue
                    info.contentLength = Int64(total)
                    info.isByteRangeAccessSupported = true
                }
            }
            if let dataRequest = loadingRequest.dataRequest {
                var offset = Int(dataRequest.requestedOffset)
                let end = dataRequest.requestsAllDataToEndOfResource
                    ? total : min(total, offset + dataRequest.requestedLength)
                while offset < end {
                    try Task.checkCancellation()
                    if queue.sync(execute: { loadingRequest.isCancelled }) { throw CancellationError() }
                    let upper = min(offset + YouTubeStream.chunkSize, end) - 1
                    let bytes = try await fetch(offset...upper)
                    guard !bytes.isEmpty else { throw YouTubeError.badResponse }
                    try Task.checkCancellation()
                    queue.sync { dataRequest.respond(with: bytes) }
                    offset += bytes.count
                }
            }
            queue.sync { if !loadingRequest.isCancelled { loadingRequest.finishLoading() } }
        } catch is CancellationError {
        } catch {
            Log.playback.warning("Chunked stream read failed: \(error.localizedDescription)")
            queue.sync { if !loadingRequest.isCancelled { loadingRequest.finishLoading(with: error) } }
        }
    }

    private func totalLength() async throws -> Int {
        if let known = lock.withLock({ length }) { return known }
        var request = URLRequest(url: remote)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await ChunkedFileDownloader.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeError.badResponse }
        guard http.statusCode == 206 || http.statusCode == 200 else { throw YouTubeError.http(http.statusCode) }
        guard let total = ChunkedFileDownloader.totalLength(http) else { throw YouTubeError.badResponse }
        lock.withLock { length = total }
        return total
    }

    private func fetch(_ range: ClosedRange<Int>) async throws -> Data {
        var request = URLRequest(url: remote)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await ChunkedFileDownloader.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw YouTubeError.badResponse }
        // A 200 carries the file from byte 0, which only matches a read that starts there.
        guard http.statusCode == 206 || (http.statusCode == 200 && range.lowerBound == 0) else {
            throw YouTubeError.http(http.statusCode)
        }
        return http.statusCode == 200 ? data.prefix(range.count) : data
    }
}
