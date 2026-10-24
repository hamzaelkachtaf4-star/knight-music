import Foundation

/// The signed-in Google session for YouTube Music, kept in the Keychain. `YouTubeClient` is an actor and the
/// UI is main-actor, so access is lock-guarded rather than bound to either.
final class YouTubeSession: @unchecked Sendable {
    static let shared = YouTubeSession()

    private static let keychainAccount = "youtube-session"
    private let lock = NSLock()
    private var stored: YouTubeSessionData?

    private init() {
        if let json = Keychain.get(account: Self.keychainAccount),
           let data = try? JSONDecoder().decode(YouTubeSessionData.self, from: Data(json.utf8)),
           YouTubeAuth.sapisid(in: data.cookies) != nil {
            stored = data
        }
    }

    /// The session to sign requests with; nil when signed out.
    var current: YouTubeSessionData? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    var isSignedIn: Bool { current != nil }

    /// Throws when the cookies carry no SAPISID (the user did not actually sign in) or can't be persisted.
    func save(_ data: YouTubeSessionData) throws {
        guard YouTubeAuth.sapisid(in: data.cookies) != nil else { throw YouTubeError.notSignedIn }
        try persist(data)
    }

    /// Attaches the account shown in Settings. Ignored if the user signed out meanwhile.
    func setAccount(_ account: YTAccount) {
        lock.lock()
        guard var data = stored else { lock.unlock(); return }
        data.account = account
        lock.unlock()
        do { try persist(data) } catch { Log.app.error("YouTube account not persisted: \(error.localizedDescription)") }
    }

    func signOut() {
        Keychain.delete(account: Self.keychainAccount)
        lock.lock(); stored = nil; lock.unlock()
    }

    private func persist(_ data: YouTubeSessionData) throws {
        let encoded = try JSONEncoder().encode(data)
        try Keychain.set(String(decoding: encoded, as: UTF8.self), account: Self.keychainAccount)
        lock.lock(); stored = data; lock.unlock()
    }
}
