import SwiftUI

/// YouTube Music results for the Search tab, in the same layout as library results. Songs shown here are
/// written to the mirror as cache (so likes, queueing and playlists work on them); albums, artists and
/// playlists are seeded when opened and filled by their detail screens.
struct YouTubeSearchResults: View {
    let query: String
    @Binding var scope: SearchView.SearchScope
    var onOpen: () -> Void

    @Environment(YouTubeLibrary.self) private var youtube
    @Environment(PlayerEngine.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(NetworkMonitor.self) private var network

    @State private var results: YTSearchResults?
    @State private var songs: [Song] = []
    @State private var failure: String?
    @State private var attempt = 0

    private var key: String { "\(query)|\(scope.rawValue)|\(attempt)" }

    var body: some View {
        Group {
            if let results, !(results.isEmpty && songs.isEmpty) {
                content(results)
            } else if results != nil {
                EmptyStateView(title: "No Results", systemImage: "magnifyingglass",
                               message: "YouTube Music has nothing for \u{201C}\(query)\u{201D}")
                    .padding(.top, 80)
            } else if let failure {
                EmptyStateView(title: "YouTube Music Unavailable", systemImage: "wifi.exclamationmark",
                               message: failure, actionTitle: "Try Again", action: { attempt += 1 })
                    .padding(.top, 80)
            } else {
                SkeletonRowList(count: 6)
                    .padding(.top, 16)
            }
        }
        .task(id: key) { await load() }
    }

    // MARK: Loading

    private func load() async {
        guard !query.isEmpty else { return }
        failure = nil
        guard network.isConnected else {
            results = nil
            failure = "You’re offline. Your library still works — switch to Library above."
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        do {
            let found = try await youtube.search(query, scope: youTubeScope)
            guard !Task.isCancelled else { return }
            let stored = await youtube.songsForPlayback(found.tracks)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.2)) {
                songs = stored
                results = found
            }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            results = nil
            failure = error.localizedDescription
            Log.network.warning("YouTube search failed: \(error.localizedDescription)")
        }
    }

    private var youTubeScope: YouTubeSearchScope {
        switch scope {
        case .top: .top
        case .songs: .songs
        case .albums: .albums
        case .artists: .artists
        case .playlists: .playlists
        }
    }

    // MARK: Layout

    @ViewBuilder
    private func content(_ results: YTSearchResults) -> some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            switch scope {
            case .top:
                if !songs.isEmpty {
                    songList(Array(songs.prefix(6)), title: "Songs", showsMore: true)
                }
                if !results.artists.isEmpty { artistShelf(results.artists) }
                if !results.albums.isEmpty { albumShelf(results.albums) }
                if !results.playlists.isEmpty { browseList(Array(results.playlists.prefix(5)), title: "Playlists") }
            case .songs:
                songList(songs, title: nil, showsMore: false)
            case .albums:
                albumGrid(results.albums)
            case .artists:
                browseList(results.artists, title: nil)
            case .playlists:
                browseList(results.playlists, title: nil)
            }
        }
        .padding(.vertical, 16)
        .animation(.smooth(duration: 0.2), value: scope)
    }

    private func songList(_ list: [Song], title: String?, showsMore: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                SectionHeader(title: title, action: showsMore ? { scope = .songs } : nil)
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 6)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, song in
                Button {
                    Haptics.impact(.medium)
                    player.play(list, startAt: index, shuffle: false)
                    onOpen()
                } label: {
                    SongRow(song: song, showsArtwork: true,
                            isPlaying: player.currentSong?.id == song.id, isPaused: !player.isPlaying,
                            isDownloaded: downloads.isDownloaded(song.id)) {
                        SongActionsMenu(song: song)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, Theme.margin)
                }
                .buttonStyle(.plain)
                .contextMenu { SongActionsMenu(song: song) }

                if index < list.count - 1 {
                    Divider().padding(.leading, 76)
                }
            }
        }
    }

    private func artistShelf(_ artists: [YTBrowseItem]) -> some View {
        ShelfSection(title: "Artists", items: artists, onHeaderTap: { scope = .artists }) { artist in
            NavigationLink(value: Route.artist(YouTubeID.make(artist.browseId))) {
                AlbumTile(coverArt: artist.thumbnailURL, title: artist.title, subtitle: "Artist", isCircle: true)
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { open(artist) })
        }
        .scrollClipDisabled()
    }

    private func albumShelf(_ albums: [YTBrowseItem]) -> some View {
        ShelfSection(title: "Albums", items: albums, onHeaderTap: { scope = .albums }) { album in
            NavigationLink(value: Route.album(YouTubeID.make(album.browseId))) {
                AlbumTile(coverArt: album.thumbnailURL, title: album.title, subtitle: albumSubtitle(album))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded { open(album) })
        }
        .scrollClipDisabled()
    }

    private func albumGrid(_ albums: [YTBrowseItem]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 16)], spacing: 20) {
            ForEach(albums) { album in
                NavigationLink(value: Route.album(YouTubeID.make(album.browseId))) {
                    AlbumTile(coverArt: album.thumbnailURL, title: album.title, subtitle: albumSubtitle(album))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { open(album) })
            }
        }
        .padding(.horizontal, Theme.margin)
    }

    private func browseList(_ items: [YTBrowseItem], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                SectionHeader(title: title, action: { scope = .playlists })
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 6)
            }
            ForEach(items) { item in
                NavigationLink(value: route(for: item)) {
                    YouTubeBrowseRow(item: item)
                        .padding(.horizontal, Theme.margin)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { open(item) })
                Divider().padding(.leading, Theme.margin + 68)
            }
        }
    }

    // MARK: Helpers

    private func route(for item: YTBrowseItem) -> Route {
        let id = YouTubeID.make(item.browseId)
        switch item.kind {
        case .artist: return .artist(id)
        case .playlist: return .playlist(id)
        case .album, .other: return .album(id)
        }
    }

    private func albumSubtitle(_ album: YTBrowseItem) -> String? {
        [album.artist, album.year.map(String.init)].compactMap { $0 }.joined(separator: " \u{2022} ").nilIfEmpty
    }

    /// The card already knows the title and cover: write them before the detail screen reads the mirror.
    private func open(_ item: YTBrowseItem) {
        onOpen()
        Task { await youtube.seed(item) }
    }
}

extension YTBrowseItem: Identifiable {
    var id: String { browseId }
}

/// A YouTube artist or playlist row: round art for artists, rounded-square for playlists.
struct YouTubeBrowseRow: View {
    let item: YTBrowseItem

    var body: some View {
        HStack(spacing: 12) {
            if item.kind == .artist {
                ArtworkView(coverArt: item.thumbnailURL, pointSize: 56, isCircle: true)
            } else {
                ArtworkView(coverArt: item.thumbnailURL, pointSize: 56, cornerRadius: Theme.Radius.tile)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.kmRowTitle)
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.kmRowSubtitle)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.tertiaryLabel)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
