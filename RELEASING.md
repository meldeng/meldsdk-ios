# Releasing

This repo ships the native iOS SDK:

| Package | What | Channel |
|---|---|---|
| **MeldSDK** | native iOS SDK (Swift) | a **git tag** (Swift Package Manager) + **CocoaPods trunk** |

The version lives in `MeldSDK.podspec` (`s.version`). Current: `0.1.1`.

> The React Native wrapper (`@meldcrypto/react-native-sdk`) now lives in its own repo,
> [meldsdk-react-native](https://github.com/meldeng/meldsdk-react-native), and is released from
> there (npm). It depends on a published `MeldSDK` pod, so release this SDK first.

Prerequisites (one-time): `pod trunk register you@meld.io 'Your Name'` (confirm the email link).

---

## Native iOS SDK (`MeldSDK`)

After the PR is merged to `main`:

```bash
git checkout main && git pull
git tag 0.1.1
git push origin 0.1.1
```

- **Swift Package Manager** — that's it. `.package(url: "https://github.com/meldeng/meldsdk-ios", from: "0.1.1")` now resolves (SPM uses the tag; no registry).
- **CocoaPods** — publish the podspec to the public trunk so `pod 'MeldSDK'` resolves by name:

  ```bash
  pod trunk push MeldSDK.podspec
  ```

  The podspec's `source` points at the `0.1.1` tag, so **tag first, then push**. Trunk lints the
  pod by building it. After this, integrators use `pod 'MeldSDK', '~> 0.1.1'` — no git line needed.

## Order & checklist

1. Version is correct in `MeldSDK.podspec` and the README.
2. Merge the PR to `main`.
3. `git tag X.Y.Z && git push origin X.Y.Z` — enables SPM and the podspec's source.
4. `pod trunk push MeldSDK.podspec` — CocoaPods by name.
5. Then release the RN wrapper from [meldsdk-react-native](https://github.com/meldeng/meldsdk-react-native).
6. Smoke-test in a fresh app: SPM resolve and `pod install`.

## Notes

- `pod trunk push` requires the git tag to already exist (the podspec's `source` is that tag).
