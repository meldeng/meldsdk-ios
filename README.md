# Meld SDK — iOS

Embed a crypto on/off-ramp provider's payment widget (Mercuryo card today) into your iOS app
with one uniform call: `Meld.mount(order, into:, handlers:)`. It's the native counterpart to
the web SDK ([`@meldcrypto/sdk`](https://www.npmjs.com/package/@meldcrypto/sdk)), with the
same integration shape and event model.

The SDK is a **container manager and event relay** — it never renders card input, never reads
or transports PAN/CVC, and never reaches into the provider's content. Card capture happens
entirely on the provider's PCI surface.

**Implemented surfaces:** Mercuryo and Uphold card widgets, Banxa card and Apple Pay,
Mercuryo native Apple Pay, Coinbase-hosted Apple Pay, and the Stripe crypto onramp (Apple Pay and
card). Use the returned capabilities to check whether this SDK build can present a particular order.

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

guard Meld.capabilities(for: order).surface != "unsupported" else {
    // This SDK cannot present this order; offer an explicitly supported alternative.
    return
}

let handle = try Meld.mount(order, into: containerView, handlers: MeldEventHandlers(
    onReady:            { _ in hideSpinner() },
    onPaymentSubmitted: { _ in showProcessing() },  // terminal; ⚠ settlement is your webhook, not this
    onStatusChange:     { e in showProgress(e.status) },  // informational only
    onCancel:           { _ in showRetryCTA() },  // terminal
    onError:            { e in if !e.recoverable { handleTerminalError(e.code) } }
))

// On teardown (navigation away, modal dismiss):
handle.unmount()
```

## Check presentation support before creating an order

Decode the `headlessPresentation` served on the selected quote or payment method. No provider name,
order ID or payment credential is needed:

```swift
guard let presentation = MeldHeadlessPresentation(json: presentationJSON),
      Meld.capabilities(for: presentation, paymentMethodType: paymentMethodType).surface != "unsupported"
else { return } // Missing, malformed or unimplemented protocol: select a supported alternative.
```

This advisory check uses the same installed adapter registry as order dispatch. It does not
establish route eligibility, Apple Pay availability, legal acceptance or authorization to pay.
Keep checking requirements and device readiness, then validate the actual order with
`Meld.capabilities(for: order)` before mounting it. `embeddable` only indicates whether a visible
host is needed; native sheets can be supported with `embeddable == false`. Never invent a
presentation from a provider name or fabricate an order for preflight.

The preflight API is available from 0.8.0. Older releases do not provide it.

## Events

| Event | Fires when | Do |
|---|---|---|
| `onReady` | Surface presented & interactive | Hide spinner |
| `onPaymentSubmitted` | **Terminal.** The customer submitted payment; settlement arrives by webhook or server polling | Unmount, show "processing" |
| `onStatusChange` | Informational; `status` is `pending` \| `completed` \| `failed` \| `cancelled` | Update progress UI only |
| `onCancel` | **Terminal.** Nothing will settle for this order | Unmount; a retry needs a new order |
| `onError` | **Terminal** when `recoverable: false`; act on `code` (see [Error codes](#error-codes)) | Unmount and follow the code |

**Exactly one terminal callback per mount.** From `mount` until you release the handle (with
`unmount()` or by dropping it), the SDK delivers exactly one of `onPaymentSubmitted`, `onCancel` or
`onError(recoverable: false)`, and nothing after it: no `onStatusChange` and no `onReady`. The
handle is then inert; a retry means a new order. Releasing the handle yourself ends the mount with
no callback.

Providers disagree on how a submission arrives: some send a "payment finished" message and never a
status, some send `completed` and never a finished message, some send both in either order. The SDK
collapses that into one `onPaymentSubmitted`, so you do not need a `settledOnce` guard of your own.
A `failed` or `cancelled` status blocks a later submission, and the provider's `onError` or
`onCancel` follows it. If a session ends without a terminal callback, the SDK reports
`onError(PAYMENT_OUTCOME_UNKNOWN)`, or `PAYMENT_REJECTED` after a `failed` status.

`pending` means the provider is processing and promises nothing by itself. `recoverable: true` comes
only from visible embedded card widgets: the surface stays up and the customer may still pay.

`status` is normalized across providers — code against it, not the raw provider string (which
is available in `providerStatus` for logging).

Every callback receives the id of the order it relates to (shown as `_` above where unused), so
an app driving several orders at once can tell them apart.

### Error codes

`code` on a terminal `onError` from an Apple Pay or native SDK surface is normalized. Embedded card
widgets keep their existing codes. The provider's own event and code, when there is one, travel in
`detail` (for example `banxa_apple_pay_failed:<Primer errorId>`).

| `code` | Can an attempt exist? | Do |
|---|---|---|
| `APPLE_PAY_UNAVAILABLE` | No | Offer hosted checkout or another method |
| `PRESENTATION_FAILED` | No | Return to your CTA; the next tap creates a new order |
| `PAYMENT_REJECTED` | No (declined) | Offer another payment option |
| `ORDER_STATE_CHANGED` | No | Create a new order |
| `VERIFICATION_PENDING` | No | Tell the customer the provider is reviewing their verification |
| `PAYMENT_OUTCOME_UNKNOWN` | Yes | Track the existing order; never pay it again |

Banxa Apple Pay reports Primer's outcomes as follows. Primer creates the payment after the customer
authorizes, so a failure once the sheet is requested can follow a payment that exists:

| Primer outcome | Callback |
|---|---|
| Checkout completed | `onPaymentSubmitted` |
| `payment-cancelled`, or the sheet dismissed | `onCancel` |
| Any failure before the sheet is requested, or neither Primer reporting the sheet shown nor an app deactivation within 8 s of the request | `onError(PRESENTATION_FAILED)` |
| `unable-to-present-apple-pay`, `apple-pay-presentation-failed`, `apple-pay-device-not-supported`, `apple-pay-no-cards-in-wallet` or `apple-pay-configuration-error` | `onError(PRESENTATION_FAILED)` |
| `payment-failed` with payment status `FAILED` | `onError(PAYMENT_REJECTED)` |
| Any other failure after the sheet is requested | `onError(PAYMENT_OUTCOME_UNKNOWN)` |

Wallet recovery codes (`VERIFICATION_WINDOW_EXPIRED`, `WAIT_FOR_PAYMENT`, `INVALID_VERIFICATION`,
`PAYMENT_CONTINUATION_UNAVAILABLE`, …) are unchanged. After a successful create, treat any code you
do not know as "an attempt may exist": track the order through your backend and never pay it again.

## Native Apple Pay

For an Apple Pay order declaring `NATIVE_TOKEN / MELD_WALLET_TOKEN` v1, use the
**same `Meld.mount`** as the card widget. The order selects the surface. Pass `applePay:` with
the sheet inputs. `Meld.capabilities(for: order)` reports `surface == "native-applepay"` and
`embeddable == false`, as it does for Banxa and provider-hosted Apple Pay. `native-applepay` means
the SDK presents the payment UI and your host needs no visible view.

The order carries the `merchantIdentifier`, `sessionToken`, and `merchantTransactionId`. You supply
the amount and currency from the quote used to create that order, a display label, and a fallback
email if the wallet does not supply one. The new action contract uses the order's server-bound
destination wallet and client IP; those values are not sent again by the SDK:

```swift
import MeldSDK

let handle = try Meld.mount(order, applePay: MeldApplePayRequest(
    amount: 15.00,
    currencyCode: "USD",
    email: "customer@example.com",          // fallback when PassKit omits the email
    summaryItemLabel: "Acme — Buy BTC"
), handlers: MeldEventHandlers(
    onReady:            { _ in /* sheet presented */ },
    onPaymentSubmitted: { _ in showProcessing() },  // terminal; ⚠ settlement is your webhook
    onStatusChange:     { e in showProgress(e.status) },  // informational only
    onCancel:           { _ in /* user dismissed the sheet; nothing will settle */ },
    onError:            { e in if !e.recoverable { handleTerminalError(e.code) } }
))

// handle.unmount() dismisses the sheet if you need to tear it down early.
```

Call mounting and teardown on the main thread. `Meld.canPresentApplePay()` can gate offering a new
wallet payment; it must not prevent recovery of an existing submitted or verification-required order.
For those states, the SDK reads the existing attempt without needing a new wallet sheet or request.

The event model is identical to the card flow (see [Events](#events)) — `onReady` /
`onPaymentSubmitted` / `onStatusChange` / `onCancel` / `onError`, with the same normalized `status`.
The SDK reads `READ_SUBMISSION` before presenting PassKit. Only `NOT_STARTED / NONE` with no
local attempt permits a new sheet. It sends the encrypted token and billing details through
`SUBMIT_WALLET_PAYMENT`, using the order's declared endpoint and scoped bearer. No integrator API
key reaches the SDK. A lost or malformed submission response triggers a read, never a second submission.

The SDK persists only a mutation UUID and submission/verification flags in the app's Keychain.
Unmounting or recreating the handle does not reset them. Unknown, pending, expired or previously
submitted attempts must be tracked through your backend's canonical order/transaction status.
`recoverable: false` means this mounted flow has stopped; it does not mean a new charge is safe.

A verification response appears after PassKit dismisses, in a visible confirmation and Safari sheet.
The SDK explains whether verification resumes a held payment or continues an unfunded attempt in a
hosted checkout. It checks the URL's allowed origin and expiry, opens it once after a user tap, and
reads payment state after the browser closes. Cancelling the confirmation does not open or reload it.
Neither disposition creates another order or presents another native payment sheet. A PassKit checkmark,
browser dismissal or SDK event does not establish settlement.

For historical orders with neither presentation nor action metadata, the compatibility path uses the
legacy session endpoint. These orders still need `walletAddress` and `clientIpAddress` in
`MeldApplePayRequest`. Ambiguous legacy outcomes are not retried. A declared wallet protocol requires
a valid `paymentActions` descriptor and never falls back to that endpoint.

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
`TRANSACTION_CRYPTO_COMPLETE` webhook. Show "processing", not "success", until then.

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

### Versioned presentation dispatch

Pass the complete order response to `MeldOrder.from`. New responses include a top-level descriptor:

```json
"headlessPresentation": {
  "surface": "PROVIDER_HOSTED",
  "protocol": "COINBASE_APPLE_PAY",
  "version": 1
}
```

The SDK chooses an adapter using the descriptor and payment method. Integrators do not choose a
renderer by provider name. `MeldOrder.headlessPresentation` exposes valid metadata, including values
this binary does not implement; capability inspection and mounting use the same registry.

| Protocol v1 | Method | Surface |
| --- | --- | --- |
| `MERCURYO_WIDGET` | `CREDIT_DEBIT_CARD` | `EMBEDDED_WIDGET` |
| `UPHOLD_WIDGET` | `CREDIT_DEBIT_CARD` | `EMBEDDED_WIDGET` |
| `BANXA_CHECKOUT` | `CREDIT_DEBIT_CARD` | `VENDOR_SDK` |
| `BANXA_CHECKOUT` | `APPLE_PAY` | `VENDOR_SDK` |
| `MELD_WALLET_TOKEN` | `APPLE_PAY` | `NATIVE_TOKEN` |
| `COINBASE_APPLE_PAY` | `APPLE_PAY` | `PROVIDER_HOSTED` |
| `STRIPE_CRYPTO_ONRAMP` | `APPLE_PAY` | `NATIVE_SDK` |
| `STRIPE_CRYPTO_ONRAMP` | `CREDIT_DEBIT_CARD` | `NATIVE_SDK` |

Unknown versions, mismatched surfaces/methods, invalid descriptors and unsupported payloads return
`surface == "unsupported"`; mounting throws before starting a payment surface. A present but invalid
descriptor never selects a legacy adapter. Orders without the descriptor keep the existing compatibility
path, including stored responses from older servers. Do not create a new order or replace its idempotency
key to obtain new metadata.

Mercuryo native wallet orders use the generic action transport and durable attempt/verification
lifecycle described above. Declared `STRIPE_CRYPTO_ONRAMP` orders use the native SDK adapter for
Apple Pay or card. An unsupported Stripe descriptor is never sent to the native-wallet adapter.
React Native consumers need a release containing this change and a matching native dependency
update; an OTA JavaScript update alone cannot change the native resolver.

### Provider-hosted Apple Pay

Mount a `COINBASE_APPLE_PAY` order the same way as the other Apple Pay protocols: `into:` is
optional and `applePay:` is accepted and ignored. It needs iOS 16 or later. Below that,
capabilities report `surface == "unsupported"` and `mount` throws `MeldMountError.unsupported`.
On a device that cannot make Apple Pay payments, `mount` returns a handle, loads nothing, and then
delivers `onError(APPLE_PAY_UNAVAILABLE)`, as Mercuryo does.

The SDK loads the provider's page in an invisible container over the top view controller and clicks
the page's Apple Pay button, so the system sheet is the only thing the customer sees. Each attempt
is a separate click, every 250 ms, up to 20 times. `onReady` fires on the click. `mount` throws
`MeldMountError.presentationUnavailable` when no visible view controller can anchor the container.
If you pass a host and it leaves its window before a terminal callback, the surface ends with no
callback, as if you had released the handle.

Every error from this surface is non-recoverable, and the SDK tears the page down after it. The
provider's event and code travel in `detail`, for example
`onramp_api.load_error:ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED`.

| Provider signal | Callback |
|---|---|
| `commit_success` or `polling_start` | `onStatusChange(pending)`, then `onPaymentSubmitted` |
| `cancel` before submission | `onCancel` |
| the device cannot make Apple Pay payments | `onError(APPLE_PAY_UNAVAILABLE)` after `mount` returns |
| `ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED` or `_NOT_SETUP` | `onError(APPLE_PAY_UNAVAILABLE)` |
| `ERROR_CODE_INIT` | `onError(ORDER_STATE_CHANGED)` |
| `commit_error` | `onError(PAYMENT_REJECTED)` |
| any other provider error, a page load failure or crash before the click, no `load_success` within 20 s, or no button | `onError(PRESENTATION_FAILED)` |
| no page event and no app deactivation within 8 s of the click | `onError(PRESENTATION_FAILED)` |
| `polling_error` before submission, a page load failure or crash after the click, or no outcome after 180 s of active time since the click | `onError(PAYMENT_OUTCOME_UNKNOWN)` |

Time the sheet holds your app inactive does not count toward the 180 s. After
`onPaymentSubmitted` the provider's page keeps confirming the payment. If you release the handle
then, the SDK keeps the page running until the provider reports its polling outcome or 60 s pass.
That outcome is logged, not delivered, so unmounting on `onPaymentSubmitted` is safe.

### Public calls

- `Meld.configure(environment:)` — `.sandbox`, `.qa` or `.production`; action origins must match it.
- `Meld.capabilities(for:)` → `{ embeddable, surface, requiresUserGesture }` — decline `unsupported`;
  `embeddable` tells you whether to supply a visible host view. Native sheets are not embeddable, and
  `native-applepay` means the SDK presents the payment UI itself.
- `Meld.mount(order, into:, applePay:, handlers:)` → `MeldWidgetHandle` — mounts the order's
  surface and relays its events. Pass `into:` a `UIView` for an embedded widget, or `applePay:` a
  `MeldApplePayRequest` for a native wallet order (provider-hosted Apple Pay needs neither);
  `handle.unmount()` tears it down (removes the widget or dismisses the sheet). Retain the handle
  while the payment UI is in use; releasing it also unmounts the session. See
  [Native Apple Pay](#native-apple-pay).
- `Meld.canPresentApplePay()` → `Bool` — whether Apple Pay is usable on this device/user now: payments
  aren't restricted and Wallet holds a card on a network some Apple Pay provider accepts (Visa,
  Mastercard, American Express, Discover or Maestro). An empty Wallet reports `false`. The check has
  no provider context; a Mercuryo order still reports `APPLE_PAY_UNAVAILABLE` before its sheet when
  Wallet holds no Visa or Mastercard.
- `MeldApplePayRequest` — amount/currency, display label and fallback email; wallet/IP fields
  are required only for historical orders using the legacy endpoint.
- `MeldOrder.from(jsonData:)` / `.from(jsonString:)` — decode your backend's order response.

## Local tests

### Stripe native flow

The Stripe adapter uses the real `StripeCryptoOnramp` 26.11.0 API and a serialized coordinator
lifecycle. It validates the order's SDK configuration, route, action declarations and recovery responses;
rejects late or foreign-session checkout callbacks; and keeps SDK ownership until pending calls and
logout finish. Identity input and SDK credentials are not persisted or returned in diagnostics.

Recovery requires the declared `PREPARE_CUSTOMER_AUTHORIZATION` action and explicit SDK authentication
state in submission reads. The decoder distinguishes initial bootstrap, seamless restoration and renewed
consent, and validates the renewed intent's handle and expiry separately from authentication secrets.
Older responses missing this contract are rejected; they do not authorize a replacement order.

Valid declared orders report `surface == "native-sdk"`. Use the same `Meld.mount` call; the adapter
owns registration, KYC and address forms, identity verification, wallet registration and payment.
Amounts, currency and wallet destination come from the order. Integrators do not route Stripe
callbacks or exchange provider credentials. Registration email is a transient SDK input; the server
still binds consent and completion to the order's customer. Use the email associated with that order.

The controller reads submission state before opening provider UI, preserves an existing session,
and stores only the shared device attempt fence and mutation UUID. Transport retries reuse the same
body and key; each actual checkout callback receives its own pair. A KYC result during checkout
resumes verification and re-quotes the same session. A payment may have been attempted once this
device has claimed the order's submission, or the server has reported an existing session or
submission. An unresolved payment emits `pending`, then `onError(PAYMENT_OUTCOME_UNKNOWN)`; so do
pending verification and Cancel once a payment may have been attempted. Before that, Cancel reports
`onCancel` and pending verification reports `onError(VERIFICATION_PENDING)`. A declined or expired
submission reports `onError(PAYMENT_REJECTED)`. Any other failure reports `PAYMENT_OUTCOME_UNKNOWN`
when a payment may have been attempted, and `PRESENTATION_FAILED` otherwise. Native SDK completion
alone does not emit a completed order. Track that existing order through your backend. Unmount
dismisses owned UI, suppresses late events and clears SDK state after pending work finishes.
Synthetic simulator tests do not establish device/provider payment acceptance; enrolled Stripe
account, trusted app, Apple Pay entitlements and device checks remain required before rollout.

Both package managers pin Stripe to **26.11.0**. SwiftPM uses Stripe's official
[`stripe-ios-spm`](https://github.com/stripe/stripe-ios-spm) repository. The 25.11 package does not expose
the onramp product, even though its CocoaPod does. Par's old direct `@stripe/stripe-react-native:0.64.0`
dependency requires Stripe 25.11 and cannot coexist with this pod pin; remove that old onramp integration
during migration before adopting this SDK release. Document verification also requires the host app's
`NSCameraUsageDescription`; the bridge rejects that operation if the usage description is absent.

### Simulator suite

Use the simulator app host for the full suite, including the real Keychain persistence tests.
An unhosted SwiftPM test process has no app identity and cannot validate Keychain access. The host
is generated outside the repository and uses a synthetic simulator-only signing identity:

```sh
gem install --user-install xcodeproj -v 1.27.0 --no-document # if not already installed with CocoaPods
ruby scripts/generate-test-host.rb /tmp/meld-sdk-test-host
xcodebuild test -project /tmp/meld-sdk-test-host/MeldSDKTests.xcodeproj \
  -scheme MeldSDKHostedTests -destination 'platform=iOS Simulator,name=<installed iPhone>'
```

The wallet action tests use synthetic payloads and mocked HTTP. The existing Banxa WKWebView smoke
tests load Primer's public CDN with an invalid test token; exclude that class with
`-skip-testing:MeldSDKHostedTests/BanxaCardAdapterSmokeTests` for an entirely local test run.
These tests do not authorize real wallets or establish provider/payment acceptance; device acceptance
remains a separate release gate. CocoaPods packaging is checked with
`POD_VERSION=0.0.1 pod lib lint MeldSDK.podspec --allow-warnings`.

## React Native

Building in React Native? Use the
**[@meldcrypto/react-native-sdk](https://github.com/meldeng/meldsdk-react-native)** wrapper — the
same `configure → capabilities → mount → events` flow, exposed as a `<MeldWidget>` component, for
**iOS and Android**. It lives in its own repo with its own README and example app, and consumes
this SDK as its iOS dependency (the `MeldSDK` pod).

### First-time SDK customer registration

Stripe bootstraps may declare `sdkFlow: REGISTER` without a `providerIntentId`. Pass these orders
unchanged to `Meld.mount`; this adapter checks/registers the customer through the provider SDK,
then prepares authorization through the shared action endpoint on the existing order. Registration
is not payment submission or settlement. Existing AUTHORIZE/SEAMLESS bootstraps still require their
real intent identifier. Backend registration-stage support and this SDK change must be released
before enabling the flow; older SDKs reject the new bootstrap. No provider/device acceptance or
package publication is implied by local tests.

If authorization preparation reports `SDK_REGISTER_CUSTOMER` after a positive SDK account check,
the adapter permits one registration on a REGISTER bootstrap and prepares consent again with a new
invocation. It rejects repeated registration instructions and attempts to register during financial
session recovery. No application-side provider routing or new order is required.
