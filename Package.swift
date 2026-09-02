// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeldSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MeldSDK", targets: ["MeldSDK"]),
    ],
    dependencies: [
        // Banxa's own iOS SDK, for orders it creates itself (providerOrderCreation = CLIENT). It pulls
        // Primer's SDK transitively, which is what actually presents the card fields and the Apple Pay
        // sheet — so taking this dependency takes Primer's too.
        //
        // NOTE its manifest declares swift-tools-version 6.3, which raises MeldSDK's own toolchain
        // floor for every integrator regardless of whether they use Banxa.
        .package(url: "https://github.com/BanxaOfficial/ios-payment-sdk", from: "1.0.1"),
    ],
    targets: [
        .target(
            name: "MeldSDK",
            dependencies: [
                .product(name: "BanxaPaymentSDK", package: "ios-payment-sdk"),
            ],
            path: "Sources/MeldSDK",
            // Vendored provider web SDKs (ESM-only upstream), each bundled to a self-contained IIFE
            // and run inside the WebView to mount that provider's capture surface. Both are pinned by
            // SHA-256 in their adapter and fail closed on drift.
            resources: [
                .copy("Resources/uphold-payment-widget.bundle.js"),
                .copy("Resources/banxa-primer-checkout.bundle.js"),
            ]
        ),
        .testTarget(name: "MeldSDKTests", dependencies: ["MeldSDK"], path: "Tests/MeldSDKTests"),
    ]
)
