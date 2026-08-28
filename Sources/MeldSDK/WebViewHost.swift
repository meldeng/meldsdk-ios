import Foundation
import os.log
import UIKit
import WebKit

// Generic WebView host: loads a URL in a WKWebView, forwards the page's window messages to
// native, maps each through the supplied `interpret` closure, and dispatches the resulting
// events to the Meld handlers. It carries no provider-specific knowledge — an adapter supplies
// the URL, the allowed message origins, and the message mapping. Reusable by any URL-rendered
// provider widget.
final class WebViewHost: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
    MeldProviderSession
{
    private let url: URL
    private let orderId: String?
    private let handlers: MeldEventHandlers
    private let interpret: ([String: Any]) -> [MeldEvent]
    // When set, the WebView loads this HTML (with `url` as the base URL/origin) instead of navigating
    // to `url`. Used to run a provider's own web SDK inside the WebView — e.g. Uphold, whose widget is
    // mounted via PaymentWidget(session) rather than loaded as a page. The bootstrap must post
    // lifecycle events through window.meldSendToNativeApp (the injected bridge).
    private let htmlContent: String?
    // Origins ("https://host") whose window.postMessage events the bridge trusts. The widget's own
    // origin is always included; an adapter may add the provider's other origins. An empty set
    // means "trust any origin" — only as a last resort, never for an embedded provider widget.
    private let allowedOrigins: Set<String>
    // Extra native handler names to register alongside the injected bridge, for providers whose
    // page posts straight to `window.webkit.messageHandlers.<name>` rather than window.postMessage
    // (Coinbase's `cbOnramp`). Their payloads arrive verbatim and are handed to `interpret`
    // wrapped as ["handler": name, "body": <payload>].
    private let nativeMessageHandlers: Set<String>
    // Hosts the MAIN FRAME may navigate to. Non-empty turns on navigation gating: off-host
    // main-frame loads and popups are cancelled, and user-activated https links open in the
    // system browser instead. Subframes are unaffected — providers legitimately load third-party
    // resources in them. Empty = no gating (the pre-existing behaviour).
    private let mainFrameHosts: Set<String>
    private let userScripts: [WKUserScript]
    // Whether finishing navigation counts as "ready". True for a surface whose page IS the widget.
    // False when the provider emits its own ready signal: reporting ready at page load would tell a
    // host the surface is usable before the provider has wired it up, and would cancel any
    // load-timeout the host runs against exactly that failure.
    private let firesReadyOnNavigation: Bool
    private weak var webView: WKWebView?
    private var didFireReady = false

    init(url: URL, orderId: String?, handlers: MeldEventHandlers,
         allowedOrigins: Set<String> = [],
         htmlContent: String? = nil,
         nativeMessageHandlers: Set<String> = [],
         mainFrameHosts: Set<String> = [],
         userScripts: [WKUserScript] = [],
         firesReadyOnNavigation: Bool = true,
         interpret: @escaping ([String: Any]) -> [MeldEvent]) {
        self.url = url
        self.orderId = orderId
        self.handlers = handlers
        self.htmlContent = htmlContent
        self.nativeMessageHandlers = nativeMessageHandlers
        self.mainFrameHosts = mainFrameHosts
        self.userScripts = userScripts
        self.firesReadyOnNavigation = firesReadyOnNavigation
        self.interpret = interpret
        // Always trust the loaded page's own origin; the adapter's set widens it to sibling
        // provider origins (widget vs. exchange host, etc.).
        var origins = allowedOrigins
        if let origin = Self.origin(of: url) { origins.insert(origin) }
        self.allowedOrigins = origins
    }

    func mount(into host: UIView) {
        // A WebViewHost owns exactly one WKWebView. Re-mounting (e.g. a second Meld.mount into a
        // reused host) tears the previous one down first so the old script handler can't leak or
        // stack a second WebView on top.
        if webView != nil { unmount() }

        let userContent = WKUserContentController()
        userContent.add(self, name: Self.bridgeName)
        userContent.addUserScript(
            WKUserScript(source: bridgeScript(), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        for name in nativeMessageHandlers {
            userContent.add(self, name: name)
        }
        for script in userScripts {
            userContent.addUserScript(script)
        }

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [] // let the widget use the camera (KYC)

        let webView = WKWebView(frame: host.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        if let htmlContent {
            // `url` is the base URL: it sets the page origin so the provider SDK's iframe is
            // same-origin with the widget host.
            webView.loadHTMLString(htmlContent, baseURL: url)
        } else {
            webView.load(URLRequest(url: url))
        }
        self.webView = webView
    }

    func unmount() {
        guard let webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        for name in nativeMessageHandlers {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: - WKNavigationDelegate (ready / load failures)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded. For a surface whose page IS the widget this is "ready"; where the provider
        // emits its own signal the adapter opts out, so a page that loads but never initialises
        // still looks unready to the host.
        guard firesReadyOnNavigation else { return }
        fireReadyOnce()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        emitError(code: "NAVIGATION_FAILED", message: error.localizedDescription,
                  detail: Self.detail(from: error), recoverable: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emitError(code: "PROVIDER_LOAD_FAILED", message: error.localizedDescription,
                  detail: Self.detail(from: error), recoverable: true)
    }

    private func fireReadyOnce() {
        guard !didFireReady else { return }
        didFireReady = true
        handlers.onReady?(orderId)
    }

    // MARK: - WKScriptMessageHandler (window messages -> interpret -> Meld events)

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if nativeMessageHandlers.contains(message.name) {
            receiveNativeHandlerMessage(message)
            return
        }
        guard message.name == Self.bridgeName else { return }
        // Enforce the posting frame's origin natively. window.webkit.messageHandlers.meld is reachable from
        // EVERY frame (main + subframes) and the bridge script is injected forMainFrameOnly:false, so the
        // JS-level origin filter alone can't stop a cross-origin 3DS/ACS subframe from calling the handler
        // directly. The threat is a hostile SUBFRAME: the main frame is our own bootstrap (loaded from the
        // trusted baseURL / widget origin), so it's trusted by construction — accepting it also avoids
        // dropping every message if a WebKit version reports an opaque securityOrigin for a loadHTMLString
        // main frame. For subframes we require the frame's securityOrigin to be allowlisted, so a forged
        // 'complete' (+attacker card id) from a 3DS/ACS frame is rejected. Empty allowlist = trust any.
        if !allowedOrigins.isEmpty, !message.frameInfo.isMainFrame,
            !isAllowedOrigin(message.frameInfo.securityOrigin) {
            Self.log.debug("dropped bridge message from untrusted subframe origin")
            return
        }
        // Each message arrives wrapped as { kind: "message", data: <provider event> }.
        guard let wrapper = message.body as? [String: Any],
              let providerMessage = wrapper["data"] as? [String: Any]
        else {
            // Silently dropping makes provider-protocol drift invisible; surface it in debug.
            Self.log.debug("dropped malformed bridge payload: \(String(describing: message.body), privacy: .public)")
            return
        }
        for event in interpret(providerMessage) {
            dispatch(event)
        }
    }

    /// A message posted straight to a provider's own native handler (not through the injected
    /// bridge). The posting frame's origin is enforced natively here for the same reason as the
    /// bridge: the handler is reachable from every frame.
    private func receiveNativeHandlerMessage(_ message: WKScriptMessage) {
        if !isTrustedMessageOrigin(message.frameInfo.securityOrigin) {
            Self.log.debug("dropped native-handler message from untrusted origin")
            return
        }
        for event in interpret(["handler": message.name, "body": message.body]) {
            dispatch(event)
        }
    }

    /// Runs JavaScript in the hosted page. Only for adapters whose provider protocol requires it
    /// (e.g. clicking the provider's own Apple Pay button so the sheet opens without an extra tap).
    ///
    /// Refuses unless the page currently loaded is on an allowed main-frame host, so injection can
    /// never reach a page the provider navigated away to. Requires `mainFrameHosts` to be set —
    /// without that pin there is nothing to verify against.
    func evaluateJavaScript(_ script: String) {
        guard !mainFrameHosts.isEmpty,
              let current = webView?.url,
              current.scheme?.lowercased() == "https",
              isAllowedMainFrameHost(current.host)
        else {
            Self.log.debug("refused to evaluate script: current page is not an allowed host")
            return
        }
        webView?.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - Navigation gating (opt-in via `mainFrameHosts`)

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !mainFrameHosts.isEmpty else { return decisionHandler(.allow) }
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }

        // Popups (window.open / target=_blank) are cancelled HERE rather than left to the
        // WKUIDelegate: this delegate runs first, and allowing the navigation swaps the main
        // frame's `url` to the popup target even when `createWebViewWith` loads nothing.
        // Cancelling also stops that callback firing, so a link cannot open twice.
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            openUserActivatedHttpsUrl(url, navigationType: navigationAction.navigationType)
            return
        }

        // Providers legitimately load third-party resources in subframes; only the visible
        // main-frame document is pinned.
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return decisionHandler(.allow) }

        guard url.scheme?.lowercased() == "https", isAllowedMainFrameHost(url.host) else {
            decisionHandler(.cancel)
            openUserActivatedHttpsUrl(url, navigationType: navigationAction.navigationType)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Fallback only — the policy delegate above cancels popups before WebKit gets here.
        // Keeps the live checkout in place and sends user-opened legal/help links to the browser.
        if !mainFrameHosts.isEmpty, let url = navigationAction.request.url {
            openUserActivatedHttpsUrl(url, navigationType: navigationAction.navigationType)
        }
        return nil
    }

    /// Opens a link the USER activated in the system browser. Script-created navigations and
    /// non-https URLs are dropped, so a compromised page cannot make the app open arbitrary URLs.
    private func openUserActivatedHttpsUrl(_ url: URL, navigationType: WKNavigationType) {
        guard navigationType == .linkActivated, url.scheme?.lowercased() == "https" else { return }
        UIApplication.shared.open(url)
    }

    /// Host-suffix match so a provider's subdomains stay in-frame ("pay.coinbase.com" against
    /// "coinbase.com") without admitting a lookalike ("evilcoinbase.com").
    private func isAllowedMainFrameHost(_ rawHost: String?) -> Bool {
        guard let host = rawHost?.lowercased() else { return false }
        return mainFrameHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private func dispatch(_ event: MeldEvent) {
        switch event {
        case .ready: fireReadyOnce()
        case .paymentSubmitted: handlers.onPaymentSubmitted?(orderId)
        case let .statusChange(change): handlers.onStatusChange?(change)
        case .cancel: handlers.onCancel?(orderId)
        case let .error(error): handlers.onError?(error)
        }
    }

    private func emitError(code: String, message: String, detail: String? = nil, recoverable: Bool) {
        handlers.onError?(MeldError(orderId: orderId, code: code, message: message,
                                    detail: detail, recoverable: recoverable))
    }

    // MARK: - Diagnostics

    static let log = Logger(subsystem: "io.meld.sdk", category: "WebViewHost")

    /// "<NSError domain> #<code>" for `MeldError.detail`, so integrators can tell a TLS failure
    /// from a DNS failure without parsing the localized message.
    private static func detail(from error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) #\(ns.code)"
    }

    /// Scheme + host of a URL as a postMessage origin string ("https://widget.mercuryo.io").
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)"
    }

    /// Whether a native-handler message may be trusted: the exact origin allowlist, OR any host the
    /// main frame is permitted to navigate to. A provider that moves between its own subdomains
    /// mid-checkout keeps posting events, instead of having them silently dropped — which would
    /// strand the host on a surface that never reports anything again.
    private func isTrustedMessageOrigin(_ origin: WKSecurityOrigin) -> Bool {
        if allowedOrigins.isEmpty, mainFrameHosts.isEmpty { return true }
        if isAllowedOrigin(origin) { return true }
        return origin.`protocol`.lowercased() == "https" && isAllowedMainFrameHost(origin.host)
    }

    /// Whether a posting frame's WebKit security origin is in `allowedOrigins`, compared as
    /// "scheme://host" to match how the allowlist is stored (port ignored, matching that format).
    private func isAllowedOrigin(_ origin: WKSecurityOrigin) -> Bool {
        guard !origin.host.isEmpty else { return false }
        return allowedOrigins.contains("\(origin.`protocol`)://\(origin.host)")
    }

    // MARK: - Injected bridge

    private static let bridgeName = "meld"

    /// Runs at document start in the widget page and forwards the widget's window messages to
    /// the native handler. Only messages from `allowedOrigins` are forwarded, so a malicious or
    /// compromised subframe can't post fake lifecycle events. An empty allowlist forwards any
    /// origin (last-resort fallback only).
    private func bridgeScript() -> String {
        let originsJSON = (try? JSONSerialization.data(withJSONObject: Array(allowedOrigins)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function () {
          var allowedOrigins = \(originsJSON);
          function send(message) {
            try { window.webkit.messageHandlers.\(Self.bridgeName).postMessage(message); }
            catch (e) { if (window.console) console.warn('[MeldSDK] bridge post failed', e); }
          }
          // The widget calling this directly is trusted (same realm as our injected script).
          window.meldSendToNativeApp = send;
          window.addEventListener('message', function (event) {
            if (allowedOrigins.length && allowedOrigins.indexOf(event.origin) === -1) return;
            send({ kind: 'message', data: event.data });
          }, false);
        })();
        """
    }
}
