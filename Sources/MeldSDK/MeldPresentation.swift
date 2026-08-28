import Foundation

/// How a payment surface is put on screen. This is the SDK's only dispatch key — adapters select on
/// it and never on a provider's identity, so adding a provider to a shape that already has an
/// adapter is a backend config change and nothing here.
///
/// The three shapes are a property of what the *provider* exposes, not of what we build:
///
/// - ``nativeToken`` — the provider accepts an encrypted wallet token on a server-to-server
///   endpoint, so the sheet can be presented by us through PassKit. No provider surface anywhere.
/// - ``vendorSdk`` — the provider's own SDK captures the token inside their PCI environment. Still a
///   native sheet, but a third-party binary presents it.
/// - ``providerHosted`` — the provider is the merchant of record and renders the sheet on their own
///   registered origin. We host their surface; we never see a token. Today that means a launchable
///   payment link; a widget-session variant is not supported and must not be inferred.
enum MeldPresentation: Equatable {
    case nativeToken
    case vendorSdk
    case providerHosted

    /// A value this SDK build does not know — a newer backend serving a shape added after this
    /// binary shipped. Kept as a distinct case rather than collapsing to nil so dispatch can fail
    /// as "unsupported order" instead of falling through to an adapter that would mishandle it.
    case unrecognized(String)

    init(serverValue: String) {
        switch serverValue {
        case "NATIVE_TOKEN": self = .nativeToken
        case "VENDOR_SDK": self = .vendorSdk
        case "PROVIDER_HOSTED": self = .providerHosted
        default: self = .unrecognized(serverValue)
        }
    }
}

extension MeldOrder {
    /// The order's presentation shape.
    ///
    /// Prefers the server's `presentation` field. Until that field ships, falls back to the field
    /// fingerprint of today's response — which is why this exists at all: the live shapes are
    /// distinguishable, just not labelled. Returns nil when neither the field nor the fingerprint
    /// identifies a shape, which the caller must treat as unsupported.
    var presentation: MeldPresentation? {
        guard let details = paymentMethodResponseDetails else { return nil }

        if let served = details["presentation"] as? String, !served.isEmpty {
            return MeldPresentation(serverValue: served)
        }
        return Self.fingerprint(details)
    }

    /// Shape inferred from which fields the response populated. Ordered most-specific first, and
    /// deliberately narrow: an order matching nothing here is unsupported, never a default.
    ///
    /// The field names are provider-shaped because today's contract is
    /// (`paymentLinkUrl` was added for one provider, `merchantTransactionId` for another). New
    /// fields should not be — see the `presentation` branch above, which is the shape this collapses
    /// into once the backend serves it.
    private static func fingerprint(_ details: MeldOrder.Details) -> MeldPresentation? {
        // A provider-hosted payment link: launching it opens the sheet on the provider's origin.
        if nonEmpty(details["paymentLinkUrl"]) != nil { return .providerHosted }

        // A session token is what authorizes submitting the encrypted token back, so it is the
        // marker for the encrypted-token shape. Deliberately NOT also requiring `merchantIdentifier`:
        // an account whose backend does not surface one yet still has a native order, and the
        // adapter reports that precisely rather than the order failing to dispatch at all.
        if nonEmpty(details["sessionToken"]) != nil { return .nativeToken }

        // A vendor client token has no live provider yet; matched here so the adapter, when it
        // lands, needs no change to this resolver.
        if nonEmpty(details["vendorClientTokenUrl"]) != nil { return .vendorSdk }

        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
