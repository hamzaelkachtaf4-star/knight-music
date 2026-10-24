import Foundation
import CryptoKit

/// Signs YouTube Music requests with a Google web session: the `Cookie` header, the `SAPISIDHASH`
/// authorization the web client derives from the SAPISID cookie, and `X-Goog-AuthUser`.
enum YouTubeAuth {
    static let musicOrigin = "https://music.youtube.com"
    static let wwwOrigin = "https://www.youtube.com"

    /// Run in the signed-in page: ytcfg knows whether Google really treats the page as logged in, which
    /// cookie presence alone doesn't prove. Returns a JSON string for `Probe.parse`.
    static let probeScript = """
    (function () {
      try {
        var cfg = window.ytcfg;
        var get = function (key) { return cfg && cfg.get ? cfg.get(key) : null; };
        return JSON.stringify({
          loggedIn: get('LOGGED_IN') === true,
          visitorData: get('VISITOR_DATA') || null,
          sessionIndex: get('SESSION_INDEX')
        });
      } catch (e) {
        return JSON.stringify({ loggedIn: false });
      }
    })();
    """

    struct Probe: Equatable, Sendable {
        var loggedIn: Bool
        var visitorData: String?
        var authUser: String

        static func parse(_ json: String?) -> Probe? {
            guard let json, let root = InnertubeJSON.parse(Data(json.utf8)) else { return nil }
            let index = root.s("sessionIndex") ?? "0"
            return Probe(loggedIn: (root["loggedIn"] as? Bool) ?? false,
                         visitorData: root.s("visitorData"),
                         authUser: Int(index) == nil ? "0" : index)
        }
    }

    /// Only cookies YouTube itself would receive are kept: the header stays small and accounts.google.com
    /// state never leaves the sign-in page.
    static func isYouTubeCookie(domain: String) -> Bool {
        let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    /// The cookie SAPISIDHASH is derived from. `__Secure-3PAPISID` carries the same value on every web session.
    static func sapisid(in cookies: [String: String]) -> String? {
        for name in ["SAPISID", "__Secure-3PAPISID"] {
            if let value = cookies[name], !value.isEmpty { return value }
        }
        return nil
    }

    static func sapisidHash(sapisid: String, origin: String, timestamp: Int) -> String {
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(sapisid) \(origin)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func authorization(sapisid: String, origin: String, now: Date = Date()) -> String {
        let timestamp = Int(now.timeIntervalSince1970)
        return "SAPISIDHASH \(timestamp)_\(sapisidHash(sapisid: sapisid, origin: origin, timestamp: timestamp))"
    }

    static func cookieHeader(_ cookies: [String: String]) -> String {
        cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// Adds the session headers to a request bound for `origin`. No-op without a usable session.
    static func sign(_ request: inout URLRequest, with session: YouTubeSessionData?, origin: String, now: Date = Date()) {
        guard let session, let sapisid = sapisid(in: session.cookies) else { return }
        request.setValue(cookieHeader(session.cookies), forHTTPHeaderField: "Cookie")
        request.setValue(authorization(sapisid: sapisid, origin: origin, now: now), forHTTPHeaderField: "Authorization")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(session.authUser, forHTTPHeaderField: "X-Goog-AuthUser")
    }
}
