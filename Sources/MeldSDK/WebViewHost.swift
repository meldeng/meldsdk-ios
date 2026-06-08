import Foundation
import UIKit
import WebKit

// Generic WebView host: loads a URL in a WKWebView, forwards the page's window messages to
// native, maps each through the supplied `interpret` closure, and dispatches the resulting
// events to the Meld handlers. It carries no provider-specific knowledge — an adapter supplies
// the URL and the message mapping. Reusable by any URL-rendered provider widget.
final class WebViewHost: NSObject, WKNavigationDelegate, WKScriptMessageHandler, MeldProviderSession {
    private let url: URL
    private let orderId: String?
    private let handlers: MeldEventHandlers
    private let interpret: ([String: Any]) -> [MeldEvent]
    private weak var webView: WKWebView?
    private var didFireReady = false

    init(url: URL, orderId: String?, handlers: MeldEventHandlers,
         interpret: @escaping ([String: Any]) -> [MeldEvent]) {
        self.url = url
        self.orderId = orderId
        self.handlers = handlers
        self.interpret = interpret
    }

    func mount(into host: UIView) {
        let userContent = WKUserContentController()
        userContent.add(self, name: Self.bridgeName)
        userContent.addUserScript(
            WKUserScript(source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

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
        emitError(code: "NAVIGATION_FAILED", message: error.localizedDescription, recoverable: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        emitError(code: "PROVIDER_LOAD_FAILED", message: error.localizedDescription, recoverable: true)
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
        else { return }
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

    private func emitError(code: String, message: String, recoverable: Bool) {
        handlers.onError?(MeldError(orderId: orderId, code: code, message: message, recoverable: recoverable))
    }

    // MARK: - Injected bridge

    private static let bridgeName = "meld"

    /// Runs at document start in the widget page and forwards the widget's window messages to
    /// the native handler.
    private static let bridgeScript = """
    (function () {
      function send(message) {
        try { window.webkit.messageHandlers.\(bridgeName).postMessage(message); } catch (e) {}
      }
      window.meldSendToNativeApp = send;
      window.addEventListener('message', function (event) {
        send({ kind: 'message', data: event.data });
      }, false);
    })();
    """
}
