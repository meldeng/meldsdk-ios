// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MeldSDK",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "MeldSDK", targets: ["MeldSDK"]),
    ],
    targets: [
        .target(name: "MeldSDK", path: "Sources/MeldSDK"),
    ]
)
