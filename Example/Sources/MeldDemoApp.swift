import SwiftUI

// A minimal example app for MeldSDK.
//
// Where to look:
//   • ContentView.swift   — the checkout screen and the SDK touchpoints (configure / capabilities)
//   • Widget.swift        — the actual integration: Meld.mount(...) + event handling
//   • OrderService.swift  — POC-only: creates the order by calling Meld directly. In a real app
//                           your backend does this so the API key never ships in the app.
@main
struct MeldDemoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
