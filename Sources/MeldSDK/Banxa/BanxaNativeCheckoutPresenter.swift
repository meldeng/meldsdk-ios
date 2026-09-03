import BanxaPaymentSDK
import PrimerSDK
import Foundation
import UIKit
import os

/// Presents Banxa's own iOS SDK, for orders Banxa creates itself
/// (`providerOrderCreation = CLIENT`).
///
/// Unlike every other presenter here, this one is handed order *parameters* rather than something to
/// render: `BanxaPaymentSDK.startPayment` runs eligibility, creates the Banxa order and presents the
/// sheet in a single call, and has no entry point that pays an order created earlier. Meld's own order
/// row already exists; what joins them is `externalOrderID`, which is carried through below and is how
/// the backend finds the order again if the completion callback never arrives.
///
/// Card and Apple Pay are the same call — Banxa maps `paymentMethodId` to Primer's method type
/// (`debit-credit-card` → `PAYMENT_CARD`, `apple-pay` → `APPLE_PAY`) and Primer presents either.
///
/// Two behaviours of that SDK are worth knowing, because neither is ours to change:
///
/// - **It falls back to Banxa's hosted checkout.** When Banxa withholds the `nativeToken` — today,
///   always, because KYC sharing is not enabled — `startPayment` presents Banxa's full hosted checkout
///   in its own WebView instead of a native sheet. That is the product the headless response
///   deliberately refuses to serve, and here it is inside the vendor's SDK. There is no dedicated
///   callback for it; `BanxaNativeSession` reports it as an `onStatusChange` with
///   `providerStatus == "HOSTED_CHECKOUT_FALLBACK"` (recognisable because the completion carries no
///   Banxa order id), so a host can tell the two apart rather than believing it got a native surface.
/// - **The hosted path returns no order id.** Its completion carries only a query string, so the
///   Meld↔Banxa join then rests entirely on the webhook matching `externalOrderId`.
@MainActor
struct BanxaNativeCheckoutPresenter: BanxaCheckoutPresenter {

    // Not embeddable: the SDK presents its own modal from a view controller and never renders into a
    // host view. An integrator guarding on `embeddable` must not lay out a container for it.
    let capabilities = MeldCapabilities(
        embeddable: false, surface: "native-sheet", requiresUserGesture: true)

    private static let logger = Logger(subsystem: "io.meld.sdk", category: "BanxaNativeCheckoutPresenter")

    func present(
        order: MeldOrder,
        context: MeldMountContext,
        handlers: MeldEventHandlers
    ) throws -> MeldProviderSession {
        let params = try BanxaProviderSdkParameters(order: order)

        // The SDK presents from a view controller. The host view is optional for this surface, so fall
        // back to whatever is on screen rather than refusing an order for the want of a container the
        // sheet never uses.
        guard let controller = Self.presentingController(for: context.host) else {
            throw MeldMountError.unsupported(
                "Banxa's SDK presents its own sheet and needs a view controller to present from; none "
                    + "could be found. Pass a host view that is in the window hierarchy.")
        }

        let session = BanxaNativeSession(orderId: order.id, handlers: handlers)
        // The SDK holds its delegate weakly, so the session owns itself until it completes; without
        // this the callbacks are silently dropped the moment the caller stops holding the handle.
        session.retainUntilFinished()
        // unmount() dismisses whatever Banxa's SDK presented from this controller.
        session.presentingController = controller

        // The provider credential is fetched rather than read off the order — the order response is
        // persisted for idempotent replay, so it carries only a short-lived bearer for this call. The
        // session is returned immediately and the sheet appears once the fetch lands.
        Self.fetchConfig(from: params.configUrl, token: params.configToken) { result in
            Task { @MainActor in
                guard !session.isFinished else { return }
                switch result {
                case .failure(let error):
                    session.failBeforeStart(error)
                case .success(let config):
                    guard let request = params.createOrderRequest(email: config.email) else {
                        session.failBeforeStart(
                            MeldMountError.unsupported(
                                "Banxa SDK configuration response carried no customer email, which Banxa's "
                                    + "order creation requires."))
                        return
                    }
                    session.link = config.providerOrderLink
                    // Apple Pay needs the merchant identifier in Primer's settings — Primer's SDK
                    // guards on `applePayOptions.merchantIdentifier` and throws before any sheet
                    // appears without it. Banxa's SDK forwards PrimerSettings verbatim, so this is the
                    // one place it can be supplied. The identifier is per-account (Mercuryo model): the
                    // integrator declares it in their Apple Pay entitlement and registers it with Banxa.
                    let primerSettings: PrimerSettings?
                    if params.paymentMethodId == "apple-pay" {
                        guard let merchantIdentifier = config.applePayMerchantIdentifier else {
                            session.failBeforeStart(
                                BanxaMountRefusal(
                                    code: "apple_pay_merchant_identifier_missing",
                                    message: "Apple Pay through Banxa needs an Apple Pay merchant identifier "
                                        + "configured on the Meld account (the same one declared in this "
                                        + "app's Apple Pay entitlement and registered with Banxa)."))
                            return
                        }
                        primerSettings = PrimerSettings(
                            paymentMethodOptions: PrimerPaymentMethodOptions(
                                applePayOptions: PrimerApplePayOptions(
                                    merchantIdentifier: merchantIdentifier,
                                    merchantName: config.applePayMerchantName)))
                    } else {
                        primerSettings = nil
                    }
                    BanxaPaymentSDK.shared.configure(
                        config: BanxaConfig(
                            apiKey: config.apiKey,
                            partnerID: config.partnerId,
                            environment: config.environment,
                            primerSettings: primerSettings))
                    BanxaPaymentSDK.shared.delegate = session
                    BanxaPaymentSDK.shared.startPayment(request: request, controller: controller)
                }
            }
        }
        return session
    }

    /// Fetches provider-SDK configuration for this order.
    private static func fetchConfig(
        from url: URL, token: String,
        completion: @escaping @Sendable (Result<BanxaProviderSdkConfig, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Audience-scoped and bound to this order, so it reaches this order's configuration and
        // nothing else.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status), let data else {
                // Keep the server's error code and message: a 422 CUSTOMER_NOT_PAYMENT_READY is not a
                // transient fetch failure, and collapsing every non-2xx into one generic
                // 'unavailable' threw away the code the integrator would branch on and mislabelled a
                // KYC gate as retryable.
                completion(.failure(BanxaSdkConfigFetchError(status: status, body: data)))
                return
            }
            do {
                completion(.success(try BanxaProviderSdkConfig(data: data)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// The view controller Banxa's SDK presents from: the one owning the host view when there is one,
    /// otherwise the topmost presented controller in the active window.
    private static func presentingController(for host: UIView?) -> UIViewController? {
        var responder: UIResponder? = host
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        var top = root
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}

/// The `ProviderSdkOrder` fields, validated once so a missing one is a clear error rather than a
/// Banxa API rejection three calls later.
private struct BanxaProviderSdkParameters {
    let configUrl: URL
    let configToken: String

    /// Read by the presenter to decide whether Primer needs Apple Pay options.
    let paymentMethodId: String
    private let crypto: String
    private let blockchain: String?
    private let fiat: String
    private let fiatAmount: String
    private let walletAddress: String
    private let redirectUrl: String
    private let externalCustomerId: String
    private let externalOrderId: String

    /// Assembled once the configuration fetch lands, because the customer's email comes with it —
    /// kept off the order for the same reason the credential is, since that response is persisted.
    func createOrderRequest(email: String?) -> CreateOrderRequest? {
        guard let email, !email.isEmpty else { return nil }
        var request = CreateOrderRequest(
            crypto: crypto,
            fiat: fiat,
            fiatAmount: fiatAmount,
            walletAddress: walletAddress,
            email: email,
            redirectURL: redirectUrl)
        request.paymentMethodID = paymentMethodId
        request.blockchain = blockchain
        // The identity Meld's KYC share was established under. Without it Banxa creates the order for
        // an unverified identity and the share never attaches.
        request.externalCustomerID = externalCustomerId
        // The join back to the Meld order, and the only one available on the hosted-fallback path.
        request.externalOrderID = externalOrderId
        return request
    }

    init(order: MeldOrder) throws {
        let details = order.paymentMethodResponseDetails

        func required(_ key: String) throws -> String {
            guard let value = details?[key] as? String, !value.isEmpty else {
                throw MeldMountError.unsupported(
                    "Banxa provider-SDK order is missing \(key). The order was created with "
                        + "providerOrderCreation=CLIENT but the response did not carry the parameters "
                        + "the SDK creates the Banxa order from.")
            }
            return value
        }

        guard let url = URL(string: try required("sdkConfigUrl")) else {
            throw MeldMountError.unsupported("Banxa provider-SDK order has a malformed sdkConfigUrl.")
        }
        configUrl = url
        configToken = try required("sdkConfigToken")

        crypto = try required("crypto")
        fiat = try required("fiat")
        fiatAmount = try required("fiatAmount")
        walletAddress = try required("walletAddress")
        redirectUrl = try required("redirectUrl")
        paymentMethodId = try required("paymentMethodId")
        blockchain = details?["blockchain"] as? String
        externalCustomerId = try required("externalCustomerId")
        externalOrderId = try required("externalOrderId")
    }
}


/// The provider-SDK configuration response, fetched per order.
private struct BanxaProviderSdkConfig {
    let email: String?
    let apiKey: String
    let partnerId: String
    let environment: BanxaEnvironment
    /// Per-account Apple Pay merchant identifier/name for Primer's Apple Pay sheet; nil when unconfigured.
    let applePayMerchantIdentifier: String?
    let applePayMerchantName: String?
    /// Absent when the backend issued no link coordinates; the webhook then makes the join on its own.
    let providerOrderLink: BanxaNativeSession.ProviderOrderLink?

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apiKey = json["apiKey"] as? String, !apiKey.isEmpty,
              let partnerId = json["partnerId"] as? String, !partnerId.isEmpty
        else {
            throw MeldMountError.unsupported("Banxa SDK configuration response was missing apiKey or partnerId.")
        }
        self.apiKey = apiKey
        self.partnerId = partnerId
        email = json["email"] as? String
        applePayMerchantIdentifier = (json["applePayMerchantIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        applePayMerchantName = json["applePayMerchantName"] as? String
        // Anything unrecognised is treated as sandbox rather than production: guessing wrong in that
        // direction moves real money.
        environment = (json["environment"] as? String)?.uppercased() == "PRODUCTION" ? .production : .sandbox

        if let urlString = json["providerOrderLinkUrl"] as? String,
           let url = URL(string: urlString),
           let token = json["providerOrderLinkToken"] as? String,
           !token.isEmpty {
            providerOrderLink = BanxaNativeSession.ProviderOrderLink(url: url, token: token)
        } else {
            providerOrderLink = nil
        }
    }
}

/// A non-2xx from the provider-SDK configuration endpoint, with the server's own error code and
/// message when the body carries them (Meld's error envelope: `{"code": ..., "message": ...}`).
struct BanxaSdkConfigFetchError: Error {
    let status: Int
    let code: String?
    let message: String

    init(status: Int, body: Data?) {
        self.status = status
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        code = json?["code"] as? String
        message = (json?["message"] as? String)
            ?? "Could not fetch Banxa SDK configuration for this order (HTTP \(status))."
    }

    /// Retrying the same Meld order can only help for transport failures and server errors. A 4xx —
    /// most importantly 422 CUSTOMER_NOT_PAYMENT_READY — is a decision about this order, not a blip.
    var isRecoverable: Bool { status == 0 || status >= 500 }
}

/// A pre-start refusal that is a decision about this order, not a fetch problem: reported under its
/// own error code and never marked recoverable.
struct BanxaMountRefusal: Error {
    let code: String
    let message: String
}
