import Foundation

/// Null-safe navigation over Innertube's deeply nested JSON (decoded with JSONSerialization).
/// Response shapes drift constantly, so nothing here throws: a missing key is just nil.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func o(_ key: String) -> JSONObject? { self[key] as? JSONObject }
    func a(_ key: String) -> [Any]? { self[key] as? [Any] }
    func s(_ key: String) -> String? {
        if let string = self[key] as? String { return string }
        if let number = self[key] as? NSNumber { return number.stringValue }
        return nil
    }

    /// Concatenated `runs[].text` of a text object under `key`.
    func runs(_ key: String) -> String {
        o(key)?.runsText ?? ""
    }

    var runsText: String {
        (a("runs") ?? []).compactMap { ($0 as? JSONObject)?.s("text") }.joined()
    }

    var runList: [JSONObject] {
        (a("runs") ?? []).compactMap { $0 as? JSONObject }
    }

    /// The largest thumbnail under `thumbnail.musicThumbnailRenderer.thumbnail.thumbnails` (or a direct `thumbnails`).
    var bestThumbnail: String? {
        let list = o("musicThumbnailRenderer")?.o("thumbnail")?.a("thumbnails") ?? a("thumbnails")
        return (list?.last as? JSONObject)?.s("url")
    }

    /// Catalogue art is square; a music-video upload is widescreen.
    var thumbnailIsWidescreen: Bool {
        let list = o("musicThumbnailRenderer")?.o("thumbnail")?.a("thumbnails") ?? a("thumbnails")
        guard let last = list?.last as? JSONObject,
              let width = (last["width"] as? NSNumber)?.doubleValue,
              let height = (last["height"] as? NSNumber)?.doubleValue, width > 0, height > 0 else { return false }
        let ratio = width / height
        return ratio < 0.85 || ratio > 1.15
    }

    /// `browseEndpoint.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig.pageType`.
    var pageType: String {
        o("browseEndpointContextSupportedConfigs")?.o("browseEndpointContextMusicConfig")?.s("pageType") ?? ""
    }
}

enum InnertubeJSON {
    static func parse(_ data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    /// Depth-first collection of every object stored under `name`. Array order is kept; sibling keys are walked
    /// sorted because Swift dictionaries have no order, and results must not reshuffle between runs.
    /// A match is not searched inside (renderers never nest themselves).
    static func collect(_ name: String, in root: Any) -> [JSONObject] {
        var out: [JSONObject] = []
        func walk(_ node: Any) {
            if let object = node as? JSONObject {
                if let match = object[name] as? JSONObject { out.append(match) }
                for key in object.keys.sorted() where key != name { walk(object[key] as Any) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            }
        }
        walk(root)
        return out
    }

    /// First string stored under `key` anywhere in the tree.
    static func findString(_ key: String, in root: Any) -> String? {
        if let object = root as? JSONObject {
            if let value = object[key] as? String { return value }
            for (_, value) in object { if let found = findString(key, in: value) { return found } }
        } else if let array = root as? [Any] {
            for value in array { if let found = findString(key, in: value) { return found } }
        }
        return nil
    }
}
