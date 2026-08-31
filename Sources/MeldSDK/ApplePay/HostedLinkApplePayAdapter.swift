import Foundation
import UIKit
import WebKit
import os

/// Provider-hosted Apple Pay delivered as a launchable payment link (shape 3).
///
/// The provider is the merchant of record and presents the sheet on their own already-registered
/// origin, so there is no `PKPaymentRequest` to build here and no encrypted token for us to submit.
/// We host their page and relay what it tells us.
///
/// Loading the link as the WebView's **top-level document** is what makes this work at all: Apple
/// Pay on the Web refuses to run in a cross-origin iframe, and because the top page is then the
/// provider's own registered domain, no Apple Pay domain registration is required of Meld or of the
/// integrator.
///
/// Matched on shape rather than provider, so a second provider issuing a payment link needs no
/// change here. What is unavoidably provider-specific — the name of the native handler their page
/// posts to, and the page's own event vocabulary — is declared per protocol below, which is exactly
/// what an adapter is for.
struct HostedLinkApplePayAdapter: MeldAdapter {
    let label = "Hosted Apple Pay link (APPLE_PAY / provider-hosted)"

    // requiresUserGesture: with auto-present off, the only thing that opens the sheet is a tap on
    // the provider's own button INSIDE their frame — Apple requires the gesture in the frame
    // holding the merchant session. Either way the host must not render its own Apple Pay button
    // in front of this one: it would be a second button that can never open a sheet.
    let capabilities = MeldCapabilities(embeddable: true, surface: "embedded", requiresUserGesture: true)

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "HostedLinkApplePayAdapter")

    /// Hosts whose payment links this adapter will load, and the native handler each page posts to.
    ///
    /// Provider-shaped by necessity: a hosted page speaks its own protocol, and there is no field
    /// on the order that names the channel. When the contract grows a `surface.eventChannel` this
    /// table collapses into it — until then, adding a hosted provider means one entry here.
    private static let protocols: [(host: String, handler: String)] = [
        ("coinbase.com", "cbOnramp")
    ]

    func matches(_ order: MeldOrder) -> Bool {
        guard order.paymentMethodType == "APPLE_PAY", order.presentation == .providerHosted else {
            return false
        }
        // A launchable link is the only provider-hosted protocol supported today.
        return Self.paymentLink(in: order) != nil
    }

    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard let host = context.host else {
            throw MeldMountError.missingHost(label)
        }
        guard let linkString = Self.paymentLink(in: order), let link = URL(string: linkString) else {
            throw MeldMountError.missingWidgetURL
        }
        guard let providerProtocol = Self.protocols.first(where: { Self.hostMatches(link.host, $0.host) }) else {
            throw MeldMountError.unsupported(
                "Apple Pay payment link is not on a host this SDK build knows how to host.")
        }

        // Device capability is checked BEFORE loading anything, so an integrator can offer another
        // method rather than a page whose button could never open a sheet.
        //
        // Only the DEVICE gate, deliberately: which cards are accepted is configured on the
        // provider's own merchant account, so asserting a network list here would refuse a user
        // whose Wallet holds a card that provider does take.
        if let unavailable = MeldApplePayAvailability.unavailableReason() {
            throw MeldMountError.unsupported(unavailable)
        }

        var webViewHost: WebViewHost?
        let hostRef = { webViewHost }

        let created = WebViewHost(
            url: link,
            orderId: order.id,
            handlers: handlers,
            nativeMessageHandlers: [providerProtocol.handler, Self.autoPresentChannel],
            mainFrameHosts: [providerProtocol.host],
            // The provider tells us when its button is wired; page load does not. Reporting ready
            // at navigation would cancel a host's load-timeout before the surface is usable.
            firesReadyOnNavigation: false,
            interpret: { message in
                Self.interpret(message, orderId: order.id, host: hostRef())
            })
        webViewHost = created
        created.mount(into: host)
        return created
    }

    // MARK: - Provider protocol

    /// Channel the injected auto-present script reports back on. The provider's own reference
    /// implementation has no equivalent — its retry loop simply stops. That is fine while their
    /// page is visible, because the user can still tap the button; with the page hidden it would
    /// strand them on a blank screen, so exhaustion is reported and surfaced as an error the
    /// integrator can fall back from.
    static let autoPresentChannel = "meldAutoPresent"
    static let autoPresentButtonNotFound = "button-not-found"

    static func interpret(_ message: [String: Any], orderId: String?, host: WebViewHost?) -> [MeldEvent] {
        guard let handler = message["handler"] as? String else { return [] }

        if handler == autoPresentChannel {
            guard message["body"] as? String == autoPresentButtonNotFound else { return [] }
            return [.error(MeldError(
                orderId: orderId,
                code: "apple_pay_button_not_found",
                message: "The provider's page did not present an Apple Pay button.",
                detail: nil,
                // Environmental, not a fault in the order — the integrator should offer another
                // method rather than invite a retry that will hit the same page.
                recoverable: true))]
        }

        // The provider posts JSON strings shaped { eventName, data }.
        guard let body = message["body"] as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = json["eventName"] as? String
        else { return [] }

        switch eventName {
        case "onramp_api.load_success":
            // The page is up and its button is wired. Hide it and click it so the sheet is the only
            // thing the user ever sees.
            host?.evaluateJavaScript(autoPresentScript)
            return [.ready]

        case "onramp_api.commit_success", "onramp_api.polling_start":
            // A UX hint only: the provider has accepted the payment and is working on it, but
            // settlement truth is the Meld webhook, which can land well after this.
            return [.paymentSubmitted]

        case "onramp_api.polling_success":
            // The provider's own terminal success. Still not settlement — surfaced as a status
            // change so a host can show "done" while the webhook remains the record of truth.
            return [.statusChange(MeldStatusChange(
                orderId: orderId, status: .completed, providerStatus: eventName, raw: json))]

        case "onramp_api.cancel", "onramp_api.polling_cancel":
            return [.cancel]

        case "onramp_api.load_error", "onramp_api.commit_error", "onramp_api.polling_error",
             "onramp_api.error":
            let data = json["data"] as? [String: Any]
            // The provider's own error code travels in `detail`. A host cannot tell "start a new
            // order" from "fall back to hosted checkout" from the event name alone, and collapsing
            // that distinction would cost a real recovery path — so it is carried, not dropped.
            let providerCode = data?["errorCode"] as? String
            return [.error(MeldError(
                orderId: orderId,
                code: eventName,
                message: data?["errorMessage"] as? String ?? "The provider reported an error.",
                detail: providerCode,
                // Only two outcomes are terminal: a polling failure (the order is spent) and an
                // init failure (the provider will reject the same order the same way). Everything
                // else — including a declined commit — can be retried on this order, which is what
                // the app this was ported from offered.
                recoverable: eventName != "onramp_api.polling_error" && providerCode != "ERROR_CODE_INIT"))]

        default:
            // The page emits progress events we have no Meld equivalent for. Tolerated, not an error.
            Self.logger.debug("unmapped hosted event \(eventName, privacy: .public)")
            return []
        }
    }

    /// Hides the provider's Apple Pay button and clicks it once their page has wired it up, which
    /// is what presents the native sheet. Mirrors the provider's own reference app
    /// (coinbase/onramp-v2-mobile-demo, `injectPayButtonClick`).
    ///
    /// This is the one piece of the SDK coupled to a provider's DOM, and it will break if they
    /// rename that element — which is why exhaustion is reported rather than silently swallowed.
    private static let autoPresentScript = """
        var style = document.createElement('style');
        style.textContent = 'apple-pay-button { display: none !important; }';
        document.head.appendChild(style);
        function tryClick(attempt) {
          var btn = document.getElementById('api-onramp-apple-pay-button');
          if (btn) { btn.click(); }
          else if (attempt < 10) { setTimeout(function () { tryClick(attempt + 1); }, 500); }
          else {
            window.webkit.messageHandlers.\(autoPresentChannel).postMessage('\(autoPresentButtonNotFound)');
          }
        }
        tryClick(1);
        """

    // MARK: - Order reading

    /// The launchable payment link, if this order carries one.
    private static func paymentLink(in order: MeldOrder) -> String? {
        guard let details = order.paymentMethodResponseDetails else { return nil }
        // `paymentLinkUrl` is the field today's contract uses; `surface.url` is where it is headed.
        if let surface = details["surface"] as? [String: Any],
           let url = surface["url"] as? String, !url.isEmpty {
            return url
        }
        guard let link = details["paymentLinkUrl"] as? String, !link.isEmpty else { return nil }
        return link
    }

    private static func hostMatches(_ rawHost: String?, _ allowed: String) -> Bool {
        guard let host = rawHost?.lowercased() else { return false }
        return host == allowed || host.hasSuffix(".\(allowed)")
    }
}
