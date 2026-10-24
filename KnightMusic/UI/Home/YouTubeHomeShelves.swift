import SwiftUI

/// The YouTube Music Home feed (Quick picks, mixes, new releases…) for the on-device library. Shown from the
/// copy cached in the mirror at once, refreshed in the background when stale.
struct YouTubeHomeShelves: View {
    @Environment(YouTubeLibrary.self) private var youtube
    @Environment(PlayerEngine.self) private var player
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if youtube.homeShelves.isEmpty {
                if youtube.isLoadingHome {
                    SkeletonRowList(count: 4)
                } else {
                    EmptyStateView(title: "YouTube Music", systemImage: "music.note.house",
                                   message: "Search for a song, album or artist to start listening.",
                                   actionTitle: "Load Recommendations",
                                   action: { Task { await youtube.loadHome(force: true) } })
                }
            } else {
                ForEach(youtube.homeShelves, id: \.title) { shelf in
                    if shelf.items.allSatisfy(\.isTrack) {
                        trackColumns(shelf)
                    } else {
                        tileShelf(shelf)
                    }
                }
            }
        }
        .task { await youtube.loadHome() }
    }

    /// "Quick picks": three rows of songs, paged sideways, like Continue Listening.
    private func trackColumns(_ shelf: YTHomeShelf) -> some View {
        let tracks = shelf.items.compactMap(\.track)
        let columnWidth: CGFloat = sizeClass == .regular ? 340 : 300
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: shelf.title)
                .padding(.horizontal, Theme.margin)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(rows: Array(repeating: GridItem(.fixed(56), spacing: 4), count: min(3, max(tracks.count, 1))), spacing: 18) {
                    ForEach(Array(tracks.enumerated()), id: \.element.videoId) { index, track in
                        Button {
                            play(tracks, startAt: index)
                        } label: {
                            SongRow(song: YouTubeMapping.song(track),
                                    isPlaying: player.currentSong?.id == YouTubeID.make(track.videoId),
                                    isPaused: !player.isPlaying) { EmptyView() }
                        }
                        .buttonStyle(.plain)
                        .frame(width: columnWidth)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, Theme.margin, for: .scrollContent)
        }
    }

    private func tileShelf(_ shelf: YTHomeShelf) -> some View {
        let tracks = shelf.items.compactMap(\.track)
        return ShelfSection(title: shelf.title, items: shelf.items.map(HomeTile.init)) { tile in
            switch tile.item {
            case .track(let track):
                Button {
                    play(tracks, startAt: tracks.firstIndex(of: track) ?? 0)
                } label: {
                    AlbumTile(coverArt: track.thumbnailURL, title: track.title, subtitle: track.artist)
                }
                .buttonStyle(.plain)
            case .browse(let item):
                NavigationLink(value: route(for: item)) {
                    AlbumTile(coverArt: item.thumbnailURL, title: item.title,
                              subtitle: item.subtitle.isEmpty ? nil : item.subtitle, isCircle: item.kind == .artist)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Task { await youtube.seed(item) } })
            }
        }
        .scrollClipDisabled()
    }

    private func play(_ tracks: [YTTrack], startAt index: Int) {
        Haptics.impact(.light)
        Task {
            let songs = await youtube.songsForPlayback(tracks)
            guard !songs.isEmpty else { return }
            player.play(songs, startAt: min(index, songs.count - 1), shuffle: false)
        }
    }

    private func route(for item: YTBrowseItem) -> Route {
        let id = YouTubeID.make(item.browseId)
        switch item.kind {
        case .artist: return .artist(id)
        case .playlist: return .playlist(id)
        case .album, .other: return .album(id)
        }
    }

    private struct HomeTile: Identifiable {
        let item: YTShelfItem
        var id: String {
            switch item {
            case .track(let track): return "t:" + track.videoId
            case .browse(let browse): return "b:" + browse.browseId
            }
        }
    }
}

private extension YTShelfItem {
    var isTrack: Bool { track != nil }
    var track: YTTrack? {
        if case .track(let track) = self { return track }
        return nil
    }
}
