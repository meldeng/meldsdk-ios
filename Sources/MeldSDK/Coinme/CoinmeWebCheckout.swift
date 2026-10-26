import CryptoKit
import Foundation
import UIKit

/// Runs the Meld web SDK's Coinme flow in the shared `WebViewHost`, as Banxa's web checkout runs: the
/// saved-card picker, Coinme's Vault fields and Risk session, the duplicate-card fallback and the wait
/// for card verification all live in the vendored bundle. The page sends each payment action over the
/// bridge; it goes from here to the order's own endpoint with the order's bearer, and the raw response
/// goes back for the web SDK to decode.
final class CoinmeWebCheckout: MeldProviderSession {
    static let bundleResource = "meld-web-sdk.bundle"

    // SHA-256 of the vendored Meld web SDK bundle (meldsdk `node sdk/build.js`, with Coinme's Vault 1.2.0
    // and Risk 1.1.1 web SDKs). Update deliberately when the bundle is revved; drift fails the mount
    // rather than silently running other checkout code.
    static let expectedBundleSha256 = "a56b784d20cc7540c486e7a98013d64cf26d91ff3e4aa7d5e2f74a7161223db8"

    /// The origin the bootstrap page claims; nothing is served or fetched from it. Ours, not Coinme's or
    /// VGS's, so Coinme's secure card fields stay cross-origin to the page and its bridge script.
    static let pageHost = "coinme-checkout.sdk.meld.io"

    struct ActionRequest {
        let operation: String
        let fields: [String: Any]
        let key: UUID?
    }

    private let coinme: CoinmeCardOrder
    private let order: [String: Any]
    private let environment: MeldEnvironment
    private let handlers: MeldEventHandlers
    private let client: PaymentActionClient
    private var page: WebViewHost?

    init(coinme: CoinmeCardOrder, order: [String: Any], environment: MeldEnvironment, handlers: MeldEventHandlers) {
        self.coinme = coinme
        self.order = order
        self.environment = environment
        self.handlers = handlers
        client = PaymentActionClient(descriptor: coinme.actions)
    }

    func present(into host: UIView) throws -> MeldProviderSession {
        guard let orderData = try? JSONSerialization.data(withJSONObject: order),
              let orderJson = String(data: orderData, encoding: .utf8)
        else { throw MeldMountError.unsupported("Coinme order could not be encoded for the checkout page.") }
        let html = Self.bootstrapHtml(bundleJs: try Self.loadBundle(), orderJson: orderJson, environment: environment.rawValue)
        let session = WebViewHost(
            url: URL(string: "https://" + Self.pageHost)!,
            orderId: coinme.id,
            handlers: handlers,
            htmlContent: html,
            // Pinned so an action's response is only ever evaluated in this page.
            mainFrameHosts: [Self.pageHost],
            // The bootstrap is local HTML and loads at once; the flow fires its own ready once the device
            // is tagged and the cards or the form are showing.
            firesReadyOnNavigation: false,
            onContentProcessTerminated: { [weak self] in self?.pageTerminated() },
            bridgeInSubframes: false
        ) { [weak self] message in
            self?.interpret(message) ?? []
        }
        page = session
        session.mount(into: host)
        return self
    }

    func unmount() {
        client.finish()
        page?.unmount()
        page = nil
    }

    private func pageTerminated() {
        unmount()
        handlers.sessionEnded?(coinme.id)
    }

    private func interpret(_ message: [String: Any]) -> [MeldEvent] {
        guard message["type"] as? String == "action" else { return Self.events(message, orderId: coinme.id) }
        guard let id = message["id"] as? String else { return [] }
        guard let request = Self.actionRequest(message) else {
            reply(id, nil)
            return []
        }
        client.relay(request.operation, fields: request.fields, key: request.key) { [weak self] response in
            self?.reply(id, response)
        }
        return []
    }

    private func reply(_ id: String, _ response: (status: Int, body: String?)?) {
        page?.evaluateJavaScript(Self.resultScript(id: id, response: response)) { _ in }
    }

    static func loadBundle() throws -> String {
        guard let url = Bundle.meldResources.url(forResource: bundleResource, withExtension: "js"),
              let data = try? Data(contentsOf: url)
        else {
            throw MeldMountError.unsupported("Meld web SDK bundle (\(bundleResource).js) is missing from SDK resources.")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedBundleSha256, let js = String(data: data, encoding: .utf8) else {
            throw MeldMountError.unsupported(
                "Meld web SDK bundle failed its pinned integrity check "
                    + "(expected \(expectedBundleSha256), got \(actual)); refusing to execute.")
        }
        return js
    }

    /// HTML that mounts `orderJson` with the web SDK, sends its payment actions to native as `action`
    /// messages and relays its callbacks through `window.meldSendToNativeApp`. Native answers each
    /// action through `window.__meldActionResult(id, status, body)`, a null status for none.
    static func bootstrapHtml(bundleJs: String, orderJson: String, environment: String) -> String {
        // Guard against a literal </script> inside the bundle, or any markup in the order, ending the script early.
        let safeBundle = bundleJs.replacingOccurrences(of: "</script", with: "<\\/script")
        let safeOrder = orderJson.replacingOccurrences(of: "<", with: "\\u003c")
        let environmentJson = quote(environment)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;padding:0;background:#fff;
        font:15px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}
        /* The WebView is edge-to-edge inside the host view, so the page owns its own gutter. */
        #meld-coinme{box-sizing:border-box;width:100%;padding:16px}</style>
        </head><body><div id="meld-coinme"></div>
        <script>if(window.crypto&&!crypto.randomUUID){crypto.randomUUID=function(){var b=crypto.getRandomValues(new Uint8Array(16)),h='';b[6]=b[6]&15|64;b[8]=b[8]&63|128;for(var i=0;i<16;i++){h+=(b[i]+256).toString(16).slice(1);if(i==3||i==5||i==7||i==9)h+='-';}return h;};}</script>
        <script>\(safeBundle)</script>
        <script>
        (function(){
          function post(m){ try{ if(window.meldSendToNativeApp){ window.meldSendToNativeApp({kind:'message',data:m}); } }catch(e){} }
          var pending = {}, next = 0;
          window.__meldActionResult = function(id, status, body){
            var call = pending[id];
            if(!call) return;
            delete pending[id];
            if(typeof status === 'number'){ call.resolve({status:status, body:body}); } else { call.reject(new Error('transport')); }
          };
          try {
            var M = window.Meld;
            if(!M || typeof M.mount !== 'function' || typeof M.__setActionTransport !== 'function'){
              post({type:'error',code:'PROVIDER_LOAD_FAILED',message:'The Meld web SDK failed to load',recoverable:false});
              return;
            }
            M.configure({environment:\(environmentJson)});
            M.__setActionTransport(function(request){
              return new Promise(function(resolve, reject){
                var id = String(++next);
                pending[id] = {resolve:resolve, reject:reject};
                if(request.signal){
                  request.signal.addEventListener('abort', function(){ if(pending[id]){ delete pending[id]; reject(new Error('aborted')); } });
                }
                post({type:'action', id:id, headers:request.headers, body:request.body});
              });
            });
            M.mount(\(safeOrder), document.getElementById('meld-coinme'), {
              onReady: function(){ post({type:'ready'}); },
              onPaymentSubmitted: function(){ post({type:'submitted'}); },
              onCancel: function(){ post({type:'cancel'}); },
              onError: function(e){
                post({type:'error', code:e&&e.code, message:e&&e.message, detail:e&&e.detail, recoverable:!!(e&&e.recoverable)});
              }
            });
          } catch(err){
            post({type:'error',code:'PRESENTATION_FAILED',message:String((err&&err.message)||err),recoverable:false});
          }
        })();
        </script></body></html>
        """
    }

    static func events(_ message: [String: Any], orderId: String?) -> [MeldEvent] {
        switch message["type"] as? String {
        case "ready":
            return [.ready]
        case "submitted":
            // UX hint only: settlement is confirmed server-side from Coinme's webhook.
            return [.paymentSubmitted]
        case "cancel":
            return [.cancel]
        case "error":
            return [.error(MeldError(orderId: orderId,
                                     code: message["code"] as? String ?? MeldErrorCode.presentationFailed,
                                     message: message["message"] as? String ?? "Coinme checkout error",
                                     detail: message["detail"] as? String,
                                     recoverable: message["recoverable"] as? Bool ?? false))]
        default:
            return []
        }
    }

    /// The operation, fields and idempotency key of a page's action, or nil for a malformed one.
    static func actionRequest(_ message: [String: Any]) -> ActionRequest? {
        guard let body = message["body"] as? String, body.utf8.count <= 65536,
              let json = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
              let operation = json["operation"] as? String,
              PaymentActionJSON.integer(json["version"]) == 1
        else { return nil }
        let key: UUID?
        switch (message["headers"] as? [String: Any])?["X-Idempotency-Key"] {
        case nil:
            key = nil
        case let text as String:
            guard let uuid = UUID(uuidString: text), uuid.uuidString.lowercased() == text else { return nil }
            key = uuid
        default:
            return nil
        }
        var fields = json
        fields.removeValue(forKey: "version")
        fields.removeValue(forKey: "operation")
        return ActionRequest(operation: operation, fields: fields, key: key)
    }

    static func resultScript(id: String, response: (status: Int, body: String?)?) -> String {
        let status = response.map { String($0.status) } ?? "null"
        let body = response?.body.map(quote) ?? "null"
        return "window.__meldActionResult(\(quote(id)), \(status), \(body));"
    }

    private static func quote(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return json
    }
}
