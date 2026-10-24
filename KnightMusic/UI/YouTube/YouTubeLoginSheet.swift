import SwiftUI
import WebKit

/// Google sign-in for YouTube Music in an in-app web view (ported from BitChord's YtMusicLoginScreen).
/// When the page lands on music.youtube.com, `YouTubeAuth.probeScript` confirms Google treats it as logged in;
/// the session cookies are saved to `YouTubeSession` (Keychain) and `AppModel` is updated.
struct YouTubeLoginSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var failure: String?
    @State private var isProcessing = false
    @State private var triggerManualCapture = false

    var body: some View {
        NavigationStack {
            YouTubeLoginWebView(
                triggerCapture: $triggerManualCapture,
                isProcessing: $isProcessing,
                onSignedIn: {
                    Haptics.success()
                    app.youTubeDidSignIn()
                    dismiss()
                },
                onFailure: { error in
                    isProcessing = false
                    failure = error
                }
            )
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in to YouTube Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        isProcessing = true
                        triggerManualCapture = true
                    } label: {
                        if isProcessing {
                            ProgressView()
                        } else {
                            Text("I'm Signed In")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }
                    .disabled(isProcessing)
                }
            }
            .alert("Sign-in Failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
        }
    }
}

private struct YouTubeLoginWebView: UIViewRepresentable {
    @Binding var triggerCapture: Bool
    @Binding var isProcessing: Bool
    let onSignedIn: () -> Void
    let onFailure: (String) -> Void

    private static let loginURL = URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&prompt=select_account&continue=https%3A%2F%2Fmusic.youtube.com%2F")!
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"

    func makeCoordinator() -> Coordinator {
        Coordinator(onSignedIn: onSignedIn, onFailure: onFailure)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/18.2 Mobile/15E148 Safari/604.1"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.webView = webView
        if triggerCapture {
            DispatchQueue.main.async { triggerCapture = false }
            context.coordinator.manualCapture()
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let onSignedIn: () -> Void
        private let onFailure: (String) -> Void
        private var capturing = false
        private var finished = false
        private var pollTask: Task<Void, Never>?

        init(onSignedIn: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.onSignedIn = onSignedIn
            self.onFailure = onFailure
            super.init()
            startPolling()
        }

        deinit {
            pollTask?.cancel()
        }

        private func startPolling() {
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let self, !self.capturing, !self.finished, let wv = self.webView else { continue }
                    if let host = wv.url?.host, host.contains("music.youtube.com") {
                        await self.capture(from: wv, isExplicit: false)
                    }
                }
            }
        }

        func manualCapture() {
            guard let webView, !capturing, !finished else { return }
            capturing = true
            Task { await capture(from: webView, isExplicit: true) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !capturing, !finished, webView.url?.host?.contains("music.youtube.com") == true else { return }
            capturing = true
            Task { await capture(from: webView, isExplicit: false) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        private func capture(from webView: WKWebView, isExplicit: Bool) async {
            defer { capturing = false }
            let probe = await loggedInProbe(webView)
            // If the probe confirms loggedIn or if the user explicitly clicked "I'm Signed In" on music.youtube.com
            let isMusicHost = webView.url?.host?.contains("music.youtube.com") == true
            guard let probe = probe, probe.loggedIn || (isExplicit && isMusicHost) else {
                if isExplicit {
                    onFailure("Please finish signing in on the Google page before confirming.")
                }
                return
            }

            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            var sessionCookies: [String: String] = [:]
            for cookie in cookies {
                let domain = cookie.domain.lowercased()
                if domain.contains("youtube.com") || domain.contains("google.com") {
                    sessionCookies[cookie.name] = cookie.value
                }
            }

            guard YouTubeAuth.sapisid(in: sessionCookies) != nil || isMusicHost else {
                if isExplicit {
                    onFailure("Google session cookies not found yet. Please wait for the page to finish loading.")
                }
                return
            }

            do {
                try YouTubeSession.shared.save(
                    YouTubeSessionData(
                        cookies: sessionCookies,
                        authUser: probe.authUser,
                        visitorData: probe.visitorData,
                        account: nil
                    )
                )
                finished = true
                pollTask?.cancel()
                onSignedIn()
            } catch {
                Log.app.error("YouTube sign-in not saved: \(error.localizedDescription)")
                onFailure(error.localizedDescription)
            }
        }

        /// ytcfg is filled a moment after navigation lands, so probe up to 6 times.
        private func loggedInProbe(_ webView: WKWebView) async -> YouTubeAuth.Probe? {
            for attempt in 0..<6 {
                let raw = try? await webView.evaluateJavaScript(YouTubeAuth.probeScript) as? String
                if let probe = YouTubeAuth.Probe.parse(raw), probe.loggedIn { return probe }
                if attempt < 5 { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            return nil
        }

        private func report(_ error: Error) {
            if (error as? URLError)?.code == .cancelled { return }
            Log.app.error("YouTube sign-in navigation failed: \(error.localizedDescription)")
        }
    }
}
