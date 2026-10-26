# Meld SDK — iOS

Embed a crypto on/off-ramp provider's payment widget (Mercuryo card today) into your iOS app
with one uniform call: `Meld.mount(order, into:, handlers:)`. It's the native counterpart to
the web SDK ([`@meldcrypto/sdk`](https://www.npmjs.com/package/@meldcrypto/sdk)), with the
same integration shape and event model.

The SDK is a **container manager and event relay** — it never renders card input, never reads
or transports PAN/CVC, and never reaches into the provider's content. Card capture happens
entirely on the provider's PCI surface.

**Implemented surfaces:** Mercuryo and Uphold card widgets, Banxa card and Apple Pay,
Mercuryo native Apple Pay, Coinbase-hosted Apple Pay, the Stripe crypto onramp (Apple Pay and
card), and Coinme card. Use the returned capabilities to check whether this SDK build can present a
particular order.

> **Building in React Native?** You don't use this Swift API directly — use the
> [@meldcrypto/react-native-sdk](https://github.com/meldeng/meldsdk-react-native) wrapper
> (iOS + Android). See [React Native](#react-native) below.

## Installation

**Swift Package Manager.** In Xcode: **File → Add Package Dependencies…**, paste the repo URL,
and add the **MeldSDK** library to your app target. Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/meldeng/meldsdk-ios", from: "0.11.0"),
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
pod 'MeldSDK', '~> 0.11.0'
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

// Keep `handle` while the payment UI is up; releasing it unmounts.
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
Keep checking requirements and [device readiness](#readiness-before-you-create-an-order), then validate the actual order with
`Meld.capabilities(for: order)` before mounting it. `embeddable` only indicates whether a visible
host is needed; native sheets can be supported with `embeddable == false`. Never invent a
presentation from a provider name or fabricate an order for preflight.

Branch only on `embeddable` and on `surface == "unsupported"`. Every other `surface` value
(`embedded`, `native-applepay`, `native-sdk`) is informational: it names what the provider exposes,
the same payment method reports different values across providers, Android reports its own values
(`native-wallet` for hosted Google Pay), and later releases may add more. Log it; do not switch on it.

The preflight API is available from 0.8.0. Older releases do not provide it.

## Readiness before you create an order

Two advisory checks answer `.ready`, `.unavailable(code:reason:)` or `.unknown(reason:)`, and mean the
same on iOS, Android, React Native and the web:

- **Before you quote**, `Meld.paymentMethodReadiness(paymentMethodType)` asks whether this device can pay
  with a method at all, for example to decide whether to show an Apple Pay entry point.
- **After you quote**, `Meld.presentationReadiness(presentation, paymentMethodType:)` asks about one quote
  row, through the provider that row would use.

`reason` is written for developers, not customers. The common answers are worded the same on every SDK,
apart from the platform's name: `This payment method has no device check; offer it and let the payment
decide.`, `Google Pay is not available on iOS.` and `Apple Pay has no usable card on this device.`

Each has an `async` form, which resumes on the caller's executor, and a completion form, such as
`Meld.paymentMethodReadiness("APPLE_PAY") { readiness in … }`. Only the completion form delivers on the
main queue: once, after the call returns.

### Before you quote

```swift
switch await Meld.paymentMethodReadiness("APPLE_PAY") {
case .ready, .unknown: showApplePayEntry()
case .unavailable: hideApplePayEntry()  // code is PAYMENT_METHOD_UNAVAILABLE
}
```

- **`APPLE_PAY`** asks PassKit once: payments must not be restricted, and Wallet must hold a card on a
  network one of this SDK's Apple Pay presentations takes (Visa, Mastercard, American Express, Discover
  or Maestro, plus any your app adds to `StripeAPI.additionalEnabledApplePayNetworks`). It answers
  `.ready` or `.unavailable`.
- **`GOOGLE_PAY`** answers `.unavailable`: there is no Google Pay on iOS.
- **Any other method**, such as `CREDIT_DEBIT_CARD` or a bank transfer, answers `.unknown`: the SDK has
  nothing on the device to check for it.

`.ready` here does not mean every provider takes the customer's card (Mercuryo takes only Visa and
Mastercard), so ask about the quote row too.

### After you quote

Pass the row's `headlessPresentation` and `paymentMethodType`
(`POST /payments/crypto/quote?integrationMode=HEADLESS`):

```swift
guard let presentation = MeldHeadlessPresentation(json: presentationJSON) else { return hide(row) }

switch await Meld.presentationReadiness(presentation, paymentMethodType: paymentMethodType) {
case .ready: offer(row)
case .unknown: offer(row)     // could not tell; the payment has the final word
case .unavailable: hide(row)  // code is PAYMENT_METHOD_UNAVAILABLE
}
```

- **`.ready`:** offer the method. Apple Pay through Mercuryo or Stripe answers `.ready` when
  payments aren't restricted and Wallet holds a card on a network that provider's sheet asks for:
  Visa or Mastercard for Mercuryo; Visa, Mastercard, American Express, Discover or Maestro for
  Stripe, plus any your app adds to `StripeAPI.additionalEnabledApplePayNetworks`.
- **`.unavailable(code:reason:)`:** hide the method. `code` is `PAYMENT_METHOD_UNAVAILABLE`. This
  SDK does not register the row's presentation, cannot present it on this device (provider-hosted
  Apple Pay below iOS 16), the device cannot make Apple Pay payments, or Wallet holds no card on a
  network the provider takes. No order exists, so there is nothing to track.
- **`.unknown(reason:)`:** the SDK could not tell. You may offer the method. Card methods answer
  `.unknown` because the SDK has nothing on the device to check for them. So do Banxa and
  provider-hosted Apple Pay once Wallet holds a card on one of the networks above, because the
  provider's own merchant account decides which cards it takes. The SDK logs the reason under the
  `io.meld.sdk` subsystem, category `Readiness`.

Readiness is advisory. If you create the order anyway, the mounted payment still reports `onError`
with `PAYMENT_METHOD_UNAVAILABLE` when it cannot pay, and that is the final word. Readiness is
available from 0.10.0.

`Meld.canPresentApplePay()` was removed in 0.10.0. `Meld.paymentMethodReadiness("APPLE_PAY")` makes the
same device-and-Wallet check, and the row's readiness knows the provider.

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
widgets normalize the failures in the table below and keep the provider's own code for the rest. The
provider's own event and code, when there is one, travel in `detail` (for example
`banxa_apple_pay_failed:<Primer errorId>`).

| `code` | Can an attempt exist? | Do |
|---|---|---|
| `PAYMENT_METHOD_UNAVAILABLE` | No | This device or customer cannot pay with the order's method; offer another |
| `PRESENTATION_FAILED` | No | Return to your CTA; the next tap creates a new order |
| `PAYMENT_REJECTED` | No (declined) | Offer another payment option |
| `ORDER_STATE_CHANGED` | No | Create a new order |
| `VERIFICATION_PENDING` | No | Tell the customer the provider is reviewing their verification |
| `PAYMENT_OUTCOME_UNKNOWN` | Yes | Track the existing order; never pay it again |
| `PROVIDER_LOAD_FAILED` | Yes | The provider's page did not load. With `recoverable: true` the surface stays up and the customer may carry on; otherwise track the existing order |

These seven codes, and whether each can follow an attempt, are the same in every Meld SDK. They are
public constants on `MeldErrorCode`, for example `MeldErrorCode.paymentOutcomeUnknown`.
`error.attemptMayExist` (or `MeldErrorCode.attemptMayExist(error.code)`) is `false` only for the five codes
above that say no attempt exists, and `true` for every other code, including codes this build does not know.

`error.paymentMethodType` is the mounted order's `paymentMethodType`, for example `APPLE_PAY`, so you can
say "Apple Pay isn't available" without branching on `code`. It is nil when the order has none. Available
from 0.10.0.

Releases before 0.10.0 reported `APPLE_PAY_UNAVAILABLE` where this one reports `PAYMENT_METHOD_UNAVAILABLE`.
0.10.0 removes it: `MeldErrorCode.applePayUnavailable` is gone, and `attemptMayExist` treats the old code like
any other code this build does not know.

Releases before 0.10.0 reported `NAVIGATION_FAILED` when the provider's page failed after it had started
loading. 0.10.0 reports `PROVIDER_LOAD_FAILED` with `recoverable: false` there instead.

A wallet payment that fails before anything is sent reports `PRESENTATION_FAILED`, with the reason in
`detail`. Releases before 0.10.0 reported these reasons as their own codes:

| `detail` | Cause |
|---|---|
| `EMPTY_APPLE_PAY_TOKEN` | PassKit returned an empty token, as the Simulator does |
| `MISSING_BILLING_NAME` | PassKit returned no cardholder first and last name |
| `PAYMENT_NOT_SUBMITTED` | The payment details failed validation, or the device could not record the submission |
| `PAYMENT_CONTINUATION_UNAVAILABLE` | The order allows a new payment, but its sheet could not be built, for example without a valid `MeldApplePayRequest` |

If the device already holds a submission claim for the order, the SDK reports
`PAYMENT_OUTCOME_UNKNOWN` (`detail` `submission_already_claimed`) instead.

The Banxa and Uphold card widgets run a provider SDK bundled with this one inside the web view. When
that page fails before the widget shows, they report:

| Failure | `code` | `detail` |
|---|---|---|
| The provider SDK did not load (`sdk_unavailable`) | `PROVIDER_LOAD_FAILED` | `banxa_card_failed:sdk_unavailable` or `uphold_card_failed:sdk_unavailable` |
| Mounting the widget threw (`mount_failed`) | `PRESENTATION_FAILED` | `banxa_card_failed:mount_failed` or `uphold_card_failed:mount_failed` |
| Primer refused the Banxa client token (`checkout_init_failed`) | `PRESENTATION_FAILED` | `banxa_card_failed:checkout_init_failed` |

Releases before 0.10.0 reported Banxa's `sdk_unavailable` as `PRESENTATION_FAILED`, and Uphold's
`sdk_unavailable` and `mount_failed` as their own codes.

Banxa Apple Pay reports Primer's outcomes as follows. Primer creates the payment after the customer
authorizes, so a failure once the sheet is requested can follow a payment that exists:

| Primer outcome | Callback |
|---|---|
| Checkout completed | `onPaymentSubmitted` |
| `payment-cancelled`, or the sheet dismissed | `onCancel` |
| Any failure before the sheet is requested, or neither Primer reporting the sheet shown nor an app deactivation within 8 s of the request | `onError(PRESENTATION_FAILED)` |
| `apple-pay-device-not-supported` or `apple-pay-no-cards-in-wallet` | `onError(PAYMENT_METHOD_UNAVAILABLE)` |
| `unable-to-present-apple-pay`, `apple-pay-presentation-failed` or `apple-pay-configuration-error` | `onError(PRESENTATION_FAILED)` |
| `payment-failed` with payment status `FAILED` | `onError(PAYMENT_REJECTED)` |
| Any other failure after the sheet is requested | `onError(PAYMENT_OUTCOME_UNKNOWN)` |

#### Codes only this SDK reports

Each of these may follow a payment, so `attemptMayExist` is `true` for all of them: track the order
through your backend and never pay it again.

| `code` | Reported when |
|---|---|
| `PAYMENT_STATE_UNAVAILABLE` | Mercuryo Apple Pay could not read the order's payment state before the sheet |
| `PAYMENT_CONTINUATION_UNAVAILABLE` | Mercuryo Apple Pay could not continue the existing order on this device |
| `INVALID_VERIFICATION` | The provider's verification response cannot be presented |
| `VERIFICATION_WINDOW_EXPIRED` | The verification window closed |
| `VERIFICATION_UNAVAILABLE` | The device could not record that verification was opened |
| `WAIT_FOR_PAYMENT` | Verification was already opened for this order |
| `PAYMENT_NOT_ACCEPTED` | The legacy Mercuryo Apple Pay endpoint did not accept the payment |
| `authorize_session_failed`, `authorize_session_invalid` | The Uphold card widget could not start its authorization step |
| The provider's own status or code | A card widget (Mercuryo, Uphold) or the legacy Mercuryo endpoint reported a failure in its own terms |

After a successful create, treat any code you do not know as "an attempt may exist": track the order
through your backend and never pay it again. `attemptMayExist` applies that rule. It is meant for
terminal errors; a `recoverable: true` error such as `PROVIDER_LOAD_FAILED` leaves the surface up.

## Native Apple Pay

For an Apple Pay order declaring `NATIVE_TOKEN / MELD_WALLET_TOKEN` v1, use the
**same `Meld.mount`** as the card widget. The order selects the surface. Pass `applePay:` with
the sheet inputs. `Meld.capabilities(for: order)` reports `surface == "native-applepay"` and
`embeddable == false`, as it does for Banxa and provider-hosted Apple Pay. `native-applepay` means
the SDK presents the payment UI and your host needs no visible view.

The order carries the `merchantIdentifier`, `sessionToken`, and `merchantTransactionId`. You supply
the amount and currency from the quote used to create that order, a display label, and a fallback
email. The sheet asks the customer for an email as a contact field, because PassKit never returns one
on the billing contact; your `email` is used only when PassKit returns none. The new action contract
uses the order's server-bound destination wallet and client IP; those values are not sent again by the SDK:

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

Call mounting and teardown on the main thread. [Readiness](#readiness-before-you-create-an-order) can
gate offering a new wallet payment; it must not prevent recovery of an existing submitted or
verification-required order.
For those states, the SDK reads the existing attempt without needing a new wallet sheet or request.

The event model is identical to the card flow (see [Events](#events)) — `onReady` /
`onPaymentSubmitted` / `onStatusChange` / `onCancel` / `onError`, with the same normalized `status`.
The SDK reads `READ_SUBMISSION` before presenting PassKit. Only `NOT_STARTED / NONE` with no
local attempt permits a new sheet. It sends the encrypted token and billing details through
`SUBMIT_WALLET_PAYMENT`, using the order's declared endpoint and scoped bearer. No integrator API
key reaches the SDK. A lost, malformed or unrecognized submission response triggers a read, never a second
submission. A status or next step this build does not know counts as unresolved and ends in
`onError(PAYMENT_OUTCOME_UNKNOWN)`. PassKit reports failure only when the server says the payment failed,
expired or never started, or gives no readable answer.

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
`MeldApplePayRequest`. On a device that cannot pay, they report `onError(PAYMENT_METHOD_UNAVAILABLE)`
after `mount` returns, as declared orders do. Ambiguous legacy outcomes are not retried. A declared
wallet protocol requires a valid `paymentActions` descriptor and never falls back to that endpoint.

**Prerequisites (one-time, in your Apple Developer account):**

- An **Apple Pay merchant identifier** (`merchant.…`) and the **Apple Pay Payment Processing** +
  **Merchant Identity** certificates registered with Meld for your account. Meld resolves your
  per-account merchant id server-side and returns it on the order as `merchantIdentifier`; if it's
  absent, the account isn't configured for Apple Pay and `mount` throws `MeldMountError.invalidOrder`.
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

### Stripe native onramp

The SDK shows nothing of its own until it needs the customer. Keep your own busy state (for example a
spinner on the button that started the purchase) until a terminal callback, and block anything that would
unmount the session or start another order meanwhile: between screens nothing of the SDK's covers yours,
and an unmount reports no outcome. Forms present over your
top-most view controller, one sheet at a time; a submitted form stays up with a spinner in its button
until the next form replaces it or a Stripe screen (Link sign-in code, identity verification, Apple Pay,
checkout) takes over. The customer cancels from any form, busy or not, or from a Stripe screen. That
delivers `onCancel`, or `onStatusChange(pending)` and `onError(PAYMENT_OUTCOME_UNKNOWN)` when a payment
may already exist. The SDK dismisses its own screens before any terminal callback, so anything you present
from one stays up. `unmount()` dismisses whatever the SDK or Stripe presented and delivers no callback.

The server's `READ_SUBMISSION` answer can carry `sdk.prefill`. Its `email` is the one Meld authorizes
with Link, so the SDK uses it instead of asking. A verified `phone` registers a new Link account
without a form, and `identity` (name, date of birth, US address, and the SSN when the customer's KYC holds
a US one) fills Stripe's KYC requests, each value sent at most once, leaving only the fields it does not
cover. If Stripe rejects that submission
the full form is shown. Without `prefill` the SDK asks for everything, as before.

Stripe's KYC confirm screen is skipped for customers verified only at L0; a server that reports no tier
keeps the confirm screen. Before payment the SDK checks
the customer's limits and, when the order is over them, asks an L0 customer for date of birth and SSN
(each prefilled when available, otherwise typed) or runs Stripe's document check for an L1
customer. Limits that cannot be read never block the purchase.

### Provider-hosted Apple Pay

Mount a `COINBASE_APPLE_PAY` order the same way as the other Apple Pay protocols: `into:` is
optional and `applePay:` is accepted and ignored. It needs iOS 16 or later. Below that,
capabilities report `surface == "unsupported"` and `mount` throws `MeldMountError.unsupported`.
On a device that cannot make Apple Pay payments, `mount` returns a handle, loads nothing, and then
delivers `onError(PAYMENT_METHOD_UNAVAILABLE)`, as Mercuryo does.

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
| the device cannot make Apple Pay payments | `onError(PAYMENT_METHOD_UNAVAILABLE)` after `mount` returns |
| `ERROR_CODE_GUEST_APPLE_PAY_NOT_SUPPORTED` or `_NOT_SETUP` | `onError(PAYMENT_METHOD_UNAVAILABLE)` |
| `ERROR_CODE_INIT` | `onError(ORDER_STATE_CHANGED)` |
| `commit_error` | `onError(PAYMENT_REJECTED)` |
| any other provider error, a page load failure or crash before the click, no `load_success` within 20 s, or no button | `onError(PRESENTATION_FAILED)` |
| no page event and no app deactivation within 8 s of the click | `onError(PRESENTATION_FAILED)` |
| `polling_error` before submission, a page load failure or crash after the click, or no outcome after 180 s of active time since the click | `onError(PAYMENT_OUTCOME_UNKNOWN)` |

Time the sheet holds your app inactive does not count toward the 180 s. After
`onPaymentSubmitted` the provider's page keeps confirming the payment. If you release the handle
then, the SDK keeps the page running until the provider reports its polling outcome or 60 s pass.
That outcome is logged, not delivered, so unmounting on `onPaymentSubmitted` is safe.

### Coinme card

A `COINME_VAULT` order (`VENDOR_SDK / COINME_VAULT / 1`, `CREDIT_DEBIT_CARD`) runs Coinme's checkout in a
WKWebView inside the view you pass as `into:`, the way Banxa's card checkout runs: the bundled Meld web
SDK shows the customer's saved Coinme cards and "Use a new card", Coinme's secure card fields (VGS
iframes, so card data never reaches this SDK or your app) and Coinme's Risk session. No Coinme library is
added to your app. `Meld.capabilities(for: order)` reports `surface == "embedded"` only when the order
declares both `CREATE_CUSTOMER_AUTH_TOKEN` and `CREATE_PAYMENT_SESSION` and its Coinme environment matches
`Meld.configure` (`live` with `.production`, `sandbox` otherwise); `mount` throws
`MeldMountError.missingHost` without a host. The checkout's payment actions go through the SDK to the
order's own endpoint with the order's bearer.

| Outcome | Callback |
|---|---|
| Payment created | `onPaymentSubmitted` |
| Coinme refused the card (for example in use by another customer, or too many cards) or the payment | `onError(PAYMENT_REJECTED)` |
| A newly added card was still being verified after 3 minutes | `onError(VERIFICATION_PENDING)` |
| The order can no longer be paid | `onError(ORDER_STATE_CHANGED)` |
| Coinme's checkout or service could not be reached | `onError(PROVIDER_LOAD_FAILED)` |
| Any other failure before the payment was requested | `onError(PRESENTATION_FAILED)` |
| No readable answer once the payment was requested | `onError(PAYMENT_OUTCOME_UNKNOWN)` |

Coinme's Risk SDK collects device and behavioral signals in the checkout page for fraud prevention: in
App Store Connect > App Privacy, declare **Identifiers > Device ID**, purpose App Functionality, linked to
the user's identity, and link Coinme's privacy policy from your app's privacy policy.

### Public calls

- `Meld.configure(environment:)` — `.sandbox`, `.qa` or `.production`; action origins must match it.
- `Meld.capabilities(for:)` → `{ embeddable, surface, requiresUserGesture }` — decline `unsupported`;
  `embeddable` tells you whether to supply a visible host view. Native sheets are not embeddable, and
  `native-applepay` means the SDK presents the payment UI itself. Any `surface` other than
  `unsupported` is informational.
- `Meld.mount(order, into:, applePay:, handlers:)` → `MeldWidgetHandle` — mounts the order's
  surface and relays its events. Pass `into:` a `UIView` for an embedded widget, or `applePay:` a
  `MeldApplePayRequest` for a native wallet order (provider-hosted Apple Pay needs neither);
  `handle.unmount()` tears it down (removes the widget or dismisses the sheet). Hold the handle
  while the payment UI is in use; releasing it unmounts the session with no callback, so the result
  of `mount` is not discardable. See [Native Apple Pay](#native-apple-pay).
- `Meld.paymentMethodReadiness(_:)` → `MeldReadiness` (`async`, resuming on the caller's executor, or
  with a `completion:` delivered on the main queue) — whether this device can pay with a method at all,
  before you quote. See [Readiness](#readiness-before-you-create-an-order).
- `Meld.presentationReadiness(_:paymentMethodType:)` → `MeldReadiness` (`async`, resuming on the
  caller's executor, or with a `completion:` delivered on the main queue) — whether this device can
  pay with a quote row's method before you create the order: `.ready`, `.unavailable(code:reason:)` or
  `.unknown(reason:)`. See [Readiness](#readiness-before-you-create-an-order).
- `MeldApplePayRequest` — amount/currency, display label and fallback email; wallet/IP fields
  are required only for historical orders using the legacy endpoint.
- `MeldMountError` — what `mount` throws for an order it cannot start: `.unsupported`,
  `.missingWidgetURL`, `.missingHost`, `.presentationUnavailable`, or `.invalidOrder` when the order or
  `applePay:` lacks a field its payment method needs. Releases before 0.10.0 threw
  `MeldApplePayError.invalidOrder` for that, and `MeldApplePayError` is gone.
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
submission reports `onError(PAYMENT_REJECTED)`. So does a session create that Meld refuses, although
the device has claimed the submission: `detail` is `create:PROVIDER_REJECTED` for a 422
`PROVIDER_REJECTED` answer to the first attempt, and `create:START_NEW_ORDER` for a `FAILED` answer
with no session whose next step is `START_NEW_ORDER`. A `PROVIDER_REJECTED` that answers the transport
retry reports `PAYMENT_OUTCOME_UNKNOWN`. Any other failure reports `PAYMENT_OUTCOME_UNKNOWN`
when a payment may have been attempted, and `PRESENTATION_FAILED` otherwise. Native SDK completion
alone does not emit a completed order. Track that existing order through your backend. Unmount
dismisses the SDK's sheet and anything Stripe presented over it, suppresses late events and clears SDK
state after pending work finishes. Stripe never resumes some of its sheets once they are dismissed, so the
SDK waits at most 90 s for a Stripe call pending at unmount, then logs out anyway. Until then, another
Stripe mount reports `PRESENTATION_FAILED`.
Synthetic simulator tests do not establish device/provider payment acceptance; enrolled Stripe
account, trusted app, Apple Pay entitlements and device checks remain required before rollout.

Both package managers accept Stripe **26.11.x**, patch releases only (`~> 26.11.0` in CocoaPods,
`.upToNextMinor(from: "26.11.0")` in SwiftPM), because the onramp alpha API changes between minor
releases. SwiftPM uses Stripe's official
[`stripe-ios-spm`](https://github.com/stripe/stripe-ios-spm) repository. The 25.11 package does not expose
the onramp product, even though its CocoaPod does. Par's old direct `@stripe/stripe-react-native:0.64.0`
dependency requires Stripe 25.11 and cannot coexist with this pod range; remove that old onramp integration
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
