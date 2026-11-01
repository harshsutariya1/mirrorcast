// swift-tools-version: 5.9
// MirrorCast macOS engine (the receiver's data plane).

import PackageDescription

let package = Package(
    name: "mirrorcast_engine",
    platforms: [
        .macOS("13.0")
    ],
    products: [
        .library(name: "mirrorcast-engine", targets: ["mirrorcast_engine"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "mirrorcast_engine",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
