#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
# The OpenCV iOS framework is NOT committed to this repository. Build it on
# macOS with scripts/build_opencv_ios.sh and drop the result at
# ios/opencv2.xcframework before running `pod install`. See
# docs/decisions/0002-opencv-dependency.md.
#
Pod::Spec.new do |s|
  s.name             = 'wechat_qrcode'
  s.version          = '1.0.0'
  s.summary          = 'Flutter wrapper around OpenCV WeChatQRCode for Android and iOS.'
  s.description      = <<-DESC
Wraps OpenCV's cv::wechat_qrcode::WeChatQRCode detector and a camera preview for
use from Flutter. Ships the four CNN model files with the plugin.
                       DESC
  s.homepage         = 'https://github.com/OWNER/REPO'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = { 'WeChatQR project' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  s.source_files        = 'wechat_qrcode/Sources/wechat_qrcode/**/*.{swift,h,mm}'
  s.public_header_files = 'wechat_qrcode/Sources/wechat_qrcode/include/*.h'
  # `.copy` semantics: the `models` directory must survive into the bundle so the
  # plugin can find it by name.
  s.resource_bundles    = {
    'wechat_qrcode' => ['wechat_qrcode/Sources/wechat_qrcode/Resources/models']
  }

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'

  # Minimal OpenCV build: core, imgproc, objdetect, dnn and wechat_qrcode only.
  s.vendored_frameworks = 'opencv2.xcframework'
  s.libraries = 'c++'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # Flutter.framework has no i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
end
