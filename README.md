# Meld SDK — iOS

Embed a crypto on/off-ramp provider's payment widget (Mercuryo card today) into your iOS app
with one uniform call: `Meld.mount(order, into:, handlers:)`. It's the native counterpart to
the web SDK ([`@meldcrypto/sdk`](https://www.npmjs.com/package/@meldcrypto/sdk)), with the
same integration shape and event model.

The SDK is a **container manager and event relay** — it never renders card input, never reads
or transports PAN/CVC, and never reaches into the provider's content. Card capture happens
entirely on the provider's PCI surface.

**Implemented surfaces:** Mercuryo and Uphold card widgets, Banxa card and Apple Pay,
Mercuryo native Apple Pay, and Coinbase-hosted Apple Pay. Use the returned capabilities to check
whether this SDK build can present a particular order. Stripe native crypto onramp supports declared
orders with the action and SDK contracts described below.

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
    onPaymentSubmitted: { _ in showProcessing() },  // ⚠ UX hint — settlement is your webhook, not this
    onStatusChange:     { e in if e.status == .completed { showOrderComplete() } },
    onCancel:           { _ in showRetryCTA() },
    onError:            { e in showError(e.message) }
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

The preflight API belongs to the coordinated, unreleased **0.8** SDK stack. Older releases do not
provide it; use this branch for local integration until that release is published.

## Events

| Event | Fires when | Do |
|---|---|---|
| `onReady` | Widget mounted & interactive | Hide spinner |
| `onPaymentSubmitted` | User finished the provider payment flow — **exactly once per mount** (UX hint only) | Unmount, show "processing" |
| `onStatusChange` | Order status changed; `status` is `pending` \| `completed` \| `failed` \| `cancelled` | React to status; `completed` = provider "order complete" (still not settlement) |
| `onCancel` | User dismissed the payment surface | Keep the existing order; inspect its status before offering another payment |
| `onError` | The flow cannot continue | Show the safe message; `recoverable: false` does not authorize a new order or charge |

`onPaymentSubmitted` fires once and only once, however the provider signals it. Some send a
"payment finished" message and never a status; some send `completed` and never a finished message;
some send both, in either order. The SDK collapses that into one callback, so you do not need a
`settledOnce` guard of your own. A terminal `failed`, `cancelled` or non-recoverable error closes
it, so a failure is never followed by a submission.

`status` is normalized across providers — code against it, not the raw provider string (which
is available in `providerStatus` for logging). A terminal `failed` also fires `onError`, and a
`cancelled` status also fires `onCancel`.

Every callback receives the id of the order it relates to (shown as `_` above where unused), so
an app driving several orders at once can tell them apart.

## Native Apple Pay

For an Apple Pay order declaring `SYSTEM_WALLET_TOKEN / MELD_WALLET_TOKEN` v1, use the
**same `Meld.mount`** as the card widget. The order selects the surface. Pass `applePay:` with
the sheet inputs. Other Apple Pay protocols can require a hosted view or a vendor SDK. `Meld.capabilities(for: order)` reports `surface == "native-applepay"` and
`embeddable == false`.

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
    onPaymentSubmitted: { _ in showProcessing() },  // ⚠ UX hint — settlement is your webhook
    onStatusChange:     { e in if e.status == .completed { showOrderComplete() } },
    onCancel:           { _ in /* user dismissed the sheet */ },
    onError:            { e in showError(e.message) }
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

Shared action failures also expose optional `MeldError.headlessError` (`MeldHeadlessError`):
`version`, typed `category`, typed `recovery`, and `automaticRetryAllowed`. Version 1 always sets
automatic retry to false. The transport accepts only known category/recovery pairs and explicit
read operations for `RETRY_READ`; response prose and unknown fields are discarded. Missing or
invalid metadata becomes `DEPENDENCY_UNAVAILABLE / RETRY_READ` for known reads and
`OUTCOME_UNKNOWN / READ_STATE` for mutations. Local and legacy surface errors can omit this field.

Follow `recovery` through your backend while retaining the original order/attempt: authenticate the
relevant Meld authorization, read requirements, read the existing operation state, explicitly retry
a read, correct a request, or stop. No category proves a payment was never dispatched. Do not
automatically remount, clear attempt history or create a new order. A Meld authentication failure
does not trigger vendor reauthorization. Stripe no longer automatically retries a lost payment or
legal-write response; wallet uncertainty may resolve through one state read, but auth/STOP/
correction/requirements advice reaches the caller directly. This additive callback field requires
the coordinated unreleased 0.8 SDK; it introduces no storage or server migration.

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
| `BANXA_CHECKOUT` | `CREDIT_DEBIT_CARD` | `EMBEDDED_WIDGET` |
| `BANXA_CHECKOUT` | `APPLE_PAY` | `VENDOR_SDK` |
| `MELD_WALLET_TOKEN` | `APPLE_PAY` | `SYSTEM_WALLET_TOKEN` |
| `COINBASE_APPLE_PAY` | `APPLE_PAY` | `PROVIDER_HOSTED` |

Unknown versions, mismatched surfaces/methods, invalid descriptors and unsupported payloads return
`surface == "unsupported"`; mounting throws before starting a payment surface. A present but invalid
descriptor never selects a legacy adapter. Orders without the descriptor keep the existing compatibility
path, including stored responses from older servers. Do not create a new order or replace its idempotency
key to obtain new metadata.

For a provider-hosted surface, keep the host view visible and accessible. The SDK reports `onReady`
when the provider button is ready; it neither hides nor clicks that button. The user must tap it, as
required by [Coinbase's headless integration](https://docs.cdp.coinbase.com/onramp/headless-onramp/overview).
Apps that previously kept the host offscreen must adopt a visible container before updating this SDK.

Mercuryo native wallet orders use the generic action transport and durable attempt/verification
lifecycle described above. Declared `STRIPE_CRYPTO_ONRAMP` orders use the native SDK adapter for
Apple Pay or card. An unsupported Stripe descriptor is never sent to the native-wallet adapter.
React Native consumers need a release containing this change and a matching native dependency
update; an OTA JavaScript update alone cannot change the native resolver.

### Public calls

- `Meld.configure(environment:)` — `.sandbox`, `.qa` or `.production`; action origins must match it.
- `Meld.capabilities(for:)` → `{ embeddable, surface, requiresUserGesture }` — decline `unsupported`;
  `embeddable` tells you whether to supply a visible host view. Native sheets are not embeddable.
- `Meld.mount(order, into:, applePay:, handlers:)` → `MeldWidgetHandle` — mounts the order's
  surface and relays its events. Pass `into:` a `UIView` for an embedded widget, or `applePay:` a
  `MeldApplePayRequest` for an Apple Pay order; `handle.unmount()` tears it down (removes the widget
  or dismisses the sheet). Retain the handle while the payment UI is in use; releasing it also unmounts
  the session. See [Native Apple Pay](#native-apple-pay).
- `Meld.canPresentApplePay()` → `Bool` — whether Apple Pay is usable on this device/user now.
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

Before collecting identity details or an address correction, the SDK reads the configured disclosure
through `READ_LEGAL_DISCLOSURE`, displays its exact text, and records the decision through
`RECORD_LEGAL_EVIDENCE`. It requires a matching durable receipt before opening the form. Existing
acceptance of the current document resumes without another prompt; declined, unavailable, malformed
or failed receipts do not authorize collection. Receipt payloads contain document metadata only.
Unmount fences late reads, presentations and receipt completions. Before dispatch, the SDK retains
an immutable legal decision and receipt UUID in device-only Keychain storage scoped to the order
and requirement. Storage failure prevents dispatch. An uncertain result survives remounts and
shows an explicit **Retry saved decision** action; it cannot be replaced by a different choice.
Retry sends the same metadata/result/key. Only a matching validated receipt resolves the saved
decision. A recovered acceptance then rereads current disclosure, so an older document cannot
authorize collection under a newer one. A recovered decline stops collection.

The journal contains document identifiers, digest, result and UUID only—not disclosure copy,
bearers, URLs or customer details. Cancellation retains it. Corrupt or unavailable storage stops
collection. There is no automatic retry, and integrators must still establish valid order-scoped
authorization before explicitly reopening an existing order. App-level re-entry and authorization
recovery are separate from this SDK journal.

The order must declare both legal actions. Deploy payment's receipt migration, action handlers and
approved disclosure configuration before releasing this SDK to clients. Missing actions reject the
native contract; missing copy stops collection. Integrators keep the same `Meld.mount` entry point
and do not implement a separate disclosure route or form. The receipt is retained by Meld. No legal
copy is bundled, and an old SDK without this gate is not a rollback for a disclosure outage.

The controller reads submission state before opening provider UI, preserves an existing session,
and stores the shared device attempt fence/mutation UUID plus unresolved legal decision metadata. Transport retries reuse the same
body and key; each actual checkout callback receives its own pair. A KYC result during checkout
resumes verification and re-quotes the same session. Pending verification and unresolved payment
emit `pending`; native SDK completion alone does not emit a completed order. Track that existing
order through your backend. Unmount dismisses owned UI, suppresses late events and clears SDK state
after pending work finishes. Synthetic simulator tests do not establish device/provider payment
acceptance; enrolled Stripe account, trusted app, Apple Pay entitlements and device checks remain
required before rollout.

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


### Shared callback recovery

Every newly constructed `MeldError` includes version-1 `headlessError` advice. Errors without
validated action metadata default to `OUTCOME_UNKNOWN / READ_STATE`, independently of the legacy
`recoverable` presentation hint. An expired hosted link reports `STATE_CHANGED / READ_STATE`.
Explicit action advice, including retries of a known read-only operation, is preserved.

Use this shared metadata to choose recovery instead of provider codes or raw messages. Preserve
the existing order and reconcile through its declared action/state protocol. No category or
`recoverable` value authorizes automatic payment replay or a replacement order;
`automaticRetryAllowed` remains false. The optional property and initializer remain source
compatible; callers on older SDKs should apply the same conservative fallback when it is absent.

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
