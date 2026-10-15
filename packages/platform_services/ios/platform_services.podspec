#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint platform_services.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'platform_services'
  s.version          = '0.0.1'
  s.summary          = 'Native device capabilities for WeChatQR on iOS.'
  s.description      = <<-DESC
Vibration, saving generated QR images to the photo library, and opening the app's
system settings screen. Installing packages is Android-only and reports
"unsupported" here.
                       DESC
  s.homepage         = 'https://github.com/sundys/WechatQR'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'sundys' => 'https://github.com/sundys' }
  s.source           = { :path => '.' }
  s.source_files = 'platform_services/Sources/platform_services/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # Ships the privacy manifest, which declares the required-reason API use
  # (UserDefaults, for settings persistence).
  s.resource_bundles = {
    'platform_services_privacy' => ['platform_services/Sources/platform_services/PrivacyInfo.xcprivacy']
  }
end
