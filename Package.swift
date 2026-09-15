// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeldSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MeldSDK", targets: ["MeldSDK"]),
    ],
    dependencies: [
        // Primer, taken directly rather than through Banxa's wrapper.
        //
        // Banxa's iOS SDK turns out to be `Primer.shared.configure` + `showPaymentMethod(_:intent:
        // clientToken:)` plus a delegate bridge; everything else in it is the catalog/quote/order REST
        // API that Meld's backend already owns. Depending on it bought nothing and cost a lot: it is
        // distributed only as a Swift package, so it cannot build for the CocoaPods consumers the
        // React Native wrapper is built on, and its manifest declares swift-tools 6.3, raising the
        // toolchain floor for every integrator. Primer ships on both CocoaPods and SPM at
        // swift-tools 5.3, so going direct removes both problems.
        .package(url: "https://github.com/primer-io/primer-sdk-ios", from: "2.49.0"),
    ],
    targets: [
        .target(
            name: "MeldSDK",
            dependencies: [
                .product(name: "PrimerSDK", package: "primer-sdk-ios"),
            ],
            path: "Sources/MeldSDK",
            // Vendored provider web SDKs (ESM-only upstream), each bundled to a self-contained IIFE
            // and run inside the WebView to mount that provider's capture surface. Both are pinned by
            // SHA-256 in their adapter and fail closed on drift.
            resources: [
                .copy("Resources/uphold-payment-widget.bundle.js"),
                .copy("Resources/banxa-primer-checkout.bundle.js"),
                // Primer ships no theme; without it every var(--primer-*) is undefined and the card
                // form renders unstyled. Extracted from the bundle above and pinned with it.
                .copy("Resources/banxa-primer-theme.css"),
            ]
        ),
        .testTarget(name: "MeldSDKTests", dependencies: ["MeldSDK"], path: "Tests/MeldSDKTests"),
    ]
)
