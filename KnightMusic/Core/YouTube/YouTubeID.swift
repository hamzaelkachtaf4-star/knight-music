import Foundation

/// YouTube items live in the same tables as Navidrome ones. Their ids carry a `yt:` prefix so every router
/// (playback, artwork, mutations, sync sweeps) can tell them apart without a schema change.
enum YouTubeID {
    static let prefix = "yt:"

    static func isYouTube(_ id: String?) -> Bool {
        id?.hasPrefix(prefix) == true
    }

    /// `yt:<videoId>` / `yt:<browseId>`.
    static func make(_ raw: String) -> String {
        raw.hasPrefix(prefix) ? raw : prefix + raw
    }

    /// The raw videoId / browseId, or nil when `id` is not a YouTube id.
    static func raw(_ id: String?) -> String? {
        guard let id, id.hasPrefix(prefix) else { return nil }
        let value = String(id.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    /// A playlist made on this device. It shares the prefix so server syncs leave it alone too.
    static func newLocalPlaylistId() -> String {
        prefix + localPlaylistMarker + UUID().uuidString
    }

    static func isLocalPlaylist(_ id: String?) -> Bool {
        raw(id)?.hasPrefix(localPlaylistMarker) == true
    }

    private static let localPlaylistMarker = "local-"

    /// SQL fragment that keeps YouTube rows out of server-mirror sweeps.
    static let notYouTubeSQL = "id NOT LIKE 'yt:%'"
}
