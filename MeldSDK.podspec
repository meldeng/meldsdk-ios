Pod::Spec.new do |s|
  s.name             = 'MeldSDK'
  s.version          = '0.1.1'
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
  s.frameworks       = 'UIKit', 'WebKit', 'PassKit', 'Contacts'
end
