# MeldSDK — React Native example (iOS)

A React Native app that runs the full flow: live quote (**You pay** / **You receive**) → editable
wallet → **Buy** → mount the Mercuryo widget with `<MeldWidget>`, with a status banner + event log
and auto-close on a terminal outcome. Same flow and events as the
[iOS](../../../Example) and web examples.

> ⚠️ **POC:** the app creates the order by calling Meld **directly**, so the API key sits in the
> app. A real app creates the order on its backend — the SDK never sees the key.

## 1. Credentials

Secrets live in a gitignored `.env` (via `react-native-dotenv`):

```bash
cp .env.example .env      # then edit .env:
#   MELD_API_KEY=...       your sandbox/QA BASIC key
#   MELD_CUSTOMER_ID=...   a customer with APPROVED Sumsub KYC
#   MELD_API_HOST=api-qa.meld.io   (host only; default is api-sb.meld.io)
```

`.env` is read at **bundle time**, so after editing it restart Metro with a clean cache
(`npm start --reset-cache`, or it's picked up on the next `npm run ios`).

## 2. Run

Requires Node, Xcode, and CocoaPods. One-time setup, from this folder:

```bash
npm install                                                  # links the local wrapper (file:..) + RN deps
cd ios && RCT_NEW_ARCH_ENABLED=0 USE_FRAMEWORKS=static pod install && cd ..
```

Then **start Metro in its own terminal and leave it running**, and build/launch from a second
terminal (this is the reliable way to avoid the *"No script URL provided"* red screen — that just
means the app launched with no packager):

```bash
npm start          # terminal 1 — wait for "Dev server ready" on http://localhost:8081
```
```bash
npm run ios        # terminal 2 — builds, installs, launches; reuses the Metro above
```

Still red? Confirm terminal 1 says "Dev server ready", then press **Cmd+R** in the simulator.

Why the flags: the wrapper uses the classic bridge, so build the **old architecture**
(`RCT_NEW_ARCH_ENABLED=0`); `MeldSDK` is a Swift pod, so use **static frameworks**
(`USE_FRAMEWORKS=static`). No publishing needed — the wrapper resolves from the parent folder
(`file:..`) and the native `MeldSDK` from the repo root (`pod 'MeldSDK', :path => '../../../..'`).

## Notes

- **Settlement is the webhook, not a client event.** Treat `completed` / `onPaymentSubmitted` as
  UX hints; mark the order paid only on Meld's `TRANSACTION_STATUS_CHANGED` webhook to your backend.
- **Mercuryo prerequisites:** the customer needs APPROVED Sumsub KYC; KYC uses the camera (a real
  device, not the Simulator); the order's `clientIpAddress` must match the device's egress IP.
