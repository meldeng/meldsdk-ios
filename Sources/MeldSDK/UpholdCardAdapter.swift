import CryptoKit
import Foundation
import UIKit
import os

/// Uphold credit/debit card (Option 1 — the SDK absorbs Uphold's two-step card flow). Uphold requires
/// the card captured BEFORE a purchase quote can be created, so a single widget can't do it. This
/// adapter orchestrates both Uphold widgets so the integrator still mounts once:
///
///   1. Mount the capture (select-for-deposit) widget from the order's session.
///   2. On card capture, POST the captured card id to the order's `authorizeSessionUrl` (bearer =
///      `continuationToken`) via `MeldApiClient` to create the authorize session.
///   3. Mount the returned authorize widget; its `ready/complete/cancel/error` map to Meld events
///      (`complete` = UX hint, NOT settlement — settlement is confirmed server-side via webhook).
///
/// Uphold's payment widget is SDK-mounted, not URL-loadable: its web SDK is ESM-only and, given a
/// session (`{url, token, flow}`), builds and mounts its own iframe against the widget host using the
/// token. So we run Uphold's web SDK (vendored as a bundled resource) inside the reused `WebViewHost`
/// via a bootstrap HTML that calls `PaymentWidget(session).mountIframe(...)` and relays its events
/// through `window.meldSendToNativeApp`. The order carries the session as `serviceProviderWidgetUrl`
/// (session url) + `sdkSessionToken` + `sdkSessionFlow`. Distinguished from other IFRAME card
/// providers by widget/API host.
struct UpholdCardAdapter: MeldAdapter {
    let label = "Uphold card (CREDIT_DEBIT_CARD / IFRAME)"
    let capabilities = MeldCapabilities(embeddable: true, surface: "embedded", requiresUserGesture: false)

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "UpholdCardAdapter")

    static let bundleResource = "uphold-payment-widget.bundle"

    func matches(paymentMethodType: String?, renderMode: String?, widgetUrl: String?) -> Bool {
        paymentMethodType == "CREDIT_DEBIT_CARD" && renderMode == "IFRAME" && Self.isUpholdHost(widgetUrl)
    }

    func mount(order: MeldOrder, into host: UIView, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        let details = order.paymentMethodResponseDetails
        guard let sessionUrl = details?.serviceProviderWidgetUrl else {
            throw MeldMountError.missingWidgetURL
        }
        guard let sessionToken = details?["sdkSessionToken"] as? String else {
            throw MeldMountError.unsupported(
                "Uphold card order is missing sdkSessionToken (needed to mount the Uphold widget SDK).")
        }
        guard let authorizeSessionUrl = details?["authorizeSessionUrl"] as? String else {
            throw MeldMountError.unsupported(
                "Uphold card order is missing authorizeSessionUrl (needed for the capture→authorize step).")
        }
        let sessionFlow = details?["sdkSessionFlow"] as? String
        let continuationToken = details?["continuationToken"] as? String

        let bundle = try Self.loadBundle()
        Self.warnIfEnvironmentMismatch(host: URL(string: sessionUrl)?.host)

        let session = UpholdTwoStepSession(
            host: host,
            handlers: handlers,
            orderId: order.id,
            bundle: bundle,
            authorizeSessionUrl: authorizeSessionUrl,
            continuationToken: continuationToken,
            paymentMethodType: order.paymentMethodType)
        session.mountCapture(sessionUrl: sessionUrl, token: sessionToken, flow: sessionFlow)
        return session
    }

    // MARK: - Bootstrap that runs Uphold's web SDK inside the WebView

    /// Map the Meld order's paymentMethodType to Uphold's widget `paymentMethods` config so the widget
    /// preselects it and skips the "Select a payment method" screen. Card-family Meld types map to
    /// Uphold's `card`; anything we can't confidently map falls back to the full picker (card + crypto).
    static func upholdPaymentMethodsJs(for paymentMethodType: String?) -> String {
        switch paymentMethodType?.uppercased() {
        case "CREDIT_DEBIT_CARD", "CREDIT_CARD", "DEBIT_CARD", "CARD":
            return "[{type:'card'}]"
        default:
            return "[{type:'card'},{type:'crypto'}]"
        }
    }

    /// HTML that loads the vendored Uphold web SDK, mounts `PaymentWidget(session)`, and relays its
    /// lifecycle events to native through `window.meldSendToNativeApp` in the normalized shape the
    /// event mappers below expect (`{type, value|detail}`).
    static func bootstrapHtml(
        bundleJs: String, sessionUrl: String, token: String, flow: String?, data: [String: Any]? = nil,
        paymentMethodsJs: String = "[{type:'card'},{type:'crypto'}]"
    ) -> String {
        var session: [String: Any] = ["url": sessionUrl, "token": token]
        if let flow { session["flow"] = flow }
        // Uphold's authorize flow requires the quote id as session `data.quoteId` — the token alone
        // isn't enough (the PaymentWidget throws "Missing 'quoteId' parameter in 'data'"). The backend
        // supplies it on the authorize order as sdkSessionData; the capture step passes nothing.
        if let data, !data.isEmpty { session["data"] = data }
        let sessionJSON = (try? JSONSerialization.data(withJSONObject: session))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // Guard against a literal </script> inside the bundle prematurely closing the tag.
        let safeBundle = bundleJs.replacingOccurrences(of: "</script", with: "<\\/script")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;padding:0;height:100%;width:100%}#meld-uphold{height:100%;width:100%}</style>
        </head><body><div id="meld-uphold"></div>
        <script>\(safeBundle)</script>
        <script>
        (function(){
          function post(m){ try{ if(window.meldSendToNativeApp){ window.meldSendToNativeApp({kind:'message',data:m}); } }catch(e){} }
          try {
            var W = window.MeldUpholdWidget && window.MeldUpholdWidget.PaymentWidget;
            if(!W){ post({type:'error',detail:{error:{code:'sdk_unavailable',message:'Uphold widget SDK failed to load'}}}); return; }
            var widget = new W(\(sessionJSON), { paymentMethods:\(paymentMethodsJs), theme:{appearance:'light'} });
            widget.on('ready', function(){ post({type:'ready'}); });
            widget.on('complete', function(e){ post({type:'complete', value:(e&&e.detail)?e.detail.value:null}); });
            widget.on('cancel', function(){ post({type:'cancel'}); });
            widget.on('error', function(e){ post({type:'error', detail:(e?e.detail:null)}); });
            widget.mountIframe(document.getElementById('meld-uphold'));
          } catch(err){ post({type:'error',detail:{error:{code:'mount_failed',message:String((err&&err.message)||err)}}}); }
        })();
        </script></body></html>
        """
    }

    // SHA-256 of the pinned vendored bundle. Update deliberately (and re-review) when the bundle is
    // intentionally revved; a drift here fails the mount rather than silently running new widget code.
    static let expectedBundleSha256 = "a4664a8568533df6f55b1e8db303ec3fa6a7f7ce73aca8d08e4acaf8c5cc823e"

    static func loadBundle() throws -> String {
        guard let url = Bundle.meldResources.url(forResource: bundleResource, withExtension: "js"),
              let data = try? Data(contentsOf: url)
        else {
            throw MeldMountError.unsupported("Uphold widget SDK bundle (\(bundleResource).js) is missing from SDK resources.")
        }
        // Pin the vendored bundle by content hash and fail closed on drift. The bundle owns the widget's
        // postMessage/bridge security surface, so a swapped or tampered asset must not run in the WebView.
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedBundleSha256 else {
            throw MeldMountError.unsupported(
                "Uphold widget SDK bundle failed its pinned integrity check "
                    + "(expected \(expectedBundleSha256), got \(actual)); refusing to execute.")
        }
        guard let js = String(data: data, encoding: .utf8) else {
            throw MeldMountError.unsupported("Uphold widget SDK bundle is not valid UTF-8.")
        }
        return js
    }

    /// Widget-host origin for the current environment; the bootstrap page's base URL / origin.
    static func widgetOrigin() -> URL {
        let host = widgetHostsByEnvironment[Meld.environment]?.first
            ?? widgetHostsByEnvironment[.sandbox]!.first!
        return URL(string: "https://\(host)")!
    }

    // MARK: - Authorize-widget message -> Meld events

    static func interpret(providerMessage: [String: Any], orderId: String?) -> [MeldEvent] {
        guard let type = (providerMessage["type"] ?? providerMessage["event"]) as? String else { return [] }
        switch type {
        case "ready": return [.ready]
        case "complete": return [.paymentSubmitted]  // UX hint; settlement via webhook
        case "cancel": return [.cancel]
        case "error": return [.error(errorFrom(providerMessage, orderId: orderId))]
        default: return []
        }
    }

    // Capture step: surface ready + terminal cancel/error; 'complete' (card captured) is out-of-band.
    static func interpretCapture(providerMessage: [String: Any]) -> [MeldEvent] {
        switch (providerMessage["type"] ?? providerMessage["event"]) as? String {
        case "ready": return [.ready]
        case "cancel": return [.cancel]
        case "error": return [.error(errorFrom(providerMessage, orderId: nil))]
        default: return []
        }
    }

    // Card id from the capture widget's 'complete' selection. POC-confirmed shape: the SDK's complete
    // event carries detail.value = { via:'external-account', selection:{ id, label } }; the bootstrap
    // forwards detail.value as `value`, so the id is value.selection.id.
    static func extractCapturedCardId(_ providerMessage: [String: Any]) -> String? {
        guard ((providerMessage["type"] ?? providerMessage["event"]) as? String) == "complete" else { return nil }
        let value = (providerMessage["value"] as? [String: Any])
            ?? ((providerMessage["detail"] as? [String: Any])?["value"] as? [String: Any])
        guard let selection = value?["selection"] as? [String: Any] else { return nil }
        return selection["id"] as? String
    }

    private static func errorFrom(_ providerMessage: [String: Any], orderId: String?) -> MeldError {
        let detail = providerMessage["detail"] as? [String: Any]
        let error = detail?["error"] as? [String: Any]
        return MeldError(
            orderId: orderId,
            code: (error?["code"] as? String) ?? "error",
            message: (error?["message"] as? String) ?? "Uphold widget error",
            detail: nil,
            recoverable: false)
    }

    // MARK: - Uphold hosts (both the API host that carries the session url and the widget host)

    private static let apiHostsByEnvironment: [MeldEnvironment: Set<String>] = [
        .sandbox: ["api.enterprise.sandbox.uphold.com"],
        .production: ["api.enterprise.uphold.com"],
    ]

    private static let widgetHostsByEnvironment: [MeldEnvironment: Set<String>] = [
        .sandbox: ["payment-widget.enterprise.sandbox.uphold.com"],
        .production: ["payment-widget.enterprise.uphold.com"],
    ]

    // Both the bootstrap page origin (widget host) and the Uphold iframe/API origins are trusted.
    static let allowedOrigins: Set<String> =
        Set((apiHostsByEnvironment.values.flatMap { $0 } + widgetHostsByEnvironment.values.flatMap { $0 })
            .map { "https://\($0)" })

    private static let allHosts: Set<String> =
        Set(apiHostsByEnvironment.values.flatMap { $0 } + widgetHostsByEnvironment.values.flatMap { $0 })

    // Env → the host(s) that identify it, for the config-mismatch warning (keyed off the session url,
    // which is the API host).
    private static let hostsByEnvironment: [MeldEnvironment: Set<String>] = {
        var merged: [MeldEnvironment: Set<String>] = [:]
        for (env, api) in apiHostsByEnvironment {
            merged[env] = api.union(widgetHostsByEnvironment[env] ?? [])
        }
        return merged
    }()

    static func isUpholdHost(_ widgetUrl: String?) -> Bool {
        guard let widgetUrl, let host = URL(string: widgetUrl)?.host else { return false }
        return allHosts.contains(host)
    }

    private static func warnIfEnvironmentMismatch(host: String?) {
        guard let host else { return }
        guard let orderEnv = hostsByEnvironment.first(where: { $0.value.contains(host) })?.key else { return }
        if orderEnv != Meld.environment {
            logger.warning(
                "order environment is '\(orderEnv.rawValue)' but Meld.configure set '\(Meld.environment.rawValue)'. Configure the matching environment to silence this.")
        }
    }
}

/// Orchestrates the capture widget → Meld authorize-session call → authorize widget.
private final class UpholdTwoStepSession: MeldProviderSession {
    private let host: UIView
    private let handlers: MeldEventHandlers
    private let orderId: String?
    private let bundle: String
    private let authorizeSessionUrl: String
    private let continuationToken: String?
    /// Uphold widget `paymentMethods` config derived from the Meld order's paymentMethodType, so the
    /// widget preselects the method (skipping its "Select a payment method" screen) when we can map it.
    private let paymentMethodsJs: String

    private var current: MeldProviderSession?
    private var advancing = false

    // The flow spans two WebView hosts (capture → authorize), each of which would fire onReady on its
    // page load. Forward only the first so the integrator sees one Ready per Meld.mount. (WKWebView
    // callbacks are main-thread, so a plain flag is safe.)
    private var readyForwarded = false
    private lazy var onceHandlers = MeldEventHandlers(
        onReady: { [weak self] id in
            guard let self, !self.readyForwarded else { return }
            self.readyForwarded = true
            self.handlers.onReady?(id)
        },
        onPaymentSubmitted: handlers.onPaymentSubmitted,
        onStatusChange: handlers.onStatusChange,
        onCancel: handlers.onCancel,
        onError: handlers.onError
    )

    init(host: UIView, handlers: MeldEventHandlers, orderId: String?, bundle: String,
         authorizeSessionUrl: String, continuationToken: String?, paymentMethodType: String?) {
        self.host = host
        self.handlers = handlers
        self.orderId = orderId
        self.bundle = bundle
        self.authorizeSessionUrl = authorizeSessionUrl
        self.continuationToken = continuationToken
        self.paymentMethodsJs = UpholdCardAdapter.upholdPaymentMethodsJs(for: paymentMethodType)
    }

    func mountCapture(sessionUrl: String, token: String, flow: String?) {
        let html = UpholdCardAdapter.bootstrapHtml(
            bundleJs: bundle, sessionUrl: sessionUrl, token: token, flow: flow, paymentMethodsJs: paymentMethodsJs)
        let capture = WebViewHost(
            url: UpholdCardAdapter.widgetOrigin(),
            orderId: orderId,
            handlers: onceHandlers,
            allowedOrigins: UpholdCardAdapter.allowedOrigins,
            htmlContent: html
        ) { [weak self] message in
            guard let self else { return [] }
            if let cardId = UpholdCardAdapter.extractCapturedCardId(message), !self.advancing {
                self.advancing = true
                self.advanceToAuthorize(cardId: cardId)
                return []  // capture 'complete' is internal; not surfaced as settlement
            }
            return UpholdCardAdapter.interpretCapture(providerMessage: message)
        }
        current = capture
        capture.mount(into: host)
    }

    private func advanceToAuthorize(cardId: String) {
        MeldApiClient.createAuthorizeSession(
            authorizeSessionUrl: authorizeSessionUrl, continuationToken: continuationToken, cardId: cardId
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let authorizeOrder):
                    self.mountAuthorize(authorizeOrder)
                case .failure(let error):
                    self.handlers.onError?(
                        MeldError(
                            orderId: self.orderId, code: "authorize_session_failed",
                            message: error.localizedDescription, detail: nil, recoverable: false))
                }
            }
        }
    }

    private func mountAuthorize(_ order: MeldOrder) {
        let details = order.paymentMethodResponseDetails
        guard let sessionUrl = details?.serviceProviderWidgetUrl,
              let token = details?["sdkSessionToken"] as? String
        else {
            handlers.onError?(
                MeldError(orderId: orderId, code: "authorize_session_invalid",
                          message: "authorize order missing session", detail: nil, recoverable: false))
            return
        }
        let flow = details?["sdkSessionFlow"] as? String
        let data = details?["sdkSessionData"] as? [String: Any]
        current?.unmount()
        let html = UpholdCardAdapter.bootstrapHtml(
            bundleJs: bundle, sessionUrl: sessionUrl, token: token, flow: flow, data: data,
            paymentMethodsJs: paymentMethodsJs)
        let authorize = WebViewHost(
            url: UpholdCardAdapter.widgetOrigin(),
            orderId: orderId,
            handlers: onceHandlers,
            allowedOrigins: UpholdCardAdapter.allowedOrigins,
            htmlContent: html
        ) { message in
            UpholdCardAdapter.interpret(providerMessage: message, orderId: order.id)
        }
        current = authorize
        authorize.mount(into: host)
    }

    func unmount() {
        current?.unmount()
        current = nil
    }
}
