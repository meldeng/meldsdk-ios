# @meldcrypto/react-native-sdk

React Native wrapper for the [Meld iOS SDK](https://github.com/meldeng/meldsdk-ios#readme) — embed a crypto on/off-ramp
provider's payment widget (Mercuryo card today) with one component. Same integration shape and
event model as the native SDK, exposed as JS. **iOS only for now.**

## Installation

Add the package, then wire the native pods on iOS:

```bash
npm install @meldcrypto/react-native-sdk
```

The wrapper autolinks, but the native `MeldSDK` pod isn't an RN module (so isn't autolinked) —
add it to your `ios/Podfile`. Install for the **old architecture** with **static frameworks**
(`MeldSDK` is a Swift pod):

```ruby
# Until MeldSDK is on CocoaPods trunk, reference it from GitHub by tag:
pod 'MeldSDK', :git => 'https://github.com/meldeng/meldsdk-ios.git', :tag => '0.1.0'
```
```bash
cd ios && RCT_NEW_ARCH_ENABLED=0 USE_FRAMEWORKS=static pod install
```

## Usage

Your **backend** creates the order (your Meld API key never reaches the app); your app passes the
response to `<MeldWidget>`.

```tsx
import { Meld, MeldWidget } from '@meldcrypto/react-native-sdk';

Meld.configure('sandbox'); // or 'production'

<MeldWidget
  style={{ flex: 1 }}
  order={order}                                  // your backend's order JSON, passed through
  onReady={() => hideSpinner()}
  onPaymentSubmitted={() => showProcessing()}    // ⚠ UX hint — settlement is your webhook
  onStatusChange={(e) => { if (e.status === 'completed') showComplete(); }}
  onCancel={() => showRetryCTA()}
  onError={(e) => showError(e.message)}
/>
```

Optionally guard before rendering: `if ((await Meld.capabilities(order)).embeddable) { … }`
(async on RN since it crosses the native bridge).

## Events

| Event | Fires when | Do |
|---|---|---|
| `onReady` | Widget mounted & interactive | Hide spinner |
| `onPaymentSubmitted` | User finished the provider payment flow (UX hint only) | Show "processing" |
| `onStatusChange` | Order status changed; `e.status` is `pending` \| `completed` \| `failed` \| `cancelled` | React to status; `completed` = provider "order complete" (still not settlement) |
| `onCancel` | User cancelled | Show retry CTA |
| `onError` | Load failure or terminal `failed` status | Show error; `e.recoverable` says retry vs. new order |

`status` is normalized across providers — code against it, not the raw provider string (in
`e.providerStatus`). A terminal `failed` also fires `onError`, and a `cancelled` also fires
`onCancel`. Every callback also receives the `orderId`.

## Settlement — webhook, never the SDK

Neither `onPaymentSubmitted` nor `onStatusChange` with `status === 'completed'` is settlement —
both are client-side UX signals. Mark the order paid only when your backend receives Meld's
`TRANSACTION_STATUS_CHANGED` webhook. Show "processing", not "success", until then.

## Run the example

A complete, runnable demo is checked in at [`example/`](https://github.com/meldeng/meldsdk-ios/tree/main/wrappers/react-native/example) (same flow as the iOS and web
demos). **It's already a full app — don't run `react-native init` inside it** (a second app there
breaks Metro).

**One-time setup** (from `example/`):

```bash
cd example
npm install                                            # installs @meldcrypto/react-native-sdk + RN deps
cp .env.example .env                                   # then add your creds (see Credentials below)
cd ios && RCT_NEW_ARCH_ENABLED=0 USE_FRAMEWORKS=static pod install && cd ..
```

**Run it — start Metro first, in its own terminal, and leave it open**, then build/launch from a
second terminal. (Starting Metro yourself is the reliable way to avoid the *"No script URL
provided"* red screen, which just means the app launched with no packager running.)

```bash
# terminal 1 — from example/ — keep this running
npm start                  # wait for "Dev server ready" on http://localhost:8081
```

```bash
# terminal 2 — from example/
npm run ios                # builds, installs, launches — reuses the Metro from terminal 1
```

Still seeing the red *"No script URL"* screen? Metro wasn't up when the app launched. Confirm
terminal 1 says **"Dev server ready"**, then press **Cmd+R** in the simulator to reload.

Notes:

- **Credentials** — fill `.env` with `MELD_API_KEY`, `MELD_CUSTOMER_ID` (a customer with APPROVED
  Sumsub KYC), and `MELD_API_HOST` (e.g. `api-qa.meld.io`). `.env` is read at **bundle time**, so
  after editing it restart Metro (Ctrl-C, then `npm start --reset-cache`).
- **The pod-install flags are required** on RN 0.80+: old architecture (the classic-bridge
  wrapper) + static frameworks (`MeldSDK` is a Swift pod).
- **Port 8081 busy** from a stale/other Metro? `lsof -ti tcp:8081 | xargs kill -9`, then `npm start`.

More detail in [example/README.md](https://github.com/meldeng/meldsdk-ios/blob/main/wrappers/react-native/example/README.md).
