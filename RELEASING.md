# Releasing

This repo ships two packages from the same source:

| Package | What | Channel |
|---|---|---|
| **MeldSDK** | native iOS SDK (Swift) | a **git tag** (Swift Package Manager) + **CocoaPods trunk** |
| **@meldcrypto/react-native-sdk** | React Native wrapper (iOS-only) | **npm** |

Versions live in `MeldSDK.podspec` (`s.version`) and `wrappers/react-native/package.json`
(`version`, which also drives the wrapper's podspec). **Keep them in sync.** Current: `0.1.0`.

Prerequisites (one-time): `npm login` (npm account on the `@meldcrypto` org) and
`pod trunk register you@meld.io 'Your Name'` (confirm the email link).

---

## 1. Native iOS SDK (`MeldSDK`)

After the PR is merged to `main`:

```bash
git checkout main && git pull
git tag 0.1.0
git push origin 0.1.0
```

- **Swift Package Manager** — that's it. `.package(url: "https://github.com/meldeng/meldsdk-ios", from: "0.1.0")` now resolves (SPM uses the tag; no registry).
- **CocoaPods** — publish the podspec to the public trunk so `pod 'MeldSDK'` resolves by name:

  ```bash
  pod trunk push MeldSDK.podspec
  ```

  The podspec's `source` points at the `0.1.0` tag, so **tag first, then push**. Trunk lints the
  pod by building it. After this, integrators use `pod 'MeldSDK', '~> 0.1.0'` — no git line needed.

## 2. React Native wrapper (`@meldcrypto/react-native-sdk`)

```bash
cd wrappers/react-native
npm publish            # access:public is set in package.json; enter your 2FA OTP
```

Because `MeldSDK` is on CocoaPods trunk (step 1), the wrapper's `pod 'MeldSDK'` dependency
resolves automatically — an RN integrator just runs:

```bash
npm install @meldcrypto/react-native-sdk
cd ios && RCT_NEW_ARCH_ENABLED=0 USE_FRAMEWORKS=static pod install
```

---

## Order & checklist

1. Versions match in `MeldSDK.podspec`, `wrappers/react-native/package.json`, and the READMEs.
2. Merge the PR to `main`.
3. `git tag X.Y.Z && git push origin X.Y.Z` — enables SPM and the podspec's source.
4. `pod trunk push MeldSDK.podspec` — CocoaPods by name.
5. `cd wrappers/react-native && npm publish` — the RN wrapper.
6. Smoke-test in a fresh app: SPM resolve, `pod install`, `npm install`.

## Notes

- `pod trunk push` requires the git tag to already exist (the podspec's `source` is that tag).
- `npm publish` requires `npm login` + a 2FA OTP.
- The wrapper podspec's `source` tag (`rn-X.Y.Z`) is only used if someone consumes the wrapper via
  CocoaPods git directly; npm-installed RN packages autolink from `node_modules` and ignore it.
