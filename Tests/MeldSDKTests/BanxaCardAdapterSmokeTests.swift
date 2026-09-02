import UIKit
import WebKit
import XCTest

@testable import MeldSDK

/// Exercises the parts of the Banxa adapter that unit tests cannot reach: that the 1.3MB vendored
/// bundle actually *executes* inside WKWebView (the pinned-hash test only proves the file is on disk
/// and contains a string), that `registerBanxaPrimerCheckout()` runs and the custom element upgrades,
/// and that a message posted from the page survives the origin allowlist and reaches native. A wrong
/// allowlist silently swallows every event, which no amount of pure-logic testing catches.
///
/// Uses an invalid client token, because Banxa has not provisioned native payments for the Meld
/// merchant and no real `nativeToken` can be obtained. Primer therefore cannot render a card form;
/// everything up to that point is what is under test.
///
/// Needs network — Primer's SDK loads from its CDN.
final class BanxaCardAdapterSmokeTests: XCTestCase {

    /// Isolates the vendored bundle: an error handler is installed BEFORE it runs (the production
    /// bootstrap's own handler comes after, so it cannot see a throw inside the bundle script), then
    /// the bundle executes alone and reports whether it defined its global.
    func testDiagnoseBundleExecutionInWebView() throws {
        let bundle = try BanxaWebCheckoutPresenter.loadBundle()
        let safeBundle = bundle.replacingOccurrences(of: "</script", with: "<\\/script")
        let html = """
        <!doctype html><html><head><meta charset="utf-8"></head><body>
        <script>
        window.__meldErrors = [];
        window.addEventListener('error', function(e){
          window.__meldErrors.push({ message: String((e && e.message) || e), line: (e && e.lineno) || 0 });
        }, true);
        window.onerror = function(msg, src, line, col, err){
          window.__meldErrors.push({ message: String((err && err.stack) || msg), line: line || 0 });
        };
        </script>
        <script>\(safeBundle)</script>
        <script>
        setTimeout(function(){
          try {
            window.meldSendToNativeApp({kind:'message', data:{
              type:'diag',
              hasGlobal: typeof window.MeldBanxaCheckout,
              keys: window.MeldBanxaCheckout ? Object.keys(window.MeldBanxaCheckout).join(',') : '',
              errors: JSON.stringify(window.__meldErrors || []),
              isSecureContext: !!window.isSecureContext,
              origin: String(window.location.origin)
            }});
          } catch(e) {}
        }, 3000);
        </script>
        </body></html>
        """

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let got = expectation(description: "diag")
        var diag: [String: Any] = [:]
        let session = WebViewHost(
            url: BanxaWebCheckoutPresenter.pageOrigin(),
            orderId: nil,
            handlers: MeldEventHandlers(),
            allowedOrigins: BanxaWebCheckoutPresenter.allowedOrigins,
            htmlContent: html
        ) { message in
            if (message["type"] as? String) == "diag" { diag = message; got.fulfill() }
            return []
        }
        session.mount(into: host)
        wait(for: [got], timeout: 30)
        session.unmount()
        print("=== BANXA DIAG: \(diag) ===")
    }

    /// `Meld.mount` alone cannot answer this: `WebViewHost` fires `onReady` from
    /// `webView(_:didFinish:)` on plain page load, so an observed `ready` says the HTML loaded and
    /// nothing more. This drives the real production bootstrap with a probe appended, so the
    /// assertions are about the page's actual state rather than an inference from a missing error.
    func testVendoredBundleExecutesAndCustomElementUpgrades() throws {
        let bundle = try BanxaWebCheckoutPresenter.loadBundle()
        let probe = """
        <script>
        (function(){
          window.addEventListener('error', function(e){
            try { window.meldSendToNativeApp({kind:'message', data:{
              type:'jserror',
              message: String(e && (e.message || e)),
              source: String((e && e.filename) || ''),
              line: (e && e.lineno) || 0
            }}); } catch(x) {}
          });
          function report(){
            try {
              window.meldSendToNativeApp({kind:'message', data:{
                type:'probe',
                hasGlobal: !!(window.MeldBanxaCheckout && window.MeldBanxaCheckout.registerBanxaPrimerCheckout),
                upgraded: !!customElements.get('banxa-primer-checkout'),
                elementPresent: !!document.querySelector('banxa-primer-checkout'),
                primerLoaded: !!customElements.get('primer-checkout'),
                visibleText: String((document.body.innerText||'').replace(/\\s+/g,' ').trim()).slice(0,300)
              }});
            } catch(e) {}
          }
          // Give the production bootstrap a tick to register and append, then report.
          setTimeout(report, 4000);
        })();
        </script>
        """
        // Insert before the FINAL </body>, not via replacingOccurrences: the vendored bundle contains
        // the literal "</body>" itself, so a global replace splices the probe into the middle of the
        // bundle's JavaScript and breaks it — which is exactly what an earlier revision of this test
        // did, and it looked like the adapter was broken.
        let base = BanxaWebCheckoutPresenter.bootstrapHtml(bundleJs: bundle, clientToken: "not-a-real-primer-client-token")
        let closingBody = try XCTUnwrap(base.range(of: "</body>", options: .backwards))
        let html = base.replacingCharacters(in: closingBody, with: probe + "</body>")

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let host = UIView(frame: window.bounds)
        window.addSubview(host)
        window.makeKeyAndVisible()

        let probed = expectation(description: "probe message crossed the bridge")
        var result: [String: Any] = [:]
        var allMessages: [[String: Any]] = []

        let session = WebViewHost(
            url: BanxaWebCheckoutPresenter.pageOrigin(),
            orderId: "smoke-order",
            handlers: MeldEventHandlers(),
            allowedOrigins: BanxaWebCheckoutPresenter.allowedOrigins,
            htmlContent: html
        ) { message in
            allMessages.append(message)
            if (message["type"] as? String) == "probe" {
                result = message
                probed.fulfill()
            }
            return []
        }
        session.mount(into: host)
        wait(for: [probed], timeout: 30)
        session.unmount()

        print("=== BANXA SMOKE probe: \(result) ===")
        for m in allMessages where (m["type"] as? String) != "probe" {
            print("=== BANXA SMOKE message: \(m) ===")
        }

        // The bridge itself: a message posted by the page reached native past the origin allowlist.
        XCTAssertFalse(result.isEmpty, "no message crossed the bridge — check allowedOrigins")
        // The vendored bundle executed and exposed the global the bootstrap calls.
        XCTAssertEqual(result["hasGlobal"] as? Bool, true, "vendored bundle did not execute")
        // registerBanxaPrimerCheckout() ran and defined the custom element.
        XCTAssertEqual(result["upgraded"] as? Bool, true, "banxa-primer-checkout was not registered")
        // The production bootstrap created and appended the element.
        XCTAssertEqual(result["elementPresent"] as? Bool, true, "bootstrap did not append the element")
        // Primer's own SDK loaded from its CDN — proves the network path and that primer-js is in the
        // bundle rather than expected as an unbundled peer dependency.
        XCTAssertEqual(result["primerLoaded"] as? Bool, true, "Primer SDK did not load/register")
    }
}
