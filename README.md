# Meld SDK — iOS

Embed a crypto on/off-ramp provider's payment widget (Mercuryo card today) into your iOS app
with one uniform call: `Meld.mount(order, into:, handlers:)`. It's the native counterpart to
the web SDK ([`@meldcrypto/sdk`](https://www.npmjs.com/package/@meldcrypto/sdk)), with the
same integration shape and event model.

The SDK is a **container manager and event relay** — it never renders card input, never reads
or transports PAN/CVC, and never reaches into the provider's content. Card capture happens
entirely on the provider's PCI surface.

**Supported today:** Mercuryo credit/debit card (embedded widget) and Mercuryo **native Apple Pay**
(PassKit sheet — see [Native Apple Pay](#native-apple-pay)).

> **Building in React Native?** You don't use this Swift API directly — use the
> [@meldcrypto/react-native-sdk](https://github.com/meldeng/meldsdk-react-native) wrapper
> (iOS + Android). See [React Native](#react-native) below.

## Installation

**Swift Package Manager.** In Xcode: **File → Add Package Dependencies…**, paste the repo URL,
and add the **MeldSDK** library to your app target. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/meldeng/meldsdk-ios", from: "0.1.1"),
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "MeldSDK", package: "meldsdk-ios"),
    ]),
]
```

**CocoaPods.** `MeldSDK` is on the public CocoaPods trunk — add it by name and run `pod install`.
(This is also how the React Native wrapper consumes the SDK.)

```ruby
pod 'MeldSDK', '~> 0.1.1'
```

Then `import MeldSDK`.

## Usage

Your **backend** creates the order (your Meld API key never reaches the app); your app passes
the response to `Meld.mount`.

```swift
import MeldSDK

Meld.configure(environment: .sandbox) // or .production

// The HeadlessOrderResponse from your backend (POST /crypto/order/headless), passed through
// untouched — the SDK reads what it needs from it.
let order = try MeldOrder.from(jsonData: orderJSON)

guard Meld.capabilities(for: order).embeddable else {
    // not an embeddable order for this SDK — handle it elsewhere
    return
}

let handle = try Meld.mount(order, into: containerView, handlers: MeldEventHandlers(
    onReady:            { _ in hideSpinner() },
    onPaymentSubmitted: { _ in showProcessing() },  // ⚠ UX hint — settlement is your webhook, not this
    onStatusChange:     { e in if e.status == .completed { showOrderComplete() } },
    onCancel:           { _ in showRetryCTA() },
    onError:            { e in showError(e.message) }
))

// On teardown (navigation away, modal dismiss):
handle.unmount()
```

## Events

| Event | Fires when | Do |
|---|---|---|
| `onReady` | Widget mounted & interactive | Hide spinner |
| `onPaymentSubmitted` | User finished the provider payment flow (UX hint only) | Show "processing" |
| `onStatusChange` | Order status changed; `status` is `pending` \| `completed` \| `failed` \| `cancelled` | React to status; `completed` = provider "order complete" (still not settlement) |
| `onCancel` | User cancelled | Show retry CTA |
| `onError` | Load failure or terminal `failed` status | Show error; `recoverable` says retry vs. new order |

`status` is normalized across providers — code against it, not the raw provider string (which
is available in `providerStatus` for logging). A terminal `failed` also fires `onError`, and a
`cancelled` status also fires `onCancel`.

Every callback receives the id of the order it relates to (shown as `_` above where unused), so
an app driving several orders at once can tell them apart.

## Native Apple Pay

When your backend creates an order with `paymentMethodType: "APPLE_PAY"`, the order isn't an
embeddable widget — it's a native Apple Pay sheet. It's the **same `Meld.mount`** as the card
widget; the order selects the surface. You pass `applePay:` instead of `into:` (there's no view to
mount into). `Meld.capabilities(for: order)` reports `surface == "native-applepay"` and
`embeddable == false`.

The order carries the `merchantIdentifier`, `sessionToken`, and `merchantTransactionId`. You supply
what the sheet and the provider need that the order doesn't carry — the amount/currency/country from
the quote you created the order against, the destination wallet, and the end-user IP:

```swift
import MeldSDK

guard Meld.canPresentApplePay() else {
    // No card provisioned or Apple Pay restricted — fall back to the card flow.
    return
}

let handle = try Meld.mount(order, applePay: MeldApplePayRequest(
    amount: 15.00,
    currencyCode: "USD",
    countryCode: "US",
    walletAddress: "bc1q…",
    clientIpAddress: endUserPublicIP,         // same IP constraint as order creation
    summaryItemLabel: "Acme — Buy BTC"
), handlers: MeldEventHandlers(
    onReady:            { _ in /* sheet presented */ },
    onPaymentSubmitted: { _ in showProcessing() },  // ⚠ UX hint — settlement is your webhook
    onStatusChange:     { e in if e.status == .completed { showOrderComplete() } },
    onCancel:           { _ in /* user dismissed the sheet */ },
    onError:            { e in showError(e.message) }
))

// handle.unmount() dismisses the sheet if you need to tear it down early.
```

The event model is identical to the card flow (see [Events](#events)) — `onReady` /
`onPaymentSubmitted` / `onStatusChange` / `onCancel` / `onError`, with the same normalized `status`.
The SDK builds the `PKPaymentRequest`, presents the sheet, and on authorization posts the encrypted
Apple Pay token to the order's session-scoped process endpoint — **authenticated with the order's
session token, never an API key**. It transports only the encrypted token and the billing
name/address Apple returns; it never sees a PAN. The same event model and settlement rule apply.

**Prerequisites (one-time, in your Apple Developer account):**

- An **Apple Pay merchant identifier** (`merchant.…`) and the **Apple Pay Payment Processing** +
  **Merchant Identity** certificates registered with Meld for your account. Meld resolves your
  per-account merchant id server-side and returns it on the order as `merchantIdentifier`; if it's
  absent, the account isn't configured for Apple Pay and `presentApplePay` throws
  `MeldApplePayError.invalidOrder`.
- The **Apple Pay capability** enabled on your app target, with the same merchant id in your app's
  entitlements.

## Settlement — webhook, never the SDK

Neither `onPaymentSubmitted` nor `onStatusChange` with `status == .completed` is settlement —
both are client-side UX signals. Mark the order paid only when your backend receives Meld's
`TRANSACTION_STATUS_CHANGED` webhook. Show "processing", not "success", until then.

## Mercuryo — prerequisites

- **KYC:** the customer needs an APPROVED Sumsub verification linked to their Meld customer.
  Meld shares it at order creation so the widget skips its own KYC. Without it, order creation
  fails with `KYC_NOT_COMPLETED`.
- **Camera:** Mercuryo's in-widget KYC liveness needs the camera — add
  `NSCameraUsageDescription` to your app's `Info.plist`.
- **End-user IP:** create the order with the end user's public IP (`clientIpAddress`);
  Mercuryo binds the widget signature to it.

## Demo app

[`Example/`](Example) is a SwiftUI app that runs the full flow — live quote, editable wallet,
**Buy** → mount the Mercuryo widget, with a status banner + event log and auto-close on a
terminal outcome. See [`Example/README.md`](Example/README.md) for credentials and run steps.
(The React Native and Android examples mirror it — see
[meldsdk-react-native](https://github.com/meldeng/meldsdk-react-native) and
[meldsdk-android](https://github.com/meldeng/meldsdk-android).)

## API reference

- `Meld.configure(environment:)` — `.sandbox` or `.production`.
- `Meld.capabilities(for:)` → `{ embeddable, surface, requiresUserGesture }` — guard with
  `embeddable` before `mount`.
- `Meld.mount(order, into:, applePay:, handlers:)` → `MeldWidgetHandle` — mounts the order's
  surface and relays its events. Pass `into:` a `UIView` for an embedded widget, or `applePay:` a
  `MeldApplePayRequest` for an Apple Pay order; `handle.unmount()` tears it down (removes the widget
  or dismisses the sheet). See [Native Apple Pay](#native-apple-pay).
- `Meld.canPresentApplePay()` → `Bool` — whether Apple Pay is usable on this device/user now.
- `MeldApplePayRequest` — the amount/currency/country/wallet/IP the Apple Pay sheet and provider
  need beyond what the order carries.
- `MeldOrder.from(jsonData:)` / `.from(jsonString:)` — decode your backend's order response.

## React Native

Building in React Native? Use the
**[@meldcrypto/react-native-sdk](https://github.com/meldeng/meldsdk-react-native)** wrapper — the
same `configure → capabilities → mount → events` flow, exposed as a `<MeldWidget>` component, for
**iOS and Android**. It lives in its own repo with its own README and example app, and consumes
this SDK as its iOS dependency (the `MeldSDK` pod).
