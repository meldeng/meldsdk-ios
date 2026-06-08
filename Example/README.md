# MeldSDK — iOS (SwiftUI) example

A SwiftUI app that runs the full flow: live quote (**You pay** / **You receive**) → editable
wallet → **Buy** → mount the Mercuryo widget, with a status banner + event log and auto-close on
a terminal outcome. Same flow and events as the
[React Native example](../wrappers/react-native/example) and the web demo (in the `meldsdk` repo).

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

## Notes

- **Settlement is the webhook, not a client event.** Treat `completed` / `onPaymentSubmitted` as
  UX hints; mark the order paid only on Meld's `TRANSACTION_STATUS_CHANGED` webhook to your backend.
- **Mercuryo prerequisites:** the customer needs APPROVED Sumsub KYC; KYC uses the camera (a real
  device, not the Simulator); the order's `clientIpAddress` must match the device's egress IP.
