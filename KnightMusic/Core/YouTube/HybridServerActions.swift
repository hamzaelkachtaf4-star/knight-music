import Foundation

/// Routes playback's server actions per song: Navidrome songs go to the server (when one is signed in),
/// YouTube songs — and everything in standalone mode — stay on the device.
struct HybridServerActions: PlaybackServerActions {
    let subsonic: SubsonicServerActions?
    let library: LibraryRepository
    let youtube: YouTubeLibrary

    private func isLocal(_ songId: String) -> Bool {
        subsonic == nil || YouTubeID.isYouTube(songId)
    }

    func scrobble(songId: String, time: Date, submission: Bool) async throws {
        if let subsonic, !YouTubeID.isYouTube(songId) {
            try await subsonic.scrobble(songId: songId, time: time, submission: submission)
            return
        }
        // Local history (Replay, "Continue Listening") is all a YouTube play reports to.
        if submission { await library.markPlayed(songId: songId, at: time) }
    }

    func savePlayQueue(songIds: [String], currentSongId: String?, positionMs: Int) async throws {
        guard let subsonic else { return }
        let serverIds = songIds.filter { !YouTubeID.isYouTube($0) }
        guard !serverIds.isEmpty else { return }
        let current = currentSongId.flatMap { YouTubeID.isYouTube($0) ? nil : $0 }
        try await subsonic.savePlayQueue(songIds: serverIds, currentSongId: current, positionMs: current == nil ? 0 : positionMs)
    }

    func getPlayQueue() async throws -> ServerPlayQueue? {
        try await subsonic?.getPlayQueue()
    }

    /// The local mirror is already updated by the caller (`PlayerEngine.onStarChanged`).
    func setStarred(songId: String, starred: Bool) async throws {
        guard !isLocal(songId), let subsonic else { return }
        try await subsonic.setStarred(songId: songId, starred: starred)
    }

    func similarSongs(to song: Song, count: Int) async throws -> [Song] {
        if YouTubeID.isYouTube(song.id) { return try await youtube.radio(after: song, count: count) }
        return try await subsonic?.similarSongs(to: song, count: count) ?? []
    }
}
