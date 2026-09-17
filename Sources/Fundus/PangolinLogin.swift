import SwiftUI
import WebKit

/// Überträgt Cookies zwischen dem Login-WebView und der URLSession der App.
///
/// Der WebView nutzt den persistenten `WKWebsiteDataStore.default()`, deshalb überlebt die
/// Pangolin-Session einen Neustart der App. Beim Start wird sie von dort in
/// `HTTPCookieStorage.shared` zurückkopiert.
@MainActor
enum CookieBridge {
    static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }

    static func syncFromWebView(host: String) async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies where matches(cookie, host: host) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    static func clearAll() async {
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// Hält den WebView, damit die Sheet-Buttons darin navigieren können.
@MainActor
final class WebViewHandle {
    weak var webView: WKWebView?

    /// Klickt auf der Pocket-ID-Seite den Link zu den Alternativen (QR-Code / Logincode).
    func openAlternativeLogin() {
        let js = """
        const a = [...document.querySelectorAll('a,button')].find(x => /Alternative|another device|other/i.test(x.innerText));
        if (a) { a.click(); true } else { false }
        """
        webView?.evaluateJavaScript(js)
    }
}

struct PangolinLoginSheet: View {
    @Environment(AppModel.self) private var model
    @State private var currentURL: URL?
    @State private var handle = WebViewHandle()
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text(currentURL?.host() ?? model.serverURL?.host() ?? "")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
                Button("Abbrechen") { model.showLogin = false }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Text(model.loginHint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            if onIdentityProvider {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(.orange)
                    Text("Passkeys aus dem Schlüsselbund gehen in diesem Fenster nicht, das erlaubt macOS nur signierten Browsern. Nimm \"Mit einem anderen Gerät anmelden\" (QR-Code mit dem iPhone scannen) oder einen Logincode.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Alternativen") { handle.openAlternativeLogin() }
                }
                .padding(10)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

            Divider()

            if let url = model.serverURL {
                LoginWebView(startURL: url, handle: handle, currentURL: $currentURL) { landedURL in
                    guard landedURL.host() == url.host() else { return }
                    isChecking = true
                    Task {
                        await model.loginWebViewLanded()
                        isChecking = false
                    }
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 740)
    }

    private var onIdentityProvider: Bool {
        guard let host = currentURL?.host() else { return false }
        return host != model.serverURL?.host() && !currentURL!.path().contains("/login/alternative")
    }
}

private struct LoginWebView: NSViewRepresentable {
    let startURL: URL
    let handle: WebViewHandle
    @Binding var currentURL: URL?
    let onFinish: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        // Mit einem Safari-ähnlichen UA liefern Pangolin und Pocket-ID ihre normale Login-Seite.
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/19.0 Safari/605.1.15"
        handle.webView = view
        view.load(URLRequest(url: startURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: LoginWebView
        init(_ parent: LoginWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            parent.currentURL = url
            parent.onFinish(url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            parent.currentURL = webView.url
        }

        // OIDC-Provider, die ein Popup öffnen wollen, im selben WebView laden.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}
