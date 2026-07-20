// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeldSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MeldSDK", targets: ["MeldSDK"]),
    ],
    targets: [
        .target(
            name: "MeldSDK",
            path: "Sources/MeldSDK",
            // Vendored Uphold Enterprise Payment Widget web SDK (ESM-only upstream), bundled to a
            // self-contained IIFE and run inside the WebView to mount the Uphold card widget.
            resources: [.copy("Resources/uphold-payment-widget.bundle.js")]
        ),
    ]
)
