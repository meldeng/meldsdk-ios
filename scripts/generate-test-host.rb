# Generates an isolated simulator app host for tests that need UIKit or the app's Keychain.
# Usage: ruby scripts/generate-test-host.rb /tmp/meld-sdk-test-host
require 'fileutils'
require 'xcodeproj'

output = File.expand_path(ARGV.fetch(0))
root = File.expand_path('..', __dir__)
FileUtils.mkdir_p(output)
File.write(File.join(output, 'App.swift'), <<~SWIFT)
  import UIKit
  @main final class TestAppDelegate: UIResponder, UIApplicationDelegate {
      var window: UIWindow?
      func application(_ application: UIApplication,
                       didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
          window = UIWindow(frame: UIScreen.main.bounds)
          window?.rootViewController = UIViewController()
          window?.makeKeyAndVisible()
          return true
      }
  }
SWIFT
Xcodeproj::Plist.write_to_path({
  'application-identifier' => 'MELDTEST.io.meld.sdk.testhost',
  'keychain-access-groups' => ['MELDTEST.io.meld.sdk.testhost']
}, File.join(output, 'TestHost.entitlements'))

project = Xcodeproj::Project.new(File.join(output, 'MeldSDKTests.xcodeproj'))
host = project.new_target(:application, 'MeldSDKTestHost', :ios, '15.0')
tests = project.new_target(:unit_test_bundle, 'MeldSDKHostedTests', :ios, '15.0')
[host, tests].each do |target|
  target.build_configurations.each do |config|
    config.build_settings.merge!({
      'SWIFT_VERSION' => '5.9', 'GENERATE_INFOPLIST_FILE' => 'YES',
      'CODE_SIGN_IDENTITY' => '-', 'TARGETED_DEVICE_FAMILY' => '1',
      'PRODUCT_BUNDLE_IDENTIFIER' => "io.meld.sdk.#{target.name.downcase}",
      'ENABLE_TESTABILITY' => 'YES'
    })
  end
end
host.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.meld.sdk.testhost'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'TestHost.entitlements'
  config.build_settings['INFOPLIST_KEY_UILaunchScreen_Generation'] = 'YES'
end
host.add_file_references([project.main_group.new_file('App.swift')])
tests.add_dependency(host)
tests.build_configurations.each do |config|
  config.build_settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/MeldSDKTestHost.app/MeldSDKTestHost'
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end
tests.add_file_references(Dir.glob(File.join(root, 'Tests/MeldSDKTests/*.swift')).sort.map do |path|
  project.main_group.new_file(path)
end)
package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package.relative_path = root
project.root_object.package_references << package
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package
product.product_name = 'MeldSDK'
tests.package_product_dependencies << product
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product
tests.frameworks_build_phase.files << build_file
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(host)
scheme.add_build_target(tests)
scheme.add_test_target(tests)
scheme.test_action.build_configuration = 'Debug'
scheme.save_as(project.path, 'MeldSDKHostedTests', true)
puts project.path
