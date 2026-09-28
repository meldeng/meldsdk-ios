import Foundation
import UIKit
import WebKit
import os

/// Provider-hosted Apple Pay delivered as a launchable payment link (shape 3).
///
/// The provider is the merchant of record and presents the sheet on their own already-registered
/// origin, so there is no `PKPaymentRequest` to build here and no encrypted token for us to submit.
/// We run their page out of sight, open its sheet, and relay what it tells us.
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

    /// iOS 15's WebKit hides `ApplePaySession` from a page that runs a user script, and the SDK's
    /// bridge always installs one.
    let supportedOS: Bool
    let unavailableReason: () -> String?

    init(supportedOS: Bool = HostedLinkApplePayAdapter.systemSupported,
         unavailableReason: @escaping () -> String? = { MeldApplePayAvailability.unavailableReason() }) {
        self.supportedOS = supportedOS
        self.unavailableReason = unavailableReason
    }

    static var systemSupported: Bool {
        if #available(iOS 16, *) { return true }
        return false
    }

    // Decided here rather than at mount, because preflight reads capabilities without an order.
    var capabilities: MeldCapabilities {
        supportedOS
            ? MeldCapabilities(embeddable: false, surface: "native-applepay", requiresUserGesture: true)
            : MeldCapabilities(embeddable: false, surface: "unsupported", requiresUserGesture: false)
    }

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "HostedLinkApplePayAdapter")

    /// Hosts whose payment links this adapter will load, and the native handler each page posts to.
    ///
    /// Provider-shaped by necessity: a hosted page speaks its own protocol, and there is no field
    /// on the order that names the channel. When the contract grows a `surface.eventChannel` this
    /// table collapses into it — until then, adding a hosted provider means one entry here.
    private static let protocols: [(host: String, handler: String)] = [
        ("coinbase.com", "cbOnramp")
    ]

    let presentations = [MeldAdapterPresentation("APPLE_PAY", "PROVIDER_HOSTED", "COINBASE_APPLE_PAY")]

    func acceptsDeclaredOrder(_ order: MeldOrder) -> Bool {
        return order.hasCompatibleLegacyPresentation("PROVIDER_HOSTED") && Self.hasSupportedLink(order)
    }

    func matches(_ order: MeldOrder) -> Bool {
        guard order.paymentMethodType == "APPLE_PAY", order.presentation == .providerHosted else {
            return false
        }
        // A launchable link is the only provider-hosted protocol supported today.
        return Self.hasSupportedLink(order)
    }

    func mount(order: MeldOrder, context: MeldMountContext, handlers: MeldEventHandlers) throws -> MeldProviderSession {
        guard supportedOS else {
            throw MeldMountError.unsupported("Provider-hosted Apple Pay needs iOS 16 or later.")
        }
        guard Self.hasSupportedLink(order),
              let linkString = Self.paymentLink(in: order), let link = URL(string: linkString) else {
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
        if let unavailable = unavailableReason() {
            let session = HostedLinkApplePaySession(orderId: order.id, handlers: handlers)
            session.deviceUnavailable(unavailable)
            return session
        }
        guard Thread.isMainThread, let surface = OffscreenSurfaceHost(host: context.host) else {
            throw MeldMountError.presentationUnavailable
        }

        let session = HostedLinkApplePaySession(orderId: order.id, handlers: handlers)
        let page = WebViewHost(
            url: link,
            orderId: order.id,
            handlers: MeldEventHandlers(onError: { [weak session] in session?.pageFailed($0) }),
            nativeMessageHandlers: [providerProtocol.handler],
            mainFrameHosts: [providerProtocol.host],
            firesReadyOnNavigation: false,
            onContentProcessTerminated: { [weak session] in session?.pageTerminated() },
            interpret: { [weak session] message in
                session?.receive(message)
                return []
            })
        session.start(page: page, surface: surface)
        return session
    }

    // MARK: - Provider protocol

    /// Maps one message from the provider's page. Every error is terminal; the provider's own event
    /// and code travel in `detail` as `<event>:<errorCode>`.
    static func interpret(_ message: [String: Any], orderId: String?) -> [MeldEvent] {
        // The provider posts JSON strings shaped { eventName, data }.
        guard isProviderMessage(message),
              let body = message["body"] as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventName = json["eventName"] as? String
        else { return [] }

        switch eventName {
        case "onramp_api.load_success":
            return [.ready]

        case "onramp_api.commit_success", "onramp_api.polling_start":
            // A UX hint only: the provider has accepted the payment and is working on it, but
            // settlement truth is the Meld webhook, which can land well after this.
            return [.statusChange(MeldStatusChange(
                        orderId: orderId, status: .pending, providerStatus: eventName, raw: json)),
                    .paymentSubmitted]

        case "onramp_api.polling_success":
            return [.statusChange(MeldStatusChange(
                orderId: orderId, status: .completed, providerStatus: eventName, raw: json))]

        case "onramp_api.cancel", "onramp_api.polling_cancel":
            return [.cancel]

        case "onramp_api.load_error", "onramp_api.commit_error", "onramp_api.polling_error",
             "onramp_api.error":
            let data = json["data"] as? [String: Any]
            let providerCode = data?["errorCode"] as? String
            return [.error(MeldError(
                orderId: orderId,
                code: errorCode(eventName, providerCode: providerCode),
                message: data?["errorMessage"] as? String ?? "The provider reported an error.",
                detail: providerCode.map { "\(eventName):\($0)" } ?? eventName,
                recoverable: false))]

        default:
            // The page emits progress events we have no Meld equivalent for. Tolerated, not an error.
            Self.logger.debug("unmapped hosted event \(eventName, privacy: .public)")
            return []
        }
    }

    static func isProviderMessage(_ message: [String: Any]) -> Bool {
        guard let handler = message["handler"] as? String else { return false }
        return protocols.contains { $0.handler == handler }
    }

    private static func errorCode(_ eventName: String, providerCode: String?) -> String {
        switch (eventName, providerCode) {
        case (_, "ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED"), (_, "ERROR_CODE_GUEST_APPLE_PAY_NOT_SETUP"):
            return MeldErrorCode.applePayUnavailable
        case (_, "ERROR_CODE_INIT"):
            return MeldErrorCode.orderStateChanged
        case ("onramp_api.commit_error", _):
            return MeldErrorCode.paymentRejected
        case ("onramp_api.polling_error", _):
            return MeldErrorCode.paymentOutcomeUnknown
        default:
            return MeldErrorCode.presentationFailed
        }
    }

    /// Clicks the provider's Apple Pay button, which presents the native sheet, and answers
    /// `'clicked'` or `'missing'`. Mirrors the provider's reference app
    /// (coinbase/onramp-v2-mobile-demo, `injectPayButtonClick`); the one piece of the SDK coupled
    /// to a provider's DOM.
    static let autoPresentScript = """
        (function () {
          if (document.head && !document.getElementById('meld-auto-present')) {
            var style = document.createElement('style');
            style.id = 'meld-auto-present';
            style.textContent = 'apple-pay-button { display: none !important; }';
            document.head.appendChild(style);
          }
          var button = document.getElementById('api-onramp-apple-pay-button');
          if (!button) { return 'missing'; }
          button.click();
          return 'clicked';
        })();
        """

    // MARK: - Order reading

    private static func hasSupportedLink(_ order: MeldOrder) -> Bool {
        MeldPresentationURL.https(paymentLink(in: order), hosts: Set(protocols.map(\.host)), subdomains: true)
    }

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

/// The page a hosted session drives. `WebViewHost` in production.
protocol HostedPage: AnyObject {
    func mount(into host: UIView)
    func unmount()
    func evaluateJavaScript(_ script: String, completion: @escaping (Any?) -> Void)
}

extension WebViewHost: HostedPage {}

/// One provider-hosted Apple Pay payment: loads the page offscreen, clicks its button once per
/// attempt, bounds the wait for an outcome, and delivers the terminal callback before tearing down.
/// A submitted session outlives its handle in `DetachedSurfaces`. Main thread only.
final class HostedLinkApplePaySession: MeldProviderSession, DetachedSurface {
    struct Timing {
        var loadTimeout: TimeInterval = 20
        var clickInterval: TimeInterval = 0.25
        var clickAttempts = 20
        var detachedGrace: TimeInterval = DetachedSurfaces.gracePeriod
    }

    private enum Phase { case loading, clicking, presented, submitted, ended }

    private static let interruptedLoads: Set = ["\(NSURLErrorDomain) #\(NSURLErrorCancelled)", "WebKitErrorDomain #102"]

    private let orderId: String?
    private let handlers: MeldEventHandlers
    private let timing: Timing
    private let deadline: PresentationDeadline
    private let ceiling: PresentationCeiling
    private let surfaces: DetachedSurfaces
    private let isActive: () -> Bool
    private var page: HostedPage?
    private var surface: OffscreenSurfaceHost?
    private var phase = Phase.loading
    private var didAutoPresent = false
    private var detached = false
    private var clicks = 0
    private var loadTimeout: DispatchWorkItem?
    private var nextClick: DispatchWorkItem?

    init(orderId: String?, handlers: MeldEventHandlers, timing: Timing = Timing(),
         deadline: PresentationDeadline = PresentationDeadline(),
         ceiling: PresentationCeiling = PresentationCeiling(),
         surfaces: DetachedSurfaces = .shared,
         isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active }) {
        self.orderId = orderId
        self.handlers = handlers
        self.timing = timing
        self.deadline = deadline
        self.ceiling = ceiling
        self.surfaces = surfaces
        self.isActive = isActive
    }

    func start(page: HostedPage, surface: OffscreenSurfaceHost) {
        self.page = page
        self.surface = surface
        surface.onHostLeftWindow = { [weak self] in self?.unmount() }
        page.mount(into: surface.container)
        loadTimeout = after(timing.loadTimeout) { [weak self] in
            self?.fail(MeldErrorCode.presentationFailed, "The provider's page did not load.", detail: "load_timeout")
        }
    }

    func deviceUnavailable(_ reason: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.handle(.error(MeldError(orderId: self.orderId, code: MeldErrorCode.applePayUnavailable,
                                         message: reason, recoverable: false)))
        }
    }

    // MARK: - Page input

    func receive(_ message: [String: Any]) {
        guard phase != .ended else { return }
        if phase == .presented, HostedLinkApplePayAdapter.isProviderMessage(message) { deadline.disarm() }
        HostedLinkApplePayAdapter.interpret(message, orderId: orderId).forEach(handle)
    }

    func pageFailed(_ error: MeldError) {
        guard !Self.interruptedLoads.contains(error.detail ?? "") else { return }
        let detail = [error.code, error.detail].compactMap { $0 }.joined(separator: ":")
        let code = phase == .presented ? MeldErrorCode.paymentOutcomeUnknown : MeldErrorCode.presentationFailed
        handle(.error(MeldError(orderId: orderId, code: code, message: error.message,
                                detail: detail, recoverable: false)))
    }

    func pageTerminated() {
        switch phase {
        case .ended:
            return
        case .loading, .clicking:
            fail(MeldErrorCode.presentationFailed, "The provider's page stopped before it presented Apple Pay.",
                 detail: "web_content_terminated")
        case .presented, .submitted:
            settle("web_content_terminated")
            handlers.sessionEnded?(orderId)
        }
    }

    // MARK: - Lifecycle

    func unmount() {
        switch phase {
        case .ended:
            return
        case .submitted:
            guard !detached else { return }
            detached = true
            surfaces.keep(self, for: timing.detachedGrace)
        case .loading, .clicking, .presented:
            tearDown()
        }
    }

    func tearDown() {
        guard phase != .ended else { return }
        phase = .ended
        stopTimers()
        page?.unmount()
        page = nil
        surface?.remove()
        surface = nil
    }

    private func handle(_ event: MeldEvent) {
        switch phase {
        case .ended: return
        case .submitted: return afterSubmission(event)
        case .loading, .clicking, .presented: break
        }
        switch event {
        case .ready:
            autoPresent()
        case .paymentSubmitted:
            submit()
            dispatch(event)
        case let .statusChange(change) where change.status == .completed:
            submit()
            dispatch(event)
            settle(change.providerStatus ?? change.status.rawValue)
        case .statusChange:
            dispatch(event)
        case .cancel, .error:
            dispatch(event)
            tearDown()
        }
    }

    private func afterSubmission(_ event: MeldEvent) {
        if !detached { dispatch(event) }
        switch event {
        case let .statusChange(change) where change.status == .completed:
            settle(change.providerStatus ?? change.status.rawValue)
        case .cancel:
            settle("cancel")
        case let .error(error):
            settle(error.detail ?? error.code)
        case .ready, .paymentSubmitted, .statusChange:
            break
        }
    }

    private func submit() {
        phase = .submitted
        stopTimers()
    }

    private func settle(_ outcome: String) {
        if detached { surfaces.release(self, outcome: outcome) }
        tearDown()
    }

    // MARK: - Auto-present

    private func autoPresent() {
        guard !didAutoPresent else { return }
        didAutoPresent = true
        loadTimeout?.cancel()
        phase = .clicking
        click()
    }

    private func click() {
        guard phase == .clicking, let page else { return }
        clicks += 1
        page.evaluateJavaScript(HostedLinkApplePayAdapter.autoPresentScript) { [weak self] result in
            self?.clicked(result as? String == "clicked")
        }
    }

    private func clicked(_ clicked: Bool) {
        guard phase == .clicking else { return }
        if clicked { return presented() }
        guard clicks < timing.clickAttempts else {
            return fail(MeldErrorCode.presentationFailed, "The provider's page did not present an Apple Pay button.",
                        detail: "apple_pay_button_not_found")
        }
        nextClick = after(timing.clickInterval) { [weak self] in self?.click() }
    }

    private func presented() {
        phase = .presented
        let sheetUp = !isActive()
        if !sheetUp {
            deadline.arm { [weak self] in
                self?.fail(MeldErrorCode.presentationFailed, "The Apple Pay sheet did not appear.",
                           detail: "presentation_deadline")
            }
        }
        ceiling.arm(paused: sheetUp) { [weak self] in
            self?.fail(MeldErrorCode.paymentOutcomeUnknown,
                       "The provider did not report an outcome. Track the existing order without paying again.",
                       detail: "presentation_ceiling")
        }
        handlers.onReady?(orderId)
    }

    // MARK: - Helpers

    private func fail(_ code: String, _ message: String, detail: String) {
        handle(.error(MeldError(orderId: orderId, code: code, message: message, detail: detail, recoverable: false)))
    }

    private func stopTimers() {
        loadTimeout?.cancel()
        loadTimeout = nil
        nextClick?.cancel()
        nextClick = nil
        deadline.disarm()
        ceiling.disarm()
    }

    private func after(_ interval: TimeInterval, _ work: @escaping () -> Void) -> DispatchWorkItem {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
        return item
    }

    private func dispatch(_ event: MeldEvent) {
        switch event {
        case .ready: handlers.onReady?(orderId)
        case .paymentSubmitted: handlers.onPaymentSubmitted?(orderId)
        case let .statusChange(change): handlers.onStatusChange?(change)
        case .cancel: handlers.onCancel?(orderId)
        case let .error(error): handlers.onError?(error)
        }
    }
}
