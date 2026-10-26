import XCTest
@testable import MeldSDK

final class CoinmeWebCheckoutTests: XCTestCase {
    private let key = "123e4567-e89b-42d3-a456-426614174000"

    private func action(body: Any?, key: Any? = "123e4567-e89b-42d3-a456-426614174000") -> [String: Any] {
        var headers: [String: Any] = [:]
        if let key { headers["X-Idempotency-Key"] = key }
        var message: [String: Any] = ["type": "action", "id": "1", "headers": headers]
        if let body { message["body"] = body }
        return message
    }

    func testThePageMountsTheOrderWithTheWebSDKAndSendsItsActionsToNative() {
        let html = CoinmeWebCheckout.bootstrapHtml(bundleJs: "/*bundle*/", orderJson: #"{"id":"ord_1"}"#, environment: "qa")

        XCTAssertTrue(html.contains("<script>/*bundle*/</script>"))
        XCTAssertTrue(html.contains(#"M.configure({environment:"qa"});"#))
        XCTAssertTrue(html.contains(#"M.mount({"id":"ord_1"}, document.getElementById('meld-coinme')"#))
        XCTAssertTrue(html.contains("M.__setActionTransport("))
        XCTAssertTrue(html.contains("post({type:'action', id:id, headers:request.headers, body:request.body});"))
    }

    func testAClosingScriptTagInTheBundleOrTheOrderCannotEndItsScriptEarly() {
        let html = CoinmeWebCheckout.bootstrapHtml(bundleJs: "var a='</script><b>';",
                                                   orderJson: #"{"note":"</script><img src=x>","c":"<!--<script>"}"#,
                                                   environment: "sandbox")

        XCTAssertFalse(html.contains("</script><b>"))
        XCTAssertFalse(html.contains("</script><img"))
        XCTAssertFalse(html.contains("<!--"))
        XCTAssertTrue(html.contains(#"{"note":"\u003c/script>\u003cimg src=x>","c":"\u003c!--\u003cscript>"}"#))
    }

    func testTheWebSDKsCallbacksBecomeNativeEvents() {
        func only(_ message: [String: Any]) -> MeldEvent? {
            let events = CoinmeWebCheckout.events(message, orderId: "ord_1")
            XCTAssertLessThanOrEqual(events.count, 1)
            return events.first
        }
        guard case .ready? = only(["type": "ready"]) else { return XCTFail("expected ready") }
        guard case .paymentSubmitted? = only(["type": "submitted"]) else { return XCTFail("expected paymentSubmitted") }
        guard case .cancel? = only(["type": "cancel"]) else { return XCTFail("expected cancel") }
        guard case let .error(error)? = only(["type": "error", "code": "PAYMENT_REJECTED", "message": "Declined",
                                              "detail": "vault:231-400-313-601", "recoverable": false])
        else { return XCTFail("expected error") }
        XCTAssertEqual(error.orderId, "ord_1")
        XCTAssertEqual(error.code, "PAYMENT_REJECTED")
        XCTAssertEqual(error.message, "Declined")
        XCTAssertEqual(error.detail, "vault:231-400-313-601")
        XCTAssertFalse(error.recoverable)
        guard case let .error(bare)? = only(["type": "error"]) else { return XCTFail("expected error") }
        XCTAssertEqual(bare.code, MeldErrorCode.presentationFailed)
        guard case let .error(recoverable)? = only(["type": "error", "code": "PROVIDER_LOAD_FAILED", "recoverable": true])
        else { return XCTFail("expected error") }
        XCTAssertTrue(recoverable.recoverable)
        XCTAssertNil(only(["type": "status"]))
    }

    func testAnActionCarriesItsOperationFieldsAndIdempotencyKey() throws {
        let request = try XCTUnwrap(CoinmeWebCheckout.actionRequest(
            action(body: #"{"version":1,"operation":"CREATE_PAYMENT_SESSION","paymentToken":"pm_1"}"#)))

        XCTAssertEqual(request.operation, "CREATE_PAYMENT_SESSION")
        XCTAssertEqual(request.fields as? [String: String], ["paymentToken": "pm_1"])
        XCTAssertEqual(request.key, UUID(uuidString: key))
        XCTAssertNil(CoinmeWebCheckout.actionRequest(action(body: #"{"version":1,"operation":"READ"}"#, key: nil))?.key)
    }

    func testAMalformedActionIsRefused() {
        let valid = #"{"version":1,"operation":"CREATE_PAYMENT_SESSION"}"#
        for message in [
            action(body: nil),
            action(body: "not json"),
            action(body: #"{"version":1}"#),
            action(body: #"{"version":2,"operation":"CREATE_PAYMENT_SESSION"}"#),
            action(body: valid, key: "not-a-uuid"),
            action(body: valid, key: key.uppercased()),
            action(body: valid, key: 7),
            action(body: #"{"version":1,"operation":"CREATE_PAYMENT_SESSION","pad":""# + String(repeating: "x", count: 65536) + #""}"#),
        ] {
            XCTAssertNil(CoinmeWebCheckout.actionRequest(message))
        }
    }

    func testThePageGetsTheRawResponseOrNothingWhenThereIsNone() {
        XCTAssertEqual(CoinmeWebCheckout.resultScript(id: "7", response: (status: 422, body: #"{"version":1}"#)),
                       #"window.__meldActionResult("7", 422, "{\"version\":1}");"#)
        XCTAssertEqual(CoinmeWebCheckout.resultScript(id: "7", response: (status: 502, body: nil)),
                       #"window.__meldActionResult("7", 502, null);"#)
        XCTAssertEqual(CoinmeWebCheckout.resultScript(id: "7", response: nil),
                       #"window.__meldActionResult("7", null, null);"#)
    }

    func testTheVendoredBundleLoadsAndMatchesItsPinnedHash() throws {
        let bundle = try CoinmeWebCheckout.loadBundle()
        XCTAssertTrue(bundle.contains("__setActionTransport"))
    }
}
