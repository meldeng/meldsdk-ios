import UIKit
import WebKit
import XCTest
@testable import MeldSDK

/// Provider-hosted Apple Pay (shape 3): dispatch, the mapping from the hosted page's own event
/// vocabulary to Meld events, and the session that runs the page offscreen. The session is driven
/// with a synthetic page; no provider page is loaded.
final class HostedLinkApplePayTests: XCTestCase {

    private let adapter = HostedLinkApplePayAdapter()
    private var window: UIWindow!
    private var root: UIViewController!

    override func setUp() {
        super.setUp()
        root = UIViewController()
        window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = root
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        window.isHidden = true
        window = nil
        root = nil
        super.tearDown()
    }

    private func order(_ json: String) throws -> MeldOrder {
        try MeldOrder.from(jsonString: json)
    }

    private func linkOrder(_ url: String = "https://pay.coinbase.com/buy/x") throws -> MeldOrder {
        try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"paymentLinkUrl":"\#(url)"}}"#)
    }

    // MARK: - Dispatch and capabilities

    func testClaimsAProviderHostedPaymentLinkAsASurfaceTheSdkPresents() throws {
        let order = try linkOrder()
        XCTAssertTrue(adapter.matches(order))
        let caps = Meld.capabilities(for: order)
        XCTAssertFalse(caps.embeddable, "the host needs no visible view")
        XCTAssertEqual(caps.surface, "native-applepay")
        XCTAssertTrue(caps.requiresUserGesture, "the host must not put its own button in front")
    }

    func testIOS16AndLaterPresentTheHiddenPage() {
        XCTAssertTrue(HostedLinkApplePayAdapter.systemSupported)
        let caps = HostedLinkApplePayAdapter(supportedOS: true).capabilities
        XCTAssertEqual(caps.surface, "native-applepay")
        XCTAssertFalse(caps.embeddable)
    }

    func testBelowIOS16TheSurfaceIsUnsupportedAndMountRefuses() throws {
        let old = HostedLinkApplePayAdapter(supportedOS: false)
        XCTAssertEqual(old.capabilities.surface, "unsupported")
        XCTAssertFalse(old.capabilities.embeddable)
        XCTAssertThrowsError(try old.mount(order: linkOrder(), context: MeldMountContext(host: root.view, applePay: nil),
                                           handlers: MeldEventHandlers())) { error in
            guard case MeldMountError.unsupported = error else { return XCTFail("expected unsupported, got \(error)") }
        }
    }

    func testADeviceWithoutApplePayMountsThenReportsUnavailableAndTearsDown() throws {
        let unable = HostedLinkApplePayAdapter(supportedOS: true, unavailableReason: { "Apple Pay is not supported on this device." })
        let subviews = root.view.subviews.count
        var errors: [MeldError] = []
        let reported = expectation(description: "onError")
        let session = try unable.mount(order: linkOrder(), context: MeldMountContext(host: root.view, applePay: nil),
                                       handlers: MeldEventHandlers(onError: { errors.append($0); reported.fulfill() }))
        XCTAssertTrue(errors.isEmpty, "the error follows mount, never inside it")
        XCTAssertEqual(root.view.subviews.count, subviews, "no page is loaded")
        wait(for: [reported], timeout: 1)
        XCTAssertEqual(errors.map(\.code), ["APPLE_PAY_UNAVAILABLE"])
        XCTAssertEqual(errors.first?.message, "Apple Pay is not supported on this device.")
        XCTAssertEqual(errors.first?.recoverable, false)
        XCTAssertEqual(errors.first?.orderId, "o1")
        session.unmount()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(errors.count, 1)
    }

    func testMountWithNoVisiblePresenterThrowsPresentationUnavailable() throws {
        let adapter = HostedLinkApplePayAdapter(supportedOS: true, unavailableReason: { nil })
        let bare = UIWindow(frame: UIScreen.main.bounds)
        bare.isHidden = false
        defer { bare.isHidden = true }
        let host = UIView()
        bare.addSubview(host)
        XCTAssertThrowsError(try adapter.mount(order: linkOrder(), context: MeldMountContext(host: host, applePay: nil),
                                               handlers: MeldEventHandlers())) { error in
            guard case MeldMountError.presentationUnavailable = error else {
                return XCTFail("expected presentationUnavailable, got \(error)")
            }
            XCTAssertEqual(error.localizedDescription,
                           "No visible view controller can present this payment. Mount on the main thread from a screen that is on screen.")
        }
    }

    func testDoesNotClaimANativeOrder() throws {
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"sessionToken":"jwt","merchantIdentifier":"m"}}"#)
        XCTAssertFalse(adapter.matches(order))
    }

    func testDoesNotClaimAnOrderWithNoPaymentLink() throws {
        // Provider-hosted is claimed only when there is a launchable link to load. An Apple Pay
        // order carrying neither a link nor the native fields is unsupported, not this adapter's.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"presentation":"PROVIDER_HOSTED"}}"#)
        XCTAssertFalse(adapter.matches(order))
    }

    func testDoesNotClaimACardOrder() throws {
        let order = try order(#"{"id":"o1","paymentMethodType":"CREDIT_DEBIT_CARD","paymentMethodResponseDetails":{"paymentLinkUrl":"https://pay.coinbase.com/buy/x"}}"#)
        XCTAssertFalse(adapter.matches(order))
    }

    func testReadsTheForwardLookingSurfaceUrlToo() throws {
        // The contract is moving from a provider-shaped `paymentLinkUrl` to a neutral `surface.url`;
        // the adapter reads both so the rename is not a flag day.
        let order = try order(#"{"id":"o1","paymentMethodType":"APPLE_PAY","paymentMethodResponseDetails":{"presentation":"PROVIDER_HOSTED","surface":{"url":"https://pay.coinbase.com/buy/x"}}}"#)
        XCTAssertTrue(adapter.matches(order))
    }

    // MARK: - Event mapping

    private static func message(_ eventName: String, data: String = "{}") -> [String: Any] {
        ["handler": "cbOnramp", "body": #"{"eventName":"\#(eventName)","data":\#(data)}"#]
    }

    private func events(_ eventName: String, data: String = "{}") -> [MeldEvent] {
        HostedLinkApplePayAdapter.interpret(Self.message(eventName, data: data), orderId: "o1")
    }

    func testLoadSuccessIsReady() {
        guard case .ready = events("onramp_api.load_success").first else {
            return XCTFail("expected .ready")
        }
    }

    func testCommitSuccessAndPollingStartArePendingThenSubmitted() {
        // Deliberately NOT a completed status: the provider accepting the payment is a UX hint,
        // and settlement truth is the Meld webhook.
        for name in ["onramp_api.commit_success", "onramp_api.polling_start"] {
            let mapped = events(name)
            XCTAssertEqual(mapped.count, 2, name)
            guard case let .statusChange(change) = mapped.first, case .paymentSubmitted = mapped.last else {
                return XCTFail("expected pending then .paymentSubmitted for \(name)")
            }
            XCTAssertEqual(change.status, .pending)
            XCTAssertEqual(change.providerStatus, name)
        }
    }

    func testCancelAndPollingCancelAreCancel() {
        for name in ["onramp_api.cancel", "onramp_api.polling_cancel"] {
            guard case .cancel = events(name).first else { return XCTFail("expected .cancel for \(name)") }
        }
    }

    func testPollingSuccessIsACompletedStatusChange() {
        guard case let .statusChange(change) = events("onramp_api.polling_success").first else {
            return XCTFail("expected .statusChange")
        }
        XCTAssertEqual(change.status, .completed)
        XCTAssertEqual(change.providerStatus, "onramp_api.polling_success")
    }

    func testEveryPageErrorMapsToANormalizedTerminalCode() {
        let table: [(event: String, providerCode: String?, code: String)] = [
            ("onramp_api.load_error", "ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED", "APPLE_PAY_UNAVAILABLE"),
            ("onramp_api.load_error", "ERROR_CODE_GUEST_APPLE_PAY_NOT_SETUP", "APPLE_PAY_UNAVAILABLE"),
            ("onramp_api.load_error", "ERROR_CODE_INIT", "ORDER_STATE_CHANGED"),
            ("onramp_api.error", "ERROR_CODE_INIT", "ORDER_STATE_CHANGED"),
            ("onramp_api.load_error", "ERROR_CODE_SOMETHING_ELSE", "PRESENTATION_FAILED"),
            ("onramp_api.error", nil, "PRESENTATION_FAILED"),
            ("onramp_api.commit_error", "ERROR_CODE_DECLINED", "PAYMENT_REJECTED"),
            ("onramp_api.polling_error", nil, "PAYMENT_OUTCOME_UNKNOWN"),
        ]
        for row in table {
            let data = row.providerCode.map { #"{"errorCode":"\#($0)"}"# } ?? "{}"
            guard case let .error(error) = events(row.event, data: data).first else {
                return XCTFail("expected .error for \(row)")
            }
            XCTAssertEqual(error.code, row.code, "\(row)")
            XCTAssertFalse(error.recoverable, "\(row)")
            XCTAssertEqual(error.detail, row.providerCode.map { "\(row.event):\($0)" } ?? row.event)
            XCTAssertEqual(error.message, "The provider reported an error.")
        }
    }

    func testErrorCarriesTheProviderMessage() {
        let mapped = events("onramp_api.commit_error", data: #"{"errorMessage":"card declined"}"#)
        guard case let .error(error) = mapped.first else { return XCTFail("expected .error") }
        XCTAssertEqual(error.code, "PAYMENT_REJECTED")
        XCTAssertEqual(error.message, "card declined")
    }

    func testUnmappedEventIsIgnoredRatherThanTreatedAsFailure() {
        XCTAssertTrue(events("onramp_api.something_new").isEmpty)
    }

    func testMalformedPayloadIsDropped() {
        let mapped = HostedLinkApplePayAdapter.interpret(["handler": "cbOnramp", "body": "not json"], orderId: "o1")
        XCTAssertTrue(mapped.isEmpty)
    }

    func testMessagesFromUnknownNativeHandlersAreIgnored() {
        let mapped = HostedLinkApplePayAdapter.interpret(
            ["handler": "unknownHandler", "body": #"{"eventName":"onramp_api.load_success","data":{}}"#], orderId: "o1")
        XCTAssertTrue(mapped.isEmpty)
        XCTAssertFalse(HostedLinkApplePayAdapter.isProviderMessage(["handler": "unknownHandler"]))
        XCTAssertFalse(HostedLinkApplePayAdapter.isProviderMessage(["data": "window message"]))
    }

    func testReadyComesFromTheProviderNotFromPageLoad() throws {
        // Nothing but load_success produces .ready; the session clicks on it.
        for event in ["onramp_api.polling_start", "onramp_api.commit_success", "onramp_api.cancel"] {
            for mapped in events(event) {
                if case .ready = mapped { XCTFail("\(event) must not report ready") }
            }
        }
    }

    // MARK: - Session harness

    private final class Recorder {
        let gate = TerminalGate()
        var log: [String] = []
        private(set) var errors: [MeldError] = []
        lazy var handlers: MeldEventHandlers = MeldEventHandlers(
            onReady: { [weak self] _ in self?.log.append("ready") },
            onPaymentSubmitted: { [weak self] _ in self?.log.append("submitted") },
            onStatusChange: { [weak self] in self?.log.append("status:\($0.status.rawValue)") },
            onCancel: { [weak self] _ in self?.log.append("cancel") },
            onError: { [weak self] in self?.errors.append($0); self?.log.append("error:\($0.code)") }
        ).gated(by: gate)
    }

    private final class FakePage: HostedPage {
        var answers: [String] = []
        var onUnmount: (() -> Void)?
        private(set) var clicks = 0
        private(set) var unmounts = 0
        private(set) weak var mountedInto: UIView?

        func mount(into host: UIView) { mountedInto = host }
        func unmount() { unmounts += 1; onUnmount?() }
        func evaluateJavaScript(_ script: String, completion: @escaping (Any?) -> Void) {
            XCTAssertEqual(script, HostedLinkApplePayAdapter.autoPresentScript)
            clicks += 1
            let answer = answers.isEmpty ? "missing" : answers.removeFirst()
            DispatchQueue.main.async { completion(answer) }
        }
    }

    private final class AppState { var active = true }

    private final class Harness {
        let recorder = Recorder()
        let page = FakePage()
        let notifications = NotificationCenter()
        let surfaces = DetachedSurfaces()
        let app = AppState()
        let surface: OffscreenSurfaceHost
        let session: HostedLinkApplePaySession

        init(host: UIView?, timing: HostedLinkApplePaySession.Timing = Harness.fast,
             deadline: TimeInterval = 5, ceiling: TimeInterval = 5) throws {
            surface = try XCTUnwrap(OffscreenSurfaceHost(host: host))
            session = HostedLinkApplePaySession(
                orderId: "o1", handlers: recorder.handlers, timing: timing,
                deadline: PresentationDeadline(interval: deadline, notifications: notifications),
                ceiling: PresentationCeiling(interval: ceiling, notifications: notifications),
                surfaces: surfaces, isActive: { [app] in app.active })
            page.onUnmount = { [weak recorder] in recorder?.log.append("unmount") }
            session.start(page: page, surface: surface)
        }

        static let fast = HostedLinkApplePaySession.Timing(loadTimeout: 5, clickInterval: 0.01, clickAttempts: 3,
                                                           detachedGrace: 5)

        var log: [String] { recorder.log }

        func send(_ eventName: String, data: String = "{}") {
            session.receive(HostedLinkApplePayTests.message(eventName, data: data))
        }

        func post(_ name: Notification.Name) { notifications.post(name: name, object: nil) }
    }

    private func eventually(_ timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let limit = Date().addingTimeInterval(timeout)
        while !condition(), Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func presentedHarness(deadline: TimeInterval = 5, ceiling: TimeInterval = 5) throws -> Harness {
        let h = try Harness(host: root.view, deadline: deadline, ceiling: ceiling)
        h.page.answers = ["clicked"]
        h.send("onramp_api.load_success")
        eventually { h.log == ["ready"] }
        XCTAssertEqual(h.log, ["ready"])
        return h
    }

    // MARK: - Offscreen surface

    func testAZeroSizeHostGetsAnInvisibleContainerTheSizeOfThePresenter() throws {
        let zero = UIView(frame: .zero)
        root.view.addSubview(zero)
        let h = try Harness(host: zero)
        let container = h.surface.container

        XCTAssertTrue(container.superview === root.view)
        XCTAssertTrue(root.view.subviews.last === container, "added as the topmost subview")
        XCTAssertEqual(container.frame, root.view.bounds)
        XCTAssertEqual(container.autoresizingMask, [.flexibleWidth, .flexibleHeight])
        XCTAssertEqual(container.alpha, 0)
        XCTAssertFalse(container.isUserInteractionEnabled)
        XCTAssertTrue(container.accessibilityElementsHidden)
        XCTAssertTrue(h.page.mountedInto === container)

        h.session.unmount()
        XCTAssertNil(container.superview)
        XCTAssertTrue(zero.subviews.isEmpty, "the window observer leaves with the surface")
    }

    /// A headless simulator keeps the app inactive, so which branch runs depends on the device.
    func testWithoutAHostOnlyAForegroundActiveKeyWindowIsUsed() throws {
        guard UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) else {
            XCTAssertNil(OffscreenSurfaceHost(host: nil), "an inactive app has no key window to present in")
            return
        }
        let surface = try XCTUnwrap(OffscreenSurfaceHost(host: nil))
        XCTAssertTrue(surface.container.superview === root.view)
        XCTAssertEqual(surface.container.frame, root.view.bounds)
        surface.remove()
    }

    func testThePresenterIsTheTopScreenAndStepsBackFromOneBeingDismissed() {
        let child = UIViewController()
        root.present(child, animated: false)
        eventually { child.viewIfLoaded?.window != nil }
        XCTAssertTrue(OffscreenSurfaceHost.presenter(for: root.view) === child)

        child.dismiss(animated: true)
        eventually { child.isBeingDismissed }
        XCTAssertTrue(child.isBeingDismissed, "precondition: the dismissal is in flight")
        XCTAssertTrue(OffscreenSurfaceHost.presenter(for: root.view) === root)
        eventually { self.root.presentedViewController == nil }
    }

    func testThereIsNoPresenterInAWindowWithoutAScreen() {
        let bare = UIWindow(frame: UIScreen.main.bounds)
        bare.isHidden = false
        defer { bare.isHidden = true }
        let host = UIView()
        bare.addSubview(host)
        XCTAssertNil(OffscreenSurfaceHost.presenter(for: host))
        XCTAssertNil(OffscreenSurfaceHost(host: host))
    }

    func testAHostLeavingItsWindowBeforeATerminalTearsDownSilently() throws {
        let host = UIView(frame: .zero)
        root.view.addSubview(host)
        let h = try Harness(host: host)

        host.removeFromSuperview()
        h.send("onramp_api.commit_success")

        XCTAssertEqual(h.log, ["unmount"])
        XCTAssertNil(h.surface.container.superview)
        XCTAssertEqual(h.page.unmounts, 1)
    }

    // MARK: - Auto-click

    func testEachAttemptIsItsOwnClickUntilTheButtonAppears() throws {
        let h = try Harness(host: root.view)
        h.page.answers = ["missing", "missing", "clicked"]

        h.send("onramp_api.load_success")
        eventually { h.log == ["ready"] }

        XCTAssertEqual(h.page.clicks, 3)
        XCTAssertEqual(h.log, ["ready"], "onReady fires on the click, not on the page load")
    }

    func testARepeatedLoadSuccessDoesNotClickAgain() throws {
        let h = try presentedHarness()

        h.send("onramp_api.load_success")
        settle(0.1)

        XCTAssertEqual(h.page.clicks, 1)
        XCTAssertEqual(h.log, ["ready"])
    }

    func testTheClickBudgetRunningOutIsAPresentationFailure() throws {
        let h = try Harness(host: root.view)

        h.send("onramp_api.load_success")
        eventually { h.log.count == 2 }

        XCTAssertEqual(h.page.clicks, 3)
        XCTAssertEqual(h.log, ["error:PRESENTATION_FAILED", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "apple_pay_button_not_found")
        XCTAssertEqual(h.recorder.errors.first?.recoverable, false)
    }

    func testTheShippedRetryScheduleIsTwentyAttemptsAQuarterSecondApart() {
        let timing = HostedLinkApplePaySession.Timing()
        XCTAssertEqual(timing.clickAttempts, 20)
        XCTAssertEqual(timing.clickInterval, 0.25)
        XCTAssertEqual(timing.loadTimeout, 20)
        XCTAssertEqual(timing.detachedGrace, 60)
        XCTAssertEqual(PresentationDeadline.defaultInterval, 8)
        XCTAssertEqual(PresentationCeiling.defaultInterval, 180)
    }

    // MARK: - Terminal callbacks

    func testCancelGivesExactlyOneOnCancelThenTeardown() throws {
        let h = try presentedHarness()

        h.send("onramp_api.cancel")
        h.send("onramp_api.cancel")

        XCTAssertEqual(h.log, ["ready", "cancel", "unmount"])
    }

    func testErrorsKeepTheirCodeThenTearDown() throws {
        let h = try presentedHarness()

        h.send("onramp_api.load_error", data: #"{"errorCode":"ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED"}"#)

        XCTAssertEqual(h.log, ["ready", "error:APPLE_PAY_UNAVAILABLE", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "onramp_api.load_error:ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED")
    }

    func testPageLoadFailuresArePresentationFailuresButInterruptedLoadsAreNot() throws {
        let h = try Harness(host: root.view)

        h.session.pageFailed(MeldError(orderId: "o1", code: "PROVIDER_LOAD_FAILED", message: "cancelled",
                                       detail: "NSURLErrorDomain #-999", recoverable: true))
        XCTAssertEqual(h.log, [])

        h.session.pageFailed(MeldError(orderId: "o1", code: "PROVIDER_LOAD_FAILED", message: "offline",
                                       detail: "NSURLErrorDomain #-1009", recoverable: true))
        XCTAssertEqual(h.log, ["error:PRESENTATION_FAILED", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "PROVIDER_LOAD_FAILED:NSURLErrorDomain #-1009")
        XCTAssertEqual(h.recorder.errors.first?.message, "offline")
        XCTAssertEqual(h.recorder.errors.first?.recoverable, false)
    }

    func testAPageLoadFailureAfterTheClickIsAnUnknownOutcome() throws {
        let h = try presentedHarness()

        h.session.pageFailed(MeldError(orderId: "o1", code: "NAVIGATION_FAILED", message: "offline",
                                       detail: "NSURLErrorDomain #-1009", recoverable: false))

        XCTAssertEqual(h.log, ["ready", "error:PAYMENT_OUTCOME_UNKNOWN", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "NAVIGATION_FAILED:NSURLErrorDomain #-1009")
    }

    func testSubmissionIsPendingThenSubmittedAndLaterPollingIsDroppedThenSettles() throws {
        let h = try presentedHarness()

        h.send("onramp_api.commit_success")
        h.send("onramp_api.polling_start")
        XCTAssertEqual(h.log, ["ready", "status:pending", "submitted"])
        XCTAssertEqual(h.page.unmounts, 0, "the page keeps polling after the terminal callback")

        h.send("onramp_api.polling_success")
        XCTAssertEqual(h.log, ["ready", "status:pending", "submitted", "unmount"])
    }

    func testPollingSuccessWithoutACommitIsTheSubmission() throws {
        let h = try presentedHarness()

        h.send("onramp_api.polling_success")

        XCTAssertEqual(h.log, ["ready", "status:completed", "submitted", "unmount"])
    }

    func testWebContentTerminationAfterTheClickIsTheBackstop() throws {
        let h = try presentedHarness()

        h.session.pageTerminated()
        h.session.pageTerminated()

        XCTAssertEqual(h.log, ["ready", "unmount", "error:PAYMENT_OUTCOME_UNKNOWN"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "session_ended")
    }

    func testWebContentTerminationBeforeTheClickIsAPresentationFailure() throws {
        let h = try Harness(host: root.view)

        h.session.pageTerminated()
        h.session.pageTerminated()

        XCTAssertEqual(h.log, ["error:PRESENTATION_FAILED", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "web_content_terminated")
        XCTAssertEqual(h.recorder.errors.first?.recoverable, false)
    }

    func testWebContentTerminationAfterSubmissionOnlyTearsDown() throws {
        let h = try presentedHarness()
        h.send("onramp_api.commit_success")

        h.session.pageTerminated()

        XCTAssertEqual(h.log, ["ready", "status:pending", "submitted", "unmount"])
    }

    // MARK: - Timers

    func testNoLoadSuccessInTimeIsAPresentationFailure() throws {
        var timing = Harness.fast
        timing.loadTimeout = 0.05
        let h = try Harness(host: root.view, timing: timing)

        eventually { h.log.count == 2 }

        XCTAssertEqual(h.log, ["error:PRESENTATION_FAILED", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "load_timeout")
    }

    func testLoadSuccessStopsTheLoadTimeout() throws {
        var timing = Harness.fast
        timing.loadTimeout = 0.1
        let h = try Harness(host: root.view, timing: timing)
        h.page.answers = ["clicked"]

        h.send("onramp_api.load_success")
        settle(0.3)

        XCTAssertEqual(h.log, ["ready"])
    }

    func testTheSheetNotAppearingFailsAtThePresentationDeadline() throws {
        let h = try presentedHarness(deadline: 0.3)

        eventually { h.log.count == 3 }

        XCTAssertEqual(h.log, ["ready", "error:PRESENTATION_FAILED", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "presentation_deadline")
    }

    func testAnyPageEventDisarmsThePresentationDeadline() throws {
        let h = try presentedHarness(deadline: 0.3)

        h.send("onramp_api.something_new")
        settle(0.5)

        XCTAssertEqual(h.log, ["ready"])
    }

    func testResigningActiveDisarmsThePresentationDeadline() throws {
        let h = try presentedHarness(deadline: 0.3)

        h.post(UIApplication.willResignActiveNotification)
        settle(0.5)

        XCTAssertEqual(h.log, ["ready"])
    }

    func testASheetUpBeforeTheClickAnswersStartsNeitherTimerUntilTheAppIsActiveAgain() throws {
        let h = try Harness(host: root.view, deadline: 0.3, ceiling: 0.3)
        h.page.answers = ["clicked"]
        h.app.active = false

        h.send("onramp_api.load_success")
        settle(0.6)
        XCTAssertEqual(h.log, ["ready"], "the sheet is up, so it did not fail to appear")

        h.app.active = true
        h.post(UIApplication.didBecomeActiveNotification)
        eventually { h.log.count == 3 }

        XCTAssertEqual(h.log, ["ready", "error:PAYMENT_OUTCOME_UNKNOWN", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "presentation_ceiling")
    }

    func testTheCeilingPausesWhileTheSheetHoldsTheAppInactive() throws {
        let h = try presentedHarness(ceiling: 0.2)

        h.post(UIApplication.willResignActiveNotification)
        settle(0.4)
        XCTAssertEqual(h.log, ["ready"], "time with the sheet up does not count")

        h.post(UIApplication.didBecomeActiveNotification)
        eventually { h.log.count == 3 }

        XCTAssertEqual(h.log, ["ready", "error:PAYMENT_OUTCOME_UNKNOWN", "unmount"])
        XCTAssertEqual(h.recorder.errors.first?.detail, "presentation_ceiling")
    }

    func testTheCeilingCountsOnlyActiveTime() {
        let notifications = NotificationCenter()
        let ceiling = PresentationCeiling(interval: 0.5, notifications: notifications)
        var expired = 0
        ceiling.arm { expired += 1 }
        XCTAssertTrue(ceiling.armed)
        XCTAssertFalse(ceiling.paused)

        settle(0.2)
        notifications.post(name: UIApplication.willResignActiveNotification, object: nil)
        XCTAssertTrue(ceiling.paused)
        settle(0.6)
        XCTAssertEqual(expired, 0)
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let resumed = Date()

        eventually { expired == 1 }
        XCTAssertEqual(expired, 1)
        XCTAssertLessThan(Date().timeIntervalSince(resumed), 0.5, "the active time before the pause still counts")
        XCTAssertFalse(ceiling.armed)
    }

    func testDisarmingTheCeilingCancelsIt() {
        let ceiling = PresentationCeiling(interval: 0.05, notifications: NotificationCenter())
        var expired = 0
        ceiling.arm { expired += 1 }

        ceiling.disarm()
        settle(0.2)

        XCTAssertEqual(expired, 0)
        XCTAssertFalse(ceiling.armed)
    }

    func testSubmissionStopsTheDeadlineAndTheCeiling() throws {
        let h = try presentedHarness(deadline: 0.3, ceiling: 0.4)

        h.send("onramp_api.commit_success")
        settle(0.6)

        XCTAssertEqual(h.log, ["ready", "status:pending", "submitted"])
    }

    // MARK: - Keep-alive after submission

    func testAReleasedSubmittedPageIsKeptUntilPollingSettles() throws {
        for outcome in ["onramp_api.polling_success", "onramp_api.polling_error", "onramp_api.polling_cancel"] {
            let h = try presentedHarness()
            let handle = MeldWidgetHandle(mode: "native-applepay", session: h.session, gate: h.recorder.gate)
            h.send("onramp_api.commit_success")

            handle.unmount()
            handle.unmount()
            XCTAssertEqual(h.surfaces.count, 1, outcome)
            XCTAssertEqual(h.page.unmounts, 0, outcome)

            h.send(outcome, data: #"{"errorCode":"ERROR_CODE_X"}"#)

            XCTAssertEqual(h.surfaces.count, 0, outcome)
            XCTAssertEqual(h.log, ["ready", "status:pending", "submitted", "unmount"], outcome)
        }
    }

    func testAReleasedPageBeforeSubmissionIsTornDownAtOnce() throws {
        let h = try presentedHarness()

        h.session.unmount()

        XCTAssertEqual(h.surfaces.count, 0)
        XCTAssertEqual(h.log, ["ready", "unmount"])
    }

    func testTheRegistryIsWhatKeepsADroppedSubmittedSessionAliveForTheGracePeriod() throws {
        let recorder = Recorder(), page = FakePage(), surfaces = DetachedSurfaces()
        var timing = Harness.fast
        timing.detachedGrace = 0.1
        weak var released: HostedLinkApplePaySession?
        try autoreleasepool {
            let session = HostedLinkApplePaySession(orderId: "o1", handlers: recorder.handlers, timing: timing,
                                                    surfaces: surfaces)
            session.start(page: page, surface: try XCTUnwrap(OffscreenSurfaceHost(host: root.view)))
            var handle: MeldWidgetHandle? = MeldWidgetHandle(mode: "native-applepay", session: session, gate: recorder.gate)
            session.receive(Self.message("onramp_api.commit_success"))
            released = session
            XCTAssertNotNil(handle)
            handle = nil
        }

        XCTAssertNotNil(released)
        XCTAssertEqual(surfaces.count, 1)
        XCTAssertEqual(page.unmounts, 0)

        eventually { released == nil }

        XCTAssertNil(released)
        XCTAssertEqual(surfaces.count, 0)
        XCTAssertEqual(page.unmounts, 1)
        XCTAssertEqual(recorder.log, ["status:pending", "submitted"])
    }

    func testTheHostLeavingAfterSubmissionKeepsThePageToo() throws {
        let host = UIView(frame: .zero)
        root.view.addSubview(host)
        let h = try Harness(host: host)
        h.send("onramp_api.commit_success")

        host.removeFromSuperview()

        XCTAssertEqual(h.surfaces.count, 1)
        h.send("onramp_api.polling_cancel")
        XCTAssertEqual(h.surfaces.count, 0)
        XCTAssertEqual(h.log, ["status:pending", "submitted", "unmount"])
    }

    // MARK: - WebViewHost

    func testScriptsAreRefusedWithNilWhenNoAllowedPageIsLoaded() throws {
        let host = WebViewHost(url: try XCTUnwrap(URL(string: "https://pay.coinbase.com/buy")), orderId: "o1",
                               handlers: MeldEventHandlers(), mainFrameHosts: ["coinbase.com"], interpret: { _ in [] })
        var results: [String?] = []

        host.evaluateJavaScript("'x'") { results.append($0 as? String) }

        XCTAssertEqual(results, [nil])
    }

    func testContentProcessTerminationIsReportedOnlyWhenAsked() throws {
        var terminated = 0
        let url = try XCTUnwrap(URL(string: "https://pay.coinbase.com/buy"))
        let reporting = WebViewHost(url: url, orderId: "o1", handlers: MeldEventHandlers(),
                                    onContentProcessTerminated: { terminated += 1 }, interpret: { _ in [] })
        let silent = WebViewHost(url: url, orderId: "o1", handlers: MeldEventHandlers(), interpret: { _ in [] })

        reporting.webViewWebContentProcessDidTerminate(WKWebView())
        silent.webViewWebContentProcessDidTerminate(WKWebView())

        XCTAssertEqual(terminated, 1)
    }

    func testTheAutoPresentScriptClicksTheProvidersButtonAndSaysSo() throws {
        let clicked = try evaluateAutoPresent(body: #"<button id="api-onramp-apple-pay-button" onclick="window.meldClicks = (window.meldClicks || 0) + 1"></button>"#,
                                              then: ["window.meldClicks", "document.querySelectorAll('#meld-auto-present').length"])
        XCTAssertEqual(clicked.first as? String, "clicked")
        XCTAssertEqual(clicked.dropFirst().first as? String, "clicked", "each attempt answers again")
        XCTAssertEqual((clicked.dropFirst(2).first as? NSNumber)?.intValue, 2)
        XCTAssertEqual((clicked.last as? NSNumber)?.intValue, 1, "the hiding style is added once")

        let missing = try evaluateAutoPresent(body: "<p>loading</p>", then: [])
        XCTAssertEqual(missing.first as? String, "missing")
    }

    /// Runs the auto-present script twice in a local page on an allowed origin, then each extra script.
    private func evaluateAutoPresent(body: String, then scripts: [String]) throws -> [Any?] {
        let loaded = expectation(description: "loaded")
        let host = WebViewHost(url: try XCTUnwrap(URL(string: "https://pay.coinbase.com/buy")), orderId: "o1",
                               handlers: MeldEventHandlers(onReady: { _ in loaded.fulfill() }),
                               htmlContent: "<html><head></head><body>\(body)</body></html>",
                               mainFrameHosts: ["coinbase.com"], interpret: { _ in [] })
        let container = UIView(frame: root.view.bounds)
        root.view.addSubview(container)
        defer { host.unmount(); container.removeFromSuperview() }
        host.mount(into: container)
        wait(for: [loaded], timeout: 10)

        var results: [Any?] = []
        let all = [HostedLinkApplePayAdapter.autoPresentScript, HostedLinkApplePayAdapter.autoPresentScript] + scripts
        let evaluated = expectation(description: "evaluated")
        evaluated.expectedFulfillmentCount = all.count
        func run(_ index: Int) {
            guard index < all.count else { return }
            host.evaluateJavaScript(all[index]) { result in
                results.append(result)
                evaluated.fulfill()
                run(index + 1)
            }
        }
        run(0)
        wait(for: [evaluated], timeout: 10)
        return results
    }
}
