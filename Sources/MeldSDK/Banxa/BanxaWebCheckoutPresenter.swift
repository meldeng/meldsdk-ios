import CryptoKit
import Foundation
import UIKit
import os

/// Presents Banxa's `<banxa-primer-checkout>` web component inside the shared `WebViewHost`.
///
/// The component takes a client token and nothing else, so no Banxa credential reaches the device
/// and the order stays Meld's. Banxa's own iOS SDK is deliberately not used: it creates its own
/// order, which would bypass Meld's order lifecycle entirely.
///
/// Card only. This presenter cannot serve Apple Pay: Apple Pay on the Web refuses to run unless the
/// page origin is a domain registered with Apple, and the bootstrap page's origin is Primer's, not
/// ours to register. Apple Pay needs the Primer-native presenter.
struct BanxaWebCheckoutPresenter: BanxaCheckoutPresenter {

    let capabilities = MeldCapabilities(embeddable: true, surface: "embedded", requiresUserGesture: false)

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "BanxaWebCheckoutPresenter")

    static let bundleResource = "banxa-primer-checkout.bundle"

    func present(
        order: MeldOrder,
        context: MeldMountContext,
        handlers: MeldEventHandlers
    ) throws -> MeldProviderSession {
        guard let host = context.host else {
            throw MeldMountError.missingHost("Banxa card (web component)")
        }
        guard let clientToken = order.paymentMethodResponseDetails?["sdkSessionToken"] as? String,
              !clientToken.isEmpty
        else {
            throw MeldMountError.unsupported(
                "Banxa card order is missing sdkSessionToken, the Primer client token the checkout mounts "
                    + "from. The backend did not receive one from Banxa for this order.")
        }
        let orderId = order.id
        let bundle = try Self.loadBundle()
        let html = Self.bootstrapHtml(bundleJs: bundle, clientToken: clientToken)

        let session = WebViewHost(
            url: Self.pageOrigin(),
            orderId: orderId,
            handlers: handlers,
            allowedOrigins: Self.allowedOrigins,
            htmlContent: html
        ) { message in
            Self.interpret(providerMessage: message, orderId: orderId)
        }
        session.mount(into: host)
        return session
    }


    /// HTML that registers `<banxa-primer-checkout>`, hands it the client token, and relays the
    /// component's `banxa:*` events to native through `window.meldSendToNativeApp`.
    ///
    /// The component re-dispatches every Primer event under a `banxa:` prefix, so the vocabulary here
    /// is Primer's: `ready`, `payment-start`, `payment-success`, `payment-failure`, `payment-cancel`,
    /// plus card-level `card-error` (inline field validation, deliberately not surfaced — see
    /// `interpret`).
    static func bootstrapHtml(bundleJs: String, clientToken: String) -> String {
        // Guard against a literal </script> inside the bundle prematurely closing the tag.
        let safeBundle = bundleJs.replacingOccurrences(of: "</script", with: "<\\/script")
        let tokenJSON = (try? JSONSerialization.data(withJSONObject: [clientToken]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;padding:0;height:100%;width:100%}#meld-banxa{height:100%;width:100%}</style>
        </head><body><div id="meld-banxa"></div>
        <script>\(safeBundle)</script>
        <script>
        (function(){
          function post(m){ try{ if(window.meldSendToNativeApp){ window.meldSendToNativeApp({kind:'message',data:m}); } }catch(e){} }
          try {
            var S = window.MeldBanxaCheckout;
            if(!S || !S.registerBanxaPrimerCheckout){ post({type:'error',detail:{error:{code:'sdk_unavailable',message:'Banxa checkout SDK failed to load'}}}); return; }
            S.registerBanxaPrimerCheckout();
            var el = document.createElement('banxa-primer-checkout');
            [
              'ready','payment-start','payment-success','payment-failure','payment-cancel','card-error'
            ].forEach(function(name){
              el.addEventListener('banxa:'+name, function(e){ post({type:name, detail:(e?e.detail:null)}); });
            });
            document.getElementById('meld-banxa').appendChild(el);
            // Property, not attribute: the component reads clientToken as a property setter, and a
            // token in the DOM would also be visible in any page inspection.
            el.clientToken = \(tokenJSON)[0];
          } catch(err){ post({type:'error',detail:{error:{code:'mount_failed',message:String((err&&err.message)||err)}}}); }
        })();
        </script></body></html>
        """
    }

    // SHA-256 of the pinned vendored bundle (esbuild IIFE of
    // @banxa-official/javascript-native-payments-sdk/web 1.0.1 + @primer-io/primer-js 1.9.0,
    // global `MeldBanxaCheckout`). Update deliberately — and re-review — when the bundle is
    // intentionally revved; drift fails the mount rather than silently running new checkout code.
    static let expectedBundleSha256 = "031c67d4851f8e5ba38b0871888bd70ebb641618b04e04369cfed9e9fb59eb7e"

    static func loadBundle() throws -> String {
        guard let url = Bundle.meldResources.url(forResource: bundleResource, withExtension: "js"),
              let data = try? Data(contentsOf: url)
        else {
            throw MeldMountError.unsupported("Banxa checkout SDK bundle (\(bundleResource).js) is missing from SDK resources.")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedBundleSha256 else {
            throw MeldMountError.unsupported(
                "Banxa checkout SDK bundle failed its pinned integrity check "
                    + "(expected \(expectedBundleSha256), got \(actual)); refusing to execute.")
        }
        guard let js = String(data: data, encoding: .utf8) else {
            throw MeldMountError.unsupported("Banxa checkout SDK bundle is not valid UTF-8.")
        }
        return js
    }

    // MARK: - Origins

    /// Base URL for the bootstrap page, i.e. the origin the page claims. Unlike Mercuryo and Uphold
    /// there is no provider URL on the order to derive this from, so it is fixed to Primer's SDK
    /// origin — the origin the checkout's own assets and iframes come from, which keeps the page
    /// same-origin with the SDK it loads.
    ///
    /// Card only. Apple Pay additionally requires the page origin to be a domain registered with the
    /// processor for Apple Pay domain verification, which this is not; that is part of the Apple Pay
    /// phase, not something to quietly inherit here.
    static func pageOrigin() -> URL {
        URL(string: "https://sdk.primer.io")!
    }

    /// Primer serves the checkout, its hosted card inputs, its assets and its analytics from distinct
    /// hosts; all are origins the bootstrap page legitimately talks to.
    static let allowedOrigins: Set<String> = [
        "https://sdk.primer.io",
        "https://sdk.production.primer.io",
        "https://assets.primer.io",
        "https://assets.production.core.primer.io",
    ]

    // MARK: - Banxa/Primer events -> Meld events

    static func interpret(providerMessage: [String: Any], orderId: String?) -> [MeldEvent] {
        guard let type = (providerMessage["type"] ?? providerMessage["event"]) as? String else { return [] }
        switch type {
        case "ready":
            return [.ready]
        case "payment-success":
            // UX hint only. Settlement is confirmed server-side from Banxa's webhook, exactly as for
            // Uphold's 'complete' — the same rule holds across providers.
            return [.paymentSubmitted]
        case "payment-cancel":
            return [.cancel]
        case "payment-failure", "error":
            return [.error(errorFrom(providerMessage, orderId: orderId))]
        case "card-error":
            // Inline field validation (a mistyped CVV, an incomplete expiry). Primer renders these in
            // its own form and the user can correct them, so surfacing them as MeldError would fire
            // onError on ordinary typing. Relayed for logging only.
            return []
        default:
            // 'payment-start' and Primer's state/bin events have no Meld equivalent.
            return []
        }
    }

    private static func errorFrom(_ providerMessage: [String: Any], orderId: String?) -> MeldError {
        let detail = providerMessage["detail"] as? [String: Any]
        let error = detail?["error"] as? [String: Any]
        // Primer's payment-failure detail is {errorCode, errorMessage}; the generic bootstrap error
        // path uses {error:{code,message}}. Accept both rather than losing the reason.
        let code = (error?["code"] as? String) ?? (detail?["errorCode"] as? String) ?? "error"
        let message = (error?["message"] as? String) ?? (detail?["errorMessage"] as? String)
            ?? "Banxa checkout error"
        return MeldError(orderId: orderId, code: code, message: message, detail: nil, recoverable: false)
    }
}
