import Foundation

private final class MeldBundleToken {}

extension Bundle {
    /// The bundle that carries MeldSDK's vendored resources, resolved for both build systems:
    /// - Swift Package Manager synthesizes `Bundle.module`.
    /// - CocoaPods packages `s.resource_bundles = { 'MeldSDK' => ... }` into a nested `MeldSDK.bundle`
    ///   located relative to the framework/class bundle (there is no `Bundle.module` under Pods).
    static var meldResources: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        let base = Bundle(for: MeldBundleToken.self)
        if let url = base.url(forResource: "MeldSDK", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return base
        #endif
    }
}
