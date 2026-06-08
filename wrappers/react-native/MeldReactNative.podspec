require 'json'
package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name         = 'MeldReactNative'
  s.version      = package['version']
  s.summary      = package['description']
  s.homepage     = 'https://github.com/meldeng/meldsdk-ios'
  s.license      = { :type => 'Proprietary' }
  s.author       = { 'Meld' => 'support@meld.io' }
  s.platform     = :ios, '15.0'
  s.swift_version = '5.9'
  s.source       = { :git => 'https://github.com/meldeng/meldsdk-ios.git', :tag => "rn-#{s.version}" }
  s.source_files = 'ios/**/*.{swift,m,h}'

  # The React Native host, and the native Meld SDK this wraps (kept in lockstep).
  s.dependency 'React-Core'
  s.dependency 'MeldSDK', '~> 0.1.0'
end
