// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// NOTE: the OpenCV iOS framework is not committed to this repository, so the
// binary target below is declared but the framework must be produced on macOS
// with scripts/build_opencv_ios.sh and placed at ios/opencv2.xcframework first.
// CocoaPods (wechat_qrcode.podspec) is the supported integration path for now;
// see docs/architecture.md.

let package = Package(
    name: "wechat_qrcode",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "wechat-qrcode", targets: ["wechat_qrcode"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "opencv2",
            path: "opencv2.xcframework"
        ),
        .target(
            name: "wechat_qrcode",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "opencv2",
            ],
            path: "Sources/wechat_qrcode",
            exclude: ["PrivacyInfo.xcprivacy"],
            resources: [
                // `.copy` keeps the directory, so the plugin can look the models
                // up by name at runtime.
                .copy("Resources/models"),
            ],
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        )
    ]
)
