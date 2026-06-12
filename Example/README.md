# MeldSDK — iOS (SwiftUI) example

A SwiftUI app that runs the full flow: live quote (**You pay** / **You receive**) → editable
wallet → pick a **Payment Method** → **Buy**, with a status banner + event log and auto-close on a
terminal outcome. Same flow and events as the
[React Native example](https://github.com/meldeng/meldsdk-react-native/tree/main/example) and the web demo (in the `meldsdk` repo).

Both surfaces go through the **same `Meld.mount`** and feed the same event log:

- **Card** → mounts the embedded Mercuryo widget into a view (`Meld.mount(order, into:)`).
- **Apple Pay** → presents the native PassKit sheet (`Meld.mount(order, applePay:)`). See
  [Apple Pay](#apple-pay) for the one-time setup.

> ⚠️ **POC:** the app creates the order by calling Meld **directly**, so the API key sits in the
> app. A real app creates the order on its backend — the SDK never sees the key.

## 1. Credentials

Secrets live in a gitignored `Secrets.xcconfig` (injected via `Info.plist` — the iOS `.env`):

```bash
cd Example
cp Secrets.example.xcconfig Secrets.xcconfig   # then edit it:
#   MELD_API_KEY=...        your sandbox/QA BASIC key
#   MELD_CUSTOMER_ID=...    a customer with APPROVED Sumsub KYC
#   MELD_API_HOST=api-qa.meld.io   (host only, no scheme; default is api-sb.meld.io)
```

## 2. Run

```bash
xcodegen generate && open MeldDemo.xcodeproj   # then Run on an iPhone simulator
```

## Apple Pay

Selecting **Apple Pay** creates an `APPLE_PAY` order and hands it to `Meld.mount(order, applePay:)`,
which builds the `PKPaymentRequest` (merchant id from the order), presents the system sheet, and on
authorization posts the encrypted token to the order's session-scoped process endpoint — relaying
the same `onReady` / `onPaymentSubmitted` / `onStatusChange` / `onCancel` / `onError` events as the
card flow. (Wiring: [`ApplePay.swift`](Sources/ApplePay.swift).)

**Apple Pay is off by default** so the demo signs and runs on a free **Personal Team** — which
*cannot* use the Apple Pay capability (Xcode shows "Personal development teams … do not support the
Apple Pay capability"). The card flow works regardless. With Apple Pay off, selecting it just shows
a friendly "Apple Pay isn't available" message instead of presenting the sheet.

To actually present the Apple Pay sheet you need a **paid Apple Developer account**, then:

1. **Merchant id.** The entitlement ([`MeldDemo.entitlements`](MeldDemo.entitlements)) uses
   `merchant.io.meld` — the id Meld's sandbox "Friendlies"/"Payment→Prod" accounts are configured
   with. Replace it if you target a different account.
2. **Enable it.** Uncomment `CODE_SIGN_ENTITLEMENTS: MeldDemo.entitlements` in
   [`project.yml`](project.yml), enable the **Apple Pay** capability for your team, then
   `xcodegen generate` again.
3. **Run.** On the Simulator (with a Wallet test card) the sheet presents so you can watch the event
   flow — but the Simulator returns an **empty token**, so `/process` ends in
   `EMPTY_APPLE_PAY_TOKEN`. A real transaction needs the real-device flow below.

### Real-device Apple Pay (end-to-end)

Mercuryo's native Apple Pay has **no sandbox / no test token** — a real device is the only way to
get a token that decrypts. What's required:

- **Sign with the team that owns `merchant.io.meld`** (Meld's paid org team — *not* a free Personal
  Team, which can't use the Apple Pay capability), with that merchant id in the entitlement.
- **Payment Processing Certificate** set up with **Mercuryo**: Mercuryo gives you a CSR, you upload
  it to Apple under `merchant.io.meld`, and return the `.cer` to Mercuryo so they can decrypt the
  token. (The Merchant Identity cert is web-validation only — not needed for native.)
- **Backend:** the account behind your `MELD_API_KEY`/customer must be Apple-Pay-configured (e.g.
  the **"Friendlies"** account `merchant.io.meld`), the customer needs APPROVED KYC, and the
  `merchantIdentifier`-on-order change must be deployed (until then this demo injects the id).
- **Device:** a real iPhone with an **App Store Connect sandbox tester** signed in and an
  [Apple sandbox test card](https://developer.apple.com/apple-pay/sandbox-testing/) in Wallet.
- **Corridor:** **not US/GB** — Mercuryo blocks native Apple Pay for US/GB users *and* US/GB-issued
  cards. The demo defaults to a EU corridor (EUR/FR) for this reason; the card networks (Visa/
  Mastercard), 3DS, and the `LT` merchant country are set by the SDK per Mercuryo's spec.

## Notes

- **Settlement is the webhook, not a client event.** Treat `completed` / `onPaymentSubmitted` as
  UX hints; mark the order paid only on Meld's `TRANSACTION_STATUS_CHANGED` webhook to your backend.
- **Mercuryo prerequisites:** the customer needs APPROVED Sumsub KYC; KYC uses the camera (a real
  device, not the Simulator); the order's `clientIpAddress` must match the device's egress IP.
