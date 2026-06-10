import Foundation
import os.log
import UIKit
import WebKit

// Generic WebView host: loads a URL in a WKWebView, forwards the page's window messages to
// native, maps each through the supplied `interpret` closure, and dispatches the resulting
// events to the Meld handlers. It carries no provider-specific knowledge — an adapter supplies
// the URL, the allowed message origins, and the message mapping. Reusable by any URL-rendered
// provider widget.
final class WebViewHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler, MeldProviderSession {
    private let url: URL
    private let orderId: String?
    private let handlers: MeldEventHandlers
    private let interpret: ([String: Any]) -> [MeldEvent]
    // Origins ("https://host") whose window.postMessage events the bridge trusts. The widget's own
    // origin is always included; an adapter may add the provider's other origins. An empty set
    // means "trust any origin" — only as a last resort, never for an embedded provider widget.
    private let allowedOrigins: Set<String>
    private weak var webView: WKWebView?
    private var didFireReady = false

    init(url: URL, orderId: String?, handlers: MeldEventHandlers,
         allowedOrigins: Set<String> = [],
         interpret: @escaping ([String: Any]) -> [MeldEvent]) {
        self.url = url
        self.orderId = orderId
        self.handlers = handlers
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

        let config = WKWebViewConfiguration()
        config.userContentController = userContent
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [] // let the widget use the camera (KYC)

        let webView = WKWebView(frame: host.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        webView.load(URLRequest(url: url))
        self.webView = webView
    }

    func unmount() {
        guard let webView else { return }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        self.webView = nil
    }

    // MARK: - WKNavigationDelegate (ready / load failures)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Page loaded; a provider's own ready event (if any) also fires this — whichever first.
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
        guard message.name == Self.bridgeName else { return }
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
