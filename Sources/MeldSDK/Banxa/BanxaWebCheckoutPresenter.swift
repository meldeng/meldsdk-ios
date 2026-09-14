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
    static let themeResource = "banxa-primer-theme"

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
        let theme = try Self.loadTheme()
        let html = Self.bootstrapHtml(bundleJs: bundle, themeCss: theme, clientToken: clientToken)

        let session = WebViewHost(
            url: Self.pageOrigin(),
            orderId: orderId,
            handlers: handlers,
            allowedOrigins: Self.allowedOrigins,
            htmlContent: html,
            // onReady means the component is mounted, which it reports as banxa:ready. Firing on
            // page navigation instead would fire at bootstrap load and then swallow the real event
            // (didFireReady), leaving the wired listener dead and a host's load-timeout disarmed.
            firesReadyOnNavigation: false
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
    static func bootstrapHtml(bundleJs: String, themeCss: String, clientToken: String) -> String {
        // Guard against a literal </script> inside the bundle prematurely closing the tag.
        let safeBundle = bundleJs.replacingOccurrences(of: "</script", with: "<\\/script")
        // The same hazard one tag over: a `</style` sequence in the theme would close the block early
        // and spill the rest into the document. Vendored today, but the escape belongs with the
        // interpolation rather than with an assumption about the resource.
        let safeTheme = themeCss.replacingOccurrences(of: "</style", with: "<\\/style")
        // JSON-encode the token so a quote inside it cannot break out of the string literal — and
        // then escape `</script` as well, because JSONSerialization does not: JSON has no reason to
        // treat `/` specially, so a token carrying that sequence would close this tag exactly as an
        // unescaped bundle would. The same guard the bundle and theme get, for the same reason.
        let tokenJSON = ((try? JSONSerialization.data(withJSONObject: [clientToken]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]")
            .replacingOccurrences(of: "</script", with: "<\\/script")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>\(safeTheme)</style>
        <style>
        html,body{margin:0;padding:0;height:100%;width:100%;background:#fff;
        font:15px/1.4 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;-webkit-text-size-adjust:100%}
        /* The WebView is edge-to-edge inside the host view, so the page owns its own gutter. */
        #meld-banxa{box-sizing:border-box;width:100%;min-height:100%;
        padding:16px calc(16px + env(safe-area-inset-right)) calc(16px + env(safe-area-inset-bottom)) calc(16px + env(safe-area-inset-left))}
        </style>
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
            // Card only. The component's default preset also renders an Apple Pay button, which a
            // WebView at the bootstrap page's origin can never validate — it would show, then fail
            // silently in the console. Apple Pay on iOS goes through Banxa's native SDK instead.
            el.setAttribute('payment-methods', 'PAYMENT_CARD');
            // Injected into the component's shadow root, where `primer-checkout` lives. Only tokens
            // travel from here into Primer's nested shadow roots, so this tunes the design system
            // rather than selecting elements — readable type, a softer radius, and roomier spacing for a phone.
            // The submit button's width is deliberately not fought for: it sits behind two shadow
            // boundaries with no exported part, so any rule reaching it would be version-fragile.
            // `--primer-size-*` is left alone: despite the name it sizes icons and spinners, not
            // fields, and raising it stretches the card-network badge across the number input.
            el.setAttribute('custom-styles', [
              'primer-checkout{',
              '--primer-typography-body-medium-size:15px;',
              '--primer-typography-body-small-size:13px;',
              '--primer-space-medium:14px;',
              '--primer-radius-base:10px;',
              '--primer-radius-button:12px;',
              '}'
            ].join(''));
            [
              'ready','payment-start','payment-success','payment-failure','payment-cancel','card-error'
            ].forEach(function(name){
              el.addEventListener('banxa:'+name, function(e){ post({type:name, detail:(e?e.detail:null)}); });
            });
            // Not a banxa: event. The component re-dispatches Primer's `primer:*` vocabulary under the
            // banxa: prefix, but an initialization failure — an expired or malformed client token, most
            // often — is raised by the inner primer-checkout as an unprefixed `checkout-error` and never
            // re-dispatched. Without this the component renders its own inline error and native hears
            // nothing at all: no ready, no failure, no way for the host to stop waiting. It bubbles and
            // is composed, so it crosses the shadow boundary.
            el.addEventListener('checkout-error', function(e){
              var err = e && e.detail && e.detail.error;
              post({type:'error',detail:{error:{code:'checkout_init_failed',
                message:String((err&&err.message)||err||'Banxa checkout failed to initialize')}}});
            });
            document.getElementById('meld-banxa').appendChild(el);
            // Set as a property — but the component's setter reflects it to the `client-token`
            // attribute, so the token is in this bootstrap page's DOM regardless. Acceptable here: the
            // page is Meld's own vendored bundle inside the app's WebView, not an integrator page.
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

    // SHA-256 of the pinned theme, extracted from the bundle above (see the file's own header).
    // Pinned for the same reason the bundle is: it is vendored third-party CSS, and silent drift
    // would change what the card form looks like without review.
    static let expectedThemeSha256 = "259f773f44fe551b92c575b22a4e112337b88a2af3770f879160bcc5da20771b"

    /// Primer's design tokens. Without them every `var(--primer-*)` in the components' own CSS is
    /// undefined and the card form renders as unstyled labels and inputs.
    static func loadTheme() throws -> String {
        guard let url = Bundle.meldResources.url(forResource: themeResource, withExtension: "css"),
              let data = try? Data(contentsOf: url)
        else {
            throw MeldMountError.unsupported("Banxa checkout theme (\(themeResource).css) is missing from SDK resources.")
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedThemeSha256 else {
            throw MeldMountError.unsupported(
                "Banxa checkout theme failed its pinned integrity check "
                    + "(expected \(expectedThemeSha256), got \(actual)); refusing to execute.")
        }
        guard let css = String(data: data, encoding: .utf8) else {
            throw MeldMountError.unsupported("Banxa checkout theme is not valid UTF-8.")
        }
        return css
    }

    // MARK: - Origins

    /// Base URL for the bootstrap page, i.e. the origin the page claims.
    ///
    /// A Meld origin, deliberately NOT Primer's. An earlier revision used `https://sdk.primer.io` to
    /// keep the page same-origin with the SDK it loads, which turned out to be the one thing it must
    /// not be: the vendored bundle mounts Primer's hosted card inputs and its api-controller from
    /// that same origin, and the bridge is injected `forMainFrameOnly: false`. Same-origin plus a
    /// script in every frame means `iframe.contentDocument` — PAN and CVV — and the api-controller's
    /// access token are readable from page context. That is the isolation Primer's hosted fields
    /// exist to provide, and the basis of the SAQ-A argument that card data never reaches our systems.
    ///
    /// Nothing is served from this URL and nothing is fetched from it: `loadHTMLString(_:baseURL:)`
    /// uses it only as the origin the page claims. It has to be https (Primer and Apple Pay both
    /// require a secure context) and it has to be ours, so it cannot collide with a real origin
    /// someone else controls.
    ///
    /// Primer does not need the parent same-origin — on a merchant site it never is, which is the
    /// configuration its SDK is built for. Its own hosts stay in `allowedOrigins` so its subframes can
    /// still reach the bridge.
    ///
    /// Card only. Apple Pay additionally requires the page origin to be a domain registered with the
    /// processor for Apple Pay domain verification, which this is not; that is part of the Apple Pay
    /// phase, not something to quietly inherit here.
    static func pageOrigin() -> URL {
        URL(string: "https://banxa-checkout.sdk.meld.io")!
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
