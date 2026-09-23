Pod::Spec.new do |s|
  s.name             = 'MeldSDK'
  # Version is tag-driven in CI (see .github/workflows/release.yml, sets POD_VERSION=<tag>);
  # the literal fallback is only for local `pod lib lint`. SPM ignores this and uses the git tag.
  s.version          = ENV['POD_VERSION'] || '0.2.0'
  s.summary          = 'Embed a crypto on/off-ramp provider widget (Mercuryo card) in your iOS app.'
  s.description      = <<-DESC
    MeldSDK mounts a payment provider's widget into a view you own and relays its lifecycle
    events, with one uniform call: Meld.mount(order, into:, handlers:). It never renders or
    transports card data. This podspec exists alongside Swift Package Manager so the SDK can be
    consumed by CocoaPods-based projects, including the React Native wrapper.
  DESC
  s.homepage         = 'https://github.com/meldeng/meldsdk-ios'
  s.license          = { :type => 'Proprietary', :file => 'LICENSE' }
  s.author           = { 'Meld' => 'support@meld.io' }
  s.source           = { :git => 'https://github.com/meldeng/meldsdk-ios.git', :tag => s.version.to_s }

  s.platform         = :ios, '15.0'
  s.swift_version    = '5.9'

  s.source_files     = 'Sources/MeldSDK/**/*.swift'
  # Vendored Uphold Enterprise Payment Widget web SDK (ESM-only upstream, bundled to an IIFE) run inside
  # the WebView to mount the Uphold card widget. Packaged as a resource bundle so CocoaPods consumers
  # (incl. the React Native wrapper) ship it; loaded via Bundle.meldResources (SPM Bundle.module vs a
  # Bundle(for:)-located MeldSDK.bundle under Pods).
  s.resource_bundles = { 'MeldSDK' => ['Sources/MeldSDK/Resources/*.js', 'Sources/MeldSDK/Resources/*.css'] }
  # PassKit/Contacts: native Apple Pay sheet + billing contact on the shape-1 (encrypted token) path.
  # Primer presents the Banxa Apple Pay sheet and creates the payment from the order's client token.
  # Taken directly rather than through Banxa's wrapper, which is SPM-only and adds nothing we use.
  s.dependency 'PrimerSDK', '~> 2.49'
  s.frameworks       = 'UIKit', 'WebKit', 'PassKit', 'Contacts', 'SafariServices', 'Security', 'CryptoKit'
end
