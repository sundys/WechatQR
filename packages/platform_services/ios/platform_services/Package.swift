// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "platform_services",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "platform-services", targets: ["platform_services"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "platform_services",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Ships the privacy manifest describing this plugin's API use.
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
