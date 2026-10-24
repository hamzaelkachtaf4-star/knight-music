import Foundation

// YouTube songs have no URL until the resolver mints one (async), while the engine's source resolution is
// synchronous. A YouTube song therefore becomes current in two steps: it is shown at once as "connecting",
// and becomes `tracked` when its stream is resolved. The next song is resolved ahead; nothing further.
extension PlayerEngine {
    /// True when `song` is a YouTube song with nothing local and no fresh stream yet.
    func needsYouTubeResolution(_ song: Song) -> Bool {
        guard let videoId = YouTubeID.raw(song.id), !services.isOffline else { return false }
        if downloads?.localFileURL(for: song.id) != nil || streamCache.contains(song.id) { return false }
        return YouTubeStreamResolver.shared.cachedStream(for: videoId) == nil
    }

    /// Shows `entry` as current right away and resolves its stream; when that lands, loads it for real.
    /// Without `autoplay` (a restored or parked queue) nothing is fetched until the user presses play.
    func beginYouTubeResolution(_ entry: QueueEntry, index: Int, autoplay: Bool, startAt: TimeInterval) {
        guard let videoId = YouTubeID.raw(entry.song.id) else { return }
        if youTubePendingEntry == entry.id, youTubeResolution != nil { return }
        cancelYouTubeResolution()
        stopPlayer()
        scrobbler.end()
        publishPending(entry, startAt: startAt, connecting: autoplay)
        youTubePendingEntry = entry.id
        guard autoplay else { return }
        youTubeResolution = Task { [weak self] in
            do {
                _ = try await YouTubeStreamResolver.shared.resolve(videoId)
                guard let self, !Task.isCancelled, self.youTubePendingEntry == entry.id else { return }
                self.youTubeResolution = nil
                self.youTubePendingEntry = nil
                guard let i = self.order.firstIndex(where: { $0.id == entry.id }) else { return }
                self.load(index: i, autoplay: self.userWantsPlaying, startAt: startAt)
            } catch {
                guard let self, !Task.isCancelled, self.youTubePendingEntry == entry.id else { return }
                self.youTubeResolution = nil
                self.youTubePendingEntry = nil
                self.youTubeResolutionFailed(entry, error: error)
            }
        }
    }

    func cancelYouTubeResolution() {
        youTubeResolution?.cancel()
        youTubeResolution = nil
        youTubePendingEntry = nil
    }

    /// Resolves an upcoming YouTube song so it can be prepared gaplessly and saved for a crossfade.
    /// Only the current and next songs: resolving further ahead is what trips YouTube's bot checks.
    func prefetchYouTube(_ song: Song) {
        guard let videoId = YouTubeID.raw(song.id), !services.isOffline, youTubePrefetches[videoId] == nil,
              downloads?.localFileURL(for: song.id) == nil, !streamCache.contains(song.id),
              YouTubeStreamResolver.shared.cachedStream(for: videoId) == nil,
              order.dropFirst(currentIndex).prefix(2).contains(where: { $0.song.id == song.id }) else { return }
        youTubePrefetches[videoId] = Task { [weak self] in
            let resolved = (try? await YouTubeStreamResolver.shared.resolve(videoId)) != nil
            if !resolved {
                // Keep the slot taken for a minute so a refusal doesn't turn into a request storm.
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
            guard let self else { return }
            self.youTubePrefetches[videoId] = nil
            guard resolved, self.tracked != nil else { return }
            self.prepareNext()
            self.syncCache()
        }
    }

    /// The stream cache may run without a Subsonic URL provider when the queue has YouTube songs.
    var isStandaloneOrYouTubeQueue: Bool {
        order.contains { YouTubeID.isYouTube($0.song.id) }
    }

    /// AVFoundation misjudges the length of YouTube's fragmented MP4 audio (407 s for a 338 s song), so a
    /// YouTube song's catalogue duration wins; everything else trusts the item.
    func playableDuration(of prepared: PreparedItem) -> TimeInterval {
        let catalogue = prepared.entry.song.durationSeconds
        if YouTubeID.isYouTube(prepared.entry.song.id), catalogue > 0 { return catalogue }
        let duration = prepared.item.duration
        return duration.isNumeric && duration.seconds > 0 ? duration.seconds : catalogue
    }

    // MARK: Private

    private func publishPending(_ entry: QueueEntry, startAt: TimeInterval, connecting: Bool) {
        let song = entry.song
        currentSong = song
        source = .streaming
        formatDescription = connecting ? "Connecting to YouTube Music\u{2026}" : "YouTube Music"
        duration = song.durationSeconds
        currentTime = startAt
        bufferedFraction = 0
        // Like a buffering stream: the transport shows pause while it connects.
        isBuffering = connecting
        isPlaying = connecting
        if let i = order.firstIndex(where: { $0.id == entry.id }) { currentIndex = i }
        nowPlaying.setSong(song, isLive: false, duration: duration, elapsed: startAt, rate: 0,
                           queueIndex: currentIndex, queueCount: order.count)
        remote?.refresh()
        refillStationIfNeeded()
        saveQueueSoon()
    }

    private func youTubeResolutionFailed(_ entry: QueueEntry, error: Error) {
        failedEntryIds.insert(entry.id)
        isBuffering = false
        report("Couldn\u{2019}t play \u{201C}\(entry.song.title)\u{201D}: \(error.localizedDescription)")
        consecutiveFailures += 1
        guard userWantsPlaying, consecutiveFailures < min(max(order.count, 1), 5), let next = nextExplicitIndex() else {
            userWantsPlaying = false
            isPlaying = false
            return
        }
        load(index: next, autoplay: true)
    }
}
