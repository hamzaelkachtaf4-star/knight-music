import SwiftUI
import WebKit

/// Google sign-in for YouTube Music in an in-app web view. When the page lands on music.youtube.com,
/// `YouTubeAuth.probeScript` confirms Google treats it as logged in; the YouTube cookies are then saved to
/// `YouTubeSession` (Keychain) and `AppModel` is told.
struct YouTubeLoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            YouTubeLoginWebView(onSignedIn: {
                Haptics.success()
                app.youTubeDidSignIn()
                dismiss()
            }, onFailure: { failure = $0 })
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in with Google")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
                .alert("Sign-in failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(failure ?? "")
                }
        }
    }
}

private struct YouTubeLoginWebView: UIViewRepresentable {
    let onSignedIn: () -> Void
    let onFailure: (String) -> Void

    private static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F")!

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn: onSignedIn, onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A throwaway store: the app keeps only the cookies it captures, never a browsing profile.
        configuration.websiteDataStore = .nonPersistent()
        // Google refuses sign-in from web views that don't identify as Safari.
        configuration.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onSignedIn: () -> Void
        private let onFailure: (String) -> Void
        private var capturing = false
        private var finished = false

        init(onSignedIn: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.onSignedIn = onSignedIn
            self.onFailure = onFailure
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !capturing, !finished, webView.url?.host == "music.youtube.com" else { return }
            capturing = true
            Task { await capture(from: webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func capture(from webView: WKWebView) async {
            defer { capturing = false }
            guard let probe = await loggedInProbe(webView) else { return }  // anonymous landing: keep waiting
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            var youTubeCookies: [String: String] = [:]
            for cookie in cookies where YouTubeAuth.isYouTubeCookie(domain: cookie.domain) {
                youTubeCookies[cookie.name] = cookie.value
            }
            do {
                try YouTubeSession.shared.save(YouTubeSessionData(cookies: youTubeCookies, authUser: probe.authUser,
                                                                  visitorData: probe.visitorData, account: nil))
                finished = true
                onSignedIn()
            } catch {
                Log.app.error("YouTube sign-in not saved: \(error.localizedDescription)")
                onFailure(error.localizedDescription)
            }
        }

        /// ytcfg is filled a moment after `didFinish`, so poll briefly before concluding the page is anonymous.
        private func loggedInProbe(_ webView: WKWebView) async -> YouTubeAuth.Probe? {
            for attempt in 0..<8 {
                let raw = try? await webView.evaluateJavaScript(YouTubeAuth.probeScript) as? String
                if let probe = YouTubeAuth.Probe.parse(raw), probe.loggedIn { return probe }
                if attempt < 7 { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            return nil
        }

        private func report(_ error: Error) {
            if (error as? URLError)?.code == .cancelled { return }
            Log.app.error("YouTube sign-in navigation failed: \(error.localizedDescription)")
            onFailure(error.localizedDescription)
        }
    }
}
