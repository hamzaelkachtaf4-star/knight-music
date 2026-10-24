import Foundation

/// Downloads a googlevideo file in ≤1 MiB ranges — the largest googlevideo serves for ANDROID_VR URLs —
/// a few at a time, into a temporary file. Used where a whole file is needed: the stream cache that feeds
/// crossfades/EQ, and downloads.
enum ChunkedFileDownloader {
    private static let parallel = 3

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    /// Returns the temporary file; the caller moves it into place. Throws on any refused or short chunk.
    static func download(_ url: URL, expectedLength: Int?, allowsCellular: Bool = true,
                         networkServiceType: URLRequest.NetworkServiceType = .default,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let chunk = YouTubeStream.chunkSize
        func request(_ range: ClosedRange<Int>) -> URLRequest {
            var request = URLRequest(url: url)
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
            request.allowsCellularAccess = allowsCellular
            request.networkServiceType = networkServiceType
            return request
        }
        func fetch(_ range: ClosedRange<Int>) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await session.data(for: request(range))
            guard let http = response as? HTTPURLResponse else { throw YouTubeError.badResponse }
            // A 200 is the whole file, not the range: only usable as the very first read.
            guard http.statusCode == 206 || (http.statusCode == 200 && range.lowerBound == 0) else {
                throw YouTubeError.http(http.statusCode)
            }
            return (data, http)
        }

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            defer { try? handle.close() }

            // The first chunk also tells us the total when the URL didn't.
            let (first, response) = try await fetch(0...(chunk - 1))
            guard !first.isEmpty else { throw YouTubeError.badResponse }
            try handle.write(contentsOf: first)
            let total = response.statusCode == 200 ? first.count : (expectedLength ?? totalLength(response) ?? first.count)
            var done = first.count
            progress?(Double(done) / Double(max(total, 1)))

            let ranges = stride(from: first.count, to: total, by: chunk).map { $0...min($0 + chunk, total) - 1 }
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var pending = ranges.makeIterator()
                for _ in 0..<parallel {
                    guard let range = pending.next() else { break }
                    group.addTask { (range.lowerBound, try await fetch(range).0) }
                }
                while let (offset, data) = try await group.next() {
                    try Task.checkCancellation()
                    guard !data.isEmpty else { throw YouTubeError.badResponse }
                    try handle.seek(toOffset: UInt64(offset))
                    try handle.write(contentsOf: data)
                    done += data.count
                    progress?(Double(done) / Double(max(total, 1)))
                    if let range = pending.next() {
                        group.addTask { (range.lowerBound, try await fetch(range).0) }
                    }
                }
            }
            guard done >= total else { throw YouTubeError.badResponse }
            return tmp
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// `Content-Range: bytes 0-1048575/3449447` → 3449447.
    static func totalLength(_ response: HTTPURLResponse) -> Int? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              let slash = header.lastIndex(of: "/") else { return nil }
        return Int(header[header.index(after: slash)...])
    }
}
