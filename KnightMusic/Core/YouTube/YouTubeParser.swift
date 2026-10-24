import Foundation

/// Reads YouTube Music (WEB_REMIX) responses into plain values. Shapes drift, so every reader walks for the
/// renderer it needs instead of trusting a fixed path, and a missing field yields nil rather than a throw.
/// Ported from BitChord's InnertubeParser.
enum YouTubeParser {
    // MARK: Search

    static func search(_ root: JSONObject) -> YTSearchResults {
        var results = YTSearchResults()
        var seenTracks = Set<String>()
        var seenBrowse = Set<String>()

        func add(_ item: YTBrowseItem) {
            guard seenBrowse.insert(item.browseId).inserted else { return }
            switch item.kind {
            case .album: results.albums.append(item)
            case .artist: results.artists.append(item)
            case .playlist: results.playlists.append(item)
            case .other: break
            }
        }
        func add(_ track: YTTrack) {
            guard !track.isVideo, seenTracks.insert(track.videoId).inserted else { return }
            results.tracks.append(track)
        }

        // The promoted top result is a card shelf. An artist card bills the rows tucked under it ("Song • 3:16").
        for card in InnertubeJSON.collect("musicCardShelfRenderer", in: root) {
            if let browse = cardBrowseItem(card) { add(browse) }
            if let track = cardTrack(card) { add(track) }
            let credit = cardCredit(card)
            for row in InnertubeJSON.collect("musicResponsiveListItemRenderer", in: card) {
                if let track = responsiveTrack(row, fallback: credit) { add(track) }
            }
        }
        for row in InnertubeJSON.collect("musicResponsiveListItemRenderer", in: root) {
            // Browse rows first: an album row also carries a "play album" videoId in its overlay.
            if let browse = browseItem(row) {
                add(browse)
            } else if let track = responsiveTrack(row, fallback: Credit()) {
                add(track)
            }
        }
        return results
    }

    static func suggestions(_ root: JSONObject) -> [String] {
        var seen = Set<String>()
        return InnertubeJSON.collect("searchSuggestionRenderer", in: root).compactMap { renderer in
            let query = renderer.o("navigationEndpoint")?.o("searchEndpoint")?.s("query") ?? renderer.runs("suggestion")
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    // MARK: Album / playlist

    static func album(_ root: JSONObject, browseId: String) -> YTAlbumPage? {
        guard let header = pageHeader(root) else { return nil }
        let title = header.runs("title")
        guard !title.isEmpty else { return nil }
        let credit = releaseCredit(header)
        let year = header.o("subtitle").flatMap { yearIn($0.runsText) }
        let thumbnail = InnertubeJSON.collect("musicThumbnailRenderer", in: header).first.flatMap { $0.o("thumbnail")?.bestThumbnail }

        var tracks: [YTTrack] = []
        var seen = Set<String>()
        for (offset, row) in albumRows(root).enumerated() {
            guard var track = responsiveTrack(row, fallback: credit) else { continue }
            guard seen.insert(track.videoId).inserted else { continue }
            track.album = title
            track.albumId = browseId
            track.year = year
            track.trackNumber = Int(row.runs("index")) ?? offset + 1
            if track.thumbnailURL == nil { track.thumbnailURL = thumbnail }
            tracks.append(track)
        }
        return YTAlbumPage(browseId: browseId, title: title, artist: credit.artist, artistId: credit.artistId,
                           year: year, thumbnailURL: thumbnail, tracks: tracks)
    }

    static func playlist(_ root: JSONObject, browseId: String) -> YTPlaylistPage? {
        let header = pageHeader(root)
        let title = header?.runs("title") ?? ""
        let shelf = InnertubeJSON.collect("musicPlaylistShelfRenderer", in: root).first
            ?? root.o("continuationContents")?.o("musicPlaylistShelfContinuation")
        guard !title.isEmpty || shelf != nil else { return nil }
        let rows = shelf.map { InnertubeJSON.collect("musicResponsiveListItemRenderer", in: $0) } ?? []
        var seen = Set<String>()
        let tracks = rows.compactMap { responsiveTrack($0, fallback: Credit()) }
            .filter { seen.insert($0.videoId).inserted }
        let thumbnail = header.flatMap { InnertubeJSON.collect("musicThumbnailRenderer", in: $0).first }
            .flatMap { $0.o("thumbnail")?.bestThumbnail }
        let author = header.map { $0.runs("straplineTextOne") }.flatMap { $0.isEmpty ? nil : $0 }
        return YTPlaylistPage(browseId: browseId, title: title, author: author, thumbnailURL: thumbnail,
                              tracks: tracks, continuation: shelf.flatMap(continuation))
    }

    // MARK: Artist

    static func artist(_ root: JSONObject, browseId: String) -> YTArtistPage? {
        guard let header = root.o("header") else { return nil }
        let renderer = header.o("musicImmersiveHeaderRenderer") ?? header.o("musicVisualHeaderRenderer")
        guard let renderer else { return nil }
        let name = renderer.runs("title")
        guard !name.isEmpty else { return nil }
        let thumbnail = (renderer.o("thumbnail") ?? renderer.o("foregroundThumbnail"))?.bestThumbnail
            ?? InnertubeJSON.collect("musicThumbnailRenderer", in: renderer).first.flatMap { $0.o("thumbnail")?.bestThumbnail }
        let credit = Credit(artist: name, artistId: browseId)

        var topTracks: [YTTrack] = []
        var albums: [YTBrowseItem] = []
        var singles: [YTBrowseItem] = []
        for section in sections(root) {
            if let shelf = section.o("musicShelfRenderer"), topTracks.isEmpty {
                topTracks = (shelf.a("contents") ?? []).compactMap {
                    responsiveTrack(($0 as? JSONObject)?.o("musicResponsiveListItemRenderer"), fallback: credit)
                }
            }
            if let carousel = section.o("musicCarouselShelfRenderer") {
                let title = carousel.o("header")?.o("musicCarouselShelfBasicHeaderRenderer")?.runs("title").lowercased() ?? ""
                let items = (carousel.a("contents") ?? []).compactMap { twoRowItem(($0 as? JSONObject)?.o("musicTwoRowItemRenderer")) }
                    .compactMap { item -> YTBrowseItem? in
                        guard case .browse(var browse) = item, browse.kind == .album else { return nil }
                        browse.artist = browse.artist ?? name
                        browse.artistId = browse.artistId ?? browseId
                        return browse
                    }
                if title.contains("single") {
                    singles += items
                } else if title.contains("album") {
                    albums += items
                }
            }
        }
        let about = InnertubeJSON.collect("musicDescriptionShelfRenderer", in: root).first?.runs("description")
        return YTArtistPage(browseId: browseId, name: name, thumbnailURL: thumbnail,
                            about: about.flatMap { $0.isEmpty ? nil : $0 },
                            topTracks: topTracks, albums: albums, singles: singles)
    }

    // MARK: Radio (`next`)

    static func watchQueue(_ root: JSONObject) -> [YTTrack] {
        var out: [YTTrack] = []
        var seen = Set<String>()
        for renderer in InnertubeJSON.collect("playlistPanelVideoRenderer", in: root) {
            guard let videoId = renderer.s("videoId"), seen.insert(videoId).inserted else { continue }
            let title = renderer.runs("title")
            guard !title.isEmpty else { continue }
            let runs = renderer.o("longBylineText")?.runList ?? []
            let parts = segments(runs)
            let credit = credits(runs)
            let byline = parts.first.map { $0.map { $0.s("text") ?? "" }.joined() }?.trimmingCharacters(in: .whitespaces)
            let isVideo = parts.contains { $0.contains { ($0.s("text") ?? "").localizedCaseInsensitiveContains("views") } }
            out.append(YTTrack(
                videoId: videoId, title: title,
                artist: byline.flatMap { $0.isEmpty ? nil : $0 } ?? credit.artist,
                artistId: credit.artistId, album: credit.album, albumId: credit.albumId,
                durationSeconds: duration(renderer.runs("lengthText")),
                thumbnailURL: renderer.o("thumbnail")?.bestThumbnail,
                year: parts.compactMap { yearIn($0.map { $0.s("text") ?? "" }.joined()) }.last,
                isExplicit: hasExplicitBadge(renderer["badges"]),
                isVideo: isVideo))
        }
        return out
    }

    // MARK: Home

    static func home(_ root: JSONObject) -> [YTHomeShelf] {
        InnertubeJSON.collect("musicCarouselShelfRenderer", in: root).compactMap { carousel in
            let title = carousel.o("header")?.o("musicCarouselShelfBasicHeaderRenderer")?.runs("title") ?? ""
            guard !title.isEmpty, !mentionsVideos(title) else { return nil }
            let items: [YTShelfItem] = (carousel.a("contents") ?? []).compactMap { raw in
                guard let item = raw as? JSONObject else { return nil }
                if let two = twoRowItem(item.o("musicTwoRowItemRenderer")) { return two }
                if let row = item.o("musicResponsiveListItemRenderer") {
                    if let track = responsiveTrack(row, fallback: Credit()), !track.isVideo { return .track(track) }
                    if let browse = browseItem(row) { return .browse(browse) }
                }
                return nil
            }
            return items.isEmpty ? nil : YTHomeShelf(title: title, items: items)
        }
    }

    // MARK: Session

    static func visitorData(_ root: JSONObject) -> String? {
        root.o("responseContext")?.s("visitorData")
    }

    static func continuation(_ root: JSONObject) -> String? {
        if let token = InnertubeJSON.collect("continuationItemRenderer", in: root).first?
            .o("continuationEndpoint")?.o("continuationCommand")?.s("token") { return token }
        return InnertubeJSON.collect("nextContinuationData", in: root).first?.s("continuation")
    }

    // MARK: Text helpers

    /// "5:38" / "1:02:03" → seconds.
    static func duration(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count >= 2, parts.count <= 3 else { return nil }
        var total = 0
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    // MARK: - Renderers

    private struct Credit {
        var artist: String?
        var artistId: String?
        var album: String?
        var albumId: String?
    }

    private static let typeWords: Set<String> = ["song", "video", "album", "single", "ep", "artist", "playlist", "podcast", "episode", "profile", "station"]

    private static func responsiveTrack(_ renderer: JSONObject?, fallback: Credit) -> YTTrack? {
        guard let renderer else { return nil }
        let videoId = renderer.o("playlistItemData")?.s("videoId")
            ?? renderer.o("overlay")?.o("musicItemThumbnailOverlayRenderer")?.o("content")?
                .o("musicPlayButtonRenderer")?.o("playNavigationEndpoint")?.o("watchEndpoint")?.s("videoId")
        guard let videoId else { return nil }
        let columns = (renderer.a("flexColumns") ?? []).compactMap {
            ($0 as? JSONObject)?.o("musicResponsiveListItemFlexColumnRenderer")?.o("text")
        }
        guard let title = columns.first?.runsText, !title.isEmpty else { return nil }

        let subtitleRuns = columns.count > 1 ? columns[1].runList : []
        let parts = segments(subtitleRuns).map { $0.map { $0.s("text") ?? "" }.joined().trimmingCharacters(in: .whitespaces) }
        let rowType = parts.first { typeWords.contains($0.lowercased()) }?.lowercased()
        let fixed = (renderer.a("fixedColumns") ?? []).compactMap {
            ($0 as? JSONObject)?.o("musicResponsiveListItemFixedColumnRenderer")?.o("text")?.runsText
        }
        let seconds = parts.compactMap(duration).last ?? fixed.compactMap(duration).first

        let credit = credits(columns.flatMap(\.runList))
        let linkedArtists = artistNames(subtitleRuns)
        let plainArtist = parts.first { !$0.isEmpty && duration($0) == nil && !typeWords.contains($0.lowercased()) && !isTally($0) }
        let thumbnail = renderer.o("thumbnail")

        return YTTrack(
            videoId: videoId, title: title,
            artist: linkedArtists ?? credit.artist ?? plainArtist ?? fallback.artist,
            artistId: credit.artistId ?? fallback.artistId,
            album: credit.album ?? fallback.album,
            albumId: credit.albumId ?? fallback.albumId,
            durationSeconds: seconds,
            thumbnailURL: thumbnail?.bestThumbnail,
            isExplicit: hasExplicitBadge(renderer["badges"]) || hasExplicitBadge(renderer["subtitleBadges"]),
            isVideo: rowType == "video" || (thumbnail?.thumbnailIsWidescreen ?? false))
    }

    private static func browseItem(_ renderer: JSONObject) -> YTBrowseItem? {
        guard let endpoint = renderer.o("navigationEndpoint")?.o("browseEndpoint"),
              let browseId = endpoint.s("browseId") else { return nil }
        let columns = (renderer.a("flexColumns") ?? []).compactMap {
            ($0 as? JSONObject)?.o("musicResponsiveListItemFlexColumnRenderer")?.o("text")
        }
        guard let title = columns.first?.runsText, !title.isEmpty else { return nil }
        let subtitleRuns = columns.count > 1 ? columns[1].runList : []
        let subtitle = subtitleRuns.map { $0.s("text") ?? "" }.joined()
        guard !mentionsVideos(title), !mentionsVideos(subtitle) else { return nil }
        return makeBrowse(browseId: browseId, pageType: endpoint.pageType, title: title, subtitleRuns: subtitleRuns,
                          thumbnail: renderer.o("thumbnail")?.bestThumbnail)
    }

    private static func cardBrowseItem(_ card: JSONObject) -> YTBrowseItem? {
        guard let endpoint = card.o("onTap")?.o("browseEndpoint"), let browseId = endpoint.s("browseId") else { return nil }
        let title = card.runs("title")
        guard !title.isEmpty else { return nil }
        let subtitleRuns = card.o("subtitle")?.runList ?? []
        return makeBrowse(browseId: browseId, pageType: endpoint.pageType, title: title, subtitleRuns: subtitleRuns,
                          thumbnail: card.o("thumbnail")?.bestThumbnail)
    }

    private static func cardTrack(_ card: JSONObject) -> YTTrack? {
        guard let videoId = card.o("onTap")?.o("watchEndpoint")?.s("videoId") else { return nil }
        let title = card.runs("title")
        guard !title.isEmpty else { return nil }
        let runs = card.o("subtitle")?.runList ?? []
        let parts = segments(runs).map { $0.map { $0.s("text") ?? "" }.joined().trimmingCharacters(in: .whitespaces) }
        let credit = credits(runs)
        let rowType = parts.first { typeWords.contains($0.lowercased()) }?.lowercased()
        return YTTrack(videoId: videoId, title: title,
                       artist: artistNames(runs) ?? credit.artist,
                       artistId: credit.artistId, album: credit.album, albumId: credit.albumId,
                       durationSeconds: parts.compactMap(duration).last,
                       thumbnailURL: card.o("thumbnail")?.bestThumbnail,
                       isExplicit: hasExplicitBadge(card["subtitleBadges"]),
                       isVideo: rowType == "video" || (card.o("thumbnail")?.thumbnailIsWidescreen ?? false))
    }

    /// An artist card's credit, lent to the rows under it (a song card's rows are other people's uploads).
    private static func cardCredit(_ card: JSONObject) -> Credit {
        guard let endpoint = card.o("onTap")?.o("browseEndpoint"), endpoint.pageType.contains("ARTIST") else { return Credit() }
        let name = card.runs("title")
        return name.isEmpty ? Credit() : Credit(artist: name, artistId: endpoint.s("browseId"))
    }

    private static func twoRowItem(_ renderer: JSONObject?) -> YTShelfItem? {
        guard let renderer else { return nil }
        let title = renderer.runs("title")
        guard !title.isEmpty else { return nil }
        let endpoint = renderer.o("navigationEndpoint")
        let browse = endpoint?.o("browseEndpoint")
        let browseId = browse?.s("browseId")
        let subtitleRuns = renderer.o("subtitle")?.runList ?? []
        let thumbnail = renderer.o("thumbnailRenderer")?.bestThumbnail
        // Cards for uncatalogued audio carry `MPED<videoId>` instead of a watch endpoint.
        let videoId = endpoint?.o("watchEndpoint")?.s("videoId")
            ?? browseId.flatMap { $0.hasPrefix("MPED") ? String($0.dropFirst(4)) : nil }
        if let browseId, !browseId.hasPrefix("MPED") {
            let subtitle = subtitleRuns.map { $0.s("text") ?? "" }.joined()
            if !browseId.hasPrefix("VL") && !browseId.hasPrefix("MPRE") && !browseId.hasPrefix("UC")
                && (mentionsVideos(title) || mentionsVideos(subtitle)) { return nil }
            return .browse(makeBrowse(browseId: browseId, pageType: browse?.pageType ?? "", title: title,
                                      subtitleRuns: subtitleRuns, thumbnail: thumbnail))
        }
        guard let videoId else { return nil }
        if renderer.o("thumbnailRenderer")?.thumbnailIsWidescreen ?? false { return nil }
        let credit = credits(subtitleRuns)
        let parts = segments(subtitleRuns).map { $0.map { $0.s("text") ?? "" }.joined().trimmingCharacters(in: .whitespaces) }
        let plain = parts.first { !$0.isEmpty && !typeWords.contains($0.lowercased()) && !isTally($0) && duration($0) == nil }
        return .track(YTTrack(videoId: videoId, title: title, artist: artistNames(subtitleRuns) ?? credit.artist ?? plain,
                              artistId: credit.artistId, album: credit.album, albumId: credit.albumId,
                              thumbnailURL: thumbnail))
    }

    private static func makeBrowse(browseId: String, pageType: String, title: String, subtitleRuns: [JSONObject], thumbnail: String?) -> YTBrowseItem {
        let kind: YTBrowseKind
        if pageType.contains("ALBUM") || browseId.hasPrefix("MPRE") { kind = .album }
        else if pageType.contains("ARTIST") || pageType.contains("USER_CHANNEL") || browseId.hasPrefix("UC") { kind = .artist }
        else if pageType.contains("PLAYLIST") || browseId.hasPrefix("VL") { kind = .playlist }
        else { kind = .other }
        let parts = segments(subtitleRuns).map { $0.map { $0.s("text") ?? "" }.joined().trimmingCharacters(in: .whitespaces) }
        let credit = credits(subtitleRuns)
        var artist: String?
        if kind == .album {
            artist = artistNames(subtitleRuns) ?? credit.artist
                ?? parts.first { !$0.isEmpty && !typeWords.contains($0.lowercased()) && Int($0) == nil && !isTally($0) }
        }
        return YTBrowseItem(browseId: browseId, title: title, subtitle: parts.joined(separator: " • "),
                            thumbnailURL: thumbnail, kind: kind, artist: artist, artistId: credit.artistId,
                            year: kind == .album ? parts.compactMap { Int($0) }.first { (1000...2999).contains($0) } : nil)
    }

    // MARK: Run helpers

    /// Splits a run list on its " • " separator runs.
    private static func segments(_ runs: [JSONObject]) -> [[JSONObject]] {
        var groups: [[JSONObject]] = [[]]
        for run in runs {
            if (run.s("text") ?? "").trimmingCharacters(in: .whitespaces) == "•" {
                groups.append([])
            } else {
                groups[groups.count - 1].append(run)
            }
        }
        return groups.filter { !$0.isEmpty }
    }

    /// First linked artist and album in a run list.
    private static func credits(_ runs: [JSONObject]) -> Credit {
        var credit = Credit()
        for run in runs {
            guard let browse = run.o("navigationEndpoint")?.o("browseEndpoint"), let id = browse.s("browseId") else { continue }
            let type = browse.pageType
            let name = run.s("text") ?? ""
            if type.contains("ARTIST") || type.contains("USER_CHANNEL") {
                if credit.artistId == nil { credit.artistId = id; credit.artist = name }
            } else if type.contains("ALBUM"), credit.albumId == nil {
                credit.albumId = id
                credit.album = name
            }
        }
        return credit
    }

    /// The whole artist segment ("A, B & C"), linked names or not, when one of its runs links an artist.
    private static func artistNames(_ runs: [JSONObject]) -> String? {
        for group in segments(runs) {
            let linksArtist = group.contains { run in
                let type = run.o("navigationEndpoint")?.o("browseEndpoint")?.pageType ?? ""
                return type.contains("ARTIST") || type.contains("USER_CHANNEL")
            }
            if linksArtist {
                let text = group.map { $0.s("text") ?? "" }.joined().trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : text
            }
        }
        return nil
    }

    /// A release header's credit: "Daft Punk" in the strapline (current layout) or "Album • Artist • 2013".
    private static func releaseCredit(_ header: JSONObject) -> Credit {
        let lines = ["straplineTextOne", "subtitle"].compactMap { header.o($0)?.runList }
        for runs in lines {
            let credit = credits(runs)
            if let names = artistNames(runs) {
                return Credit(artist: names, artistId: credit.artistId)
            }
        }
        if let strap = header.o("straplineTextOne")?.runsText, !strap.isEmpty { return Credit(artist: strap) }
        let parts = (header.o("subtitle")?.runsText ?? "").components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }
        let name = parts.first { !$0.isEmpty && !typeWords.contains($0.lowercased()) && Int($0) == nil && !isTally($0) }
        return Credit(artist: name)
    }

    private static func pageHeader(_ root: JSONObject) -> JSONObject? {
        for name in ["musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer"] {
            if let header = InnertubeJSON.collect(name, in: root).first {
                if name == "musicEditablePlaylistDetailHeaderRenderer",
                   let inner = InnertubeJSON.collect("musicResponsiveHeaderRenderer", in: header).first { return inner }
                return header
            }
        }
        return nil
    }

    /// An album's own track rows: the shelf in the secondary column, not the recommendation carousels.
    private static func albumRows(_ root: JSONObject) -> [JSONObject] {
        let scope: Any = root.o("contents")?.o("twoColumnBrowseResultsRenderer")?.o("secondaryContents") ?? root
        if let shelf = InnertubeJSON.collect("musicShelfRenderer", in: scope).first {
            return InnertubeJSON.collect("musicResponsiveListItemRenderer", in: shelf)
        }
        return InnertubeJSON.collect("musicResponsiveListItemRenderer", in: scope)
    }

    private static func sections(_ root: JSONObject) -> [JSONObject] {
        let tab = (root.o("contents")?.o("singleColumnBrowseResultsRenderer")?.a("tabs")?.first as? JSONObject)?.o("tabRenderer")
        return (tab?.o("content")?.o("sectionListRenderer")?.a("contents") ?? []).compactMap { $0 as? JSONObject }
    }

    private static func yearIn(_ text: String) -> Int? {
        text.components(separatedBy: " • ").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .first { (1000...2999).contains($0) }
    }

    private static func isTally(_ text: String) -> Bool {
        text.range(of: #"^[\d.,]+\s*[KMB]?\s+(plays|views|likes|songs|tracks|subscribers|monthly|hours?|minutes?|seconds?)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func mentionsVideos(_ text: String) -> Bool {
        text.range(of: #"\bvideos?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func hasExplicitBadge(_ node: Any?) -> Bool {
        switch node {
        case let string as String: return string == "MUSIC_EXPLICIT_BADGE"
        case let array as [Any]: return array.contains { hasExplicitBadge($0) }
        case let object as JSONObject: return object.values.contains { hasExplicitBadge($0) }
        default: return false
        }
    }
}
